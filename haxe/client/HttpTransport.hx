import haxe.Json;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.net.Socket;

private typedef HttpHead = {
  var status:Int;
  var headers:StringMap<String>;
}

/** Minimal strict HTTP/1.1 transport with a hard body cap and absolute
 * deadline. It deliberately asks for identity encoding so the measured bytes
 * are the bytes handed to the JSON parser. */
class HttpTransport {
  public static inline var MAX_BODY = 8 * 1024 * 1024;
  static inline var MAX_HEADERS = 16 * 1024;
  static inline var TIMEOUT = 30.0;

  final deployment:DeploymentUrl;
  final clientVersion:String;

  public function new(deployment:DeploymentUrl, clientVersion:String) {
    this.deployment = deployment;
    this.clientVersion = clientVersion;
  }

  public function call(operation:String, path:String, arguments:Dynamic, authToken:String):ConvexResult {
    if (path.length == 0) throw ConvexError.protocol("Convex function path is required");
    var wire = buildRequest(operation, path, arguments, authToken);

    var socket:Null<Socket> = null;
    try {
      var deadline = Sys.time() + TIMEOUT;
      socket = SocketTransport.dial(deployment, TIMEOUT);
      SocketTransport.writeAll(socket, wire, deadline, operation);
      var rawHead = SocketTransport.readUntil(socket, "\r\n\r\n", MAX_HEADERS, deadline, operation).toString();
      var head = parseHead(rawHead);
      var response = readBody(socket, head.headers, deadline, operation);
      SocketTransport.closeQuietly(socket);
      socket = null;
      // Convex reports function failures inside the envelope, and the status
      // code that carries them is not part of the documented contract. Decode
      // first so an application error stays an application error, and let the
      // status describe only genuinely non-Convex responses.
      return decodeEnvelope(operation, head.status, response);
    } catch (error:ConvexError) {
      SocketTransport.closeQuietly(socket);
      throw error;
    } catch (error:Dynamic) {
      SocketTransport.closeQuietly(socket);
      throw ConvexError.transport(operation, Std.string(error));
    }
  }

  /** The request is assembled in full before dialling so a malformed header
   * value cannot be discovered halfway through a live connection. */
  function buildRequest(operation:String, path:String, arguments:Dynamic, authToken:String):Bytes {
    var body = Bytes.ofString(Json.stringify({path: path, args: arguments, format: "json"}));
    if (body.length > MAX_BODY) throw ConvexError.protocol('HTTP request exceeds $MAX_BODY bytes');
    var endpoint = deployment.path + "/api/" + operation;
    var request = new StringBuf();
    request.add('POST $endpoint HTTP/1.1\r\n');
    request.add('Host: ${deployment.hostHeader()}\r\n');
    request.add('Convex-Client: $clientVersion\r\n');
    request.add("Content-Type: application/json\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n");
    // The configured token is opaque and is transmitted byte for byte.
    if (authToken.length > 0) request.add('Authorization: Bearer $authToken\r\n');
    request.add('Content-Length: ${body.length}\r\n\r\n');
    var prefix = Bytes.ofString(request.toString());
    var wire = Bytes.alloc(prefix.length + body.length);
    wire.blit(0, prefix, 0, prefix.length);
    wire.blit(prefix.length, body, 0, body.length);
    return wire;
  }

  static function parseHead(raw:String):HttpHead {
    var lines = raw.substr(0, raw.length - 4).split("\r\n");
    var statusPattern = ~/^HTTP\/1\.[01] ([0-9]{3})(?: |$)/;
    if (lines.length == 0 || !statusPattern.match(lines.shift())) throw ConvexError.protocol("HTTP status line was malformed");
    var status = Std.parseInt(statusPattern.matched(1));
    var headers = new StringMap<String>();
    for (line in lines) {
      var colon = line.indexOf(":");
      if (colon <= 0) throw ConvexError.protocol("HTTP header was malformed");
      var name = line.substr(0, colon).toLowerCase();
      var value = StringTools.trim(line.substr(colon + 1));
      headers.set(name, headers.exists(name) ? headers.get(name) + "," + value : value);
    }
    return {status: status, headers: headers};
  }

  static function readBody(socket:Socket, headers:StringMap<String>, deadline:Float, operation:String):Bytes {
    var transfer = headers.get("transfer-encoding");
    var rawLength = headers.get("content-length");
    if (transfer != null && rawLength != null) throw ConvexError.protocol("HTTP response supplied both Transfer-Encoding and Content-Length");
    if (transfer != null) {
      var codings = transfer.toLowerCase().split(",").map(StringTools.trim);
      if (codings.length != 1 || codings[0] != "chunked") throw ConvexError.protocol("HTTP response used unsupported transfer coding");
      return readChunked(socket, deadline, operation);
    }
    if (rawLength != null) {
      var length = Std.parseInt(rawLength);
      if (length == null || Std.string(length) != rawLength || length < 0) throw ConvexError.protocol("HTTP Content-Length was invalid");
      if (length > MAX_BODY) throw ConvexError.transport(operation, 'response exceeds $MAX_BODY bytes');
      return SocketTransport.readExact(socket, length, deadline, operation);
    }
    return readUntilClose(socket, deadline, operation);
  }

