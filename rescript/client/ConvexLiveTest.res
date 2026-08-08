open ConvexTestSupport

// Every test below drives a scripted transport, so reconnects, replays, and
// failures are exact rather than timing-dependent. Only the reconnect delay
// itself is real, and the tests wait for the owner to make its next
// connection instead of assuming when that happens.

let roomArgs = room => jsonObject([("room", jsonString(room))])

let makeManager = fake =>
  ConvexLive.make(
    ~deploymentUrl="http://backend:3210",
    ~clientVersion="rescript-test",
    ~transport=fake.transport,
  )

let expectValue = (update, label) =>
  switch update {
  | Some(ConvexLive.Value({value})) => value
  | Some(ConvexLive.Failure(error)) => {
      fail(label ++ " failed: " ++ error.message)
      ConvexJson.emptyObject()
    }
  | None => {
      fail(label ++ " ended instead of delivering a value")
      ConvexJson.emptyObject()
    }
  }

let expectCount = (update, label, expected) =>
  equal(ConvexJson.intField(expectValue(update, label), "count"), Some(expected))

let expectFailureUpdate = (update, label) =>
  switch update {
  | Some(ConvexLive.Failure(error)) => error
  | _ => {
      fail(label ++ " should have been a failure")
      ConvexError.transport("unreachable")
    }
  }

test("a subscription opens one connection, sends its query set, and gets a value", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let socket = await handshake(fake, 1)

  // Connect first, then exactly one ModifyQuerySet describing the whole set.
  deepEqual(messageTypes(socket), ["Connect", "ModifyQuerySet"])
  let modify = switch lastMessage(socket) {
  | Some(message) => message
  | None => ConvexJson.emptyObject()
  }
  equal(ConvexJson.intField(modify, "baseVersion"), Some(0))
  equal(ConvexJson.intField(modify, "newVersion"), Some(1))
  let add = switch ConvexJson.field(modify, "modifications") {
  | Some(value) =>
    switch ConvexJson.asArray(value) {
    | Some(items) => Js.Array2.unsafe_get(items, 0)
    | None => ConvexJson.emptyObject()
    }
  | None => ConvexJson.emptyObject()
  }
  equal(ConvexJson.stringField(add, "type"), Some("Add"))
  equal(ConvexJson.stringField(add, "udfPath"), Some("demo:state"))

  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  expectCount(await ConvexLive.next(subscription), "initial value", 0)
  await ConvexLive.close(manager)
})

test("a later external write arrives on the same socket", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let socket = await handshake(fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  expectCount(await ConvexLive.next(subscription), "initial value", 0)

  // Nothing is sent by the client here: the second value is pushed.
  sendTransition(
    socket,
    ~from=(1, timestampOne),
    ~to_=(1, timestampTwo),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(1.0))],
  )
  expectCount(await ConvexLive.next(subscription), "external update", 1)
  equal(Js.Array2.length(socket.sent), 2)
  await ConvexLive.close(manager)
})

test("duplicate changes publish only the final value in a transition", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("last-wins"))
  let socket = await handshake(fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[
      queryUpdated(~queryId=0, ~value=countValue(1.0)),
      queryUpdated(~queryId=0, ~value=countValue(2.0)),
    ],
  )
  expectCount(await ConvexLive.next(subscription), "last change", 2)
  let pending = ConvexLive.next(subscription)
  await ConvexLive.close(manager)
  equal(await pending, None)
})

test("a regressing transition retires the connection with a protocol error", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("regression"))
  let socket = await handshake(fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampTwo),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(1.0))],
  )
  expectCount(await ConvexLive.next(subscription), "forward transition", 1)
  sendTransition(socket, ~from=(1, timestampTwo), ~to_=(1, timestampOne), ~modifications=[])
  let error = expectFailureUpdate(await ConvexLive.next(subscription), "regressing transition")
  equal(ConvexError.name(error), "ProtocolError")
  await ConvexLive.close(manager)
})

