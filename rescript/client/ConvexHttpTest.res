open ConvexTestSupport

type capturedRequest = {
  url: string,
  headers: Js.Dict.t<string>,
  body: Js.Json.t,
}

let captureAnd = (respond, requests) => (request, response, rawBody) => {
  let body = switch ConvexJson.parse(rawBody) {
  | Ok(json) => json
  | Error(_) => ConvexJson.emptyObject()
  }
  let _ = Js.Array2.push(
    requests,
    {url: requestUrl(request), headers: requestHeaders(request), body},
  )
  respond(response, body)
}

test("a successful call preserves the value, the logs, and the sent request", async () => {
  let requests = []
  let server = await startHttpServer(
    captureAnd(
      (response, _body) =>
        respondJson(
          response,
          200,
          `{"status":"success","value":{"count":1},"logLines":["one log line"]}`,
        ),
      requests,
    ),
  )
  let client = Convex.makeWithOptions(
    server.url,
    {...Convex.defaultOptions, authToken: "opaque token"},
  )
  let result = await Convex.query(client, "demo:state", jsonObject([("room", jsonString("a"))]))
  equal(ConvexJson.intField(result.value, "count"), Some(1))
  deepEqual(result.logs, ["one log line"])

  let sent = Js.Array2.unsafe_get(requests, 0)
  equal(sent.url, "/api/query")
  // The configured token must reach Convex byte for byte, with no re-encoding.
  equal(Js.Dict.get(sent.headers, "authorization"), Some("Bearer opaque token"))
  equal(Js.Dict.get(sent.headers, "convex-client"), Some(Convex.version))
  equal(ConvexJson.stringField(sent.body, "path"), Some("demo:state"))
  // Yellow deliberately uses the documented public format.
  equal(ConvexJson.stringField(sent.body, "format"), Some("json"))
  equal(
    switch ConvexJson.objectField(sent.body, "args") {
    | Some(args) => Js.Dict.get(args, "room")
    | None => None
    },
    Some(jsonString("a")),
  )
  await Convex.close(client)
  await server.stop()
})

test("mutation and action use their own documented endpoints", async () => {
  let requests = []
  let server = await startHttpServer(
    captureAnd(
      (response, _body) => respondJson(response, 200, `{"status":"success","value":true}`),
      requests,
    ),
  )
  let client = Convex.make(server.url)
  let _ = await Convex.mutation(client, "demo:increment", ConvexJson.emptyObject())
  let _ = await Convex.action(client, "demo:greet", ConvexJson.emptyObject())
  equal(Js.Array2.unsafe_get(requests, 0).url, "/api/mutation")
  equal(Js.Array2.unsafe_get(requests, 1).url, "/api/action")
  // No token was configured, so no Authorization header is sent at all.
  equal(Js.Dict.get(Js.Array2.unsafe_get(requests, 0).headers, "authorization"), None)
  await Convex.close(client)
  await server.stop()
})

test("an application failure keeps its message, structured data, and logs", async () => {
  let server = await startHttpServer((_request, response, _body) =>
    respondJson(
      response,
      200,
      `{"status":"error","errorMessage":"deliberate failure","errorData":{"code":"EXPECTED"},"logLines":["failure log"]}`,
    )
  )
  let client = Convex.make(server.url)
  let error = await expectFailure(
    () => Convex.query(client, "demo:fail", ConvexJson.emptyObject()),
    "a ConvexError query",
  )
  equal(ConvexError.name(error), "FunctionError")
  equal(error.message, "deliberate failure")
  equal(
    switch error.data {
    | Some(data) => ConvexJson.stringField(data, "code")
    | None => None
    },
    Some("EXPECTED"),
  )
  deepEqual(error.logs, ["failure log"])
  await Convex.close(client)
  await server.stop()
})

test("auth tokens can be replaced and cleared", async () => {
  let requests = []
  let server = await startHttpServer(
    captureAnd(
      (response, _body) => respondJson(response, 200, `{"status":"success","value":null}`),
      requests,
    ),
  )
  let client = Convex.make(server.url)
  Convex.setAuth(client, "first")
  let _ = await Convex.query(client, "demo:state", ConvexJson.emptyObject())
  Convex.setAuth(client, "second")
  let _ = await Convex.query(client, "demo:state", ConvexJson.emptyObject())
  Convex.setAuth(client, "")
  let _ = await Convex.query(client, "demo:state", ConvexJson.emptyObject())
  equal(
    Js.Dict.get(Js.Array2.unsafe_get(requests, 0).headers, "authorization"),
    Some("Bearer first"),
  )
  equal(
    Js.Dict.get(Js.Array2.unsafe_get(requests, 1).headers, "authorization"),
    Some("Bearer second"),
  )
  // Clearing the token removes the header rather than sending "Bearer ".
  equal(Js.Dict.get(Js.Array2.unsafe_get(requests, 2).headers, "authorization"), None)
  await Convex.close(client)
  await server.stop()
})

