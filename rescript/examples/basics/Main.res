// The canonical Convex-from-ReScript example: read a shared counter over HTTP,
// watch it over a Live subscription, increment it once, and prove the
// subscription reports the new value without asking again.
//
// Every line it prints is part of the shared happy-path transcript, so
// diagnostics go to stderr and any unexpected value ends the run with a
// failure instead of a plausible-looking transcript.

// The verifier passes a unique room as the first argument. The environment
// variable and the fixed name are conveniences for running the image by hand.
let room = switch Belt.Array.get(ConvexNode.argv, 2) {
| Some(value) if value != "" => value
| _ =>
  switch Js.Dict.get(ConvexNode.environment, "EXAMPLE_ROOM") {
  | Some(value) if value != "" => value
  | _ => "rescript-example"
  }
}

let deploymentUrl = switch Js.Dict.get(ConvexNode.environment, "CONVEX_URL") {
| Some(value) if value != "" => value
| _ => ConvexError.raiseError(ConvexError.usage("CONVEX_URL is required"))
}

let roomArguments = () => ConvexJson.object_([("room", Js.Json.string(room))])

// Convex counts are JSON numbers, so the same value can arrive as `0` or as
// `0.0`. This accepts either, and refuses anything fractional, quoted, or out
// of range rather than printing a rounded guess.
let requireCount = (label, value) =>
  switch ConvexJson.intField(value, "count") {
  | Some(count) => count
  | None =>
    ConvexError.raiseError(ConvexError.protocol(label ++ " did not return an integral count"))
  }

let requireExactly = (label, actual, expected) =>
  if actual != expected {
    ConvexError.raiseError(
      ConvexError.protocol(
        label ++
        " count was " ++
        Belt.Int.toString(actual) ++
        ", expected " ++
        Belt.Int.toString(expected),
      ),
    )
  }

// A Live read must not be able to hang the example forever. The timer is
// unreferenced, so a successful run still exits immediately.
let deadline = (label, milliseconds) =>
  ConvexNode.makePromise((_resolve, reject) => {
    let timer = ConvexNode.setTimeout(
      () => reject(ConvexError.ConvexFailure(ConvexError.transport(label ++ " timed out"))),
      milliseconds,
    )
    let _ = ConvexNode.unrefTimer(timer)
  })

// Waits for the next Live value, turning a finished subscription or a reactive
// query failure into an error instead of a silently missing line of output.
let nextValue = async (subscription, label) => {
  let update = await ConvexNode.race([ConvexLive.next(subscription), deadline(label, 10000)])
  switch update {
  | None => ConvexError.raiseError(ConvexError.protocol(label ++ " ended before a value arrived"))
  | Some(ConvexLive.Failure(error)) => ConvexError.raiseError(error)
  | Some(ConvexLive.Value({value})) => value
  }
}

// ReScript has no `finally`, so cleanup that must happen on both paths is
// written out: keep the failure, always clean up, then re-raise it.
let protectWith = async (body, cleanup) => {
  let failure = try {
    await body()
    None
  } catch {
  | error => Some(error)
  }
  await cleanup()
  switch failure {
  | None => ()
  | Some(error) => raise(error)
  }
}

let liveJourney = async (client, subscription, startingCount) => {
  // The first Live value proves the state the increment starts from.
  let initial = await nextValue(subscription, "initial Live value")
  let initialCount = requireCount("initial Live value", initial)
  requireExactly("initial Live value", initialCount, startingCount)
  Js.log("live initial count: " ++ Belt.Int.toString(initialCount))

  // The run id is the mutation's idempotency key. The backend records it, so a
  // retried increment cannot count twice.
  let applied = await Convex.mutation(
    client,
    "demo:increment",
    ConvexJson.object_([
      ("room", Js.Json.string(room)),
      ("language", Js.Json.string("rescript")),
      ("runId", Js.Json.string(ConvexNode.randomUUID())),
    ]),
  )
  switch ConvexJson.field(applied.value, "applied") {
  | Some(flag) if ConvexJson.asBool(flag) == Some(true) => ()
  | _ => ConvexError.raiseError(ConvexError.protocol("mutation was not applied"))
  }
  Js.log("mutation applied: true")

  let mutationState = switch ConvexJson.field(applied.value, "state") {
  | Some(state) => state
  | None => ConvexError.raiseError(ConvexError.protocol("mutation returned no room state"))
  }
  requireExactly("mutation", requireCount("mutation", mutationState), 1)
  Js.log("mutation count: 1")

  // The next Live value is the write that just happened: the server pushed it
  // down the socket that was already open, with no second query.
  let updated = await nextValue(subscription, "updated Live value")
  let updatedCount = requireCount("updated Live value", updated)
  requireExactly("updated Live value", updatedCount, 1)
  Js.log("live updated count: " ++ Belt.Int.toString(updatedCount))

  // Printed only after the HTTP read, the initial Live value, the mutation, and
  // the Live update all agreed.
  Js.log("verified count: 0 -> 1")
}

let journey = async client => {
  // Read the counter once over Convex's documented HTTP query endpoint.
  let current = await Convex.query(client, "demo:state", roomArguments())
  let currentCount = requireCount("current query", current.value)
  requireExactly("current query", currentCount, 0)
  Js.log("current count: " ++ Belt.Int.toString(currentCount))

  // Subscribing before the mutation is what makes the update below evidence:
  // the socket is already watching this room when the write happens.
  let subscription = await Convex.subscribe(client, "demo:state", roomArguments())
  await protectWith(
    () => liveJourney(client, subscription, currentCount),
    // Unsubscribe even when a check above failed, so the query set is clean
    // before the client closes.
    () => ConvexLive.closeSubscription(subscription),
  )
}

let main = async () => {
  // Create the client for the deployment the verifier selected. Nothing
  // connects yet: HTTP calls are independent requests, and Live starts with the
  // first subscription.
  let client = Convex.make(deploymentUrl)
  await protectWith(
    () => journey(client),
    // Close the WebSocket and refuse later calls, so the example exits instead
    // of lingering on an open connection.
    () => Convex.close(client),
  )
}

ConvexNode.catchError(main(), error => {
  ConvexNode.logDiagnostic("convex example failed: " ++ ConvexError.fromException(error).message)
  ConvexNode.exitProcess(1)
})