test("a failed reactive query stays subscribed and recovers when repaired", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:requiresNonzero", roomArgs("a"))
  let socket = await handshake(fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryFailed(~queryId=0, ~message="room is empty", ~code="ROOM_EMPTY")],
  )
  let failure = expectFailureUpdate(await ConvexLive.next(subscription), "the empty room")
  equal(ConvexError.name(failure), "FunctionError")
  equal(
    switch failure.data {
    | Some(data) => ConvexJson.stringField(data, "code")
    | None => None
    },
    Some("ROOM_EMPTY"),
  )

  // The query set was never touched, so the repaired value arrives on the same
  // subscription.
  sendTransition(
    socket,
    ~from=(1, timestampOne),
    ~to_=(1, timestampTwo),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(1.0))],
  )
  expectCount(await ConvexLive.next(subscription), "the repaired query", 1)
  await ConvexLive.close(manager)
})

test("unsubscribe sends Remove and no queued value crosses the acknowledgement", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let socket = await handshake(fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  // A value is sitting in the queue, unread, when the caller unsubscribes.
  await ConvexLive.closeSubscription(subscription)
  deepEqual(messageTypes(socket), ["Connect", "ModifyQuerySet", "ModifyQuerySet"])
  let remove = switch lastMessage(socket) {
  | Some(message) => message
  | None => ConvexJson.emptyObject()
  }
  let modification = switch ConvexJson.field(remove, "modifications") {
  | Some(value) =>
    switch ConvexJson.asArray(value) {
    | Some(items) => Js.Array2.unsafe_get(items, 0)
    | None => ConvexJson.emptyObject()
    }
  | None => ConvexJson.emptyObject()
  }
  equal(ConvexJson.stringField(modification, "type"), Some("Remove"))
  equal(ConvexJson.intField(modification, "queryId"), Some(0))

  // The queued value is gone, and a later server message cannot revive it.
  sendTransition(
    socket,
    ~from=(1, timestampOne),
    ~to_=(1, timestampTwo),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(9.0))],
  )
  equal(await ConvexLive.next(subscription), None)
  await ConvexLive.close(manager)
})

// The shared controller proves five real reconnects. Each one must rebuild the
// query set and must not republish a value the subscriber already has.
test("five debugDisconnects each reconnect, replay, and suppress a stale value", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let firstSocket = await handshake(fake, 1)
  sendTransition(
    firstSocket,
    ~from=startVersion,
    ~to_=(1, timestampFor(1)),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  expectCount(await ConvexLive.next(subscription), "initial value", 0)

  let round = ref(1)
  while round.contents <= 5 {
    let attempt = round.contents
    let previous = switch latestSocket(fake) {
    | Some(socket) => socket
    | None => await waitForSocket(fake, attempt)
    }
    await ConvexLive.debugDisconnect(manager)
    ok(previous.terminated, "the old connection was retired before the acknowledgement")

    let socket = await handshake(fake, attempt + 1)
    // Every connection resends the active Add operations.
    deepEqual(messageTypes(socket), ["Connect", "ModifyQuerySet"])
    let connect = Js.Array2.unsafe_get(sentMessages(socket), 0)
    equal(ConvexJson.intField(connect, "connectionCount"), Some(attempt))
    equal(ConvexJson.stringField(connect, "lastCloseReason"), Some("DebugDisconnect"))
    equal(
      ConvexJson.stringField(connect, "maxObservedTimestamp"),
      Some(timestampFor(attempt * 2 - 1)),
    )

    // The server rehydrates the query with the value already delivered. That
    // must not be republished.
    sendTransition(
      socket,
      ~from=startVersion,
      ~to_=(1, timestampFor(attempt * 2)),
      ~modifications=[queryUpdated(~queryId=0, ~value=countValue(Belt.Int.toFloat(attempt - 1)))],
    )
    // Then a real external write happens.
    sendTransition(
      socket,
      ~from=(1, timestampFor(attempt * 2)),
      ~to_=(1, timestampFor(attempt * 2 + 1)),
      ~modifications=[queryUpdated(~queryId=0, ~value=countValue(Belt.Int.toFloat(attempt)))],
    )
    expectCount(await ConvexLive.next(subscription), "the value after reconnect", attempt)
    round := attempt + 1
  }
  await ConvexLive.close(manager)
})

