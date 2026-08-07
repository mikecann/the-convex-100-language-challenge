import haxe.crypto.Base64;
import haxe.crypto.Sha1;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.io.File;
import sys.net.Socket;

/** Strict RFC 6455 client used only by the single Live owner thread.
 *
 * Readiness is decided by a short blocking read rather than `Socket.select`.
 * Under TLS a whole record can already sit in the runtime's decrypt buffer
 * while the underlying descriptor looks idle, so selecting on the descriptor
 * would strand a message that has in fact arrived.
 *
 * Once any byte of a frame has been consumed the connection is committed: a
 * later deadline, malformed length, or invalid payload marks the transport
 * unusable instead of resuming at what would be a false frame boundary. */
class WebSocketTransport {
  static inline var MAX_MESSAGE = 4 * 1024 * 1024;
  static inline var HANDSHAKE_TIMEOUT = 10.0;

  /** Upper bound on one server message once its first byte has arrived. It
   * also bounds how long close and unsubscribe can wait behind a peer that
   * stalls halfway through a frame. */
  public static inline var MESSAGE_TIMEOUT = 2.5;

  static inline var WRITE_TIMEOUT = 3.0;

  final socket:Socket;
  var closed = false;
  var poisoned = false;
  var fragmentOpcode = 0;
  var fragments = new BytesBuffer();

  public function new(deployment:DeploymentUrl, clientVersion:String) {
    socket = SocketTransport.dial(deployment, HANDSHAKE_TIMEOUT);
    var key = Base64.encode(secureRandom(16));
    var target = deployment.path + "/api/sync?clientVersion=" + StringTools.urlEncode(clientVersion);
    var request = 'GET $target HTTP/1.1\r\nHost: ${deployment.hostHeader()}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n';
    var deadline = Sys.time() + HANDSHAKE_TIMEOUT;
    try {
      SocketTransport.writeAll(socket, Bytes.ofString(request), deadline, "WebSocket handshake");
      var raw = SocketTransport.readUntil(socket, "\r\n\r\n", 16 * 1024, deadline, "WebSocket handshake").toString();
      validateHandshake(raw, key);
    } catch (error:Dynamic) {
      SocketTransport.closeQuietly(socket);
      closed = true;
      throw error;
    }
  }

  public function isUsable():Bool {
    return !closed && !poisoned;
  }

  public function sendJson(value:Dynamic):Void {
    sendFrame(1, Bytes.ofString(haxe.Json.stringify(value)), true);
  }

  /** Wait up to `idle` seconds for a message. Returns null when the socket was
   * simply quiet, so the owner thread stays responsive to its own commands
   * without ever abandoning a healthy connection. */
  public function pollJson(idle:Float):Null<Dynamic> {
    if (!isUsable()) throw ConvexError.transport("Live", "WebSocket is not usable");
    return commit(function() {
      var first = SocketTransport.pollByte(socket, idle, "WebSocket frame");
      if (first < 0) return null;
      var text = readMessage(first);
      // A control frame on its own leaves the parser at a clean frame
      // boundary, so there is simply no application message to report yet.
      if (text == null) return null;
      JsonTools.checkJsonShape(Bytes.ofString(text), "WebSocket message JSON");
      var value:Dynamic;
      try value = haxe.Json.parse(text) catch (error:Dynamic) {
        throw ConvexError.protocol('WebSocket message was not valid JSON: ${Std.string(error)}');
      }
      return JsonTools.requireObject(value, "WebSocket message");
    });
  }

  public function close():Void {
    if (closed) return;
    if (!poisoned) try sendFrame(8, closePayload(1000), true) catch (_:Dynamic) {}
    closed = true;
    SocketTransport.closeQuietly(socket);
  }

  public function abort():Void {
    closed = true;
    SocketTransport.closeQuietly(socket);
  }

  /** Any failure while reading leaves the parser in an unknown position or
   * proves the peer is speaking a protocol this client cannot follow, so the
   * connection is retired rather than resumed. A quiet socket is not a
   * failure and never reaches here. */
  function commit<T>(body:Void->T):T {
    try {
      return body();
    } catch (error:Dynamic) {
      poisoned = true;
      SocketTransport.closeQuietly(socket);
      throw error;
    }
  }

