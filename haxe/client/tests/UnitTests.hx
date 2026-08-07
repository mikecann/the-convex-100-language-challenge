import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.crypto.Sha1;

/** Pure boundary checks: URL parsing, strict UTF-8, protocol timestamps, the
 * handshake validator, and the global Live delivery budget. */
@:access(LiveOwner)
@:access(WebSocketTransport)
class UnitTests {
  public static function run():Void {
    urlParsing();
    strictUtf8();
    jsonShapeBounds();
    timestamps();
    unsignedSyncIntegers();
    handshakeTokens();
    globalLiveBudget();
  }

  static function urlParsing():Void {
    var url = new DeploymentUrl("https://example.com/base/");
    Assert.equal(url.host, "example.com", "host is parsed");
    Assert.equal(url.path, "/base", "trailing slashes are trimmed");
    Assert.equal(url.port, 443, "https defaults to 443");
    Assert.equal(url.hostHeader(), "example.com", "default port is omitted from Host");
    Assert.equal(new DeploymentUrl("http://[::1]:8080").hostHeader(), "[::1]:8080", "IPv6 Host is bracketed");
    Assert.throwsKind("ProtocolError", function() return new DeploymentUrl("https://user@example.com"), "user information is rejected");
    Assert.throwsKind("ProtocolError", function() return new DeploymentUrl("file:///tmp/socket"), "non-HTTP schemes are rejected");
    Assert.throwsKind("ProtocolError", function() return new DeploymentUrl("https://example.com/a?b=c"), "query strings are rejected");
    Assert.throwsKind("ProtocolError", function() return new DeploymentUrl("https://example.com\r\nX: y"), "control characters are rejected");
  }