// Matches the shared harness's client/live/reconnect-five-times scenario
// exactly: each of the five rounds subscribes to a brand-new query, forces a
// disconnect, mutates, awaits the reconnected value, and unsubscribes before
// the next round starts -- unlike the test above, which keeps one
// subscription alive across all five rounds. This is the shape that exposed
// the real "Live WebSocket is not connected" failure the shared conformance
// pilot reported: activeCount(manager) legitimately hits zero between
// rounds, and a subsequent debugDisconnect must still find a live
// connection.
test(
  "five independent subscribe/disconnect/mutate/unsubscribe rounds each reconnect and deliver",
  async () => {
    let fake = makeFakeTransport()
    let manager = makeManager(fake)
    let socketCount = ref(0)
    let tsCounter = ref(0)
    let nextTimestamp = () => {
      tsCounter := tsCounter.contents + 1
      timestampFor(tsCounter.contents)
    }
    // Mirrors manager.remoteVersion. querySetVersion is read straight off the
    // manager instead of tracked by hand: the protocol allows only one
    // outstanding ModifyQuerySet at a time (see sendOrQueueModification in
    // ConvexLive.res), so a Remove this test never acknowledges would leave a
    // later Subscribe's Add queued rather than sent, and any hand-computed
    // version would silently drift from what the client actually wrote.
    let remote = ref(startVersion)

    let round = ref(1)
    while round.contents <= 5 {
      let attempt = round.contents
      let label = "round " ++ Belt.Int.toString(attempt)
      let subscription = await ConvexLive.subscribe(
        manager,
        "demo:state",
        roomArgs("round-" ++ Belt.Int.toString(attempt)),
      )

      // The very first round's subscribe opens a fresh connection; every
      // later round's subscribe reuses the connection left open by the
      // previous round's reconnect, exactly like the real transport does --
      // activeCount(manager) genuinely reaches zero between rounds, since
      // each round unsubscribes before the next one starts.
      let socket = if attempt == 1 {
        socketCount := socketCount.contents + 1
        let socket = await handshake(fake, socketCount.contents)
        remote := startVersion
        socket
      } else {
        switch latestSocket(fake) {
        | Some(socket) => socket
        | None => await waitForSocket(fake, socketCount.contents)
        }
      }
      let initialTs = nextTimestamp()
      sendTransition(
        socket,
        ~from=remote.contents,
        ~to_=(manager.querySetVersion, initialTs),
        ~modifications=[queryUpdated(~queryId=attempt - 1, ~value=countValue(0.0))],
      )
      remote := (manager.querySetVersion, initialTs)
      expectCount(await ConvexLive.next(subscription), label ++ ": initial value", 0)

      let beforeDisconnect = switch latestSocket(fake) {
      | Some(socket) => socket
      | None => await waitForSocket(fake, socketCount.contents)
      }
      await ConvexLive.debugDisconnect(manager)
      ok(beforeDisconnect.terminated, label ++ ": the old connection was retired")

      socketCount := socketCount.contents + 1
      let reconnected = await handshake(fake, socketCount.contents)
      // Every reconnect resets remoteVersion and immediately re-adds the
      // still-active subscription, exactly like the very first connection.
      remote := startVersion
      let mutatedTs = nextTimestamp()
      sendTransition(
        reconnected,
        ~from=remote.contents,
        ~to_=(manager.querySetVersion, mutatedTs),
        ~modifications=[queryUpdated(~queryId=attempt - 1, ~value=countValue(1.0))],
      )
      remote := (manager.querySetVersion, mutatedTs)
      expectCount(await ConvexLive.next(subscription), label ++ ": the value after reconnect", 1)

      await ConvexLive.closeSubscription(subscription)
      // Acknowledge the Remove closeSubscription just sent, the way a real
      // server eventually would, so it never sits as an outstanding,
      // unacknowledged ModifyQuerySet across the boundary into the next
      // round -- exactly the gap that let two of these race in production.
      let removeTs = nextTimestamp()
      sendTransition(
        reconnected,
        ~from=remote.contents,
        ~to_=(manager.querySetVersion, removeTs),
        ~modifications=[],
      )
      remote := (manager.querySetVersion, removeTs)
      round := attempt + 1
    }
    await ConvexLive.close(manager)
  },
)

