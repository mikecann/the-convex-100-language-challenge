import haxe.Json;
import haxe.ds.StringMap;
import haxe.io.Input;
import haxe.io.Output;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Thread;

private class RelayState {
  public final subscription:LiveSubscription;
  public final token:Int;
  public var stopped = false;

  public function new(subscription:LiveSubscription, token:Int) {
    this.subscription = subscription;
    this.token = token;
  }
}

/** Strict NDJSON conformance surface. Test plumbing lives here rather than in
 * the educational client API. */
class Adapter {
  static inline var MAX_COMMAND = 64 * 1024;
  static inline var RELAY_POLL = 0.2;
  static inline var ACCEPT_DEADLINE = 120.0;

  /** The Docker build asserts `neko -version` matches this string, so the
   * reported runtime cannot drift away from the image it ships in. */
  static inline var RUNTIME_VERSION = "Neko 2.3.0";

  final input:Input;
  final events:AdapterOutput;
  final relays = new StringMap<RelayState>();
  var nextToken = 1;
  var client:Null<ConvexClient> = null;

  public function new(input:Input, output:Output, ?socket:Socket) {
    this.input = input;
    events = new AdapterOutput(output, socket);
  }

  public static function main():Void {
    var listen = Sys.getEnv("ADAPTER_LISTEN");
    if (listen == null || listen.length == 0) {
      new Adapter(Sys.stdin(), Sys.stdout()).run();
      return;
    }
    var address = parseListen(listen);
    var server = new Socket();
    server.bind(new Host(address.host), address.port);
    server.listen(1);
    Sys.stderr().writeString('adapter listening on ${address.host}:${address.port}\n');
    Sys.stderr().flush();
    var accepted = acceptOne(server, ACCEPT_DEADLINE);
    server.close();
    if (accepted == null) {
      Sys.stderr().writeString("no controller connected before the accept deadline\n");
      Sys.stderr().flush();
      Sys.exit(1);
      return;
    }
    new Adapter(accepted.input, accepted.output, accepted).run();
    SocketTransport.closeQuietly(accepted);
  }

  /** Wait a bounded time for the single controller connection so a missing
   * controller cannot hang the container indefinitely. Unlike the socket
   * reader, Neko's `accept` reports an expired timeout as the raw runtime
   * value rather than a mapped `haxe.io.Error`, so both forms are treated as
   * "still waiting". */
  static function acceptOne(server:Socket, timeout:Float):Null<Socket> {
    var deadline = Sys.time() + timeout;
    while (Sys.time() < deadline) {
      var left = deadline - Sys.time();
      server.setTimeout(left < 0.5 ? left : 0.5);
      try {
        return server.accept();
      } catch (error:Dynamic) {
        var text = Std.string(error);
        if (text != "Blocking" && text != "Blocked") {
          throw ConvexError.transport("adapter accept", text);
        }
      }
    }
    return null;
  }

  public function run():Void {
    while (true) {
      var record:Null<{line:String, oversized:Bool}> = null;
      try record = readCommandLine() catch (error:Dynamic) {
        emitProtocol(null, Std.string(error));
        break;
      }
      if (record == null) break;
      if (record.oversized) {
        emitProtocol(null, "command exceeded 65536 bytes");
        continue;
      }
      if (!Utf8Text.isValid(haxe.io.Bytes.ofString(record.line))) {
        emitProtocol(null, "command was not valid UTF-8");
        continue;
      }
      try JsonTools.checkJsonShape(haxe.io.Bytes.ofString(record.line), "adapter command JSON") catch (error:ConvexError) {
        emitProtocol(null, error.message);
        continue;
      }
      var command:Dynamic;
      try command = Json.parse(record.line) catch (error:Dynamic) {
        emitProtocol(null, 'invalid JSON: ${Std.string(error)}');
        continue;
      }
      var id:Null<String> = null;
      try {
        id = validOptionalId(command);
        if (handle(validate(command))) break;
      } catch (error:Dynamic) {
        emitFailure(id, null, error);
      }
    }
    stopAll();
    if (client != null) client.close();
    try events.close() catch (_:Dynamic) {}
  }

  function readCommandLine():Null<{line:String, oversized:Bool}> {
    var buffer = new haxe.io.BytesBuffer();
    var oversized = false;
    while (true) {
      var byte:Int;
      try {
        byte = input.readByte();
      } catch (_:haxe.io.Eof) {
        if (buffer.length == 0 && !oversized) return null;
        break;
      } catch (error:haxe.io.Error) {
        // Neko's socket timeout is an ambient, thread-level setting rather
        // than a true per-socket option (see AdapterOutput's writeTcp for the
        // same quirk on the write side): a short poll timeout left over from
        // handling an HTTP call on this thread (SocketTransport's POLL) still
        // governs this controller socket's own read. A `Blocked` here only
        // means the controller has not sent the next command yet - the same
        // benign polling signal SocketTransport already treats as "retry" -
        // so keep waiting instead of tearing down an otherwise idle session.
        if (error == haxe.io.Error.Blocked) continue;
        throw error;
      }
      if (byte == 10) break;
      if (!oversized) {
        if (buffer.length == MAX_COMMAND) {
          oversized = true;
        } else {
          buffer.addByte(byte);
        }
      }
    }
    if (oversized) return {line: "", oversized: true};
    var bytes = buffer.getBytes();
    var length = bytes.length;
    if (length > 0 && bytes.get(length - 1) == 13) length--;
    return {line: bytes.sub(0, length).toString(), oversized: false};
  }

