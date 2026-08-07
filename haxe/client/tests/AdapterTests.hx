import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Thread;

/** The shared controller validates every emitted line against
 * `_shared/schemas/adapter.schema.json`. These tests assert the exact
 * serialized shapes locally, so a mismatch is found here rather than in shared
 * conformance: absent fields must be omitted, never written as null. */
@:access(Adapter)
class AdapterTests {
  public static function run():Void {
    commandValidation();
    serializedEventShapes();
    subscriptionEventShapes();
    relayOwnershipBarrier();
    slowConsumerIsBounded();
  }

  static function commandValidation():Void {
    var astral = Utf8Text.encodeScalar(0x1F680).toString();
    var longest = new StringBuf();
    for (_ in 0...128) longest.add(astral);
    var boundary = longest.toString();
    Adapter.validate({protocolVersion: 1, id: boundary, op: "hello"});
    Assert.ok(true, "128 astral code points are inside the schema boundary");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({protocolVersion: 1, id: boundary + astral, op: "hello"}), "a 129 code-point id is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({protocolVersion: 1, id: "ok", op: "hello", extra: true}), "an unknown field is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({protocolVersion: "1", id: "ok", op: "hello"}), "a non-numeric protocol version is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({protocolVersion: 2, id: "ok", op: "hello"}), "an unsupported protocol version is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({id: 4, op: "close"}), "a numeric id is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({id: "   ", op: "close"}), "a blank id is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({id: "a", op: "query", path: "ab", args: {}}), "a two-character path is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({id: "a", op: "query", path: "demo:x", args: []}), "array arguments are rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({id: "a", op: "invent"}), "an unknown operation is rejected");
    Assert.throwsKind("ProtocolError", function() return Adapter.validate({id: "a", op: "setAuth"}), "setAuth requires a token");
  }

  static function serializedEventShapes():Void {
    var fixture = new HttpFixture([
      HttpFixture.success('{"ok":true}'),
      HttpFixture.body('{"status":"success","value":1,"logLines":["from the function"]}'),
      HttpFixture.response(400, '{"status":"error","errorMessage":"boom","errorData":{"code":"HAXE_EXPECTED"},"logLines":["before the throw"]}')
    ]);
    Sys.putEnv("CONVEX_URL", fixture.url());

    var script:Array<Dynamic> = [
      '{"protocolVersion":1,"id":"h","op":"hello"}',
      '{"id":"q1","op":"query","path":"demo:state","args":{}}',
      '{"id":"q2","op":"query","path":"demo:state","args":{}}',
      '{"id":"q3","op":"query","path":"demo:fail","args":{}}',
      '{"id":"bad","op":"invent"}',
      'not json',
      '{"id":"c","op":"close"}'
    ];
    var events = drive(script);

    var ready = events[0];
    Assert.equal(field(ready, "type"), "ready", "hello answers with ready");
    Assert.equal(field(ready, "protocolVersion"), 1, "ready reports the protocol version");
    Assert.equal(field(ready, "language"), "haxe", "ready reports the roster language id");
    Assert.equal(field(ready, "implementation"), "native-haxe-neko", "ready reports its provenance");
    Assert.ok(Reflect.hasField(ready, "runtime"), "ready reports a runtime version");
    absent(ready, ["subscriptionId", "error", "value"], "ready");

    var success = events[1];
    Assert.equal(field(success, "type"), "result", "a call answers with result");
    Assert.equal(field(success, "id"), "q1", "a result carries its request id");
    Assert.equal(field(field(success, "value"), "ok"), true, "a result carries the decoded value");
    absent(success, ["logs", "error", "subscriptionId"], "a result with no logs");

    var logged = events[2];
    Assert.equal(field(logged, "type"), "result", "a logged call still answers with result");
    Assert.equal((cast field(logged, "logs"):Array<String>)[0], "from the function", "log lines stay distinct from the value");

    var failure = events[3];
    Assert.equal(field(failure, "type"), "error", "a function failure answers with error");
    Assert.equal(field(failure, "id"), "q3", "a structured error carries its request id");
    Assert.equal(field(field(failure, "error"), "name"), "FunctionError", "the error kind is preserved");
    Assert.equal(field(field(failure, "error"), "message"), "boom", "the error message is preserved");
    Assert.equal(field(field(field(failure, "error"), "data"), "code"), "HAXE_EXPECTED", "application error data is preserved");
    Assert.equal((cast field(failure, "logs"):Array<String>)[0], "before the throw", "logs survive alongside a failure");
    absent(failure, ["value", "subscriptionId"], "a structured error");

    var unknown = events[4];
    Assert.equal(field(unknown, "type"), "error", "an unknown operation answers with error");
    Assert.equal(field(unknown, "id"), "bad", "a rejected command keeps its valid id");

    var malformed = events[5];
    Assert.equal(field(malformed, "type"), "error", "a malformed line answers with error");
    absent(malformed, ["id", "subscriptionId", "value"], "an error with no usable id");

    var closed = events[6];
    Assert.equal(field(closed, "type"), "closed", "close answers with closed");
    Assert.equal(field(closed, "id"), "c", "the close acknowledgement carries its id");
    Assert.equal(events.length, 7, "stdout carries exactly one event per command");
  }

  /** A subscription failure must serialize as a subscription event carrying an
   * error object and no value at all. */
  static function subscriptionEventShapes():Void {
    var fixture = new SyncFixture();
    Sys.putEnv("CONVEX_URL", fixture.url());

    Thread.create(function() {
      // Answer the client's first query set with one failing query.
      var modify = fixture.expect("ModifyQuerySet", 20.0);
      var add = (cast Reflect.field(modify, "modifications"):Array<Dynamic>)[0];
      fixture.sendJson(SyncFixture.transition(0, "AAAAAAAAAAA=", SyncFixture.timestamp(1), [
        {
          type: "QueryFailed",
          queryId: Reflect.field(add, "queryId"),
          errorMessage: "room is empty",
          errorData: {code: "ROOM_EMPTY"},
          logLines: []
        }
      ]));
    });

    var script:Array<Dynamic> = [
      '{"protocolVersion":1,"id":"h","op":"hello"}',
      '{"id":"s","op":"subscribe","subscriptionId":"room","path":"demo:requiresNonzero","args":{}}',
      // Give the relay time to publish before the close barrier arrives.
      3.0,
      '{"id":"c","op":"close"}'
    ];
    var events = drive(script, 30.0);
    fixture.close();

    var failed:Dynamic = null;
    for (event in events) {
      if (field(event, "type") != "subscription") continue;
      var error = Reflect.field(event, "error");
      if (error != null && Reflect.field(error, "name") == "FunctionError") failed = event;
    }
    Assert.ok(failed != null, "the relay emits the reactive failure as a subscription event");
    Assert.equal(field(failed, "subscriptionId"), "room", "a subscription event names its subscription");
    Assert.equal(field(field(field(failed, "error"), "data"), "code"), "ROOM_EMPTY", "reactive error data is preserved");
    absent(failed, ["value", "id"], "a subscription failure");
  }

  /** A relay that dequeued an update before it lost ownership must never
   * publish it, whether ownership ended through unsubscribe or replacement. */
  static function relayOwnershipBarrier():Void {
    var capture = new BytesOutput();
    var output = new AdapterOutput(capture);
    output.setOwner("room", 1);

    output.revoke("room");
    output.emit({type: "subscription", subscriptionId: "room", value: 1}, "room", 1);

    output.setOwner("room", 2);
    output.emit({type: "subscription", subscriptionId: "room", value: 2}, "room", 1);
    output.emit({type: "subscription", subscriptionId: "room", value: 3}, "room", 2);
    output.close();

    var lines = splitEvents(capture.getBytes().toString());
    Assert.equal(lines.length, 1, "only the owning relay's event is written");
    Assert.equal(field(lines[0], "value"), 3, "the surviving event is the current owner's");
  }

  /** With a reader that never reads, the adapter must fail its own output
   * rather than retain an unbounded queue. */
  static function slowConsumerIsBounded():Void {
    var server = new Socket();
    server.bind(new Host("127.0.0.1"), 0);
    server.listen(4);
    var port = server.host().port;
    var controller = new Socket();
    controller.connect(new Host("127.0.0.1"), port);
    var peer = server.accept();
    server.close();

    var output = new AdapterOutput(peer.output, peer);
    var padding = new StringBuf();
    for (_ in 0...16384) padding.add("0123456789abcdef");
    var filler = padding.toString();
    var stopped = false;
    var elapsed = Assert.within(30.0, function() {
      for (index in 0...64) {
        output.emit({id: 'e$index', type: "result", value: filler});
      }
      return true;
    }, "a stopped reader is detected inside the output bound");
    try {
      output.emit({id: "after", type: "result", value: filler});
    } catch (_:ConvexError) {
      stopped = true;
    }
    Assert.ok(stopped, "the adapter refuses to keep queueing for a stopped reader");
    Assert.ok(elapsed < 30.0, "the stopped reader is detected promptly");
    SocketTransport.closeQuietly(controller);
    SocketTransport.closeQuietly(peer);
  }

  /** Run one NDJSON script through a real adapter over a real TCP connection,
   * which is the transport the shared harness uses. */
  static function drive(script:Array<Dynamic>, timeout:Float = 20.0):Array<Dynamic> {
    var server = new Socket();
    server.bind(new Host("127.0.0.1"), 0);
    server.listen(4);
    var port = server.host().port;

    var controller = new Socket();
    controller.connect(new Host("127.0.0.1"), port);
    var peer = server.accept();
    server.close();

    Thread.create(function() {
      try new Adapter(peer.input, peer.output, peer).run() catch (_:Dynamic) {}
      SocketTransport.closeQuietly(peer);
    });

    // The writer runs alongside the reader so a relay can publish while the
    // script is still being delivered.
    Thread.create(function() {
      for (step in script) {
        if (Std.isOfType(step, String)) {
          try {
            SocketTransport.writeAll(controller, Bytes.ofString(step + "\n"), Sys.time() + 5.0, "controller write");
          } catch (_:Dynamic) {
            break;
          }
        } else {
          Sys.sleep(step);
        }
      }
    });

    var received = new StringBuf();
    var deadline = Sys.time() + timeout;
    var finished = false;
    while (Sys.time() < deadline && !finished) {
      var byte = 0;
      try {
        byte = SocketTransport.pollByte(controller, 0.2, "controller read");
      } catch (_:ConvexError) {
        break;
      }
      if (byte < 0) continue;
      received.addChar(byte);
      // The closed acknowledgement is always the adapter's last event.
      if (byte == 10) {
        for (event in splitEvents(received.toString())) {
          if (Reflect.field(event, "type") == "closed") finished = true;
        }
      }
    }
    SocketTransport.closeQuietly(controller);
    return splitEvents(received.toString());
  }

  static function splitEvents(raw:String):Array<Dynamic> {
    var events = [];
    for (line in raw.split("\n")) {
      if (StringTools.trim(line).length == 0) continue;
      events.push(Json.parse(line));
    }
    return events;
  }

  static function field(event:Dynamic, name:String):Dynamic {
    if (!Reflect.hasField(event, name)) throw 'FAILED event has no $name field: ${Json.stringify(event)}';
    return Reflect.field(event, name);
  }

  /** Optional fields must be omitted, not serialized as null. */
  static function absent(event:Dynamic, names:Array<String>, label:String):Void {
    for (name in names) {
      Assert.ok(!Reflect.hasField(event, name), '$label omits $name entirely');
    }
  }
}
