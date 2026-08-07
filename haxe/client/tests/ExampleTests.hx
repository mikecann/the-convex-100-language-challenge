/** Regressions for the canonical example's own decoder.
 *
 * These call the exact functions in `examples/basics/Main.hx` that the README
 * and website publish, and they feed them values decoded from a real HTTP
 * response rather than hand-built integers, so an integral `0.0` from Convex
 * is proven to work end to end. */
@:access(Main)
class ExampleTests {
  public static function run():Void {
    var fixture = new HttpFixture([
      HttpFixture.success('{"count":0.0}'),
      HttpFixture.success('{"count":1}'),
      HttpFixture.success('{"count":1.5}'),
      HttpFixture.success('{"count":"1"}'),
      HttpFixture.success('{"count":1e999}'),
      HttpFixture.success('{"other":1}')
    ]);
    var client = new ConvexClient(fixture.url());
    Assert.equal(Main.countOf(client.query("demo:state", {}).value, "test"), 0, "an integral 0.0 decodes as zero");
    Assert.equal(Main.countOf(client.query("demo:state", {}).value, "test"), 1, "a plain 1 decodes as one");

    var fractional = client.query("demo:state", {}).value;
    throwsExample(function() return Main.countOf(fractional, "test"), "a fractional count is rejected");
    var quoted = client.query("demo:state", {}).value;
    throwsExample(function() return Main.countOf(quoted, "test"), "a quoted count is rejected");
    var overflowing = client.query("demo:state", {}).value;
    throwsExample(function() return Main.countOf(overflowing, "test"), "a non-finite count is rejected");
    var missing = client.query("demo:state", {}).value;
    throwsExample(function() return Main.countOf(missing, "test"), "a missing count is rejected");
    client.close();
  }

  static function throwsExample(callback:Void->Dynamic, label:String):Void {
    Assert.count++;
    try {
      callback();
    } catch (_:haxe.Exception) {
      return;
    }
    throw 'FAILED $label: expected the example decoder to reject the value';
  }
}
