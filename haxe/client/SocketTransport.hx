import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;
import haxe.io.Error;
import sys.net.Host;
import sys.net.Socket;
import sys.ssl.Certificate;
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;

private typedef DialResult = {
  var socket:Null<Socket>;
  var error:Null<String>;
}

/** Deadline-aware socket primitives.
 *
 * Neko reports a socket timeout by throwing `haxe.io.Error.Blocked`. That is a
 * "nothing arrived yet" signal, not a failure, so every read and write here
 * polls with a short socket timeout and retries until the caller's absolute
 * deadline. Treating `Blocked` as fatal would turn any peer slower than the
 * poll interval into a transport error. The late-dial guard retires a socket
 * even when DNS or connect completes after its caller has already timed out. */
class SocketTransport {
  /** Distinguishes an orderly peer close from any other transport failure so
   * `Connection: close` framing does not have to match on message text. */
  public static inline var PEER_CLOSED = "peer closed the socket";

  static inline var POLL = 0.1;

  static final dialBudget = new Mutex();
  static var activeDials = 0;

  public static function dial(url:DeploymentUrl, timeout:Float):Socket {
    dialBudget.acquire();
    if (activeDials >= 8) {
      dialBudget.release();
      throw ConvexError.transport("connect", "bounded dial worker budget exhausted");
    }
    activeDials++;
    dialBudget.release();
    var result = new Deque<DialResult>();
    var guard = new Mutex();
    var abandoned = false;
    Thread.create(function() {
      var socket:Null<Socket> = null;
      var error:Null<String> = null;
      try {
        if (url.secure) {
          var tls = new sys.ssl.Socket();
          tls.verifyCert = true;
          tls.setCA(Certificate.loadDefaults());
          tls.setHostname(url.host);
          socket = tls;
        } else {
          socket = new Socket();
        }
        socket.setTimeout(timeout);
        socket.connect(new Host(url.host), url.port);
      } catch (failure:Dynamic) {
        error = Std.string(failure);
        closeQuietly(socket);
        socket = null;
      }
      guard.acquire();
      if (abandoned) {
        closeQuietly(socket);
      } else {
        result.add({socket: socket, error: error});
      }
      guard.release();
      dialBudget.acquire();
      activeDials--;
      dialBudget.release();
    });

    var deadline = Sys.time() + timeout;
    while (Sys.time() < deadline) {
      var ready = result.pop(false);
      if (ready != null) {
        if (ready.socket == null) throw ConvexError.transport("connect", ready.error == null ? "connection failed" : ready.error);
        return ready.socket;
      }
      Sys.sleep(0.005);
    }
    guard.acquire();
    abandoned = true;
    // The worker may have published a socket after the final poll but before
    // this guard was acquired. Drain and retire that late result here; the
    // worker closes it itself when it observes `abandoned` first.
    var late = result.pop(false);
    if (late != null) closeQuietly(late.socket);
    guard.release();
    throw ConvexError.transport("connect", "absolute connection deadline exceeded");
  }

  static inline function isBlocked(error:Error):Bool {
    return switch error {
      case Blocked: true;
      default: false;
    };
  }

  public static function writeAll(socket:Socket, bytes:Bytes, deadline:Float, operation:String):Void {
    var offset = 0;
    while (offset < bytes.length) {
      var left = deadline - Sys.time();
      if (left <= 0) throw ConvexError.transport(operation, "absolute write deadline exceeded");
      socket.setTimeout(left < POLL ? left : POLL);
      try {
        var wrote = socket.output.writeBytes(bytes, offset, bytes.length - offset);
        if (wrote <= 0) throw ConvexError.transport(operation, "socket made no write progress");
        offset += wrote;
      } catch (error:ConvexError) {
        throw error;
      } catch (error:Error) {
        // Blocked simply means this poll window expired with no room to write.
        if (!isBlocked(error)) throw ConvexError.transport(operation, Std.string(error));
      } catch (_:Eof) {
        throw ConvexError.transport(operation, PEER_CLOSED);
      } catch (error:Dynamic) {
        throw ConvexError.transport(operation, Std.string(error));
      }
    }
    flushWithin(socket, deadline, operation);
  }