  /** Returns the completed text message, or null when the frame just consumed
   * was control traffic and the parser is back at a clean frame boundary. */
  function readMessage(firstByte:Int):Null<String> {
    var deadline = Sys.time() + MESSAGE_TIMEOUT;
    var byte0 = firstByte;
    while (true) {
      var byte1 = SocketTransport.readExact(socket, 1, deadline, "WebSocket frame").get(0);
      var fin = (byte0 & 0x80) != 0;
      var opcode = byte0 & 0x0F;
      if ((byte0 & 0x70) != 0) throw ConvexError.protocol("WebSocket RSV bits were set");
      if ((byte1 & 0x80) != 0) throw ConvexError.protocol("server WebSocket frame was masked");
      var length = byte1 & 0x7F;
      if (length == 126) {
        var extended = SocketTransport.readExact(socket, 2, deadline, "WebSocket frame");
        length = (extended.get(0) << 8) | extended.get(1);
        if (length < 126) throw ConvexError.protocol("WebSocket length was not minimally encoded");
      } else if (length == 127) {
        var extended = SocketTransport.readExact(socket, 8, deadline, "WebSocket frame");
        for (index in 0...5) if (extended.get(index) != 0) throw ConvexError.protocol("WebSocket message exceeds supported range");
        length = (extended.get(5) << 16) | (extended.get(6) << 8) | extended.get(7);
        if (length < 65536) throw ConvexError.protocol("WebSocket length was not minimally encoded");
      }
      var control = opcode >= 8;
      if (control && (!fin || length > 125)) throw ConvexError.protocol("WebSocket control frame was fragmented or oversized");
      if (length > MAX_MESSAGE || fragments.length + length > MAX_MESSAGE) throw ConvexError.protocol("WebSocket message exceeded 4194304 bytes");
      var payload = SocketTransport.readExact(socket, length, deadline, "WebSocket frame");

      switch opcode {
        case 8:
          validateClose(payload);
          // Echo the peer's status before retiring the transport. The reply is
          // best effort: the peer may already have gone away.
          try sendFrame(8, payload.length >= 2 ? payload.sub(0, 2) : payload, true) catch (_:Dynamic) {}
          throw ConvexError.transport("Live", "WebSocket peer closed the connection");
        case 9:
          sendFrame(10, payload, true);
        case 10:
          // Pongs are transport housekeeping and never reach the Live parser.
        case 1:
          if (fragmentOpcode != 0) throw ConvexError.protocol("new data frame interrupted a fragmented message");
          if (fin) return validText(payload);
          fragmentOpcode = 1;
          fragments.addBytes(payload, 0, payload.length);
        case 0:
          if (fragmentOpcode == 0) throw ConvexError.protocol("unexpected WebSocket continuation frame");
          fragments.addBytes(payload, 0, payload.length);
          if (fin) {
            var completed = fragments.getBytes();
            fragments = new BytesBuffer();
            fragmentOpcode = 0;
            // Validation happens on the reassembled message so a split
            // multi-byte character is decoded rather than rejected.
            return validText(completed);
          }
        default:
          throw ConvexError.protocol('unsupported WebSocket opcode $opcode');
      }
      // A ping or pong that did not interrupt a fragmented message leaves the
      // parser at a clean boundary. Reporting that immediately keeps an idle
      // connection alive instead of holding the read open until the message
      // deadline expires and the connection is retired.
      if (control && fragmentOpcode == 0) return null;
      // Otherwise more frames belong to this message. The connection is
      // already committed, so the same message deadline still applies.
      byte0 = SocketTransport.readExact(socket, 1, deadline, "WebSocket frame").get(0);
    }
  }

