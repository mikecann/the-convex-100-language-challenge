open ConvexTestSupport

// These tests drive the adapter exactly as the shared controller does: NDJSON
// in, NDJSON out. They exist so a shape mismatch is caught here rather than by
// the shared conformance run.

type harness = {
  feeder: feeder,
  collector: collector,
  fake: fakeTransport,
  server: testServer,
  adapter: ConvexAdapter.adapter,
}

let send = (harness, command) => harness.feeder.push(ConvexJson.stringify(command) ++ "\n")

let lines = harness => harness.collector.written()

let events = harness =>
  Js.Array2.map(lines(harness), line =>
    switch ConvexJson.parse(line) {
    | Ok(json) => json
    | Error(_) => ConvexJson.emptyObject()
    }
  )

let eventTypes = harness =>
  Js.Array2.map(events(harness), event => ConvexJson.stringFieldOr(event, "type", "?"))

// Waits for the adapter's command chain and relays to settle. Every step is
// event-loop work, so a short poll is enough and nothing is timing-sensitive.
let settle = async harness => {
  let seen = ref(-1)
  let stable = ref(0)
  while stable.contents < 3 {
    await delay(5)
    let count = Js.Array2.length(lines(harness))
    if count == seen.contents {
      stable := stable.contents + 1
    } else {
      seen := count
      stable := 0
    }
  }
}

let startHarness = async (~afterDequeue, ~respond) => {
  let server = await startHttpServer(respond)
  let feeder = makeFeeder()
  let collector = makeCollector()
  let fake = makeFakeTransport()
  let environment = Js.Dict.empty()
  Js.Dict.set(environment, "CONVEX_URL", server.url)
  let adapter = ConvexAdapter.makeAdapter(
    ~stream=collector.stream,
    ~environment,
    ~options={...Convex.defaultOptions, transport: fake.transport},
    ~afterDequeue,
    ~onFinished=() => (),
  )
  ConvexAdapter.attachInput(adapter, feeder.input)
  {feeder, collector, fake, server, adapter}
}

let stopHarness = async harness => {
  harness.collector.flush()
  await harness.server.stop()
}

let successResponse = (_request, response, _body) =>
  respondJson(response, 200, `{"status":"success","value":{"count":0},"logLines":["a log line"]}`)

let helloCommand = ConvexJson.object_([
  ("protocolVersion", jsonNumber(1.0)),
  ("id", jsonString("hello-1")),
  ("op", jsonString("hello")),
])

test("hello reports the protocol, language, provenance, and runtime", async () => {
  let harness = await startHarness(
    ~afterDequeue=ConvexAdapter.noAfterDequeue,
    ~respond=successResponse,
  )
  send(harness, helloCommand)
  await settle(harness)
  let ready = Js.Array2.unsafe_get(events(harness), 0)
  equal(ConvexJson.stringField(ready, "type"), Some("ready"))
  equal(ConvexJson.intField(ready, "protocolVersion"), Some(1))
  equal(ConvexJson.stringField(ready, "id"), Some("hello-1"))
  equal(ConvexJson.stringField(ready, "language"), Some("rescript"))
  ok(
    switch ConvexJson.stringField(ready, "implementation") {
    | Some(value) => Js.String2.includes(value, "native-rescript-")
    | None => false
    },
    "the provenance string names a native ReScript implementation",
  )
  ok(
    switch ConvexJson.stringField(ready, "runtime") {
    | Some(value) => Js.String2.startsWith(value, "node-")
    | None => false
    },
    "the runtime version is reported",
  )
  await stopHarness(harness)
})

