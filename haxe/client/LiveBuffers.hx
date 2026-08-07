import haxe.ds.StringMap;
import sys.thread.Lock;
import sys.thread.Mutex;

private typedef BufferedEvent = {
  var subscriptionId:String;
  var generation:Int;
  var event:LiveEvent;
  var charge:Int;
}

/** One global count and memory budget, rather than an unbounded queue hidden
 * in each subscription. Consumers remove only their exact generation.
 *
 * A queued update is retained as a decoded Neko value, which costs several
 * times its encoded length. The budget therefore charges a multiple of the
 * encoded size plus a fixed per-record allowance, so the real resident cost
 * stays well inside the shared 128 MiB container limit even when the reader
 * has stopped and every queued message is close to the frame maximum. */
class LiveBuffers {
  static inline var MAX_COUNT = 16;
  static inline var MAX_CHARGE = 24 * 1024 * 1024;
  static inline var DECODED_MULTIPLE = 4;
  static inline var RECORD_OVERHEAD = 512;

  final mutex = new Mutex();
  final wakeups = new StringMap<Lock>();
  var entries:Array<BufferedEvent> = [];
  var charged = 0;

  public function new() {}

  public function register(subscriptionId:String, generation:Int):Void {
    mutex.acquire();
    wakeups.set(key(subscriptionId, generation), new Lock());
    mutex.release();
  }

  public function add(subscriptionId:String, generation:Int, event:LiveEvent):Bool {
    var charge = chargeFor(event);
    var replaced = false;
    if (charge > MAX_CHARGE) {
      replaced = true;
      event = new LiveEvent(null, ConvexError.protocol("Live update exceeded the delivery budget"));
      charge = chargeFor(event);
    }
    mutex.acquire();
    var wake = wakeups.get(key(subscriptionId, generation));
    if (wake == null) {
      mutex.release();
      return false;
    }
    // Discard the globally oldest queued state first. Dropping newest would
    // leave a consumer permanently behind the current value.
    while (entries.length > 0 && (entries.length >= MAX_COUNT || charged + charge > MAX_CHARGE)) {
      var removed = entries.shift();
      charged -= removed.charge;
    }
    entries.push({subscriptionId: subscriptionId, generation: generation, event: event, charge: charge});
    charged += charge;
    wake.release();
    mutex.release();
    return !replaced;
  }

  static function chargeFor(event:LiveEvent):Int {
    var encoded = JsonTools.encodedBytes({
      value: event.value,
      error: event.error == null ? null : event.error.message,
      data: event.error == null ? null : event.error.data,
      logs: event.logs
    });
    return encoded * DECODED_MULTIPLE + RECORD_OVERHEAD;
  }

  public function next(subscriptionId:String, generation:Int, timeout:Float):LiveEvent {
    var deadline = Sys.time() + timeout;
    var name = key(subscriptionId, generation);
    while (true) {
      mutex.acquire();
      var wake = wakeups.get(name);
      if (wake == null) {
        mutex.release();
        throw ConvexError.protocol("subscription generation is no longer active");
      }
      var found = -1;
      for (index in 0...entries.length) {
        var entry = entries[index];
        if (entry.subscriptionId == subscriptionId && entry.generation == generation) {
          found = index;
          break;
        }
      }
      if (found >= 0) {
        var entry = entries.splice(found, 1)[0];
        charged -= entry.charge;
        mutex.release();
        return entry.event;
      }
      mutex.release();
      var left = deadline - Sys.time();
      if (left <= 0 || !wake.wait(left)) throw ConvexError.transport("Live next", "deadline exceeded");
    }
  }

  public function invalidate(subscriptionId:String, generation:Int):Void {
    mutex.acquire();
    var name = key(subscriptionId, generation);
    var wake = wakeups.get(name);
    wakeups.remove(name);
    var kept:Array<BufferedEvent> = [];
    for (entry in entries) {
      if (entry.subscriptionId == subscriptionId && entry.generation == generation) charged -= entry.charge else kept.push(entry);
    }
    entries = kept;
    if (wake != null) wake.release();
    mutex.release();
  }

  static inline function key(subscriptionId:String, generation:Int):String {
    return subscriptionId + "\x00" + generation;
  }
}