  function handle(command:Dynamic):Bool {
    var id:String = Reflect.field(command, "id");
    var operation:String = Reflect.field(command, "op");
    switch operation {
      case "hello":
        events.emit({protocolVersion: 1, id: id, type: "ready", language: "haxe", implementation: "native-haxe-neko", runtime: RUNTIME_VERSION});
      case "query", "mutation", "action":
        var current = ensureClient();
        var result = operation == "query" ? current.query(Reflect.field(command, "path"), Reflect.field(command, "args")) :
          operation == "mutation" ? current.mutation(Reflect.field(command, "path"), Reflect.field(command, "args")) :
          current.action(Reflect.field(command, "path"), Reflect.field(command, "args"));
        var event:Dynamic = {id: id, type: "result", value: result.value};
        if (result.logs.length > 0) Reflect.setField(event, "logs", result.logs);
        events.emit(event);
      case "setAuth":
        ensureClient().setAuth(Reflect.field(command, "token"));
        events.emit({id: id, type: "ack"});
      case "subscribe":
        var subscriptionId:String = Reflect.field(command, "subscriptionId");
        removeRelay(subscriptionId);
        var subscription = ensureClient().subscribe(subscriptionId, Reflect.field(command, "path"), Reflect.field(command, "args"));
        var relay = new RelayState(subscription, nextToken++);
        relays.set(subscriptionId, relay);
        events.setOwner(subscriptionId, relay.token);
        // Enqueue the command acknowledgement before the relay can enqueue its
        // initial snapshot, preserving one universal event order.
        events.emit({id: id, type: "ack"});
        Thread.create(function() relayLoop(subscriptionId, relay));
      case "unsubscribe":
        removeRelay(Reflect.field(command, "subscriptionId"));
        events.emit({id: id, type: "ack"});
      case "debugDisconnect":
        ensureClient().debugDisconnectForAdapter();
        events.emit({id: id, type: "ack"});
      case "close":
        stopAll();
        if (client != null) client.close();
        events.emit({id: id, type: "closed"});
        events.flush(1.0);
        return true;
    }
    return false;
  }

  function relayLoop(subscriptionId:String, relay:RelayState):Void {
    while (!relay.stopped) {
      try {
        var update = relay.subscription.next(RELAY_POLL);
        if (relay.stopped) break;
        if (update.error != null) {
          emitFailure(null, subscriptionId, update.error, relay.token);
        } else {
          var event:Dynamic = {type: "subscription", subscriptionId: subscriptionId, value: update.value};
          if (update.logs.length > 0) Reflect.setField(event, "logs", update.logs);
          events.emit(event, subscriptionId, relay.token);
        }
      } catch (error:ConvexError) {
        if (relay.stopped) break;
        // An expired poll window is the normal idle case.
        if (error.operation == "Live next") continue;
        // The generation is gone, so no later event can ever arrive on it.
        // Reporting once and stopping avoids an unbounded error stream when
        // the owner has retired every subscription.
        emitFailure(null, subscriptionId, error, relay.token);
        if (error.kind == "ProtocolError" || error.kind == "ClientClosed") break;
      } catch (error:Dynamic) {
        if (relay.stopped) break;
        emitFailure(null, subscriptionId, error, relay.token);
        break;
      }
    }
  }

  function removeRelay(subscriptionId:String):Void {
    events.revoke(subscriptionId);
    var relay = relays.get(subscriptionId);
    relays.remove(subscriptionId);
    if (relay != null) {
      relay.stopped = true;
      relay.subscription.close();
    } else if (client != null) {
      client.unsubscribe(subscriptionId);
    }
  }

  function stopAll():Void {
    var ids:Array<String> = [];
    for (id in relays.keys()) ids.push(id);
    // Shutdown is best effort per relay. One already-broken subscription must
    // not prevent the remaining generations, client and output writer from
    // being retired.
    for (id in ids) try removeRelay(id) catch (_:Dynamic) {}
  }

  function ensureClient():ConvexClient {
    if (client != null) return client;
    var url = Sys.getEnv("CONVEX_URL");
    if (url == null || url.length == 0) throw ConvexError.protocol("CONVEX_URL is required");
    client = new ConvexClient(url);
    var token = Sys.getEnv("CONVEX_AUTH_TOKEN");
    if (token != null && token.length > 0) client.setAuth(token);
    return client;
  }

