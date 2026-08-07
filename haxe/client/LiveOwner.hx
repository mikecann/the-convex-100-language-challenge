import haxe.Json;
import haxe.crypto.Base64;
import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

private class OwnerCommand {
  public final kind:String;
  public final id:Null<String>;
  public final generation:Int;
  public final path:Null<String>;
  public final arguments:Dynamic;
  public final ack = new Lock();
  public var result:Dynamic;
  public var error:Null<ConvexError>;

  public function new(kind:String, ?id:String, generation:Int = 0, ?path:String, ?arguments:Dynamic) {
    this.kind = kind;
    this.id = id;
    this.generation = generation;
    this.path = path;
    this.arguments = arguments;
  }
}

private class QueryState {
  public final subscriptionId:String;
  public final generation:Int;
  public final queryId:Int;
  public final path:String;
  public final arguments:Dynamic;
  public final charge:Int;
  public var lastFingerprint:Null<String> = null;
  public var lastWasFailure = false;
  public var rehydrating = true;

  public function new(subscriptionId:String, generation:Int, queryId:Int, path:String, arguments:Dynamic, charge:Int) {
    this.subscriptionId = subscriptionId;
    this.generation = generation;
    this.queryId = queryId;
    this.path = path;
    this.arguments = arguments;
    this.charge = charge;
  }

  public function addModification():Dynamic {
    return {type: "Add", queryId: queryId, udfPath: path, args: [arguments]};
  }
}

private typedef SyncVersion = {
  var querySet:Int;
  var identity:Int;
  var timestamp:String;
}

private typedef StagedUpdate = {
  var state:QueryState;
  var event:Null<LiveEvent>;
  var fingerprint:Null<String>;
  var removed:Bool;
}

/** Sole owner of the WebSocket, remote query-set version, reconnect metadata,
 * and every local subscription lifecycle mutation. */
class LiveOwner {
  static inline var INITIAL_TIMESTAMP = "AAAAAAAAAAA=";
  static inline var MAX_SUBSCRIPTIONS = 64;
  static inline var MAX_RETIRING_QUERIES = 128;
  static inline var MAX_SUBSCRIPTION_BYTES = 8 * 1024 * 1024;
  static inline var SUBSCRIPTION_OVERHEAD = 512;
  static inline var MAX_PENDING_COMMANDS = 128;

  /** Owner commands are bounded by the work they may have to wait behind: at
   * most one in-flight message read, plus one handshake when the command has
   * to build a replacement connection. */
  static inline var COMMAND_DEADLINE = 12.0;

  // Dial and WebSocket handshake each have their own ten-second absolute
  // budget, followed by a bounded replay write. Keep the public wait strictly
  // above that cumulative worst case so a successful late connection cannot
  // leave an unreachable subscription after its caller has timed out.
  static inline var SUBSCRIBE_DEADLINE = 30.0;

  final deployment:DeploymentUrl;
  final clientVersion:String;
  final commands = new Deque<OwnerCommand>();
  final commandMutex = new Mutex();
  final sessionIdentifier:String;
  final buffers = new LiveBuffers();
  final active = new StringMap<QueryState>();
  final byQuery = new IntMap<QueryState>();
  // Query IDs whose Remove has been written but whose QueryRemoved has not yet
  // arrived. A Transition may still mention them, and that is not drift.
  final retiring = new IntMap<Bool>();
  final stopped = new Lock();
  var socket:Null<WebSocketTransport> = null;
  var closed = false;
  var nextQueryId = 0;
  var nextGeneration = 1;
  var activeBytes = 0;
  var pendingCommands = 0;
  var querySetVersion = 0;
  var remoteVersion:SyncVersion = {querySet: 0, identity: 0, timestamp: INITIAL_TIMESTAMP};
  var connectionCount = 0;
  var lastCloseReason = "InitialConnect";
  var maxObservedTimestamp:Null<String> = null;
  var reconnectAt = 0.0;
  var backoff = 0.05;

  public function new(deployment:DeploymentUrl, clientVersion:String) {
    this.deployment = deployment;
    this.clientVersion = clientVersion;
    // One Convex session survives transport reconnects. Regenerating this UUID
    // per socket would make connectionCount and maxObservedTimestamp describe
    // a session the server has never seen before.
    this.sessionIdentifier = createSessionId();
    Thread.create(run);
  }