  /** `Connection: close` framing. The peer closing is the terminator, so an
   * end-of-file here is success rather than a transport failure. */
  static function readUntilClose(socket:Socket, deadline:Float, operation:String):Bytes {
    var output = new BytesBuffer();
    var chunk = Bytes.alloc(16 * 1024);
    while (true) {
      var count = 0;
      try {
        count = SocketTransport.readSome(socket, chunk, 0, chunk.length, deadline, operation);
      } catch (error:ConvexError) {
        if (error.kind == "TransportError" && error.message == SocketTransport.PEER_CLOSED) break;
        throw error;
      }
      if (output.length + count > MAX_BODY) throw ConvexError.transport(operation, 'response exceeds $MAX_BODY bytes');
      output.addBytes(chunk, 0, count);
    }
    return output.getBytes();
  }

  static function readChunked(socket:Socket, deadline:Float, operation:String):Bytes {
    var output = new BytesBuffer();
    while (true) {
      var line = SocketTransport.readUntil(socket, "\r\n", 128, deadline, operation).toString();
      line = line.substr(0, line.length - 2);
      var semicolon = line.indexOf(";");
      if (semicolon >= 0) line = line.substr(0, semicolon);
      // Seven hex digits already exceed the body cap while staying inside
      // Neko's signed integer range, so a longer size can never wrap negative.
      if (!(~/^[0-9A-Fa-f]{1,7}$/).match(line)) throw ConvexError.protocol("chunk length was malformed");
      var length = Std.parseInt("0x" + line);
      if (output.length + length > MAX_BODY) throw ConvexError.transport(operation, 'response exceeds $MAX_BODY bytes');
      if (length == 0) {
        // Only an empty trailer is accepted. This keeps the educational parser
        // strict and prevents unbounded trailer fields.
        var trailer = SocketTransport.readUntil(socket, "\r\n", MAX_HEADERS, deadline, operation).toString();
        if (trailer != "\r\n") throw ConvexError.protocol("HTTP trailers are not supported");
        return output.getBytes();
      }
      var chunk = SocketTransport.readExact(socket, length, deadline, operation);
      output.addBytes(chunk, 0, chunk.length);
      if (SocketTransport.readExact(socket, 2, deadline, operation).toString() != "\r\n") throw ConvexError.protocol("chunk omitted terminator");
    }
  }

  static function decodeEnvelope(operation:String, status:Int, body:Bytes):ConvexResult {
    if (!Utf8Text.isValid(body)) throw ConvexError.protocol('HTTP $status response was not valid UTF-8');
    JsonTools.checkJsonShape(body, "HTTP response JSON");
    var decoded:Dynamic;
    try decoded = Json.parse(body.toString()) catch (error:Dynamic) {
      throw ConvexError.protocol('HTTP $status returned a non-Convex response: ${Std.string(error)}');
    }
    if (!JsonTools.isObject(decoded)) throw ConvexError.protocol('HTTP $status returned a non-Convex response');
    var rawStatus = Reflect.field(decoded, "status");
    if (!Std.isOfType(rawStatus, String)) throw ConvexError.protocol('HTTP $status returned a non-Convex response');
    var envelopeStatus:String = rawStatus;
    var logs = JsonTools.optionalStringArray(decoded, "logLines", "HTTP response.logLines");
    if (envelopeStatus == "success") {
      if (!Reflect.hasField(decoded, "value")) throw ConvexError.protocol("success response omitted value");
      // A proxy or failed deployment must not be able to turn a non-success
      // HTTP response into a successful Convex result merely by shaping its
      // body like an envelope. Convex function failures remain valid below on
      // any status because their `error` envelope is the application result.
      if (status < 200 || status >= 300) throw ConvexError.protocol('HTTP $status carried a success envelope');
      return new ConvexResult(Reflect.field(decoded, "value"), logs);
    }
    if (envelopeStatus == "error") {
      var message = JsonTools.requireString(decoded, "errorMessage", "HTTP error response");
      throw new ConvexError("FunctionError", message, operation, Reflect.field(decoded, "errorData"), logs);
    }
    throw ConvexError.protocol('HTTP $status response has unknown status $envelopeStatus');
  }
}
