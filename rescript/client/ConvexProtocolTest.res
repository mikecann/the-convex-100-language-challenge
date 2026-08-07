open ConvexTestSupport

test("deployment URLs are normalised once, and bad ones are refused", async () => {
  deepEqual(
    ConvexProtocol.normalizeDeploymentUrl("https://example.convex.cloud/"),
    Ok("https://example.convex.cloud"),
  )
  deepEqual(
    ConvexProtocol.normalizeDeploymentUrl("  http://backend:3210  "),
    Ok("http://backend:3210"),
  )
  // A path, query string, or fragment would change every endpoint, so none is
  // silently discarded or retained.
  switch ConvexProtocol.normalizeDeploymentUrl("https://example.convex.cloud/base/?a=1#b") {
  | Ok(_) => fail("a deployment URL with path/query/fragment was accepted")
  | Error(_) => ()
  }
  switch ConvexProtocol.normalizeDeploymentUrl("wss://example.convex.cloud") {
  | Ok(_) => fail("a non-HTTP scheme was accepted")
  | Error(_) => ()
  }
  switch ConvexProtocol.normalizeDeploymentUrl("https://user:secret@example.convex.cloud") {
  | Ok(_) => fail("credentials in the URL were accepted")
  | Error(_) => ()
  }
  switch ConvexProtocol.normalizeDeploymentUrl("https://") {
  | Ok(_) => fail("a URL without a host was accepted")
  | Error(_) => ()
  }
})

test("the sync endpoint is the pinned unversioned one", async () => {
  equal(
    ConvexProtocol.syncUrl("https://example.convex.cloud"),
    "wss://example.convex.cloud/api/sync",
  )
  equal(ConvexProtocol.syncUrl("http://backend:3210"), "ws://backend:3210/api/sync")
})

// The wire timestamp is a little-endian unsigned 64-bit value in base64, so
// string order and byte order both give the wrong answer once the low bytes
// roll over.
test("timestamps compare by value, not by encoded text", async () => {
  deepEqual(ConvexProtocol.compareTimestamps(timestampTwo, timestampOne), Ok(1))
  deepEqual(ConvexProtocol.compareTimestamps(timestampOne, timestampTwo), Ok(-1))
  deepEqual(ConvexProtocol.compareTimestamps(timestampOne, timestampOne), Ok(0))
  // 0x0000000000000100 against 0x00000000000000ff: the larger value has the
  // smaller-looking first byte.
  deepEqual(ConvexProtocol.compareTimestamps("AAEAAAAAAAA=", "/wAAAAAAAAA="), Ok(1))
  deepEqual(ConvexProtocol.compareTimestamps(ConvexProtocol.initialTimestamp, timestampOne), Ok(-1))
})

test("a malformed timestamp is a protocol failure, not a zero", async () => {
  switch ConvexProtocol.decodeTimestamp("not base64!") {
  | Ok(_) => fail("junk decoded as a timestamp")
  | Error(_) => ()
  }
  // Seven bytes, correctly encoded, is still not a timestamp.
  switch ConvexProtocol.decodeTimestamp("AAAAAAAAAA==") {
  | Ok(_) => fail("a short timestamp decoded")
  | Error(_) => ()
  }
  switch ConvexProtocol.compareTimestamps(timestampOne, "zzz") {
  | Ok(_) => fail("comparison against junk succeeded")
  | Error(_) => ()
  }
})

test("Connect carries session identity and only a known maximum timestamp", async () => {
  let withoutTimestamp = ConvexProtocol.connectMessage(
    ~sessionId="abc",
    ~connectionCount=2,
    ~lastCloseReason="DebugDisconnect",
    ~maxObservedTimestamp="",
  )
  equal(ConvexJson.stringField(withoutTimestamp, "type"), Some("Connect"))
  equal(ConvexJson.stringField(withoutTimestamp, "sessionId"), Some("abc"))
  equal(ConvexJson.intField(withoutTimestamp, "connectionCount"), Some(2))
  equal(ConvexJson.stringField(withoutTimestamp, "lastCloseReason"), Some("DebugDisconnect"))
  equal(ConvexJson.intField(withoutTimestamp, "clientTs"), Some(0))
  // Never send an empty timestamp; the field is absent until one is observed.
  equal(ConvexJson.field(withoutTimestamp, "maxObservedTimestamp"), None)

  let withTimestamp = ConvexProtocol.connectMessage(
    ~sessionId="abc",
    ~connectionCount=0,
    ~lastCloseReason="InitialConnect",
    ~maxObservedTimestamp=timestampTwo,
  )
  equal(ConvexJson.stringField(withTimestamp, "maxObservedTimestamp"), Some(timestampTwo))
})

