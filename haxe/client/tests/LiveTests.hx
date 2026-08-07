import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/** One scripted sync peer per scenario, driving the real owner thread.
 *
 * The peer holds the client's query-set version, so every assertion about
 * Add/Remove, atomic transitions, replay after reconnect, and suppressed
 * rehydration is made against the bytes the client actually sent. */
@:access(LiveOwner)
class LiveTests {
  public static function run():Void {
    addUpdateFailAndRecover();
    unsubscribeInvalidatesBeforeAcknowledgement();
    sameIdReplacementRetiresTheOldGeneration();
    fiveRealReconnectsReplayAndSuppressRehydration();
    protocolDriftRetiresThenRecovers();
    transitionsApplyAtomically();
    backwardsTimestampRetiresTheConnection();
    subscriptionCapacityIsBounded();
    closeIsBoundedWhenThePeerIsIdle();
    closeIsBoundedWhenThePeerStallsMidFrame();
    closeIsBoundedWhenThePeerFloods();
  }

  static function addUpdateFailAndRecover():Void {
    var session = new Session();
    var subscription = session.subscribe("counter", "demo:state", {room: "a"});

    var add = session.awaitAdd();
    Assert.equal(Reflect.field(add, "udfPath"), "demo:state", "the Add carries the function path");
    Assert.equal(Reflect.field(Reflect.field(add, "args")[0], "room"), "a", "the Add carries the arguments");

    session.push([session.updated({count: 0})]);
    Assert.equal(count(subscription.next(5.0)), 0, "the initial value is delivered");

    session.push([session.updated({count: 1})]);
    Assert.equal(count(subscription.next(5.0)), 1, "an external update is delivered without polling");

    session.push([session.failed("ROOM_EMPTY", "room is empty")]);
    var failure = subscription.next(5.0);
    Assert.ok(failure.error != null, "a reactive query failure is a typed subscription event");
    Assert.equal(failure.error.kind, "FunctionError", "a query failure is not flattened into a transport error");
    Assert.equal(Reflect.field(failure.error.data, "code"), "ROOM_EMPTY", "structured error data survives");

    session.push([session.updated({count: 2})]);
    Assert.equal(count(subscription.next(5.0)), 2, "the same subscription recovers after its query is repaired");
    session.finish();
  }

  /** No event dequeued before the acknowledgement may cross it, and removing
   * one query must leave every other subscription working. */
  static function unsubscribeInvalidatesBeforeAcknowledgement():Void {
    var session = new Session();
    var retired = session.subscribe("counter", "demo:state", {room: "a"});
    var retiredQuery = Reflect.field(session.awaitAdd(), "queryId");
    var kept = session.subscribe("other", "demo:state", {room: "b"});
    var keptQuery = Reflect.field(session.awaitAdd(), "queryId");

    session.push([session.updatedFor(retiredQuery, {count: 0}), session.updatedFor(keptQuery, {count: 0})]);
    Assert.equal(count(retired.next(5.0)), 0, "the initial value arrives before the barrier");
    Assert.equal(count(kept.next(5.0)), 0, "the second subscription is independent");

    // Queue a value the consumer has not read, then unsubscribe.
    session.push([session.updatedFor(retiredQuery, {count: 1})]);
    Sys.sleep(0.3);
    retired.close();

    var remove = session.awaitRemove();
    Assert.equal(Reflect.field(remove, "queryId"), retiredQuery, "unsubscribe removes exactly the retired query");
    Assert.throwsKind("ProtocolError", function() return retired.next(0.2), "the retired generation cannot deliver a value queued before the acknowledgement");

    // The server may still be reporting the removed query. That is in-flight
    // state, not drift, and must not disturb the surviving subscription.
    session.push([{type: "QueryRemoved", queryId: retiredQuery}, session.updatedFor(keptQuery, {count: 2})]);
    Assert.equal(count(kept.next(5.0)), 2, "a trailing QueryRemoved does not retire the connection");
    session.finish();
  }

  static function sameIdReplacementRetiresTheOldGeneration():Void {
    var session = new Session();
    var first = session.subscribe("counter", "demo:state", {room: "a"});
    session.awaitAdd();
    session.push([session.updated({count: 0})]);
    Assert.equal(count(first.next(5.0)), 0, "the first generation receives its value");

    session.push([session.updated({count: 1})]);
    Sys.sleep(0.3);
    var second = session.client.subscribe("counter", "demo:state", {room: "a"});
    Assert.ok(second.generation != first.generation, "a replacement subscription is a new generation");
    Assert.throwsKind("ProtocolError", function() return first.next(0.2), "the replaced generation is invalidated before the replacement is returned");
    session.finish();
  }