test("transport backoff resets after a healthy connection", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let first = await handshake(fake, 1)
  equal(manager.backoffMs, ConvexLive.initialBackoffMs)

  // A drop before any handshake grows the delay.
  dropSocket(first, "network gone")
  ok(manager.backoffMs > ConvexLive.initialBackoffMs, "a failure grows the retry delay")
  // Every closed socket is reported to the subscriber (see "a refused
  // connection is retried rather than raised at the caller"), so the drop's
  // failure must be drained before the reconnect's value is read, or it is
  // this failure -- not the new value -- that comes back first.
  let _ = expectFailureUpdate(await ConvexLive.next(subscription), "the dropped connection")

  let second = await handshake(fake, 2)
  // A healthy connection must not inherit the previous outage's delay.
  equal(manager.backoffMs, ConvexLive.initialBackoffMs)
  equal(manager.connectionCount, 1)
  sendTransition(
    second,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(3.0))],
  )
  expectCount(await ConvexLive.next(subscription), "the value after reconnect", 3)
  await ConvexLive.close(manager)
})

test("a protocol violation is reported and the subscription still recovers", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let first = await handshake(fake, 1)
  // A transition that does not continue from the client's version cannot be
  // applied: applying it would silently skip state.
  sendTransition(
    first,
    ~from=(7, timestampTwo),
    ~to_=(8, timestampTwo),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(5.0))],
  )
  let error = expectFailureUpdate(await ConvexLive.next(subscription), "the bad transition")
  equal(ConvexError.name(error), "ProtocolError")
  ok(first.terminated, "the offending connection was dropped")

  let second = await handshake(fake, 2)
  sendTransition(
    second,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(2.0))],
  )
  expectCount(await ConvexLive.next(subscription), "the value after recovery", 2)
  await ConvexLive.close(manager)
})

test("messages outside the pinned profile are reported as drift", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let socket = await handshake(fake, 1)
  deliver(socket, `{"type":"TransitionChunk","id":1}`)
  let error = expectFailureUpdate(await ConvexLive.next(subscription), "a chunked transition")
  equal(ConvexError.name(error), "ProtocolError")
  ok(Js.String2.includes(error.message, "TransitionChunk"), "the drift names the message")

  let recovered = await handshake(fake, 2)
  // Invalid JSON is a protocol failure too, not a silent reconnect.
  deliver(recovered, "{not json")
  let parseError = expectFailureUpdate(await ConvexLive.next(subscription), "invalid JSON")
  equal(ConvexError.name(parseError), "ProtocolError")
  await ConvexLive.close(manager)
})

