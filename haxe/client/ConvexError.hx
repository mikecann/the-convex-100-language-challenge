import haxe.Exception;

/** A typed failure that survives the adapter boundary without guesswork. */
class ConvexError extends Exception {
  public final kind:String;
  public final operation:Null<String>;
  public final data:Dynamic;
  public final logs:Array<String>;

  public function new(kind:String, message:String, ?operation:String, ?data:Dynamic, ?logs:Array<String>) {
    super(message);
    this.kind = kind;
    this.operation = operation;
    this.data = data;
    this.logs = logs == null ? [] : logs;
  }

  public static function protocol(message:String):ConvexError {
    return new ConvexError("ProtocolError", message);
  }

  public static function transport(operation:String, message:String):ConvexError {
    return new ConvexError("TransportError", message, operation);
  }

  public static function closed():ConvexError {
    return new ConvexError("ClientClosed", "Convex client is closed");
  }
}