test("a response that is not a Convex answer is a protocol failure", async () => {
  let server = await startHttpServer((request, response, _body) =>
    switch requestUrl(request) {
    | "/api/query" => respondJson(response, 200, "<html>not convex</html>")
    // A non-2xx status is always a transport failure regardless of body (see
    // "HTTP status takes precedence over a success-shaped body" below), so this
    // must be a 200 to actually exercise decodeResponse's unknown-status branch.
    | _ => respondJson(response, 200, `{"status":"confused"}`)
    }
  )
  let client = Convex.make(server.url)
  let parseFailure = await expectFailure(
    () => Convex.query(client, "demo:state", ConvexJson.emptyObject()),
    "a non-JSON response",
  )
  equal(ConvexError.name(parseFailure), "ProtocolError")
  let statusFailure = await expectFailure(
    () => Convex.mutation(client, "demo:state", ConvexJson.emptyObject()),
    "an unknown status",
  )
  equal(ConvexError.name(statusFailure), "ProtocolError")
  ok(
    Js.String2.includes(statusFailure.message, "confused"),
    "the unknown status is reported verbatim",
  )
  await Convex.close(client)
  await server.stop()
})

test("HTTP status takes precedence over a success-shaped body", async () => {
  let server = await startHttpServer((_request, response, _body) =>
    respondJson(response, 503, `{"status":"success","value":{"count":99}}`)
  )
  let client = Convex.make(server.url)
  let error = await expectFailure(
    () => Convex.query(client, "demo:state", ConvexJson.emptyObject()),
    "a non-success HTTP status",
  )
  equal(ConvexError.name(error), "TransportError")
  await Convex.close(client)
  await server.stop()
})

test("malformed logs and error envelopes are protocol failures", async () => {
  let calls = ref(0)
  let server = await startHttpServer((_request, response, _body) => {
    calls := calls.contents + 1
    calls.contents == 1
      ? respondJson(response, 200, `{"status":"success","value":null,"logLines":[7]}`)
      : respondJson(response, 200, `{"status":"error","errorData":{"code":"NO_MESSAGE"}}`)
  })
  let client = Convex.make(server.url)
  let badLogs = await expectFailure(
    () => Convex.query(client, "demo:state", ConvexJson.emptyObject()),
    "non-string logs",
  )
  equal(ConvexError.name(badLogs), "ProtocolError")
  let missingMessage = await expectFailure(
    () => Convex.query(client, "demo:state", ConvexJson.emptyObject()),
    "an error without a message",
  )
  equal(ConvexError.name(missingMessage), "ProtocolError")
  await Convex.close(client)
  await server.stop()
})

test("an oversized body is refused before it is decoded", async () => {
  let filler = Js.String2.repeat("x", ConvexHttp.maximumResponseBytes + 1024)
  let server = await startHttpServer((_request, response, _body) =>
    respondJson(response, 200, `{"status":"success","value":"` ++ filler ++ `"}`)
  )
  let client = Convex.make(server.url)
  let error = await expectFailure(
    () => Convex.query(client, "demo:echo", ConvexJson.emptyObject()),
    "an oversized response",
  )
  equal(ConvexError.name(error), "TransportError")
  await Convex.close(client)
  await server.stop()
})

test("the body deadline is absolute even while bytes keep arriving", async () => {
  let server = await startHttpServer((_request, response, _body) => dripResponse(response))
  let headers = Js.Dict.empty()
  let request: ConvexNode.fetchRequest = {method: "POST", headers, body: "{}"}
  let error = await expectFailure(async () => {
    let _ = await ConvexNode.boundedFetch(server.url, request, 1024, 75)
  }, "a continuously dribbling response")
  equal(ConvexError.name(error), "TransportError")
  await server.stop()
})

test("a dead deployment is a transport failure, not a value", async () => {
  let server = await startHttpServer((_request, response, _body) =>
    respondJson(response, 200, `{"status":"success","value":null}`)
  )
  let url = server.url
  await server.stop()
  let client = Convex.make(url)
  let error = await expectFailure(
    () => Convex.query(client, "demo:state", ConvexJson.emptyObject()),
    "a query against a stopped server",
  )
  equal(ConvexError.name(error), "TransportError")
  await Convex.close(client)
})

test("misuse is refused before anything reaches the network", async () => {
  switch ConvexProtocol.normalizeDeploymentUrl("not-a-url") {
  | Ok(_) => fail("an invalid deployment URL was accepted")
  | Error(_) => ()
  }
  let client = Convex.make("https://example.test")
  let arrayArgs = await expectFailure(
    () => Convex.query(client, "demo:state", Js.Json.array([])),
    "positional arguments",
  )
  equal(ConvexError.name(arrayArgs), "UsageError")
  let emptyPath = await expectFailure(
    () => Convex.query(client, "", ConvexJson.emptyObject()),
    "an empty function path",
  )
  equal(ConvexError.name(emptyPath), "UsageError")
  await Convex.close(client)
  let afterClose = await expectFailure(
    () => Convex.query(client, "demo:state", ConvexJson.emptyObject()),
    "a call after close",
  )
  equal(ConvexError.name(afterClose), "ClosedError")
})
