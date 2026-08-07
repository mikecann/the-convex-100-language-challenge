import haxe.io.Bytes;

/** Educational native Haxe client for Convex HTTP and the pinned sync profile.
 * It is intentionally small and is not an official Convex SDK. */
class ConvexClient {
  static inline var CLIENT_VERSION = "haxe-0.1.0";

  final deployment:DeploymentUrl;
  final http:HttpTransport;
  var authToken = "";
  var live:Null<LiveOwner> = null;
  var closed = false;

  public function new(deploymentUrl:String) {
    deployment = new DeploymentUrl(deploymentUrl);
    http = new HttpTransport(deployment, CLIENT_VERSION);
  }

  public function setAuth(token:String):Void {
    assertOpen();
    if (token == null) throw ConvexError.protocol("authentication token must be a string");
    if (token.indexOf("\r") >= 0 || token.indexOf("\n") >= 0) throw ConvexError.protocol("authentication token must not contain line breaks");
    if (haxe.io.Bytes.ofString(token).length > 64 * 1024) throw ConvexError.protocol("authentication token exceeds 65536 bytes");
    authToken = token;
  }

  public function query(path:String, arguments:Dynamic):ConvexResult {
    assertOpen();
    validatePath(path);
    JsonTools.requireObject(arguments, "query arguments");
    return http.call("query", path, arguments, authToken);
  }

  public function mutation(path:String, arguments:Dynamic):ConvexResult {
    assertOpen();
    validatePath(path);
    JsonTools.requireObject(arguments, "mutation arguments");
    return http.call("mutation", path, arguments, authToken);
  }

  public function action(path:String, arguments:Dynamic):ConvexResult {
    assertOpen();
    validatePath(path);
    JsonTools.requireObject(arguments, "action arguments");
    return http.call("action", path, arguments, authToken);
  }

  public function subscribe(subscriptionId:String, path:String, arguments:Dynamic):LiveSubscription {
    assertOpen();
    validateSubscriptionId(subscriptionId);
    validatePath(path);
    JsonTools.requireObject(arguments, "subscription arguments");
    if (live == null) live = new LiveOwner(deployment, CLIENT_VERSION);
    return live.subscribe(subscriptionId, path, arguments);
  }

  public function unsubscribe(subscriptionId:String):Void {
    assertOpen();
    validateSubscriptionId(subscriptionId);
    if (live != null) live.unsubscribe(subscriptionId);
  }

  /** Adapter-only lifecycle hook. It retires the old TCP connection before
   * reconnecting and replaying every active Add modification. */
  public function debugDisconnectForAdapter():Void {
    assertOpen();
    if (live == null) throw ConvexError.protocol("Live WebSocket has not been started");
    live.debugDisconnect();
  }

  public function close():Void {
    if (closed) return;
    closed = true;
    if (live != null) live.close();
  }

  public static function randomId():String {
    var bytes = WebSocketTransport.secureRandom(16);
    var output = new StringBuf();
    for (index in 0...bytes.length) output.add(StringTools.hex(bytes.get(index), 2).toLowerCase());
    return output.toString();
  }

  static function validateSubscriptionId(value:String):Void {
    if (value == null) throw ConvexError.protocol("subscription id must be a string");
    var length = JsonTools.codePoints(value);
    if (length < 1 || length > 128 || StringTools.trim(value).length == 0) {
      throw ConvexError.protocol("subscription id must contain 1 to 128 Unicode code points");
    }
  }

  static function validatePath(value:String):Void {
    if (value == null || !(~/^[^:\r\n]+:[^:\r\n]+$/).match(value)) {
      throw ConvexError.protocol("Convex function path must be module:function");
    }
    if (haxe.io.Bytes.ofString(value).length > 4096) throw ConvexError.protocol("Convex function path exceeds 4096 bytes");
  }

  function assertOpen():Void {
    if (closed) throw ConvexError.closed();
  }
}
