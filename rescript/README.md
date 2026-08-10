<img src="logo.png" alt="ReScript brandmark" width="120">
<!-- Logo source: https://www.rescript-lang.org/brand/rescript-brandmark.svg -->

# ReScript

[ReScript](https://rescript-lang.org/) is a statically typed language that
compiles to JavaScript for browser and Node.js applications. Its roots are in
OCaml: BuckleScript adapted OCaml for JavaScript developers, Reason supplied an
alternative syntax, and [the projects unified under the ReScript name in
2020](https://rescript-lang.org/blog/bucklescript-is-rebranding/). Today it
occupies a focused niche for developers who want JavaScript output and interop
with a type system descended from OCaml, including type inference, variants,
and exhaustive pattern matching.

This repository's client is an educational, unofficial demonstration. It is
not a production SDK, is not published to a package registry, and is not
supported by Convex or the ReScript project.

## Getting Started

Start with [`examples/basics/Main.res`](examples/basics/Main.res). It reads a
shared counter over HTTP, opens a Live subscription before mutating the counter,
and confirms that the already-open subscription receives the new value.

From the repository root, run the canonical program in its Docker image:

```sh
./run verify-example rescript
```

Docker supplies the pinned ReScript and Node.js toolchain, so you do not need
either installed on your machine. The command uses a unique room on the
approved test deployment and checks the program's exact six-line transcript.

## Interesting Parts

### A generated TypeScript client versus checked JSON

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function RoomCount() {
  const state = useQuery(api.demo.state, { room: "rescript-tour" });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // The generated API makes state.count a number.
}
```

**ReScript**

```rescript
let deploymentUrl = switch Js.Dict.get(ConvexNode.environment, "CONVEX_URL") {
| Some(value) if value != "" => value
| _ => ConvexError.raiseError(ConvexError.usage("CONVEX_URL is required"))
}

let readCount = async () => {
  let client = Convex.make(deploymentUrl)
  // This small client names the function as a string and builds JSON arguments.
  let args = ConvexJson.object_([("room", Js.Json.string("rescript-tour"))])
  let result = await Convex.query(client, "demo:state", args)

  // Server JSON is checked at the boundary before it becomes a ReScript int.
  let count = switch ConvexJson.intField(result.value, "count") {
  | Some(count) => count
  | None => ConvexError.raiseError(ConvexError.protocol("state had no integral count"))
  }
  Js.log(count)
  await Convex.close(client)
}
```

The React hook is reactive and uses Convex's generated TypeScript API. This
ReScript call is a one-off HTTP request, and this educational client deliberately
returns `Js.Json.t`, so the application must decode the result. ReScript's
`option` and exhaustive `switch` make the success and failure paths visible.

### React owns reactivity; this client hands you the subscription

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const room = "rescript-live-demo";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={() =>
        increment({ room, language: "typescript", runId: crypto.randomUUID() })
      }
    >
      Count: {state?.count ?? "loading"}
    </button>
  ); // React keeps the query subscribed and rerenders after the mutation.
}
```

**ReScript**

```rescript
let deploymentUrl = switch Js.Dict.get(ConvexNode.environment, "CONVEX_URL") {
| Some(value) if value != "" => value
| _ => ConvexError.raiseError(ConvexError.usage("CONVEX_URL is required"))
}

let watchOneIncrement = async () => {
  let client = Convex.make(deploymentUrl)
  let room = "rescript-live-demo"
  let args = ConvexJson.object_([("room", Js.Json.string(room))])

  // This command-line API exposes subscription ownership directly.
  let subscription = await Convex.subscribe(client, "demo:state", args)
  let initial = await ConvexLive.next(subscription) // Wait for the initial state.

  let mutationResult = await Convex.mutation(
    client,
    "demo:increment",
    ConvexJson.object_([
      ("room", Js.Json.string(room)),
      ("language", Js.Json.string("rescript")),
      ("runId", Js.Json.string(ConvexNode.randomUUID())),
    ]),
  )
  let updated = await ConvexLive.next(subscription) // The server pushes the new state.

  await ConvexLive.closeSubscription(subscription)
  await Convex.close(client)
  (initial, mutationResult.value, updated)
}
```

ReScript supports promises and `async`/`await`. The blocking-looking `next`
operation is this client's API choice, not a language limitation. Unlike a
React hook, the command-line program must explicitly consume updates,
unsubscribe, and close the client. The complete example also validates the
initial value, the mutation's `{applied, state}` result, and the pushed update.

## Status

The checked-in manifest records both HTTP and Live as earned capabilities from
the existing shared local and hosted conformance evidence. This README rewrite
does not claim a new verification run.

| Capability | Evidence-backed state |
| --- | --- |
| HTTP query, mutation, and action | Implemented and verified |
| Bearer token set, replace, and clear | Implemented and verified |
| Structured `ConvexError` data and log lines | Implemented and verified |
| Live subscribe, unsubscribe, reconnect, and replay | Implemented and verified |
| Reactive query failure and recovery | Implemented and verified |
| Earned capability badges | HTTP and Live |

## Example

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

## Implementation Notes

This is a transpiled implementation. ReScript 11.1.4 compiles the client to
JavaScript, and Node.js 22.16.0 executes that output. Node's `fetch` handles
HTTP, while the `ws` package handles WebSocket framing and TLS. The Convex
request shapes, response decoding, error classification, subscription state,
reconnects, and delivery limits are implemented in ReScript. The client does
not delegate those decisions to an existing JavaScript Convex client.

| Module | Responsibility |
| --- | --- |
| `client/Convex.res` | The public client: configuration, HTTP calls, subscriptions, shutdown |
| `client/ConvexHttp.res` | `/api/query`, `/api/mutation`, `/api/action` with `format: "json"` |
| `client/ConvexLive.res` | One owner for the Live socket, reconnects, replay, and delivery |
| `client/ConvexProtocol.res` | URL construction and the pinned realtime message profile |
| `client/ConvexJson.res` | Decoding rules, including Convex's integral JSON numbers |
| `client/ConvexError.res` | Function, protocol, transport, closed, and usage failures |
| `client/ConvexNode.res` | The small boundary to Node.js and the `ws` package |

The HTTP side uses Convex's documented JSON endpoints. Responses are limited to
2 MiB and must finish within 10 seconds. JSON numbers are checked before they
become ReScript `int` values, so `1.0` is accepted while fractional, quoted,
non-finite, and overflowing values are rejected.

Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`,
based on source commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`.
One owner serialises every socket operation so a reconnect cannot race a new
subscription. Each subscription keeps at most 16 pending updates and 1 MiB,
preferring newer state when a consumer is slow. Reconnects replay active
queries but suppress an unchanged value the caller already received.

The Docker images are pinned for `linux/amd64`, run as user `65532:65532`, and
retain Node only because it is ReScript's execution target here. Build tools and
package managers are removed from the runtime images. The test-only conformance
adapter is separate from the public client and owns the `debugDisconnect` hook.

## Known Issues

1. Live authentication, WebSocket mutations and actions, optimistic updates,
   journals, and mutation replay are deferred. Mutations and actions currently
   use the HTTP API.
2. Live depends on an inspected internal protocol profile. `TransitionChunk`
   and unknown realtime messages are reported as protocol drift, and
   `TransitionChunk` assembly is not implemented.
3. The delegated `ws` heartbeat and size limits still need a hostile-peer
   Docker proof for a connection that continuously dribbles an incomplete
   frame.
4. HTTP uses Convex's documented `format: "json"`. Int64 values, bytes, special
   floats, negative zero, and other non-JSON Convex encodings are not claimed
   to round-trip losslessly.