  static function flushWithin(socket:Socket, deadline:Float, operation:String):Void {
    while (true) {
      var left = deadline - Sys.time();
      if (left <= 0) throw ConvexError.transport(operation, "absolute write deadline exceeded");
      socket.setTimeout(left < POLL ? left : POLL);
      try {
        socket.output.flush();
        return;
      } catch (error:Error) {
        if (!isBlocked(error)) throw ConvexError.transport(operation, Std.string(error));
      } catch (_:Eof) {
        throw ConvexError.transport(operation, PEER_CLOSED);
      } catch (error:Dynamic) {
        throw ConvexError.transport(operation, Std.string(error));
      }
    }
  }

  public static function readExact(socket:Socket, length:Int, deadline:Float, operation:String):Bytes {
    var bytes = Bytes.alloc(length);
    var offset = 0;
    while (offset < length) {
      offset += readSome(socket, bytes, offset, length - offset, deadline, operation);
    }
    return bytes;
  }

  /** Read at least one byte, polling until the absolute deadline. */
  public static function readSome(socket:Socket, into:Bytes, offset:Int, length:Int, deadline:Float, operation:String):Int {
    while (true) {
      var left = deadline - Sys.time();
      if (left <= 0) throw ConvexError.transport(operation, "absolute read deadline exceeded");
      socket.setTimeout(left < POLL ? left : POLL);
      try {
        var count = socket.input.readBytes(into, offset, length);
        if (count <= 0) throw ConvexError.transport(operation, PEER_CLOSED);
        return count;
      } catch (error:ConvexError) {
        throw error;
      } catch (error:Error) {
        if (!isBlocked(error)) throw ConvexError.transport(operation, Std.string(error));
      } catch (_:Eof) {
        throw ConvexError.transport(operation, PEER_CLOSED);
      } catch (error:Dynamic) {
        throw ConvexError.transport(operation, Std.string(error));
      }
    }
  }

  /** Read one byte, returning -1 when the poll window expired with the socket
   * still idle. Callers use this to stay responsive to their own work without
   * abandoning a connection that is merely quiet. */
  public static function pollByte(socket:Socket, idle:Float, operation:String):Int {
    var single = Bytes.alloc(1);
    socket.setTimeout(idle);
    try {
      var count = socket.input.readBytes(single, 0, 1);
      if (count <= 0) throw ConvexError.transport(operation, PEER_CLOSED);
      return single.get(0);
    } catch (error:ConvexError) {
      throw error;
    } catch (error:Error) {
      if (!isBlocked(error)) throw ConvexError.transport(operation, Std.string(error));
      return -1;
    } catch (_:Eof) {
      throw ConvexError.transport(operation, PEER_CLOSED);
    } catch (error:Dynamic) {
      throw ConvexError.transport(operation, Std.string(error));
    }
  }

  /** Read until the ASCII marker, comparing raw bytes so a multi-byte value
   * can never shift the window and hide a real boundary. */
  public static function readUntil(socket:Socket, marker:String, maximum:Int, deadline:Float, operation:String):Bytes {
    var needle = Bytes.ofString(marker);
    var output = new BytesBuffer();
    var window = Bytes.alloc(needle.length);
    var filled = 0;
    while (true) {
      var byte = readExact(socket, 1, deadline, operation).get(0);
      output.addByte(byte);
      if (filled == needle.length) {
        // Shift in place; an overlapping blit is not guaranteed to be safe.
        for (slot in 0...needle.length - 1) window.set(slot, window.get(slot + 1));
        window.set(needle.length - 1, byte);
      } else {
        window.set(filled, byte);
        filled++;
      }
      if (filled == needle.length && window.compare(needle) == 0) return output.getBytes();
      if (output.length >= maximum) throw ConvexError.protocol('$operation exceeded $maximum bytes');
    }
  }

  public static function closeQuietly(socket:Null<Socket>):Void {
    if (socket == null) return;
    try socket.shutdown(true, true) catch (_:Dynamic) {}
    try socket.close() catch (_:Dynamic) {}
  }
}