test("an unsupported protocol version is refused", async () => {
  let harness = await startHarness(
    ~afterDequeue=ConvexAdapter.noAfterDequeue,
    ~respond=successResponse,
  )
  send(
    harness,
    ConvexJson.object_([
      ("protocolVersion", jsonNumber(2.0)),
      ("id", jsonString("hello-2")),
      ("op", jsonString("hello")),
    ]),
  )
  await settle(harness)
  let event = Js.Array2.unsafe_get(events(harness), 0)
  equal(ConvexJson.stringField(event, "type"), Some("error"))
  equal(ConvexJson.stringField(event, "id"), Some("hello-2"))
  await stopHarness(harness)
})

test("a result carries its value and logs, and omits what is absent", async () => {
  let harness = await startHarness(~afterDequeue=ConvexAdapter.noAfterDequeue, ~respond=(
    request,
    response,
    _body,
  ) =>
    switch requestUrl(request) {
    | "/api/query" =>
      respondJson(
        response,
        200,
        `{"status":"success","value":{"count":0},"logLines":["a log line"]}`,
      )
    | _ => respondJson(response, 200, `{"status":"success","value":null}`)
    }
  )
  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("q1")),
      ("op", jsonString("query")),
      ("path", jsonString("demo:state")),
      ("args", jsonObject([("room", jsonString("a"))])),
    ]),
  )
  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("m1")),
      ("op", jsonString("mutation")),
      ("path", jsonString("demo:increment")),
      ("args", ConvexJson.emptyObject()),
    ]),
  )
  await settle(harness)
  deepEqual(eventTypes(harness), ["result", "result"])

  let first = Js.Array2.unsafe_get(events(harness), 0)
  equal(ConvexJson.stringField(first, "id"), Some("q1"))
  equal(
    switch ConvexJson.field(first, "value") {
    | Some(value) => ConvexJson.intField(value, "count")
    | None => None
    },
    Some(0),
  )
  deepEqual(ConvexJson.logLines(first, "logs"), ["a log line"])

  // A result with no logs must not carry an empty or null `logs` field, and a
  // null Convex value is still a value.
  let second = Js.Array2.unsafe_get(events(harness), 1)
  equal(ConvexJson.field(second, "logs"), None)
  ok(
    switch ConvexJson.field(second, "value") {
    | Some(value) => ConvexJson.isNull(value)
    | None => false
    },
    "a null Convex value is serialised as a value, not omitted",
  )
  ok(
    !Js.String2.includes(Js.Array2.unsafe_get(lines(harness), 1), "subscriptionId"),
    "an absent subscription id is never serialised",
  )
  await stopHarness(harness)
})

test("a structured Convex failure keeps its name, message, and data", async () => {
  let harness = await startHarness(~afterDequeue=ConvexAdapter.noAfterDequeue, ~respond=(
    _request,
    response,
    _body,
  ) =>
    respondJson(
      response,
      200,
      `{"status":"error","errorMessage":"deliberate failure","errorData":{"code":"EXPECTED"},"logLines":["failure log"]}`,
    )
  )
  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("q2")),
      ("op", jsonString("query")),
      ("path", jsonString("demo:fail")),
      ("args", ConvexJson.emptyObject()),
    ]),
  )
  await settle(harness)
  let event = Js.Array2.unsafe_get(events(harness), 0)
  equal(ConvexJson.stringField(event, "type"), Some("error"))
  equal(ConvexJson.stringField(event, "id"), Some("q2"))
  let error = switch ConvexJson.field(event, "error") {
  | Some(value) => value
  | None => ConvexJson.emptyObject()
  }
  equal(ConvexJson.stringField(error, "name"), Some("FunctionError"))
  equal(ConvexJson.stringField(error, "message"), Some("deliberate failure"))
  equal(
    switch ConvexJson.field(error, "data") {
    | Some(data) => ConvexJson.stringField(data, "code")
    | None => None
    },
    Some("EXPECTED"),
  )
  deepEqual(ConvexJson.logLines(event, "logs"), ["failure log"])
  await stopHarness(harness)
})

