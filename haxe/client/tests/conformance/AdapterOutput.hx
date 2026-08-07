import haxe.Json;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.Output;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

private class OutputItem {
  /** Only the encoded line is retained. Holding the decoded event as well
   * would double the queue's real memory cost for no benefit, because the
   * writer never inspects anything but these bytes. */
  public final encoded:Null<Bytes>;

  public final subscriptionId:Null<String>;
  public final token:Int;
  public final done:Null<Lock>;

  public var counted(get, never):Bool;

  function get_counted():Bool {
    return encoded != null;
  }

  public function new(?encoded:Bytes, ?subscriptionId:String, token:Int = 0, ?done:Lock) {
    this.encoded = encoded;
    this.subscriptionId = subscriptionId;
    this.token = token;
    this.done = done;
  }
}

/** One ordered writer for stdout or TCP. Count and byte reservations happen
 * before enqueue; relay ownership is checked again immediately before write. */
class AdapterOutput {
  static inline var MAX_EVENTS = 16;

  /** Retained encoded output. One HTTP result may legitimately approach the
   * transport's body cap, so a single event is allowed to be large while the
   * queue as a whole stays small. */
  static inline var MAX_BYTES = 12 * 1024 * 1024;

  static inline var MAX_EVENT_BYTES = HttpTransport.MAX_BODY + 1024 * 1024;

  final output:Output;
  final socket:Null<Socket>;
  final queue = new Deque<OutputItem>();
  final mutex = new Mutex();
  final owners = new StringMap<Int>();
  final stopped = new Lock();
  var count = 0;
  var bytes = 0;
  var terminal = false;

  public function new(output:Output, ?socket:Socket) {
    this.output = output;
    this.socket = socket;
    Thread.create(writer);
  }

  public function setOwner(subscriptionId:String, token:Int):Void {
    mutex.acquire();
    owners.set(subscriptionId, token);
    mutex.release();
  }

  public function revoke(subscriptionId:String):Void {
    mutex.acquire();
    owners.remove(subscriptionId);
    mutex.release();
  }

  public function emit(event:Dynamic, ?subscriptionId:String, token:Int = 0):Void {
    var encoded = Bytes.ofString(Json.stringify(event) + "\n");
    if (encoded.length > MAX_EVENT_BYTES) throw ConvexError.protocol("adapter event exceeded output limit");
    mutex.acquire();
    // A revoked relay may race shutdown after it has already obtained a value.
    // Discard it before applying terminal overflow policy, then check ownership
    // again in the writer immediately before the actual write.
    if (subscriptionId != null && owners.get(subscriptionId) != token) {
      mutex.release();
      return;
    }
    if (terminal || count >= MAX_EVENTS || bytes + encoded.length > MAX_BYTES) {
      terminal = true;
      mutex.release();
      if (socket != null) SocketTransport.closeQuietly(socket) else Sys.exit(1);
      throw ConvexError.transport("adapter output", "bounded output queue exhausted");
    }
    count++;
    bytes += encoded.length;
    queue.add(new OutputItem(encoded, subscriptionId, token));
    mutex.release();
  }

  public function flush(timeout:Float):Void {
    var done = new Lock();
    queue.add(new OutputItem(null, null, 0, done));
    if (!done.wait(timeout)) throw ConvexError.transport("adapter output", "flush deadline exceeded");
  }

  public function close():Void {
    flush(1.0);
    mutex.acquire();
    terminal = true;
    mutex.release();
    queue.add(new OutputItem());
    stopped.wait(1.0);
  }

  function writer():Void {
    while (true) {
      var item = queue.pop(true);
      mutex.acquire();
      var shouldStop = terminal && !item.counted && item.done == null;
      var allowed = item.subscriptionId == null || owners.get(item.subscriptionId) == item.token;
      mutex.release();
      if (shouldStop) break;
      if (item.done != null) {
        try output.flush() catch (_:Dynamic) {}
        item.done.release();
        continue;
      }
      if (!allowed) {
        release(item);
        continue;
      }
      try {
        if (socket != null) {
          writeTcp(item.encoded);
        } else {
          writeStdout(item.encoded);
        }
        release(item);
      } catch (_:Dynamic) {
        release(item);
        mutex.acquire();
        terminal = true;
        mutex.release();
        if (socket != null) SocketTransport.closeQuietly(socket) else Sys.exit(1);
        break;
      }
    }
    stopped.release();
  }

  function writeStdout(encoded:Bytes):Void {
    var done = new Lock();
    var failure:Dynamic = null;
    Thread.create(function() {
      try {
        output.writeFullBytes(encoded, 0, encoded.length);
        output.flush();
      } catch (error:Dynamic) {
        failure = error;
      }
      done.release();
    });
    // Neko does not expose stdout as a selectable Socket. A blocked stdout
    // write is therefore isolated to this worker; missing the cumulative
    // deadline terminates the adapter instead of retaining unbounded output.
    if (!done.wait(1.0)) Sys.exit(1);
    if (failure != null) throw failure;
  }

  function writeTcp(encoded:Bytes):Void {
    var done = new Lock();
    var failure:Dynamic = null;
    Thread.create(function() {
      try {
        output.writeFullBytes(encoded, 0, encoded.length);
        output.flush();
      } catch (error:Dynamic) {
        failure = error;
      }
      done.release();
    });
    // Socket.setTimeout is shared by reads and writes on Neko. Isolating the
    // blocking write avoids shortening the controller's independent read while
    // still enforcing one cumulative deadline for the serialized event.
    if (!done.wait(1.0)) {
      SocketTransport.closeQuietly(socket);
      throw ConvexError.transport("adapter TCP output", "cumulative write deadline exceeded");
    }
    if (failure != null) throw failure;
  }

  function release(item:OutputItem):Void {
    if (!item.counted) return;
    mutex.acquire();
    count--;
    bytes -= item.encoded.length;
    mutex.release();
  }
}