  public function subscribe(subscriptionId:String, path:String, arguments:Dynamic):LiveSubscription {
    var command = submit(new OwnerCommand("subscribe", subscriptionId, 0, path, arguments), SUBSCRIBE_DEADLINE);
    var state:QueryState = command.result;
    return new LiveSubscription(this, state.subscriptionId, state.generation);
  }

  public function unsubscribe(subscriptionId:String):Void {
    submit(new OwnerCommand("unsubscribe", subscriptionId), COMMAND_DEADLINE);
  }

  public function unsubscribeGeneration(subscriptionId:String, generation:Int):Void {
    submit(new OwnerCommand("unsubscribeGeneration", subscriptionId, generation), COMMAND_DEADLINE);
  }

  public function debugDisconnect():Void {
    submit(new OwnerCommand("debugDisconnect"), SUBSCRIBE_DEADLINE);
  }

  public function next(subscriptionId:String, generation:Int, timeout:Float):LiveEvent {
    return buffers.next(subscriptionId, generation, timeout);
  }

  public function close():Void {
    if (closed) {
      stopped.wait(COMMAND_DEADLINE);
      return;
    }
    try submit(new OwnerCommand("close"), COMMAND_DEADLINE) catch (_:Dynamic) {}
    stopped.wait(COMMAND_DEADLINE);
  }

  function submit(command:OwnerCommand, timeout:Float):OwnerCommand {
    if (closed) throw ConvexError.closed();
    commandMutex.acquire();
    if (closed) {
      commandMutex.release();
      throw ConvexError.closed();
    }
    if (pendingCommands >= MAX_PENDING_COMMANDS) {
      commandMutex.release();
      throw ConvexError.transport("Live command", "owner command capacity exceeded");
    }
    pendingCommands++;
    commands.add(command);
    commandMutex.release();
    if (!command.ack.wait(timeout)) throw ConvexError.transport("Live command", "owner deadline exceeded");
    if (command.error != null) throw command.error;
    return command;
  }

  function run():Void {
    try {
      while (!closed) {
        var command = commands.pop(false);
        if (command != null) {
          releaseCommandSlot();
          handleCommand(command);
          continue;
        }
        if (socket == null && hasActive() && Sys.time() >= reconnectAt) connect();
        var current = socket;
        if (current != null) {
          try {
            var message = current.pollJson(0.02);
            if (message != null) handleMessage(message);
          } catch (error:Dynamic) {
            retire(asConvexError("Live read", error), true);
          }
        } else {
          Sys.sleep(0.005);
        }
      }
    } catch (fatal:Dynamic) {
      publishFailure(asConvexError("Live owner", fatal));
      markClosed();
    }
    if (socket != null) socket.close();
    failPendingCommands();
    for (state in active) buffers.invalidate(state.subscriptionId, state.generation);
    active.clear();
    byQuery.clear();
    retiring.clear();
    activeBytes = 0;
    stopped.release();
  }

  function handleCommand(command:OwnerCommand):Void {
    try {
      switch command.kind {
        case "subscribe":
          var old = active.get(command.id);
          var charge = subscriptionCharge(command.path, command.arguments);
          var projectedCount = activeCount() + (old == null ? 1 : 0);
          var projectedBytes = activeBytes - (old == null ? 0 : old.charge) + charge;
          if (projectedCount > MAX_SUBSCRIPTIONS || projectedBytes > MAX_SUBSCRIPTION_BYTES) {
            throw ConvexError.protocol("Live subscription capacity exceeded");
          }
          if (old != null && socket != null && retiringCount() >= MAX_RETIRING_QUERIES) {
            throw ConvexError.protocol("Live retiring-query capacity exceeded");
          }
          if (nextQueryId == 0x7FFFFFFF || nextGeneration == 0x7FFFFFFF) {
            throw ConvexError.protocol("Live subscription identifiers are exhausted");
          }
          var modifications:Array<Dynamic> = [];
          if (old != null) {
            buffers.invalidate(old.subscriptionId, old.generation);
            active.remove(old.subscriptionId);
            activeBytes -= old.charge;
            retireQuery(old);
            modifications.push({type: "Remove", queryId: old.queryId});
          }
          var state = new QueryState(command.id, nextGeneration++, nextQueryId++, command.path, command.arguments, charge);
          active.set(state.subscriptionId, state);
          activeBytes += charge;
          byQuery.set(state.queryId, state);
          buffers.register(state.subscriptionId, state.generation);
          command.result = state;
          modifications.push(state.addModification());
          if (socket == null) {
            // A fresh connection replays every active query from scratch, so
            // the modifications collected above would be redundant.
            connect();
          } else {
            modify(modifications, "subscribe");
          }
        case "unsubscribe", "unsubscribeGeneration":
          var state = active.get(command.id);
          if (state != null && (command.kind == "unsubscribe" || state.generation == command.generation)) {
            // Invalidate locally before the remote Remove can fail. A stale
            // handle can therefore never receive a later generation's value.
            buffers.invalidate(state.subscriptionId, state.generation);
            active.remove(state.subscriptionId);
            activeBytes -= state.charge;
            retireQuery(state);
            if (socket != null) modify([{type: "Remove", queryId: state.queryId}], "unsubscribe");
            if (!hasActive()) retire(null, false);
          }
        case "debugDisconnect":
          if (socket == null) throw ConvexError.protocol("Live WebSocket has not been started");
          retire(null, false, "DebugDisconnect");
          if (!connect()) throw ConvexError.transport("debugDisconnect", "replacement WebSocket could not be established");
        case "close":
          markClosed();
        default:
          throw ConvexError.protocol('unknown owner command ${command.kind}');
      }
    } catch (error:Dynamic) {
      var converted = asConvexError("Live command", error);
      if (socket != null) retire(converted, true);
      // A subscribe remains locally owned and will be replayed after a failed
      // Add write, so return its handle and surface the transport failure on
      // that subscription instead of stranding an unreachable active query.
      if (command.kind != "subscribe" || command.result == null) command.error = converted;
    }
    command.ack.release();
  }

