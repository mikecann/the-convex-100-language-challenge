/** A successful Convex function result and its structured log lines. */
class ConvexResult {
  public final value:Dynamic;
  public final logs:Array<String>;

  public function new(value:Dynamic, logs:Array<String>) {
    this.value = value;
    this.logs = logs;
  }
}
