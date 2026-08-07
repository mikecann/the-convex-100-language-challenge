import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/** RFC 6455 decoding against a real server that emits exactly the bytes each
 * case needs, including frames a permissive parser would accept. */
class FrameTests {
  public static function run():Void {
    fragmentedUtf8AndControlFrames();
    rejects("a masked server frame", maskedServerFrame());
    rejects("a frame with RSV bits set", SyncFixture.frame(0xC1, Bytes.ofString("{}")));
    rejects("a non-minimal two-byte length", nonMinimalLength());
    rejects("an unsupported opcode", SyncFixture.frame(0x83, Bytes.ofString("{}")));
    rejects("a continuation without a start frame", SyncFixture.frame(0x80, Bytes.ofString("{}")));
    rejects("a fragmented control frame", SyncFixture.frame(0x09, Bytes.ofString("ping")));
    rejects("overlong UTF-8 in a text frame", SyncFixture.frame(0x81, bytes([0x22, 0xC0, 0xAF, 0x22])));
    rejects("a lone surrogate in a text frame", SyncFixture.frame(0x81, bytes([0x22, 0xED, 0xA0, 0x80, 0x22])));
    rejects("a one-byte close payload", SyncFixture.frame(0x88, bytes([0x03])));
    rejects("a reserved close code", SyncFixture.frame(0x88, bytes([0x03, 0xEC])));
    rejects("a non-object sync message", SyncFixture.frame(0x81, Bytes.ofString("[1,2]")));
    rejects("a truncated JSON message", SyncFixture.frame(0x81, Bytes.ofString("{\"type\":")));
    committedFrameIsAbandonedNotResumed();
  }

  /** A message split across a multi-byte character, with control traffic in
   * between, must be reassembled before it is validated or parsed. */
  static function fragmentedUtf8AndControlFrames():Void {
    var fixture = new SyncFixture();
    var transport = connect(fixture);

    var rocket = Utf8Text.encodeScalar(0x1F680);
    var payload = Bytes.ofString('{"type":"Ping","note":"');
    var whole = new BytesBuffer();
    whole.addBytes(payload, 0, payload.length);
    whole.addBytes(rocket, 0, rocket.length);
    whole.addBytes(Bytes.ofString('"}'), 0, 2);
    var message = whole.getBytes();

    // Split inside the astral character so a per-frame validator would fail.
    var head = message.sub(0, payload.length + 2);
    var tail = message.sub(payload.length + 2, message.length - payload.length - 2);
    fixture.sendRaw(SyncFixture.frame(0x01, head));
    fixture.sendRaw(SyncFixture.frame(0x89, Bytes.ofString("keepalive")));
    fixture.sendRaw(SyncFixture.frame(0x80, tail));

    var decoded = awaitMessage(transport, 5.0);
    Assert.equal(Reflect.field(decoded, "type"), "Ping", "a fragmented message is reassembled before parsing");
    Assert.equal(Reflect.field(decoded, "note"), rocket.toString(), "a character split across frames survives intact");
    var pong = fixture.expect("ClientPong", 5.0);
    Assert.equal(Reflect.field(pong, "payload"), "keepalive", "a ping is answered with its own payload");
    Assert.ok(transport.isUsable(), "control traffic leaves the connection usable");
    transport.close();
    fixture.close();
  }

  /** Once a frame has been partially consumed, a deadline must never let the
   * parser resynchronise at a byte that only looks like a frame boundary. */
  static function committedFrameIsAbandonedNotResumed():Void {
    var fixture = new SyncFixture();
    var transport = connect(fixture);

    // A text frame promising 200 bytes, followed by four bytes and silence.
    // The length is carried in the 2-byte extended form (marker 126) because a
    // literal 200 in the single-byte length slot would set the high bit that
    // the parser reserves for the server-must-not-mask check.
    var stalled = new BytesBuffer();
    stalled.addByte(0x81);
    stalled.addByte(126);
    stalled.addByte(0);
    stalled.addByte(200);
    stalled.addBytes(Bytes.ofString("{\"ty"), 0, 4);
    fixture.sendRaw(stalled.getBytes());

    var elapsed = Assert.within(WebSocketTransport.MESSAGE_TIMEOUT + 2.0, function() {
      return transport.pollJson(1.0);
    }, "a stalled frame fails at its message deadline");
    Assert.ok(elapsed >= WebSocketTransport.MESSAGE_TIMEOUT - 0.5, "the stalled read waited for the whole message deadline");
    Assert.ok(!transport.isUsable(), "a half-read frame retires the connection instead of resuming");
    Assert.throwsKind("TransportError", function() return transport.pollJson(0.1), "a retired connection refuses further reads");
    transport.close();
    fixture.close();
  }

  static function rejects(label:String, frameBytes:Bytes):Void {
    var fixture = new SyncFixture();
    var transport = connect(fixture);
    fixture.sendRaw(frameBytes);
    var failed = false;
    var deadline = Sys.time() + 5.0;
    while (Sys.time() < deadline && !failed) {
      try {
        transport.pollJson(0.2);
      } catch (_:ConvexError) {
        failed = true;
      }
    }
    Assert.ok(failed, 'the parser rejects $label');
    Assert.ok(!transport.isUsable(), 'rejecting $label retires the connection');
    transport.close();
    fixture.close();
  }

  static function connect(fixture:SyncFixture):WebSocketTransport {
    return new WebSocketTransport(new DeploymentUrl(fixture.url()), "haxe-tests");
  }

  static function awaitMessage(transport:WebSocketTransport, timeout:Float):Dynamic {
    var deadline = Sys.time() + timeout;
    while (Sys.time() < deadline) {
      var message = transport.pollJson(0.2);
      if (message != null) return message;
    }
    throw "no WebSocket message arrived";
  }

  static function maskedServerFrame():Bytes {
    var output = new BytesBuffer();
    output.addByte(0x81);
    output.addByte(0x80 | 2);
    for (_ in 0...4) output.addByte(0);
    output.addBytes(Bytes.ofString("{}"), 0, 2);
    return output.getBytes();
  }

  static function nonMinimalLength():Bytes {
    var output = new BytesBuffer();
    output.addByte(0x81);
    output.addByte(126);
    output.addByte(0);
    output.addByte(2);
    output.addBytes(Bytes.ofString("{}"), 0, 2);
    return output.getBytes();
  }

  static function bytes(values:Array<Int>):Bytes {
    var output = Bytes.alloc(values.length);
    for (index in 0...values.length) output.set(index, values[index]);
    return output;
  }
}