  function connect():Bool {
    if (!hasActive() || closed) return false;
    try {
      var replacement = new WebSocketTransport(deployment, clientVersion);
      socket = replacement;
      querySetVersion = 0;
      remoteVersion = {querySet: 0, identity: 0, timestamp: INITIAL_TIMESTAMP};
      byQuery.clear();
      retiring.clear();
      for (state in active) {
        state.rehydrating = state.lastFingerprint != null;
        byQuery.set(state.queryId, state);
      }
      var connect:Dynamic = {
        type: "Connect",
        sessionId: sessionIdentifier,
        connectionCount: connectionCount,
        lastCloseReason: lastCloseReason,
        clientTs: 0
      };
      if (maxObservedTimestamp != null) Reflect.setField(connect, "maxObservedTimestamp", maxObservedTimestamp);
      replacement.sendJson(connect);
      var additions:Array<Dynamic> = [];
      for (state in active) additions.push(state.addModification());
      if (additions.length > 0) modify(additions, "connect replay");
      reconnectAt = 0;
      // A complete handshake and replay is a healthy connection. Do not let a
      // later independent failure inherit an old maximum retry delay.
      backoff = 0.05;
      return true;
    } catch (error:Dynamic) {
      var established = socket != null;
      retire(asConvexError("Live connect", error), true);
      if (!established) connectionCount++;
      return false;
    }
  }

  function modify(modifications:Array<Dynamic>, operation:String):Void {
    var current = socket;
    if (current == null) throw ConvexError.transport(operation, "WebSocket is not connected");
    // Haxe's Neko target uses signed 32-bit Int values. Stop before wrapping
    // the query-set version into a negative number that Convex must reject.
    if (querySetVersion == 0x7fffffff) throw ConvexError.protocol("Live query-set version exhausted");
    current.sendJson({type: "ModifyQuerySet", baseVersion: querySetVersion, newVersion: querySetVersion + 1, modifications: modifications});
    querySetVersion++;
  }

  function handleMessage(message:Dynamic):Void {
    var type = JsonTools.requireString(message, "type", "sync message");
    switch type {
      case "Transition":
        handleTransition(message);
        backoff = 0.05;
      case "Ping", "MutationResponse", "ActionResponse":
        backoff = 0.05;
      case "FatalError", "AuthError":
        throw ConvexError.protocol(type + ": " + Std.string(Reflect.field(message, "error")));
      case "TransitionChunk":
        throw ConvexError.protocol("TransitionChunk assembly is deferred by this educational client");
      default:
        throw ConvexError.protocol('unknown sync message $type');
    }
  }

