/** Parsed deployment URL with no ambiguous user-info, query, or fragment. */
class DeploymentUrl {
  public final secure:Bool;
  public final host:String;
  public final port:Int;
  public final path:String;

  public function new(value:String) {
    if (value == null) throw ConvexError.protocol("deployment URL must be a string");
    if (value.length > 4096) throw ConvexError.protocol("deployment URL exceeds 4096 characters");
    if ((~/[\x00-\x20\x7f]/).match(value)) throw ConvexError.protocol("deployment URL must not contain control characters or spaces");
    var pattern = ~/^(https?):\/\/([^\/?#:@]+|\[[0-9A-Fa-f:]+\])(?::([0-9]+))?(\/[^?#]*)?$/;
    if (!pattern.match(value)) {
      throw ConvexError.protocol("deployment URL must be an HTTP(S) host without user information, query, or fragment");
    }
    secure = pattern.matched(1) == "https";
    var rawHost = pattern.matched(2);
    host = StringTools.startsWith(rawHost, "[") ? rawHost.substr(1, rawHost.length - 2) : rawHost;
    var rawPort = pattern.matched(3);
    port = rawPort == null ? (secure ? 443 : 80) : Std.parseInt(rawPort);
    if (port < 1 || port > 65535) throw ConvexError.protocol("deployment URL has an invalid port");
    var rawPath = pattern.matched(4);
    path = rawPath == null ? "" : ~/\/+$/g.replace(rawPath, "");
  }

  public function hostHeader():String {
    var bracketed = host.indexOf(":") >= 0 ? '[${host}]' : host;
    return port == (secure ? 443 : 80) ? bracketed : '$bracketed:$port';
  }
}