  function sendFrame(opcode:Int, payload:Bytes, fin:Bool):Void {
    if (closed || poisoned) throw ConvexError.transport("WebSocket", "socket is closed");
    if (payload.length > MAX_MESSAGE || (opcode >= 8 && payload.length > 125)) {
      throw ConvexError.protocol("outbound WebSocket frame exceeded its bound");
    }
    var output = new BytesBuffer();
    output.addByte((fin ? 0x80 : 0) | opcode);
    if (payload.length < 126) {
      output.addByte(0x80 | payload.length);
    } else if (payload.length <= 65535) {
      output.addByte(0x80 | 126);
      output.addByte((payload.length >> 8) & 0xFF);
      output.addByte(payload.length & 0xFF);
    } else {
      output.addByte(0x80 | 127);
      for (_ in 0...4) output.addByte(0);
      output.addByte((payload.length >> 24) & 0xFF);
      output.addByte((payload.length >> 16) & 0xFF);
      output.addByte((payload.length >> 8) & 0xFF);
      output.addByte(payload.length & 0xFF);
    }
    var mask = secureRandom(4);
    output.addBytes(mask, 0, 4);
    for (index in 0...payload.length) output.addByte(payload.get(index) ^ mask.get(index % 4));
    SocketTransport.writeAll(socket, output.getBytes(), Sys.time() + WRITE_TIMEOUT, "WebSocket write");
  }

  static function closePayload(code:Int):Bytes {
    var payload = Bytes.alloc(2);
    payload.set(0, (code >> 8) & 0xFF);
    payload.set(1, code & 0xFF);
    return payload;
  }

  static function validateHandshake(raw:String, key:String):Void {
    var lines = raw.substr(0, raw.length - 4).split("\r\n");
    var status = lines.shift();
    if (status == null || !(~/^HTTP\/1\.1 101(?: |$)/).match(status)) throw ConvexError.protocol("WebSocket handshake did not return HTTP 101");
    var headers = new Map<String, String>();
    for (line in lines) {
      var colon = line.indexOf(":");
      if (colon <= 0) throw ConvexError.protocol("WebSocket handshake header was malformed");
      var name = line.substr(0, colon).toLowerCase();
      var value = StringTools.trim(line.substr(colon + 1));
      headers.set(name, headers.exists(name) ? headers.get(name) + "," + value : value);
    }
    if (!hasToken(headers.get("upgrade"), "websocket")) throw ConvexError.protocol("WebSocket Upgrade token was missing");
    if (!hasToken(headers.get("connection"), "upgrade")) throw ConvexError.protocol("WebSocket Connection token was missing");
    // No extension or subprotocol was offered, so the server must not select
    // one; the frame parser below assumes an unextended data path.
    if (headers.exists("sec-websocket-extensions")) throw ConvexError.protocol("WebSocket server selected an unrequested extension");
    if (headers.exists("sec-websocket-protocol")) throw ConvexError.protocol("WebSocket server selected an unrequested subprotocol");
    var expected = Base64.encode(Sha1.make(Bytes.ofString(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
    if (headers.get("sec-websocket-accept") != expected) throw ConvexError.protocol("WebSocket accept value was invalid");
  }

  static function hasToken(value:Null<String>, token:String):Bool {
    if (value == null) return false;
    for (part in value.split(",")) if (StringTools.trim(part).toLowerCase() == token) return true;
    return false;
  }

  static function validText(bytes:Bytes):String {
    if (!Utf8Text.isValid(bytes)) throw ConvexError.protocol("WebSocket text was not valid UTF-8");
    return bytes.toString();
  }

  static function validateClose(payload:Bytes):Void {
    if (payload.length == 1) throw ConvexError.protocol("WebSocket close payload was malformed");
    if (payload.length >= 2) {
      var code = (payload.get(0) << 8) | payload.get(1);
      if (code < 1000 || code == 1004 || code == 1005 || code == 1006 || (code >= 1016 && code < 3000) || code >= 5000) {
        throw ConvexError.protocol("WebSocket close code was invalid");
      }
      if (payload.length > 2) validText(payload.sub(2, payload.length - 2));
    }
  }

  public static function secureRandom(length:Int):Bytes {
    var input = File.read("/dev/urandom", true);
    var bytes = Bytes.alloc(length);
    try input.readFullBytes(bytes, 0, length) catch (error:Dynamic) {
      input.close();
      throw ConvexError.transport("random", Std.string(error));
    }
    input.close();
    return bytes;
  }
}
