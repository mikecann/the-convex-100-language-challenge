/** One value or one structured failure delivered by a Live subscription. */
class LiveEvent {
  public final value:Dynamic;
  public final error:Null<ConvexError>;
  public final logs:Array<String>;

  public function new(value:Dynamic, ?error:ConvexError, ?logs:Array<String>) {
    this.value = value;
    this.error = error;
    this.logs = logs == null ? [] : logs;
  }
}