  function handleTransition(message:Dynamic):Void {
    var start = parseVersion(Reflect.field(message, "startVersion"), "Transition.startVersion");
    var end = parseVersion(Reflect.field(message, "endVersion"), "Transition.endVersion");
    if (!sameVersion(start, remoteVersion)) throw ConvexError.protocol("Transition start version did not match local version");
    var raw = Reflect.field(message, "modifications");
    if (!Std.isOfType(raw, Array)) throw ConvexError.protocol("Transition.modifications must be an array");
    var staged:Array<StagedUpdate> = [];
    var completedRemovals:Array<Int> = [];
    var seen = new IntMap<Bool>();
    var startTimestamp = decodeTimestamp(start.timestamp);
    var endTimestamp = decodeTimestamp(end.timestamp);
    if (compareTimestamp(endTimestamp, startTimestamp) < 0) throw ConvexError.protocol("Transition timestamp moved backwards");
    for (item in (cast raw:Array<Dynamic>)) {
      JsonTools.requireObject(item, "Transition modification");
      var queryId = JsonTools.nonNegativeInteger(Reflect.field(item, "queryId"), "Transition modification.queryId");
      if (seen.exists(queryId)) throw ConvexError.protocol('Transition repeated query $queryId');
      seen.set(queryId, true);
      var state = byQuery.get(queryId);
      var kind = JsonTools.requireString(item, "type", "Transition modification");
      if (state == null) {
        // The server is still reporting a query this client has already
        // removed. That is expected in-flight state, not profile drift.
        if (!retiring.exists(queryId)) throw ConvexError.protocol('Transition referenced unknown query $queryId');
        switch kind {
          case "QueryRemoved": completedRemovals.push(queryId);
          case "QueryUpdated", "QueryFailed":
            // A last value for a query this client has stopped observing. It
            // is dropped rather than delivered to a retired generation.
          default: throw ConvexError.protocol('unknown Transition modification $kind');
        }
        continue;
      }
      switch kind {
        case "QueryUpdated":
          if (!Reflect.hasField(item, "value")) throw ConvexError.protocol("QueryUpdated omitted value");
          var logs = JsonTools.optionalStringArray(item, "logLines", "QueryUpdated.logLines");
          var event = new LiveEvent(Reflect.field(item, "value"), null, logs);
          staged.push({state: state, event: event, fingerprint: Json.stringify({value: event.value, logs: logs}), removed: false});
        case "QueryFailed":
          var logs = JsonTools.optionalStringArray(item, "logLines", "QueryFailed.logLines");
          var failure = new ConvexError("FunctionError", JsonTools.requireString(item, "errorMessage", "QueryFailed"), "query", Reflect.field(item, "errorData"), logs);
          staged.push({state: state, event: new LiveEvent(null, failure, logs), fingerprint: Json.stringify({error: failure.message, data: failure.data, logs: logs}), removed: false});
        case "QueryRemoved":
          // A QueryRemoved for a still-active query was not requested by this
          // owner. Accepting it would strand the public subscription locally.
          throw ConvexError.protocol('server removed active query $queryId');
        default:
          throw ConvexError.protocol('unknown Transition modification $kind');
      }
    }

    // Commit protocol state only after the entire transition validates.
    // Validate the timestamp before committing any version or publication.
    remoteVersion = end;
    observeTimestamp(end.timestamp);
    for (queryId in completedRemovals) retiring.remove(queryId);
    for (update in staged) {
      if (update.removed) {
        update.state.lastFingerprint = null;
        byQuery.remove(update.state.queryId);
        retiring.remove(update.state.queryId);
      } else {
        var duplicateHydration = update.state.rehydrating && !update.state.lastWasFailure && update.state.lastFingerprint == update.fingerprint;
        update.state.rehydrating = false;
        update.state.lastFingerprint = update.fingerprint;
        update.state.lastWasFailure = update.event.error != null;
        if (!duplicateHydration && !buffers.add(update.state.subscriptionId, update.state.generation, update.event)) {
          update.state.lastWasFailure = true;
        }
      }
    }
  }

  /** Stop routing a query locally while the server may still mention it. The
   * pending Remove is acknowledged by a later QueryRemoved, or discarded
   * wholesale when the connection is rebuilt. */
  function retireQuery(state:QueryState):Void {
    byQuery.remove(state.queryId);
    if (socket != null) retiring.set(state.queryId, true);
  }

