/** Language-local suite for the Haxe Convex client.
 *
 * Every suite runs against real sockets and the real owner thread, so a
 * failure here is a real defect rather than a disagreement between two mocks.
 * The Docker `test` stage runs this before it builds either runtime image. */
class Tests {
  public static function main():Void {
    var started = Sys.time();
    UnitTests.run();
    HttpTests.run();
    ExampleTests.run();
    FrameTests.run();
    LiveTests.run();
    AdapterTests.run();
    var elapsed = Math.round((Sys.time() - started) * 10) / 10;
    Sys.println('haxe tests passed: ${Assert.count} assertions in ${elapsed}s');
  }
}
