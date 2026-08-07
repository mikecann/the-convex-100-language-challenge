import haxe.Exception;

class Main {
  static function wholeCount(value:Dynamic, operation:String):Int {
    // Convex may encode a whole count as either 1 or 1.0. Accept only a finite,
    // exactly integral value that fits the teaching example's Int range.
    if (!Std.isOfType(value, Int) && !Std.isOfType(value, Float)) {
      throw new Exception('$operation count was not a JSON number');
    }
    var number:Float = value;
    if (!Math.isFinite(number) || Math.floor(number) != number || number < -2147483648.0 || number > 2147483647.0) {
      throw new Exception('$operation count was not an in-range whole number');
    }
    return Std.int(number);
  }

  static function countOf(value:Dynamic, operation:String):Int {
    if (value == null || !Reflect.hasField(value, "count")) {
      throw new Exception('$operation omitted count');
    }
    return wholeCount(Reflect.field(value, "count"), operation);
  }

  public static function main():Void {
    // Read the deployment and verifier-provided isolated room without baking
    // credentials or environment-specific data into the example image.
    var url = Sys.getEnv("CONVEX_URL");
    if (url == null || url.length == 0) throw new Exception("CONVEX_URL is required");
    var arguments = Sys.args();
    var room = arguments.length > 0 ? arguments[0] : "haxe-basic-example";

    // Create the native Haxe client. Its Neko runtime supplies only ordinary
    // TLS and sockets; the Convex protocol lives in the adjacent Haxe source.
    var client = new ConvexClient(url);
    var subscription:Null<LiveSubscription> = null;
    var failure:Dynamic = null;
    try {
      var callArguments:Dynamic = {room: room};

      // Query first so HTTP establishes the expected initial counter value.
      var current = countOf(client.query("demo:state", callArguments).value, "current query");
      if (current != 0) throw new Exception('current count was $current, expected 0');
      Sys.println('current count: $current');

      // Start Live before mutating, so the initial snapshot cannot be missed.
      subscription = client.subscribe("basic-counter", "demo:state", callArguments);
      var initial = subscription.next(10.0);
      if (initial.error != null) throw initial.error;
      if (countOf(initial.value, "initial Live value") != current) {
        throw new Exception("initial Live value disagreed with HTTP");
      }
      Sys.println('live initial count: $current');

      // Use a fresh idempotency key so retrying transport work cannot apply
      // this logical increment twice.
      var mutation = client.mutation("demo:increment", {
        room: room,
        language: "Haxe",
        runId: ConvexClient.randomId()
      }).value;
      if (Reflect.field(mutation, "applied") != true) throw new Exception("mutation was not applied");
      Sys.println("mutation applied: true");
      var expected = current + 1;
      if (countOf(Reflect.field(mutation, "state"), "mutation") != expected) {
        throw new Exception("mutation count disagreed");
      }
      Sys.println('mutation count: $expected');

      // Wait for the same Live query to observe the mutation before claiming
      // the full 0 -> 1 journey succeeded.
      var updated = subscription.next(10.0);
      if (updated.error != null) throw updated.error;
      if (countOf(updated.value, "updated Live value") != expected) {
        throw new Exception("updated Live count disagreed");
      }
      Sys.println('live updated count: $expected');
      Sys.println('verified count: $current -> $expected');
    } catch (error:Dynamic) {
      failure = error;
    }
    // Retire this exact subscription generation before closing the owner. Haxe
    // has no finally statement, so cleanup is explicit and the original error
    // is rethrown only after both lifecycle operations have had a chance to run.
    if (subscription != null) try subscription.close() catch (_:Dynamic) {}
    client.close();
    if (failure != null) throw failure;
  }
}