  function retire(error:Null<ConvexError>, reconnect:Bool, ?reason:String):Void {
    var current = socket;
    socket = null;
    if (current != null) {
      current.abort();
      connectionCount++;
    }
    if (error != null) publishFailure(error);
    lastCloseReason = reason != null ? reason : (error == null ? "Closed" : error.message);
    querySetVersion = 0;
    remoteVersion = {querySet: 0, identity: 0, timestamp: INITIAL_TIMESTAMP};
    for (state in active) state.rehydrating = state.lastFingerprint != null;
    if (reconnect && hasActive() && !closed) {
      reconnectAt = Sys.time() + backoff;
      backoff = Math.min(backoff * 2, 2.0);
    }
  }

  function publishFailure(error:ConvexError):Void {
    for (state in active) {
      state.lastWasFailure = true;
      buffers.add(state.subscriptionId, state.generation, new LiveEvent(null, error));
    }
  }

  function observeTimestamp(timestamp:String):Void {
    var candidate = decodeTimestamp(timestamp);
    if (maxObservedTimestamp == null) {
      maxObservedTimestamp = timestamp;
      return;
    }
    var current = decodeTimestamp(maxObservedTimestamp);
    // Convex timestamps are unsigned little-endian values, so comparison runs
    // from the most significant byte without coercing through a 53-bit Float.
    for (offset in 0...8) {
      var index = 7 - offset;
      if (candidate.get(index) == current.get(index)) continue;
      if (candidate.get(index) > current.get(index)) maxObservedTimestamp = timestamp;
      return;
    }
  }

  static function parseVersion(value:Dynamic, label:String):SyncVersion {
    JsonTools.requireObject(value, label);
    return {
      querySet: JsonTools.nonNegativeInteger(Reflect.field(value, "querySet"), label + ".querySet"),
      identity: JsonTools.nonNegativeInteger(Reflect.field(value, "identity"), label + ".identity"),
      timestamp: JsonTools.requireString(value, "ts", label)
    };
  }

  static function sameVersion(left:SyncVersion, right:SyncVersion):Bool {
    return left.querySet == right.querySet && left.identity == right.identity && left.timestamp == right.timestamp;
  }

  static function compareTimestamp(left:Bytes, right:Bytes):Int {
    for (offset in 0...8) {
      var index = 7 - offset;
      if (left.get(index) < right.get(index)) return -1;
      if (left.get(index) > right.get(index)) return 1;
    }
    return 0;
  }

  static function asConvexError(operation:String, error:Dynamic):ConvexError {
    return Std.isOfType(error, ConvexError) ? cast error : ConvexError.transport(operation, Std.string(error));
  }

  static function decodeTimestamp(timestamp:String):Bytes {
    if (!(~/^[A-Za-z0-9+\/]{11}=$/).match(timestamp)) throw ConvexError.protocol("sync timestamp was not canonical base64");
    var decoded:Bytes;
    try decoded = Base64.decode(timestamp) catch (_:Dynamic) throw ConvexError.protocol("sync timestamp was not base64");
    if (decoded.length != 8) throw ConvexError.protocol("sync timestamp was not eight bytes");
    if (Base64.encode(decoded) != timestamp) throw ConvexError.protocol("sync timestamp was not canonical base64");
    return decoded;
  }

  static function createSessionId():String {
    var bytes = WebSocketTransport.secureRandom(16);
    bytes.set(6, (bytes.get(6) & 0x0F) | 0x40);
    bytes.set(8, (bytes.get(8) & 0x3F) | 0x80);
    var output = new StringBuf();
    for (index in 0...bytes.length) {
      if (index == 4 || index == 6 || index == 8 || index == 10) output.add("-");
      output.add(StringTools.hex(bytes.get(index), 2).toLowerCase());
    }
    return output.toString();
  }

  inline function hasActive():Bool {
    return active.iterator().hasNext();
  }

  function releaseCommandSlot():Void {
    commandMutex.acquire();
    pendingCommands--;
    commandMutex.release();
  }

  function markClosed():Void {
    commandMutex.acquire();
    closed = true;
    commandMutex.release();
  }

  function failPendingCommands():Void {
    while (true) {
      var command = commands.pop(false);
      if (command == null) return;
      releaseCommandSlot();
      command.error = ConvexError.closed();
      command.ack.release();
    }
  }

  function activeCount():Int {
    var count = 0;
    for (_ in active) count++;
    return count;
  }

  function retiringCount():Int {
    var count = 0;
    for (_ in retiring) count++;
    return count;
  }

  static function subscriptionCharge(path:String, arguments:Dynamic):Int {
    return haxe.io.Bytes.ofString(path).length + JsonTools.encodedBytes(arguments) + SUBSCRIPTION_OVERHEAD;
  }
}