  /** Five real reconnects, each proving the query set is rebuilt and that an
   * unchanged rehydration is suppressed rather than republished. */
  static function fiveRealReconnectsReplayAndSuppressRehydration():Void {
    var session = new Session();
    var subscription = session.subscribe("counter", "demo:state", {room: "a"});
    session.awaitAdd();
    session.push([session.updated({count: 0})]);
    Assert.equal(count(subscription.next(5.0)), 0, "the pre-disconnect value is delivered");

    var current = 0;
    var reconnectSession:Null<String> = null;
    for (attempt in 1...6) {
      var before = session.fixture.connections();
      session.client.debugDisconnectForAdapter();
      session.fixture.awaitConnections(before + 1, 10.0);

      var connect = session.awaitConnect();
      var observedSession:String = Reflect.field(connect, "sessionId");
      if (reconnectSession == null) reconnectSession = observedSession else {
        Assert.equal(observedSession, reconnectSession, 'reconnect $attempt preserves the Convex session id');
      }
      Assert.equal(Reflect.field(connect, "connectionCount"), attempt, 'reconnect $attempt reports its connection count');
      Assert.equal(Reflect.field(connect, "lastCloseReason"), "DebugDisconnect", 'reconnect $attempt reports why the last socket closed');
      session.reset();
      var add = session.awaitAdd();
      Assert.equal(Reflect.field(add, "udfPath"), "demo:state", 'reconnect $attempt resends the active Add');

      // The server rehydrates with the value the client already has.
      session.push([session.updated({count: current})]);
      Assert.throwsKind("TransportError", function() return subscription.next(0.5), 'reconnect $attempt suppresses an unchanged rehydration');

      current++;
      session.push([session.updated({count: current})]);
      Assert.equal(count(subscription.next(10.0)), current, 'reconnect $attempt delivers the value that changed');
    }
    session.finish();
  }

  /** A protocol failure is reported, the socket is rebuilt, and the same
   * subscription can still deliver a later valid value. */
  static function protocolDriftRetiresThenRecovers():Void {
    var session = new Session();
    var subscription = session.subscribe("counter", "demo:state", {room: "a"});
    session.awaitAdd();
    session.push([session.updated({count: 0})]);
    Assert.equal(count(subscription.next(5.0)), 0, "the subscription is healthy first");

    var before = session.fixture.connections();
    session.fixture.sendJson({type: "TransitionChunk", chunk: 1});
    var reported = subscription.next(10.0);
    Assert.ok(reported.error != null, "deferred protocol drift becomes a typed event");
    Assert.equal(reported.error.kind, "ProtocolError", "drift is a protocol error, not a query failure");

    session.fixture.awaitConnections(before + 1, 15.0);
    session.awaitConnect();
    session.reset();
    session.awaitAdd();
    session.push([session.updated({count: 5})]);
    Assert.equal(count(subscription.next(10.0)), 5, "the subscription still delivers a later valid value");
    session.finish();
  }

  /** A transition is applied whole or not at all. */
  static function transitionsApplyAtomically():Void {
    var session = new Session();
    var subscription = session.subscribe("counter", "demo:state", {room: "a"});
    var add = session.awaitAdd();
    var queryId = Reflect.field(add, "queryId");
    session.push([session.updated({count: 0})]);
    Assert.equal(count(subscription.next(5.0)), 0, "the subscription is healthy first");

    // A valid modification followed by an unknown one. Neither may be applied.
    session.fixture.sendJson(SyncFixture.transition(session.querySet, session.ts, SyncFixture.timestamp(session.clock + 1), [
      {type: "QueryUpdated", queryId: queryId, value: {count: 99}, logLines: []},
      {type: "QueryInvented", queryId: queryId}
    ]));
    var reported = subscription.next(10.0);
    Assert.ok(reported.error != null, "an unknown modification rejects the whole transition");
    Assert.equal(reported.error.kind, "ProtocolError", "an unknown modification is protocol drift");
    Assert.throwsKind("TransportError", function() return subscription.next(0.5), "no part of the rejected transition is published");
    session.finish();
  }

  static function backwardsTimestampRetiresTheConnection():Void {
    var session = new Session();
    var subscription = session.subscribe("counter", "demo:state", {room: "a"});
    var add = session.awaitAdd();
    var queryId = Reflect.field(add, "queryId");
    session.push([session.updated({count: 0})]);
    Assert.equal(count(subscription.next(5.0)), 0, "the timestamp test starts from a valid transition");

    session.fixture.sendJson(SyncFixture.transition(session.querySet, session.ts, "AAAAAAAAAAA=", [
      {type: "QueryUpdated", queryId: queryId, value: {count: 1}, logLines: []}
    ]));
    var failure = subscription.next(10.0);
    Assert.ok(failure.error != null, "a backwards timestamp is reported to the subscription");
    Assert.equal(failure.error.kind, "ProtocolError", "a backwards timestamp is protocol drift");
    session.finish();
  }

