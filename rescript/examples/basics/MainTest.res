open ConvexTestSupport

// Runs the canonical example exactly as the verifier does: as a separate
// process against a Convex-shaped backend, checking the six lines it prints on
// stdout. The shared root verifier owns the authoritative comparison against
// `_shared/examples/basics.expected.txt`; this test exists so an obvious
// regression fails inside the language's own Docker test stage.

// The compiled example sits beside this compiled test in the build layout.
let exampleEntry: string = %raw(`new URL("./Main.res.mjs", import.meta.url).pathname`)

let readAll = (stream, sink) => {
  ConvexNode.setEncoding(stream, "utf8")
  ConvexNode.onData(stream, "data", chunk => sink := sink.contents ++ chunk)
}

test("the canonical example prints the six-line journey and closes Live", async () => {
  let liveSocket = ref(None)
  let liveClosed = ref(false)
  let server = createHttpServer((request, response) => {
    requestSetEncoding(request, "utf8")
    let body = ref("")
    onRequestData(request, "data", chunk => body := body.contents ++ chunk)
    onRequestEnd(
      request,
      "end",
      () =>
        switch requestUrl(request) {
        // Convex may serialise an integral count as `0.0`, so the fixture does
        // too: the example must accept it and still print `0`.
        | "/api/query" => respondJson(response, 200, `{"status":"success","value":{"count":0.0}}`)
        | _ => {
            respondJson(
              response,
              200,
              `{"status":"success","value":{"applied":true,"state":{"count":1.0}}}`,
            )
            // The write is then pushed to the open subscription, which is what
            // the example's last two lines prove.
            switch liveSocket.contents {
            | Some(socket) =>
              ConvexNode.webSocketSend(
                socket,
                ConvexJson.stringify(
                  transitionJson(
                    ~from=(1, timestampOne),
                    ~to_=(1, timestampTwo),
                    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(1.0))],
                  ),
                ),
              )
            | None => fail("the example mutated before subscribing")
            }
          }
        },
    )
  })
  let sockets = makeWebSocketServer({server, path: "/api/sync"})
  onWebSocketConnection(sockets, "connection", socket => {
    liveSocket := Some(socket)
    ConvexNode.webSocketOnClose(socket, "close", (_code, _reason) => liveClosed := true)
    ConvexNode.webSocketOnMessage(
      socket,
      "message",
      data =>
        switch ConvexJson.parse(ConvexNode.bytesToString(data, "utf8")) {
        | Ok(message) =>
          // Answer the query set the client just registered.
          if ConvexJson.stringField(message, "type") == Some("ModifyQuerySet") {
            ConvexNode.webSocketSend(
              socket,
              ConvexJson.stringify(
                transitionJson(
                  ~from=startVersion,
                  ~to_=(1, timestampOne),
                  ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
                ),
              ),
            )
          }
        | Error(_) => fail("the client sent invalid JSON")
        },
    )
  })
  await ConvexNode.makePromise((resolve, _reject) =>
    httpListen(server, 0, "127.0.0.1", () => resolve())
  )

  let environment = Js.Dict.empty()
  Js.Dict.set(
    environment,
    "PATH",
    switch Js.Dict.get(processEnvironment, "PATH") {
    | Some(value) => value
    | None => ""
    },
  )
  Js.Dict.set(
    environment,
    "CONVEX_URL",
    "http://127.0.0.1:" ++ Belt.Int.toString(httpAddress(server).port),
  )

  let child = spawn(
    execPath,
    [exampleEntry, "rescript-example-test-room"],
    {env: environment, stdio: ["ignore", "pipe", "pipe"]},
  )
  let stdout = ref("")
  let stderr = ref("")
  readAll(childStdout(child), stdout)
  readAll(childStderr(child), stderr)
  let exitCode = await ConvexNode.makePromise((resolve, _reject) =>
    onChildExit(child, "exit", (code, _signal) => resolve(Js.Nullable.toOption(code)))
  )

  equal(exitCode, Some(0))
  ok(stderr.contents == "", "the happy path writes nothing to stderr: " ++ stderr.contents)
  deepEqual(
    Js.String2.split(Js.String2.trim(stdout.contents), "\n"),
    [
      "current count: 0",
      "live initial count: 0",
      "mutation applied: true",
      "mutation count: 1",
      "live updated count: 1",
      "verified count: 0 -> 1",
    ],
  )
  ok(liveClosed.contents, "the example closed its Live WebSocket before exiting")

  await ConvexNode.makePromise((resolve, _reject) => closeWebSocketServer(sockets, () => resolve()))
  await ConvexNode.makePromise((resolve, _reject) => httpClose(server, () => resolve()))
})
