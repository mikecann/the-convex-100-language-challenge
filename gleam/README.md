<img src="logo.png" alt="Lucy, the Gleam language mascot" width="150">
<!-- Logo source: https://github.com/gleam-lang/gleam/blob/main/images/lucy.png -->

# Gleam

[Gleam](https://gleam.run/) is a small, statically typed functional language
that normally runs on the Erlang virtual machine, also known as the BEAM. Its
first public release arrived in 2019 and version 1.0 followed in 2024. It takes
inspiration from languages including Elm, OCaml, Erlang, and Elixir, and its
modern niche is type-safe web services and concurrent systems. Gleam can also
compile to JavaScript, though this client deliberately targets Erlang.

The BEAM gives Gleam lightweight processes and message passing, while Gleam
adds exhaustive pattern matching and a sound type system. Its ecosystem is
smaller than TypeScript's, but it can call Erlang and Elixir libraries on the
same runtime. This client is an educational, unofficial demonstration, not a
production SDK and not supported by Convex.

## Getting Started

Start with [`examples/basics/main.gleam`](examples/basics/main.gleam). It reads
a counter over HTTP, subscribes before mutating it, and then observes the Live
update from `0` to `1`.

From the repository root, run:

```sh
./run verify-example gleam
```

That command builds the pinned Gleam and Erlang environment in Docker, gives
the example a fresh room, and runs the exact source printed later in this
README. Nothing needs to be installed on the host.

## Interesting Parts

### `use` flattens the error-handling staircase

Gleam is famously small — the whole language fits in a weekend — yet it has one
piece of syntax TypeScript lacks: `use`. Each `use x <- result.try(...)` line
means "unwrap this `Result` or return the error right here", so a Convex read
that must survive an HTTP call and two decode steps still reads top to bottom
instead of nesting into a pyramid.

```gleam
pub fn read_count(client: convex.Client, room: String) -> Result(Int, ConvexError) {
  let args = JsonObject([#("room", JsonString(room))])
  // TypeScript: const state = useQuery(api.demo.state, { room })
  use response <- result.try(convex.call(client, convex.Query, "demo:state", args))
  use raw <- result.try(
    json.field(response.value, "count")
    |> result.map_error(fn(_) { convex_error.protocol_error("no count field") }),
  )
  json.integral_int(raw)
  |> result.map_error(fn(_) { convex_error.protocol_error("count is not whole") })
}
```

There is no `try`/`catch` anywhere in this client — the return type
`Result(Int, ConvexError)` is the entire error story.

### A Convex subscription is a typed mailbox

Gleam's home is the BEAM, the Erlang virtual machine built for telephone
switches in the 1980s, where everything is a featherweight process with a
mailbox. Gleam types the mailbox: a `Subject(SubscriptionEvent)` can only ever
receive subscription events. Hand one to `convex.subscribe` and each reactive
update arrives as a plain message you `receive`.

```gleam
let updates = process.new_subject()
let assert Ok(subscription) =
  convex.subscribe(client, "demo:state", args, updates)

// TypeScript: useQuery re-renders the component; here the update is a message.
let assert Ok(SubscriptionEvent(_, LiveValue(first, _logs), acknowledged)) =
  process.receive(updates, 10_000)
// Tell the client's bounded relay this value has left the mailbox.
process.send(acknowledged, Nil)
```

`let assert` pattern-matches and crashes on anything else — exactly right for a
verification program that should stop loudly on a surprise.

### Deleting the failure branch is a compile error

`LiveValue` and `LiveFailure` are two variants of one type, and Gleam's `case`
must be exhaustive. The canonical example's `next_count` cannot quietly ignore
a failed query, because the compiler rejects a `case` that forgets a variant.

```gleam
case event {
  LiveValue(value, _logs) -> count(value)
  // Remove this branch and the program no longer compiles.
  LiveFailure(error) -> {
    report(error.name <> ": " <> error.message)
    panic as "Live reported a failure"
  }
}
```

The unhappy path is not a runtime surprise; it is a branch the compiler makes
you write.

### `set_auth` hands you a whole new client

Every value in Gleam is immutable, including the Convex client. Attaching a
bearer token does not flip a field — it returns a fresh `Client` that shares
the same Live connection, built internally with Gleam's `Client(..client, ...)`
record-update syntax.

```gleam
// TypeScript: client.setAuth(fetchToken) mutates the client in place.
let assert Ok(authed) = convex.set_auth(client, token)
// An empty string hands back an anonymous client again.
let assert Ok(anonymous) = convex.set_auth(authed, "")
```

The original `client` is untouched and still anonymous — no shared mutable
state to reason about.

## Status

| Capability | State | Notes |
| --- | --- | --- |
| HTTP queries, mutations, actions | verified | Shared local and hosted conformance passed from a clean exact-head build. |
| Bearer token lifecycle | verified | `convex.set_auth`, cleared by an empty string; unsafe header values are rejected. |
| Live subscriptions | verified | Deterministic fixtures cover values, errors, delayed removal, close handshakes, reconnect, and bounded delivery. |
| Live reconnect and resend | verified | The session identifier stays stable and active queries are rebuilt after reconnect. |
| Earned capability badges | http, live | Awarded by the shared result evaluator from local and hosted runs at this exact head. |

The implementation is native: Convex-specific HTTP and sync behavior is
written in Gleam rather than delegated to another Convex client.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.gleam -->
```gleam
//// Convex from Gleam: one shared counter, read two different ways.
////
//// The program reads a room's counter over Convex's HTTP API, subscribes to
//// the same query over the reactive `/api/sync` connection, increments the
//// counter once, and shows both surfaces agreeing on the journey from 0 to 1.

import convex
import convex_json.{type Json, JsonObject, JsonString} as json
import convex_live.{
  type SubscriptionEvent, LiveFailure, LiveValue, SubscriptionEvent,
}
import convex_sys
import gleam/erlang/process.{type Subject}
import gleam/io

/// A Live update should arrive in milliseconds. Waiting forever would turn a
/// broken subscription into a hung example instead of a clear failure.
const live_timeout = 10_000

pub fn main() -> Nil {
  // The verifier passes a unique room so concurrent runs cannot share a
  // counter. The default only exists for someone running the image by hand.
  let room = case convex_sys.plain_arguments() {
    [first, ..] -> first
    [] -> "gleam-basic-example"
  }
  // The verifier also supplies the deployment URL; the default points at the
  // repository's local self-hosted backend.
  let deployment = convex_sys.env("CONVEX_URL", "http://127.0.0.1:3210")

  // One client owns both documented HTTP calls and the single sync connection.
  let assert Ok(client) = convex.new(deployment)
  let args = JsonObject([#("room", JsonString(room))])

  // These demo functions are public, so no token is needed. A protected
  // function would call `convex.set_auth` before any HTTP call.

  // Read the durable counter through Convex's documented HTTP API first.
  let assert Ok(initial) = convex.call(client, convex.Query, "demo:state", args)
  expect(count(initial.value) == 0, "expected the room to start at 0")
  io.println("current count: 0")

  // Subscribe before changing anything. Starting Live first means no update
  // can fall into a gap between the initial read and the subscription.
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", args, updates)

  // A Live query first hydrates with its current value. Decode it into the
  // same idiomatic integer the HTTP result produced.
  expect(next_count(updates, subscription) == 0, "expected Live to start at 0")
  io.println("live initial count: 0")

  // Convex records this idempotency key, so retrying this exact write cannot
  // increment the room twice.
  let mutation_args =
    JsonObject([
      #("room", JsonString(room)),
      #("language", JsonString("Gleam")),
      #("runId", JsonString(room <> "-once")),
    ])
  let assert Ok(mutation) =
    convex.call(client, convex.Mutation, "demo:increment", mutation_args)
  expect(
    json.field(mutation.value, "applied") == Ok(json.JsonBool(True)),
    "expected the mutation to be applied",
  )
  let assert Ok(state) = json.field(mutation.value, "state")
  expect(count(state) == 1, "expected the mutation to leave the room at 1")
  io.println("mutation applied: true")
  io.println("mutation count: 1")

  // The sole Live owner decodes the resulting WebSocket transition and relays
  // the changed value in protocol order.
  expect(
    next_count(updates, subscription) == 1,
    "expected Live to report the incremented value",
  )
  io.println("live updated count: 1")

  // Remove the server-side query, then release the socket and the owner.
  let assert Ok(_) = convex.unsubscribe(client, subscription)
  let assert Ok(_) = convex.close(client)

  // Reaching this line proves HTTP and Live agreed on one 0 -> 1 journey.
  io.println("verified count: 0 -> 1")
}

/// Wait for the next value on one subscription.
///
/// Live also reports query failures and transport failures on the same
/// channel. Turning those into an immediate stop keeps the example honest: a
/// failed subscription must never look like a missing update.
fn next_count(updates: Subject(SubscriptionEvent), subscription: String) -> Int {
  case process.receive(updates, live_timeout) {
    Error(_) -> {
      report("Live delivered no update before the timeout")
      panic as "Live delivered no update before the timeout"
    }
    Ok(SubscriptionEvent(id, event, acknowledged)) -> {
      expect(id == subscription, "received an event for another subscription")
      // Tell the bounded relay this value has left our mailbox before it sends
      // another one. A consumer that stops reading therefore cannot grow an
      // unbounded BEAM mailbox behind the client's queue limits.
      process.send(acknowledged, Nil)
      case event {
        LiveValue(value, _logs) -> count(value)
        LiveFailure(error) -> {
          report(error.name <> ": " <> error.message)
          panic as "Live reported a failure"
        }
      }
    }
  }
}

/// Decode the room's counter.
///
/// Convex may spell a whole number as `0` or `0.0`, so both are accepted, and
/// a fraction, a quoted number, or an out-of-range value is rejected rather
/// than rounded into something that looks like agreement.
///
/// This is public only so the regression test can exercise the exact function
/// the example uses, rather than a second copy of it.
pub fn count(value: Json) -> Int {
  case json.field(value, "count") {
    Error(_) -> {
      report("Convex value has no count field")
      panic as "Convex value has no count field"
    }
    Ok(raw) ->
      case json.integral_int(raw) {
        Ok(number) -> number
        Error(_) -> {
          report("count is not a whole number in range")
          panic as "count is not a whole number in range"
        }
      }
  }
}

/// Stop on an unexpected value. Compilation is not evidence, so every step the
/// example demonstrates has to be checked at runtime.
fn expect(condition: Bool, message: String) -> Nil {
  case condition {
    True -> Nil
    False -> {
      report(message)
      panic as "unexpected Convex value"
    }
  }
}

/// Diagnostics go to standard error, because standard output is the shared
/// transcript every language in this repository has to match exactly.
fn report(message: String) -> Nil {
  convex_sys.stderr_write(message)
}
```
<!-- END GENERATED EXAMPLE -->
## Implementation Notes

This is an Erlang-target Gleam 1.9.1 program running as BEAM bytecode. The
public API in [`client/convex.gleam`](client/convex.gleam) returns immutable
client values and typed `Result` values. Gleam generally uses `Result` rather
than exceptions for recoverable failure. The canonical example uses
`let assert` intentionally because any unexpected value should stop that
verification program immediately.

JSON encoding and decoding, HTTP/1.1, the WebSocket handshake and framing, and
all Convex behavior are implemented in Gleam. The small
[`client/convex_ffi.erl`](client/convex_ffi.erl) module exposes generic
Erlang/OTP sockets, TLS, cryptography, clocks, and bounded binary operations.
That foreign code is outside Gleam's type checker, which is why the boundary is
kept narrow and covered by language-local tests.

Live uses three kinds of lightweight BEAM process: one owner serializes all
subscription state, one process owns the current socket, and one relay per
subscription delivers bounded events. A caller acknowledges each event before
the relay advances. This keeps a slow consumer from quietly growing an
unbounded mailbox and makes `unsubscribe` a real delivery barrier.

The Docker build pins the compiler, package versions, builder image, and
minimal runtime image. It also creates separate test and production projections
because Gleam has no conditional compilation. The final runtime contains BEAM
bytecode and the required Erlang runtime pieces, but no Gleam compiler or
package manager.

## Known Issues

1. Live uses Convex's undocumented `/api/sync` interface pinned to the profile
   in `manifest.yaml`. It is verified here, but it is not a supported public
   protocol and may drift.
2. Live authentication, mutations and actions over WebSocket, and tagged Convex
   values are not implemented. Mutations and actions do work through the
   documented HTTP API.
3. `TransitionChunk` assembly is deferred. Receiving one is treated as a
   protocol error and causes a reconnect.
4. The client allows at most eight active subscriptions. Queues, controller
   output, HTTP bodies, command lines, and WebSocket messages also have explicit
   byte and event limits so a stalled reader cannot consume memory without
   bound.
5. The checked-in final-adapter pressure probe is marked for a fresh rerun in
   the manifest. The existing HTTP and Live capability awards remain the
   evidence-backed status recorded by the shared evaluator.