  static function strictUtf8():Void {
    Assert.equal(Utf8Text.scalarCount(Bytes.ofString("ok")), 2, "ASCII counts scalars");
    Assert.equal(Utf8Text.scalarCount(Utf8Text.encodeScalar(0x1F680)), 1, "an astral scalar counts once");
    Assert.equal(Utf8Text.scalarCount(Utf8Text.encodeScalar(0x10FFFF)), 1, "the last legal scalar is accepted");

    // Sequences a length-only validator would wrongly accept.
    Assert.equal(Utf8Text.scalarCount(bytes([0xC0, 0xAF])), -1, "overlong two-byte solidus is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xE0, 0x80, 0xAF])), -1, "overlong three-byte solidus is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xF0, 0x80, 0x80, 0xAF])), -1, "overlong four-byte solidus is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xED, 0xA0, 0x80])), -1, "a lone high surrogate is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xED, 0xBF, 0xBF])), -1, "a lone low surrogate is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xF4, 0x90, 0x80, 0x80])), -1, "a scalar above U+10FFFF is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xF5, 0x80, 0x80, 0x80])), -1, "an out-of-range lead byte is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0xE2, 0x82])), -1, "a truncated sequence is rejected");
    Assert.equal(Utf8Text.scalarCount(bytes([0x80])), -1, "a bare continuation byte is rejected");
    Assert.throwsKind("ProtocolError", function() return Utf8Text.encodeScalar(0xD800), "surrogates cannot be encoded");
  }

  static function jsonShapeBounds():Void {
    var deep = new StringBuf();
    for (_ in 0...129) deep.add("[");
    for (_ in 0...129) deep.add("]");
    Assert.throwsKind("ProtocolError", function() {
      JsonTools.checkJsonShape(Bytes.ofString(deep.toString()), "test JSON");
      return true;
    }, "deep JSON is rejected before the recursive runtime parser");
    JsonTools.checkJsonShape(Bytes.ofString('{"text":"[not structure]","values":[1,2]}'), "test JSON");
    Assert.ok(true, "brackets and commas inside strings do not consume the JSON shape budget");
  }

  static function timestamps():Void {
    Assert.equal(LiveOwner.decodeTimestamp("AAAAAAAAAAA=").length, 8, "the zero timestamp decodes to eight bytes");
    Assert.throwsKind("ProtocolError", function() return LiveOwner.decodeTimestamp("AAAAAAAAAA=="), "a six-byte timestamp is rejected");
    Assert.throwsKind("ProtocolError", function() return LiveOwner.decodeTimestamp("AAAAAAAAAAA!"), "a non-base64 timestamp is rejected");
    Assert.throwsKind("ProtocolError", function() return LiveOwner.decodeTimestamp("AAAAAAAAAAB="), "a non-canonical encoding is rejected");
  }

  static function unsignedSyncIntegers():Void {
    Assert.equal(JsonTools.nonNegativeInteger(0.0, "sync"), 0, "an integral decimal zero is accepted");
    Assert.equal(JsonTools.nonNegativeInteger(2147483647, "sync"), 2147483647, "the signed target maximum is exact");
    Assert.throwsKind("ProtocolError", function() return JsonTools.nonNegativeInteger(-1, "sync"), "negative sync counters are rejected");
    Assert.throwsKind("ProtocolError", function() return JsonTools.nonNegativeInteger(1.5, "sync"), "fractional sync counters are rejected");
  }

  static function handshakeTokens():Void {
    var key = "dGhlIHNhbXBsZSBub25jZQ==";
    var accept = Base64.encode(Sha1.make(Bytes.ofString(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
    WebSocketTransport.validateHandshake('HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: keep-alive, UpGrAdE\r\nSec-WebSocket-Accept: $accept\r\n\r\n', key);
    Assert.ok(true, "a case-insensitive, multi-token handshake is accepted");
    Assert.throwsKind("ProtocolError", function() { WebSocketTransport.validateHandshake('HTTP/1.1 200 OK\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n', key); return true; }, "a non-101 status is rejected");
    Assert.throwsKind("ProtocolError", function() { WebSocketTransport.validateHandshake('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Accept: $accept\r\n\r\n', key); return true; }, "a missing Connection token is rejected");
    Assert.throwsKind("ProtocolError", function() { WebSocketTransport.validateHandshake('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n', key); return true; }, "a wrong accept value is rejected");
    Assert.throwsKind("ProtocolError", function() { WebSocketTransport.validateHandshake('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Extensions: permessage-deflate\r\nSec-WebSocket-Accept: $accept\r\n\r\n', key); return true; }, "an unrequested extension is rejected");
  }

  static function globalLiveBudget():Void {
    var buffers = new LiveBuffers();
    buffers.register("room", 1);
    // Overfill the queue. The oldest queued state is what gets dropped, so a
    // consumer that returns late still sees the most recent values.
    for (value in 0...24) buffers.add("room", 1, new LiveEvent(value));
    Assert.equal(buffers.next("room", 1, 0.1).value, 8, "the global count cap drops the oldest queued state");

    buffers.invalidate("room", 1);
    Assert.throwsKind("ProtocolError", function() return buffers.next("room", 1, 0.01), "an invalidated generation can never receive");

    buffers.register("room", 2);
    buffers.add("room", 2, new LiveEvent("fresh"));
    Assert.equal(buffers.next("room", 2, 0.1).value, "fresh", "a replacement generation is isolated from the old one");
    Assert.throwsKind("TransportError", function() return buffers.next("room", 2, 0.05), "an idle consumer times out rather than blocking");

    // One value larger than the whole budget is replaced by a bounded failure
    // instead of being retained.
    var oversized:Array<String> = [];
    for (_ in 0...110000) oversized.push("0123456789012345678901234567890123456789012345678901234567890123");
    Assert.equal(buffers.add("room", 2, new LiveEvent(oversized)), false, "an oversized update is reported as dropped");
    var replaced = buffers.next("room", 2, 0.1);
    Assert.ok(replaced.error != null, "the oversized update is replaced by a structured failure");
    Assert.equal(replaced.value, null, "the oversized payload itself is not retained");
  }

  static function bytes(values:Array<Int>):Bytes {
    var output = Bytes.alloc(values.length);
    for (index in 0...values.length) output.set(index, values[index]);
    return output;
  }
}