test("a malformed command is reported without inventing a request id", async () => {
  let harness = await startHarness(
    ~afterDequeue=ConvexAdapter.noAfterDequeue,
    ~respond=successResponse,
  )
  harness.feeder.push("{not json\n")
  await settle(harness)
  let event = Js.Array2.unsafe_get(events(harness), 0)
  equal(ConvexJson.stringField(event, "type"), Some("error"))
  equal(ConvexJson.field(event, "id"), None)
  ok(
    !Js.String2.includes(Js.Array2.unsafe_get(lines(harness), 0), `"id"`),
    "an absent id is omitted rather than serialised as null",
  )
  await stopHarness(harness)
})

test(
  "command schema rejects wrong, overlong, and additional fields without echoing ids",
  async () => {
    let harness = await startHarness(
      ~afterDequeue=ConvexAdapter.noAfterDequeue,
      ~respond=successResponse,
    )
    send(harness, ConvexJson.object_([("id", jsonNumber(7.0)), ("op", jsonString("close"))]))
    send(
      harness,
      ConvexJson.object_([
        ("id", jsonString(Js.String2.repeat("😀", 129))),
        ("op", jsonString("close")),
      ]),
    )
    send(harness, ConvexJson.object_([("id", jsonString("   ")), ("op", jsonString("close"))]))
    send(
      harness,
      ConvexJson.object_([
        ("id", jsonString("extra")),
        ("op", jsonString("close")),
        ("surprise", jsonString("no")),
      ]),
    )
    send(
      harness,
      ConvexJson.object_([
        ("protocolVersion", jsonNumber(1.0)),
        ("id", jsonString(Js.String2.repeat("😀", 128))),
        ("op", jsonString("hello")),
      ]),
    )
    await settle(harness)
    deepEqual(eventTypes(harness), ["error", "error", "error", "error", "ready"])
    let invalidEvents = events(harness)
    equal(ConvexJson.field(Js.Array2.unsafe_get(invalidEvents, 0), "id"), None)
    equal(ConvexJson.field(Js.Array2.unsafe_get(invalidEvents, 1), "id"), None)
    equal(ConvexJson.field(Js.Array2.unsafe_get(invalidEvents, 2), "id"), None)
    equal(ConvexJson.stringField(Js.Array2.unsafe_get(invalidEvents, 3), "id"), Some("extra"))
    equal(
      ConvexJson.stringField(Js.Array2.unsafe_get(invalidEvents, 4), "id"),
      Some(Js.String2.repeat("😀", 128)),
    )
    await stopHarness(harness)
  },
)

test("subscription events carry values, failures, and a clean close", async () => {
  let harness = await startHarness(
    ~afterDequeue=ConvexAdapter.noAfterDequeue,
    ~respond=successResponse,
  )
  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("s1")),
      ("op", jsonString("subscribe")),
      ("subscriptionId", jsonString("sub-a")),
      ("path", jsonString("demo:state")),
      ("args", jsonObject([("room", jsonString("a"))])),
    ]),
  )
  await settle(harness)
  let socket = await handshake(harness.fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  sendTransition(
    socket,
    ~from=(1, timestampOne),
    ~to_=(1, timestampTwo),
    ~modifications=[queryFailed(~queryId=0, ~message="room is empty", ~code="ROOM_EMPTY")],
  )
  await settle(harness)

  send(harness, ConvexJson.object_([("id", jsonString("c1")), ("op", jsonString("close"))]))
  await settle(harness)
  deepEqual(eventTypes(harness), ["ack", "subscription", "subscription", "closed"])

  let value = Js.Array2.unsafe_get(events(harness), 1)
  equal(ConvexJson.stringField(value, "subscriptionId"), Some("sub-a"))
  equal(
    switch ConvexJson.field(value, "value") {
    | Some(payload) => ConvexJson.intField(payload, "count")
    | None => None
    },
    Some(0),
  )
  equal(ConvexJson.field(value, "id"), None)

  let failure = Js.Array2.unsafe_get(events(harness), 2)
  equal(ConvexJson.field(failure, "value"), None)
  equal(
    switch ConvexJson.field(failure, "error") {
    | Some(error) =>
      switch ConvexJson.field(error, "data") {
      | Some(data) => ConvexJson.stringField(data, "code")
      | None => None
      }
    | None => None
    },
    Some("ROOM_EMPTY"),
  )
  equal(ConvexJson.stringField(Js.Array2.unsafe_get(events(harness), 3), "id"), Some("c1"))
  await stopHarness(harness)
})