  static function subscriptionCapacityIsBounded():Void {
    var session = new Session();
    for (index in 0...64) session.client.subscribe('room-$index', "demo:state", {room: 'r-$index'});
    Assert.throwsKind("ProtocolError", function() {
      return session.client.subscribe("room-overflow", "demo:state", {room: "overflow"});
    }, "the owner refuses an unbounded active subscription set");
    session.finish();
  }

  static function closeIsBoundedWhenThePeerIsIdle():Void {
    var session = new Session();
    session.subscribe("counter", "demo:state", {room: "a"});
    session.awaitAdd();
    Assert.within(8.0, function() { session.client.close(); return true; }, "close is bounded against a silent peer");
    session.fixture.close();
  }

  static function closeIsBoundedWhenThePeerStallsMidFrame():Void {
    var session = new Session();
    session.subscribe("counter", "demo:state", {room: "a"});
    session.awaitAdd();

    // Promise 200 bytes, deliver four, then stop. The owner must abandon that
    // connection rather than resynchronise inside the frame.
    var stalled = new BytesBuffer();
    stalled.addByte(0x81);
    stalled.addByte(200);
    stalled.addBytes(Bytes.ofString("{\"ty"), 0, 4);
    session.fixture.sendRaw(stalled.getBytes());

    Assert.within(15.0, function() { session.client.close(); return true; }, "close is bounded against a peer stalled mid-frame");
    session.fixture.close();
  }

  static function closeIsBoundedWhenThePeerFloods():Void {
    var session = new Session();
    session.subscribe("counter", "demo:state", {room: "a"});
    var add = session.awaitAdd();
    var queryId = Reflect.field(add, "queryId");
    for (index in 0...400) {
      session.fixture.sendJson(SyncFixture.transition(index, SyncFixture.timestamp(index), SyncFixture.timestamp(index + 1), [
        {type: "QueryUpdated", queryId: queryId, value: {count: index}, logLines: []}
      ]));
    }
    Assert.within(15.0, function() { session.client.close(); return true; }, "close is bounded against a continuously sending peer");
    session.fixture.close();
  }

  static function count(event:LiveEvent):Int {
    if (event.error != null) throw 'unexpected subscription failure: ${event.error.message}';
    return JsonTools.exactInteger(Reflect.field(event.value, "count"), "count");
  }
}

/** One client bound to one scripted peer, tracking the query-set version and
 * timestamp the peer must quote back. */
private class Session {
  public final fixture:SyncFixture;
  public final client:ConvexClient;
  public var querySet = 0;
  public var clock = 0;
  public var ts(get, never):String;

  var queryId:Null<Int> = null;

  public function new() {
    fixture = new SyncFixture();
    client = new ConvexClient(fixture.url());
  }

  function get_ts():String {
    return clock == 0 ? "AAAAAAAAAAA=" : SyncFixture.timestamp(clock);
  }

  public function subscribe(id:String, path:String, arguments:Dynamic):LiveSubscription {
    return client.subscribe(id, path, arguments);
  }

  public function awaitConnect():Dynamic {
    return fixture.expect("Connect", 10.0);
  }

  /** The next Add modification the client writes, remembering its query ID. */
  public function awaitAdd():Dynamic {
    var modification = awaitModification("Add");
    queryId = Reflect.field(modification, "queryId");
    return modification;
  }

  public function awaitRemove():Dynamic {
    return awaitModification("Remove");
  }

  /** A reconnect restarts the server-visible version at zero. */
  public function reset():Void {
    querySet = 0;
    clock = 0;
  }

  public function push(modifications:Array<Dynamic>):Void {
    var next = clock + 1;
    fixture.sendJson(SyncFixture.transition(querySet, ts, SyncFixture.timestamp(next), modifications));
    querySet++;
    clock = next;
  }

  public function updated(value:Dynamic):Dynamic {
    return updatedFor(queryId, value);
  }

  public function updatedFor(target:Null<Int>, value:Dynamic):Dynamic {
    return {type: "QueryUpdated", queryId: target, value: value, logLines: []};
  }

  public function failed(code:String, message:String):Dynamic {
    return {type: "QueryFailed", queryId: queryId, errorMessage: message, errorData: {code: code}, logLines: []};
  }

  public function finish():Void {
    client.close();
    fixture.close();
  }

  function awaitModification(kind:String):Dynamic {
    var deadline = Sys.time() + 10.0;
    while (Sys.time() < deadline) {
      var message = fixture.expect("ModifyQuerySet", 10.0);
      for (modification in (cast Reflect.field(message, "modifications"):Array<Dynamic>)) {
        if (Reflect.field(modification, "type") == kind) return modification;
      }
    }
    throw 'the client never wrote a $kind modification';
  }
}
