# Convex from ReScript

A small Convex client written in ReScript. It reads a shared counter over
Convex's documented HTTP API, watches the same counter over a realtime
WebSocket subscription, increments it once, and proves the subscription
reported the new value without asking again.

This is an educational demonstration for a video and website about how many
languages can talk to Convex. It is not an official Convex SDK, it is not
published to any registry, and it is not intended for production use.

## Start here

The canonical program is [`examples/basics/Main.res`](examples/basics/Main.res).
It walks one journey end to end: configure a client, read `0` over HTTP, start a
Live subscription and receive `0`, apply one idempotent increment, and receive
`1` on the subscription that was already open. Every step asserts the value it
expects, so an unexpected answer ends the run instead of printing a plausible
transcript.

## What works

| Capability | State |
| --- | --- |
| HTTP query, mutation, action | Implemented, verified by shared conformance |
| Bearer token set, replace, clear | Implemented, verified by shared conformance |
| Structured `ConvexError` data and log lines | Implemented, verified by shared conformance |
| Live subscribe, unsubscribe, reconnect, replay | Implemented, verified by shared conformance |
| Reactive query failure and recovery | Implemented, verified by shared conformance |
| Earned capability badges | HTTP and Live |

The Docker `test` target formats, compiles, and runs the language-local unit and
conformance suites on native `linux/amd64`. The shared local and hosted result
evaluator also passed, earning HTTP and Live.

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.res -->
```rescript
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
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

Every command runs from the repository root and builds inside Docker. The
language-local and shared verification commands passed for the reviewed source.

```sh
./run build rescript          # build the linux/amd64 image
./run test rescript           # format check, compile, unit tests, example test
./run verify-example rescript # run the canonical example against local Convex
./run verify rescript         # example plus shared black-box conformance
./run verify-hosted rescript  # the same suites against the hosted drift target
```

`test` proves the source is formatted, compiles, and passes the language-local
suites. `verify-example` proves the exact program printed above produces the
shared happy-path transcript against a real deployment. `verify` adds the
shared controller's black-box HTTP and Live suites. `verify-hosted` repeats them
against the dedicated hosted deployment, which is where protocol drift shows up.

## How it is put together

| Module | Responsibility |
| --- | --- |
| `client/Convex.res` | The public client: configuration, HTTP calls, subscriptions, shutdown |
| `client/ConvexHttp.res` | `/api/query`, `/api/mutation`, `/api/action` with `format: "json"` |
| `client/ConvexLive.res` | The single-owner sync socket: reconnect, replay, delivery |
| `client/ConvexProtocol.res` | URLs, state versions, timestamps, and every wire message |
| `client/ConvexJson.res` | Decoding rules, including Convex's integral JSON numbers |
| `client/ConvexError.res` | Function, protocol, transport, closed, and usage failures |
| `client/ConvexNode.res` | Every borrowed JavaScript value, in one auditable place |
| `client/tests/conformance/` | The NDJSON adapter the shared controller drives |

### Provenance

The client is native ReScript. ReScript's only compilation target is
JavaScript, so the runtime is Node.js: `fetch` performs HTTP, and the `ws`
package performs WebSocket framing and TLS. Every Convex-specific decision —
request shape, error classification, query-set versioning, transition
application, reconnect and replay, delivery bounds — is written in ReScript.
Nothing shells out to another Convex client or to the Convex CLI.

### Pinned realtime profile

Realtime is an internal Convex wire protocol, not a documented third-party API.
This client implements one inspected profile and nothing else:

| Property | Value |
| --- | --- |
| Profile | `convex-rs-0.10.4-unversioned-sync` |
| Source commit | `6f1df8a8ba1665084ec001e307ca841ca17074d7` |
| Endpoint | `/api/sync` |
| Timestamps | Opaque little-endian base64, compared by value |
| `TransitionChunk` | Reported as profile drift, not assembled |

Convex JavaScript 1.43.0 uses `/api/<version>/sync` and keeps different session
state. This client does not mix the two.

### The single-owner socket

One owner holds the WebSocket. Subscribes, unsubscribes, reads, reconnect
timers, socket callbacks, and shutdown all become commands on one queue, and the
owner drains that queue one command at a time. Nothing else may write to the
socket or move the query-set version, so a reconnect can never race a subscribe
and a retired connection's message can never be applied to a fresh session. Each
connection is tagged with a generation, and events from an older generation are
dropped.

A reconnect rebuilds the entire query set from scratch. Where a subscriber has
already been given a value, that query is marked as awaiting rehydration, so an
identical replayed value is not published a second time: after
`debugDisconnect`, the subscriber sees the initial value, then the next real
write, and nothing in between.

### Delivery bounds

Live delivery is a bounded newest-value queue per subscription: at most 16
updates and at most 1 MiB. An individual value that cannot fit is replaced by a
small structured transport failure rather than retained outside the byte
budget. A reactive query describes current state, so a slow reader is given the
newest values rather than an unbounded backlog. There are at most 16 active
subscriptions, with at most 16 KiB of encoded arguments each. Even a full
replay therefore remains below the 2 MiB outgoing-message guard.

Reconnect suppression stores a SHA-256 fingerprint of the last delivered
value, not another copy of the value itself.

HTTP reads stream through a 2 MiB decoded-body byte bound under one 10 second absolute
deadline. WebSocket handshakes have a 5 second deadline and `ws` rejects any
incoming message above 2 MiB before handing it to ReScript. A referenced
five-second ping/pong heartbeat retires a socket within two heartbeat periods
when an incomplete frame prevents control frames from being processed.

The conformance adapter bounds both directions. One command line may not exceed
1 MiB before the connection is abandoned, and output the runtime has not yet
flushed may not exceed 16 records or 8 MiB. Those bounds exist because a
controller that stops reading is the only realistic way for this process to
approach the 128 MiB the verifier allows it.

### The conformance adapter

`client/tests/conformance/` implements NDJSON adapter protocol v1 over stdio, or
over one accepted TCP connection when `ADAPTER_LISTEN` is set. Stdout carries
protocol events only; diagnostics go to stderr. It is test infrastructure, not
public client code, and it owns the only test hook in this repository:
`debugDisconnect`, which drops the socket without closing the client so the
shared controller can prove five real reconnects. `debugDisconnect` is not part
of the educational client API.

## Limitations and what is not proven

- **The Docker `test` target passes on native `linux/amd64`.** Format check,
  compilation, the language-local unit and conformance suites, the canonical
  example, and the adapter protocol smoke test all run green inside Docker.
  `verify` and `verify-hosted` also passed against local and hosted
  deployments, so the manifest records the earned HTTP and Live capabilities.
- **First-build fixes.** This checkpoint had never been compiled before its
  first Docker build, and several genuine defects surfaced: a recursive
  `sources` scan trying to compile the `rescript` package's own `.resi`-only
  stdlib interface as a project source (fixed with an `ignored-dirs` entry for
  `node_modules`); a `bytes` type name colliding with the compiler's built-in
  type; a punned single-field record `{queryId}` parsing as a block expression
  instead of a record in constructor position, in three places; a missing
  `rec` on a mutually recursive type group; a missing pair of braces that let a
  `switch` parse as a separate top-level statement, losing its enclosing
  function's parameter; two field-name ambiguities across record types with
  overlapping field names, needing explicit annotations; a test fixture that
  exercised the wrong HTTP status for an "unknown status field" case; a
  polling helper's `setTimeout` being unref'd, which let Node's test runner
  conclude the event loop was idle mid-poll and cancel every later test in the
  file; a test missing a drain of an expected failure event before reading the
  next value; and a double-escaped `"\\n"` inside a `%raw` JS template literal
  that never actually split on the real newlines `writeEvent` writes, so any
  test reading back more than one record saw one unparseable blob instead of
  two. `ws` exposing `WebSocket` as a named ESM export, the runtime stage's
  `{"type":"module"}` marker, `node --test`'s explicit globs, and the projected
  npm v3 lockfile all worked as assumed; only formatting and the defects above
  needed correcting.
- **The runtime image cannot pass image policy yet.** ReScript compiles to
  JavaScript, so the minimal images need `node` as their declared target runtime
  command. The shared policy in
  `_shared/harness/scripts/target-runtime-policy.mjs` approves that command for
  `javascript` and `typescript` only. Extending it to `rescript` is a shared
  infrastructure decision, so `manifest.yaml` deliberately leaves
  `targetRuntimeCommand` undeclared and this branch changes nothing under
  `_shared/`.
- **Frame progress uses a heartbeat guard.** `ws` owns frame parsing and the
  2 MiB message bound. The client adds a five-second ping/pong deadline, so an
  incomplete frame that prevents a pong from being parsed retires within ten
  seconds. The first hostile-peer Docker fixture still has to prove this exact
  delegated-runtime behaviour under continuous dribble and bounded shutdown.
- **Syntax highlighting.** `.res` is not in the shared README fence map, so the
  generated block above renders as plain text. Adding it is a shared change.
- Live authentication, WebSocket mutations and actions, mutation replay,
  optimistic updates, journals, read-your-own-write commit timestamps, and full
  Convex value encodings are outside this client's scope.
- Yellow uses the documented `format: "json"`, so Int64, bytes, special floats,
  and negative zero are not claimed to round-trip losslessly.