// The relay is paused between dequeueing an update and publishing it, which is
// the only window where a stale event could cross an acknowledgement.
test("no dequeued event can cross an unsubscribe acknowledgement", async () => {
  let gate = makeGate()
  let harness = await startHarness(
    ~afterDequeue=(_subscriptionId, _generation) => gate.wait(),
    ~respond=successResponse,
  )
  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("s1")),
      ("op", jsonString("subscribe")),
      ("subscriptionId", jsonString("sub-a")),
      ("path", jsonString("demo:state")),
      ("args", jsonObject([("room", jsonString("a"))])),
    ]),
  )
  await settle(harness)
  let socket = await handshake(harness.fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  // Wait until the relay is holding an update it has not yet published.
  let waited = ref(0)
  while !gate.entered() && waited.contents < 200 {
    await delay(5)
    waited := waited.contents + 1
  }
  ok(gate.entered(), "the relay dequeued an update")

  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("u1")),
      ("op", jsonString("unsubscribe")),
      ("subscriptionId", jsonString("sub-a")),
    ]),
  )
  await settle(harness)
  gate.release()
  await settle(harness)
  // The acknowledgement is the last word: the held update is discarded.
  deepEqual(eventTypes(harness), ["ack", "ack"])
  await stopHarness(harness)
})