test("ModifyQuerySet names the version it expects to apply to", async () => {
  let message = ConvexProtocol.modifyQuerySetMessage(
    ~baseVersion=3,
    ~newVersion=4,
    ~modifications=[
      ConvexProtocol.Add({queryId: 7, path: "demo:state", args: countValue(0.0)}),
      ConvexProtocol.Remove({queryId: 2}),
    ],
  )
  equal(ConvexJson.stringField(message, "type"), Some("ModifyQuerySet"))
  equal(ConvexJson.intField(message, "baseVersion"), Some(3))
  equal(ConvexJson.intField(message, "newVersion"), Some(4))
  let modifications = switch ConvexJson.field(message, "modifications") {
  | Some(value) =>
    switch ConvexJson.asArray(value) {
    | Some(items) => items
    | None => []
    }
  | None => []
  }
  equal(Js.Array2.length(modifications), 2)
  let add = Js.Array2.unsafe_get(modifications, 0)
  equal(ConvexJson.stringField(add, "type"), Some("Add"))
  equal(ConvexJson.intField(add, "queryId"), Some(7))
  equal(ConvexJson.stringField(add, "udfPath"), Some("demo:state"))
  // Convex takes a single named-arguments object, wrapped in the wire array.
  equal(
    switch ConvexJson.field(add, "args") {
    | Some(value) =>
      switch ConvexJson.asArray(value) {
      | Some(items) => Js.Array2.length(items)
      | None => -1
      }
    | None => -1
    },
    1,
  )
  let remove = Js.Array2.unsafe_get(modifications, 1)
  equal(ConvexJson.stringField(remove, "type"), Some("Remove"))
  equal(ConvexJson.field(remove, "udfPath"), None)
})

test("a Transition decodes into typed changes", async () => {
  let json = transitionJson(
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[
      queryUpdated(~queryId=0, ~value=countValue(1.0)),
      queryFailed(~queryId=1, ~message="room is empty", ~code="ROOM_EMPTY"),
      ConvexJson.object_([
        ("type", Js.Json.string("QueryRemoved")),
        ("queryId", Js.Json.number(2.0)),
      ]),
    ],
  )
  switch ConvexProtocol.decodeServerMessage(json) {
  | Ok(ConvexProtocol.Transition(transition)) => {
      equal(transition.startVersion.ts, ConvexProtocol.initialTimestamp)
      equal(transition.endVersion.ts, timestampOne)
      equal(Js.Array2.length(transition.changes), 3)
      switch Js.Array2.unsafe_get(transition.changes, 0) {
      | ConvexProtocol.QueryUpdated({queryId, value}) => {
          equal(queryId, 0)
          equal(ConvexJson.intField(value, "count"), Some(1))
        }
      | _ => fail("the first change should be QueryUpdated")
      }
      switch Js.Array2.unsafe_get(transition.changes, 1) {
      | ConvexProtocol.QueryFailed({message, data}) => {
          equal(message, "room is empty")
          equal(
            switch data {
            | Some(payload) => ConvexJson.stringField(payload, "code")
            | None => None
            },
            Some("ROOM_EMPTY"),
          )
        }
      | _ => fail("the second change should be QueryFailed")
      }
    }
  | _ => fail("a valid Transition failed to decode")
  }
})

test("unsupported and malformed server messages are named, not ignored", async () => {
  switch ConvexProtocol.decodeServerMessage(
    ConvexJson.object_([("type", Js.Json.string("Ping"))]),
  ) {
  | Ok(ConvexProtocol.Ignorable(name)) => equal(name, "Ping")
  | _ => fail("Ping should be ignorable")
  }
  // The pinned convex-rs 0.10.4 base client does not assemble chunks, so this
  // client treats one as profile drift rather than pretending to understand it.
  switch ConvexProtocol.decodeServerMessage(
    ConvexJson.object_([("type", Js.Json.string("TransitionChunk"))]),
  ) {
  | Ok(ConvexProtocol.Unsupported(message)) =>
    ok(Js.String2.includes(message, "TransitionChunk"), "the drift names the message")
  | _ => fail("TransitionChunk should be unsupported")
  }
  switch ConvexProtocol.decodeServerMessage(
    ConvexJson.object_([("type", Js.Json.string("FatalError")), ("error", Js.Json.string("boom"))]),
  ) {
  | Ok(ConvexProtocol.ServerError(message)) =>
    ok(Js.String2.includes(message, "boom"), "the server's reason is preserved")
  | _ => fail("FatalError should be a server error")
  }
  switch ConvexProtocol.decodeServerMessage(ConvexJson.emptyObject()) {
  | Error(_) => ()
  | Ok(_) => fail("a message without a type decoded")
  }
  let badModification = transitionJson(
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[
      ConvexJson.object_([
        ("type", Js.Json.string("QueryReticulated")),
        ("queryId", Js.Json.number(0.0)),
      ]),
    ],
  )
  switch ConvexProtocol.decodeServerMessage(badModification) {
  | Error(message) => ok(Js.String2.includes(message, "QueryReticulated"), "the change is named")
  | Ok(_) => fail("an unknown modification decoded")
  }

  let missingModifications = ConvexJson.object_([
    ("type", Js.Json.string("Transition")),
    ("startVersion", versionJson(startVersion)),
    ("endVersion", versionJson((1, timestampOne))),
  ])
  switch ConvexProtocol.decodeServerMessage(missingModifications) {
  | Error(_) => ()
  | Ok(_) => fail("a Transition without modifications decoded")
  }

  let negativeQuery = transitionJson(
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=-1, ~value=countValue(0.0))],
  )
  switch ConvexProtocol.decodeServerMessage(negativeQuery) {
  | Error(_) => ()
  | Ok(_) => fail("a negative query id decoded")
  }

  let malformedFailure = transitionJson(
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[
      ConvexJson.object_([
        ("type", Js.Json.string("QueryFailed")),
        ("queryId", Js.Json.number(0.0)),
        ("logLines", Js.Json.array([Js.Json.number(7.0)])),
      ]),
    ],
  )
  switch ConvexProtocol.decodeServerMessage(malformedFailure) {
  | Error(_) => ()
  | Ok(_) => fail("a QueryFailed without a message and with malformed logs decoded")
  }
})