test("a slow reader keeps the newest updates, by count and by bytes", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let socket = await handshake(fake, 1)

  // Twenty updates, no reader. The queue keeps the newest sixteen.
  let index = ref(1)
  while index.contents <= 20 {
    let step = index.contents
    // The first transition continues from the version a fresh connection has;
    // the rest continue from the previous one.
    sendTransition(
      socket,
      ~from=(step == 1 ? 0 : 1, timestampFor(step - 1)),
      ~to_=(1, timestampFor(step)),
      ~modifications=[queryUpdated(~queryId=0, ~value=countValue(Belt.Int.toFloat(step)))],
    )
    index := step + 1
  }
  expectCount(await ConvexLive.next(subscription), "the oldest retained update", 5)

  let drain = ref(1)
  while drain.contents < ConvexLive.maximumQueuedUpdates {
    let _ = await ConvexLive.next(subscription)
    drain := drain.contents + 1
  }

  // One value larger than half the byte budget, twice: the count bound would
  // keep both, so only the byte budget can drop the first.
  let filler = Js.String2.repeat("x", 700 * 1024)
  let large = count =>
    ConvexJson.object_([("count", Js.Json.number(count)), ("filler", Js.Json.string(filler))])
  sendTransition(
    socket,
    ~from=(1, timestampFor(20)),
    ~to_=(1, timestampFor(21)),
    ~modifications=[queryUpdated(~queryId=0, ~value=large(21.0))],
  )
  sendTransition(
    socket,
    ~from=(1, timestampFor(21)),
    ~to_=(1, timestampFor(22)),
    ~modifications=[queryUpdated(~queryId=0, ~value=large(22.0))],
  )
  expectCount(await ConvexLive.next(subscription), "the newest large update", 22)

  // One value cannot be retained merely because it is newest. The queue stays
  // inside its byte bound and reports why that update was unavailable.
  let oversized = Js.String2.repeat("y", ConvexLive.maximumQueuedBytes + 1024)
  sendTransition(
    socket,
    ~from=(1, timestampFor(22)),
    ~to_=(1, timestampFor(23)),
    ~modifications=[
      queryUpdated(~queryId=0, ~value=ConvexJson.object_([("filler", Js.Json.string(oversized))])),
    ],
  )
  let oversizedError = expectFailureUpdate(
    await ConvexLive.next(subscription),
    "the oversized queued update",
  )
  equal(ConvexError.name(oversizedError), "TransportError")
  await ConvexLive.close(manager)
})

test("one subscription allows one pending read", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let _socket = await handshake(fake, 1)
  // The first read is still parked when the second arrives.
  let first = ConvexLive.next(subscription)
  let error = await expectFailure(() => ConvexLive.next(subscription), "a second concurrent read")
  equal(ConvexError.name(error), "UsageError")
  await ConvexLive.close(manager)
  equal(await first, None)
})

test("close finishes every subscription and never reconnects", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let first = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let second = await ConvexLive.subscribe(manager, "demo:state", roomArgs("b"))
  let socket = await handshake(fake, 1)
  await ConvexLive.close(manager)

  ok(socket.gracefulClose, "the socket was asked to close politely")
  // Close does not wait for a peer that may never answer.
  equal(await ConvexLive.next(first), None)
  equal(await ConvexLive.next(second), None)
  await delay(250)
  equal(Js.Array2.length(fake.sockets), 1)
})

test("a refused connection is retried rather than raised at the caller", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  fake.failNextConnect := true
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("a"))
  let refused = expectFailureUpdate(await ConvexLive.next(subscription), "the refused connection")
  equal(ConvexError.name(refused), "TransportError")
  let socket = await handshake(fake, 1)
  equal(manager.connectionCount, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(0.0))],
  )
  expectCount(await ConvexLive.next(subscription), "the value after a refused connect", 0)
  await ConvexLive.close(manager)
})

test("one logical session id survives a transport reconnect", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let _subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("session"))
  let first = await handshake(fake, 1)
  let firstConnect = Js.Array2.unsafe_get(sentMessages(first), 0)
  let firstId = ConvexJson.stringField(firstConnect, "sessionId")

  dropSocket(first, "fixture disconnect")
  let second = await handshake(fake, 2)
  let secondConnect = Js.Array2.unsafe_get(sentMessages(second), 0)
  equal(ConvexJson.stringField(secondConnect, "sessionId"), firstId)
  await ConvexLive.close(manager)
})

test("a retired transport drops queued values before its structured error", async () => {
  let fake = makeFakeTransport()
  let manager = makeManager(fake)
  let subscription = await ConvexLive.subscribe(manager, "demo:state", roomArgs("retire"))
  let socket = await handshake(fake, 1)
  sendTransition(
    socket,
    ~from=startVersion,
    ~to_=(1, timestampOne),
    ~modifications=[queryUpdated(~queryId=0, ~value=countValue(7.0))],
  )
  // The value is unread when the connection dies. The next observation must
  // describe the retirement, not leak a value from the old generation.
  dropSocket(socket, "connection reset")
  let error = expectFailureUpdate(await ConvexLive.next(subscription), "retired transport")
  equal(ConvexError.name(error), "TransportError")
  await ConvexLive.close(manager)
})
