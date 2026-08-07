import haxe.Json;
import haxe.crypto.Base64;
import haxe.crypto.Sha1;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;

/** A scripted Convex sync peer: a real RFC 6455 server that records every
 * client message and emits exactly the frames a test asks for, including
 * deliberately malformed ones. */
class SyncFixture {
  static inline var GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

  public final port:Int;

  final server:Socket;
  final inbound = new Deque<Dynamic>();
  final outbound = new Deque<Bytes>();
  final mutex = new Mutex();
  var connectionsSeen = 0;
  var running = true;

  public function new() {
    server = new Socket();
    server.bind(new Host("127.0.0.1"), 0);
    server.listen(8);
    port = server.host().port;
    Thread.create(acceptLoop);
  }

  public function url():String {
    return 'http://127.0.0.1:$port';
  }

  public function connections():Int {
    mutex.acquire();
    var seen = connectionsSeen;
    mutex.release();
    return seen;
  }

  /** Block until the client has established `expected` connections in total. */
  public function awaitConnections(expected:Int, timeout:Float):Void {
    var deadline = Sys.time() + timeout;
    while (Sys.time() < deadline) {
      if (connections() >= expected) return;
      Sys.sleep(0.005);
    }
    throw 'fixture saw ${connections()} connections, expected $expected';
  }

  public function sendJson(value:Dynamic):Void {
    sendRaw(textFrame(Bytes.ofString(Json.stringify(value))));
  }

  /** Queue bytes exactly as given, so malformed framing can be tested. */
  public function sendRaw(bytes:Bytes):Void {
    outbound.add(bytes);
  }

  /** The next client message of the given type, ignoring earlier ones. */
  public function expect(type:String, timeout:Float):Dynamic {
    var deadline = Sys.time() + timeout;
    while (Sys.time() < deadline) {
      var message = inbound.pop(false);
      if (message != null && Reflect.field(message, "type") == type) return message;
      if (message == null) Sys.sleep(0.005);
    }
    throw 'fixture never received a $type message';
  }

  /** Assert no client message arrives within the window. */
  public function expectSilence(window:Float):Void {
    var deadline = Sys.time() + window;
    while (Sys.time() < deadline) {
      var message = inbound.pop(false);
      if (message != null) throw 'fixture received an unexpected ${Reflect.field(message, "type")} message';
      Sys.sleep(0.005);
    }
  }

  public function close():Void {
    running = false;
    SocketTransport.closeQuietly(server);
  }

  public static function textFrame(payload:Bytes):Bytes {
    return frame(0x81, payload);
  }

  public static function frame(header:Int, payload:Bytes):Bytes {
    var output = new BytesBuffer();
    output.addByte(header);
    if (payload.length < 126) {
      output.addByte(payload.length);
    } else if (payload.length <= 65535) {
      output.addByte(126);
      output.addByte((payload.length >> 8) & 0xFF);
      output.addByte(payload.length & 0xFF);
    } else {
      output.addByte(127);
      for (_ in 0...4) output.addByte(0);
      output.addByte((payload.length >> 24) & 0xFF);
      output.addByte((payload.length >> 16) & 0xFF);
      output.addByte((payload.length >> 8) & 0xFF);
      output.addByte(payload.length & 0xFF);
    }
    output.addBytes(payload, 0, payload.length);
    return output.getBytes();
  }

  /** Protocol timestamps are base64 of eight little-endian bytes. */
  public static function timestamp(value:Int):String {
    var bytes = Bytes.alloc(8);
    var remaining = value;
    for (index in 0...8) {
      bytes.set(index, remaining & 0xFF);
      remaining = remaining >> 8;
    }
    return Base64.encode(bytes);
  }

  /** A transition whose start version is the client's current one. */
  public static function transition(querySet:Int, fromTs:String, toTs:String, modifications:Array<Dynamic>):Dynamic {
    return {
      type: "Transition",
      startVersion: {querySet: querySet, identity: 0, ts: fromTs},
      endVersion: {querySet: querySet + 1, identity: 0, ts: toTs},
      modifications: modifications
    };
  }

  function acceptLoop():Void {
    while (running) {
      var peer:Null<Socket> = null;
      try {
        server.setTimeout(0.25);
        peer = server.accept();
      } catch (_:Dynamic) {
        continue;
      }
      mutex.acquire();
      connectionsSeen++;
      mutex.release();
      try serveConnection(peer) catch (_:Dynamic) {}
      SocketTransport.closeQuietly(peer);
    }
  }

  function serveConnection(peer:Socket):Void {
    var deadline = Sys.time() + 5.0;
    var raw = SocketTransport.readUntil(peer, "\r\n\r\n", 16 * 1024, deadline, "fixture handshake").toString();
    var key = headerValue(raw, "sec-websocket-key");
    if (key == null) throw "fixture handshake had no key";
    var accept = Base64.encode(Sha1.make(Bytes.ofString(key + GUID)));
    var response = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n';
    SocketTransport.writeAll(peer, Bytes.ofString(response), deadline, "fixture handshake");

    while (running) {
      var pending = outbound.pop(false);
      while (pending != null) {
        SocketTransport.writeAll(peer, pending, Sys.time() + 5.0, "fixture write");
        pending = outbound.pop(false);
      }
      var first = SocketTransport.pollByte(peer, 0.02, "fixture read");
      if (first < 0) continue;
      var message = readClientFrame(peer, first);
      if (message != null) inbound.add(message);
    }
  }

  function readClientFrame(peer:Socket, firstByte:Int):Null<Dynamic> {
    var deadline = Sys.time() + 5.0;
    var opcode = firstByte & 0x0F;
    var second = SocketTransport.readExact(peer, 1, deadline, "fixture frame").get(0);
    if ((second & 0x80) == 0) throw "client frame was not masked";
    var length = second & 0x7F;
    if (length == 126) {
      var extended = SocketTransport.readExact(peer, 2, deadline, "fixture frame");
      length = (extended.get(0) << 8) | extended.get(1);
    } else if (length == 127) {
      var extended = SocketTransport.readExact(peer, 8, deadline, "fixture frame");
      length = (extended.get(5) << 16) | (extended.get(6) << 8) | extended.get(7);
    }
    var mask = SocketTransport.readExact(peer, 4, deadline, "fixture frame");
    var payload = SocketTransport.readExact(peer, length, deadline, "fixture frame");
    var plain = Bytes.alloc(length);
    for (index in 0...length) plain.set(index, payload.get(index) ^ mask.get(index % 4));
    // Only client text frames carry sync messages; pongs and closes are
    // recorded as their own pseudo-messages so tests can assert them.
    if (opcode == 1) return Json.parse(plain.toString());
    if (opcode == 8) return {type: "ClientClose"};
    if (opcode == 10) return {type: "ClientPong", payload: plain.toString()};
    return null;
  }

  static function headerValue(raw:String, name:String):Null<String> {
    for (line in raw.split("\r\n")) {
      var colon = line.indexOf(":");
      if (colon <= 0) continue;
      if (line.substr(0, colon).toLowerCase() == name) return StringTools.trim(line.substr(colon + 1));
    }
    return null;
  }
}
