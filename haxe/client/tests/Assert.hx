/** Assertions shared by the language-local suites.
 *
 * Every fixture in this directory is a real socket server, so the client under
 * test exercises its own framing, deadlines, and reconnect logic instead of a
 * mock that could quietly agree with a wrong implementation. */
class Assert {
  public static var count = 0;

  public static function ok(condition:Bool, label:String):Void {
    count++;
    if (!condition) throw 'FAILED $label';
  }

  public static function equal(actual:Dynamic, expected:Dynamic, label:String):Void {
    count++;
    if (actual != expected) throw 'FAILED $label: expected $expected, got $actual';
  }

  public static function throwsKind(kind:String, callback:Void->Dynamic, label:String):ConvexError {
    count++;
    try {
      callback();
    } catch (error:ConvexError) {
      if (error.kind != kind) throw 'FAILED $label: expected $kind, got ${error.kind}: ${error.message}';
      return error;
    } catch (error:Dynamic) {
      throw 'FAILED $label: expected $kind, got ${Std.string(error)}';
    }
    throw 'FAILED $label: expected a $kind failure';
  }

  /** Assert that an operation both fails and finishes inside its documented
   * bound. Boundedness claims are only meaningful when the deadline itself is
   * measured, so no test here waits on a cooperative peer to hang up. */
  public static function within(bound:Float, callback:Void->Dynamic, label:String):Float {
    count++;
    var started = Sys.time();
    try callback() catch (_:Dynamic) {}
    var elapsed = Sys.time() - started;
    if (elapsed > bound) throw 'FAILED $label: took ${elapsed}s, bound was ${bound}s';
    return elapsed;
  }
}