test("a repeated subscription id replaces the old relay before it is acknowledged", async () => {
  let gate = makeGate()
  let harness = await startHarness(
    ~afterDequeue=(_subscriptionId, _generation) => gate.wait(),
    ~respond=successResponse,
  )
  let subscribeCommand = id =>
    ConvexJson.object_([
      ("id", jsonString(id)),
      ("op", jsonString("subscribe")),
      ("subscriptionId", jsonString("sub-a")),
      ("path", jsonString("demo:state")),
      ("args", jsonObject([("room", jsonString("a"))])),
    ])
  send(harness, subscribeCommand("s1"))
  await settle(harness)
  let socket = await handshake(harness.fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  let waited = ref(0)
  while !gate.entered() && waited.contents < 200 {
    await delay(5)
    waited := waited.contents + 1
  }
  send(harness, subscribeCommand("s2"))
  await settle(harness)
  gate.release()
  await settle(harness)
  // The value belonged to the replaced subscription, so it is dropped.
  deepEqual(eventTypes(harness), ["ack", "ack"])
  await stopHarness(harness)
})

test("an unbounded command line is refused instead of buffered", async () => {
  let harness = await startHarness(
    ~afterDequeue=ConvexAdapter.noAfterDequeue,
    ~respond=successResponse,
  )
  let chunk = Js.String2.repeat("x", 1024 * 1024)
  let pushed = ref(0)
  while pushed.contents < 9 {
    harness.feeder.push(chunk)
    pushed := pushed.contents + 1
  }
  await settle(harness)
  let event = Js.Array2.unsafe_get(events(harness), 0)
  equal(ConvexJson.stringField(event, "type"), Some("error"))
  ok(harness.feeder.destroyed(), "the input was abandoned rather than kept growing")
  // The shipped adapter exits nonzero for a truncated protocol stream. Reset
  // the shared test process after proving that path so later fixtures can run.
  ConvexNode.setExitCode(0)
  await stopHarness(harness)
})

test("input EOF closes the owned Live client instead of leaving a reconnect alive", async () => {
  let harness = await startHarness(
    ~afterDequeue=ConvexAdapter.noAfterDequeue,
    ~respond=successResponse,
  )
  send(
    harness,
    ConvexJson.object_([
      ("id", jsonString("eof-subscribe")),
      ("op", jsonString("subscribe")),
      ("subscriptionId", jsonString("eof-sub")),
      ("path", jsonString("demo:state")),
      ("args", ConvexJson.emptyObject()),
    ]),
  )
  await settle(harness)
  let socket = await handshake(harness.fake, 1)
  harness.feeder.finish()
  let attempts = ref(0)
  while !socket.gracefulClose && attempts.contents < 100 {
    await delay(5)
    attempts := attempts.contents + 1
  }
  ok(socket.gracefulClose, "EOF closed the Live socket")
  await stopHarness(harness)
})

test("the output budget stops a stalled stream instead of buffering it", async () => {
  let collector = makeCollector()
  let output = ConvexAdapter.makeOutput(collector.stream)
  let stopped = ref(false)
  output.onExhausted = () => stopped := true
  let event = ConvexAdapter.ackEvent("id", "ack")
  let written = ref(0)
  while written.contents < ConvexAdapter.maximumOutstandingRecords {
    ConvexAdapter.writeEvent(output, event)
    written := written.contents + 1
  }
  equal(Js.Array2.length(collector.written()), ConvexAdapter.maximumOutstandingRecords)
  equal(collector.pending(), ConvexAdapter.maximumOutstandingRecords)

  // Nothing has been flushed, so the next record would grow the buffer.
  ConvexAdapter.writeEvent(output, event)
  equal(Js.Array2.length(collector.written()), ConvexAdapter.maximumOutstandingRecords)
  ok(output.exhausted, "the adapter reports the exhausted budget instead of buffering")
  ok(stopped.contents, "budget exhaustion invokes bounded shutdown")
})

test("the output budget also counts bytes, not just records", async () => {
  let collector = makeCollector()
  let output = ConvexAdapter.makeOutput(collector.stream)
  let filler = Js.String2.repeat("x", 5 * 1024 * 1024)
  let large = ConvexJson.object_([
    ("type", jsonString("result")),
    ("id", jsonString("big")),
    ("value", jsonString(filler)),
  ])
  ConvexAdapter.writeEvent(output, large)
  equal(Js.Array2.length(collector.written()), 1)
  // Two of these are inside the record bound but far outside the byte budget.
  ConvexAdapter.writeEvent(output, large)
  equal(Js.Array2.length(collector.written()), 1)
  ok(output.exhausted, "the byte budget stops the stream before memory grows")

  // A flushed record releases its budget again.
  let released = makeCollector()
  let releasedOutput = ConvexAdapter.makeOutput(released.stream)
  ConvexAdapter.writeEvent(releasedOutput, large)
  released.flush()
  ConvexAdapter.writeEvent(releasedOutput, large)
  equal(Js.Array2.length(released.written()), 2)
  ok(!releasedOutput.exhausted, "flushed output does not count against the budget")
})

test("the TCP listen address is validated before anything listens", async () => {
  deepEqual(ConvexAdapter.parseListenAddress("0.0.0.0:8080"), Ok(("0.0.0.0", 8080)))
  deepEqual(ConvexAdapter.parseListenAddress("127.0.0.1:0"), Ok(("127.0.0.1", 0)))
  switch ConvexAdapter.parseListenAddress("8080") {
  | Ok(_) => fail("a port without a host was accepted")
  | Error(_) => ()
  }
  switch ConvexAdapter.parseListenAddress("host:notaport") {
  | Ok(_) => fail("a non-numeric port was accepted")
  | Error(_) => ()
  }
  switch ConvexAdapter.parseListenAddress("host:70000") {
  | Ok(_) => fail("an out-of-range port was accepted")
  | Error(_) => ()
  }
})