  static function validate(command:Dynamic):Dynamic {
    JsonTools.requireObject(command, "command");
    var operation = JsonTools.requireString(command, "op", "command");
    requireId(command, "id");
    switch operation {
      case "hello":
        JsonTools.allowedFields(command, ["protocolVersion", "id", "op"], "hello command");
        if (!Reflect.hasField(command, "protocolVersion") || JsonTools.exactInteger(Reflect.field(command, "protocolVersion"), "protocolVersion") != 1) {
          throw ConvexError.protocol("unsupported adapter protocol");
        }
      case "query", "mutation", "action":
        JsonTools.allowedFields(command, ["id", "op", "path", "args"], operation + " command");
        var path = JsonTools.requireString(command, "path", operation + " command");
        if (JsonTools.codePoints(path) < 3) throw ConvexError.protocol("path must contain at least three Unicode code points");
        JsonTools.requireObject(Reflect.field(command, "args"), operation + " args");
      case "subscribe":
        JsonTools.allowedFields(command, ["id", "op", "subscriptionId", "path", "args"], "subscribe command");
        requireId(command, "subscriptionId");
        var path = JsonTools.requireString(command, "path", "subscribe command");
        if (path.length == 0) throw ConvexError.protocol("subscribe path is required");
        JsonTools.requireObject(Reflect.field(command, "args"), "subscribe args");
      case "unsubscribe":
        JsonTools.allowedFields(command, ["id", "op", "subscriptionId", "path", "args"], "unsubscribe command");
        requireId(command, "subscriptionId");
        if (Reflect.hasField(command, "path") && !Std.isOfType(Reflect.field(command, "path"), String)) throw ConvexError.protocol("unsubscribe path must be a string");
        if (Reflect.hasField(command, "args")) JsonTools.requireObject(Reflect.field(command, "args"), "unsubscribe args");
      case "setAuth":
        JsonTools.allowedFields(command, ["id", "op", "token"], "setAuth command");
        JsonTools.requireString(command, "token", "setAuth command");
      case "close", "debugDisconnect":
        JsonTools.allowedFields(command, ["id", "op"], operation + " command");
      default:
        throw ConvexError.protocol('unknown operation $operation');
    }
    return command;
  }

  static function requireId(command:Dynamic, field:String):String {
    var value = JsonTools.requireString(command, field, "command");
    var length = JsonTools.codePoints(value);
    if (length < 1 || length > 128 || StringTools.trim(value).length == 0) {
      throw ConvexError.protocol('$field must contain 1 to 128 nonblank Unicode code points');
    }
    return value;
  }

  static function validOptionalId(command:Dynamic):Null<String> {
    if (!JsonTools.isObject(command) || !Reflect.hasField(command, "id") || !Std.isOfType(Reflect.field(command, "id"), String)) return null;
    var value:String = Reflect.field(command, "id");
    var length = JsonTools.codePoints(value);
    return length >= 1 && length <= 128 && StringTools.trim(value).length > 0 ? value : null;
  }

  function emitProtocol(id:Null<String>, message:String):Void {
    var event:Dynamic = {type: "error", error: {name: "ProtocolError", message: message}};
    if (id != null) Reflect.setField(event, "id", id);
    events.emit(event);
  }

  function emitFailure(id:Null<String>, subscriptionId:Null<String>, error:Dynamic, token:Int = 0):Void {
    var converted = Std.isOfType(error, ConvexError) ? cast(error, ConvexError) : ConvexError.transport("adapter", Std.string(error));
    var detail:Dynamic = {name: converted.kind, message: converted.message};
    if (converted.data != null) Reflect.setField(detail, "data", converted.data);
    var event:Dynamic = {type: subscriptionId == null ? "error" : "subscription", error: detail};
    if (id != null) Reflect.setField(event, "id", id);
    if (subscriptionId != null) Reflect.setField(event, "subscriptionId", subscriptionId);
    if (converted.logs.length > 0) Reflect.setField(event, "logs", converted.logs);
    events.emit(event, subscriptionId, token);
  }

  static function parseListen(value:String):{host:String, port:Int} {
    var bracketed = ~/^\[([^\]]+)\]:([0-9]+)$/;
    var host:String;
    var rawPort:String;
    if (bracketed.match(value)) {
      host = bracketed.matched(1);
      rawPort = bracketed.matched(2);
    } else {
      var split = value.lastIndexOf(":");
      if (split <= 0) throw ConvexError.protocol("ADAPTER_LISTEN must be host:port");
      host = value.substr(0, split);
      rawPort = value.substr(split + 1);
    }
    if (!(~/^[0-9]+$/).match(rawPort)) throw ConvexError.protocol("ADAPTER_LISTEN has invalid port");
    var port = Std.parseInt(rawPort);
    if (port == null || port < 1 || port > 65535) throw ConvexError.protocol("ADAPTER_LISTEN has invalid port");
    return {host: host, port: port};
  }
}
