/** Real-socket HTTP behaviour: envelope strictness, bearer transport, framing
 * limits, and the ability to keep working after each rejection. */
class HttpTests {
  public static function run():Void {
    envelopeStrictness();
    functionErrorsSurviveAnyStatus();
    bearerTokenIsSentVerbatim();
    framingLimits();
  }

  static function envelopeStrictness():Void {
    var fixture = new HttpFixture([
      HttpFixture.body("[]"),
      HttpFixture.body('{"status":"success"}'),
      HttpFixture.body('{"status":"success","value":0,"logLines":[1]}'),
      HttpFixture.body('{"status":"success","value":0,"logLines":null}'),
      HttpFixture.body('{"status":"weird","value":0}'),
      HttpFixture.body("not json at all"),
      HttpFixture.response(500, '{"status":"success","value":99,"logLines":[]}'),
      HttpFixture.success("0")
    ]);
    var client = new ConvexClient(fixture.url());
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "a non-object root is not a Convex envelope");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "a success envelope must carry a value");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "log lines must all be strings");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "explicit null log lines are not silently accepted");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "an unknown envelope status is rejected");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "a non-JSON body is a protocol failure");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "a non-2xx response cannot masquerade as success");
    Assert.equal(client.query("demo:state", {}).value, 0, "the client still works after seven rejected responses");
    client.close();
  }

  /** Convex reports application failures inside the envelope. The HTTP status
   * that carries them is not part of the documented contract, so decoding
   * happens first and a function error never degrades into a transport error. */
  static function functionErrorsSurviveAnyStatus():Void {
    var fixture = new HttpFixture([
      HttpFixture.response(400, '{"status":"error","errorMessage":"boom","errorData":{"code":"HAXE_EXPECTED"},"logLines":["log one"]}'),
      HttpFixture.response(500, "upstream exploded"),
      HttpFixture.success("1")
    ]);
    var client = new ConvexClient(fixture.url());
    var failure = Assert.throwsKind("FunctionError", function() return client.query("demo:fail", {}), "a non-2xx function error stays a function error");
    Assert.equal(failure.message, "boom", "the error message is preserved");
    Assert.equal(Reflect.field(failure.data, "code"), "HAXE_EXPECTED", "structured error data is preserved");
    Assert.equal(failure.logs.length, 1, "log lines survive alongside the error");

    var transport = Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "a non-Convex body is reported with its status");
    Assert.ok(transport.message.indexOf("500") >= 0, "the rejected status is named in the failure");
    Assert.equal(client.query("demo:state", {}).value, 1, "the client recovers after both failures");
    client.close();
  }

  static function bearerTokenIsSentVerbatim():Void {
    var token = "opaque.token-value_1234567890/+=";
    var fixture = new HttpFixture([HttpFixture.success("0"), HttpFixture.success("0")]);
    var client = new ConvexClient(fixture.url());
    client.setAuth(token);
    client.query("demo:state", {});
    var head = fixture.nextRequest(5.0);
    Assert.ok(head.indexOf('Authorization: Bearer $token\r\n') >= 0, "the configured token is transmitted byte for byte");
    Assert.ok(head.indexOf("Convex-Client: haxe-") >= 0, "the client identifies itself");

    client.setAuth("");
    client.query("demo:state", {});
    Assert.ok(fixture.nextRequest(5.0).indexOf("Authorization:") < 0, "clearing the token removes the header entirely");
    Assert.throwsKind("ProtocolError", function() { client.setAuth("bad\r\nInjected: header"); return true; }, "a token cannot inject a header line");
    client.close();
  }

  static function framingLimits():Void {
    var fixture = new HttpFixture([
      // A chunk size larger than the body cap, rejected before it is buffered.
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n800001\r\n",
      // Ambiguous framing must not be resolved by guessing.
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc",
      "HTTP/1.1 200 OK\r\nContent-Length: 007\r\nConnection: close\r\n\r\n{\"a\":1}",
      // Well-formed chunked framing still decodes.
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n19\r\n{\"status\":\"success\",\"valu\r\n13\r\ne\":7,\"logLines\":[]}\r\n0\r\n\r\n"
    ]);
    var client = new ConvexClient(fixture.url());
    Assert.throwsKind("TransportError", function() return client.query("demo:state", {}), "an oversized chunk is rejected before buffering");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "both framing headers together are ambiguous");
    Assert.throwsKind("ProtocolError", function() return client.query("demo:state", {}), "a non-canonical Content-Length is rejected");
    Assert.equal(client.query("demo:state", {}).value, 7, "a chunked envelope split mid-token still decodes");
    client.close();
  }
}
