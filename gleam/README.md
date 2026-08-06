# Convex from Gleam

This is a Convex client written in Gleam. It talks to a Convex deployment two
ways: the documented HTTP API, which is one POST per function call, and the
reactive `/api/sync` WebSocket, which pushes a new value whenever a subscribed
query's result changes.

Almost all of it is Gleam. JSON encoding and decoding, HTTP/1.1, the WebSocket
handshake, WebSocket frame codec, and every Convex-specific decision live in
`client/`. Erlang/OTP supplies only what Gleam cannot reach directly: sockets,
TLS, cryptography, and a few bounded binary and stream primitives. Those
generic helpers live in `client/convex_ffi.erl`, which contains no Convex logic
at all.

It is educational and unofficial. It is not a Convex SDK, it is not supported
by Convex, and it should not be used in production. It exists to answer one
question honestly: can this language talk to Convex, and how much of the
protocol can it carry?

## Start here

[`examples/basics/main.gleam`](examples/basics/main.gleam) is the canonical
example, and the block below is generated from that exact file. It walks one
room's shared counter from `0` to `1`:

1. read the counter over HTTP,
2. subscribe to the same query over Live and receive its current value,
3. increment the counter with an idempotency key,
4. receive the new value over Live,
5. print a single verification line once HTTP and Live agree.

The source and both minimal linux/amd64 runtime images have passed their first
Docker build. The exact example has completed this `0 -> 1` journey against the
approved local backend, and the language-local codec, Live fixture, adapter,
and example tests pass. It has not passed the shared local and hosted
black-box conformance runs, so no capability has been earned or claimed.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP queries, mutations, actions | implemented, Docker-tested | The exact example's query and mutation passed against the approved local backend; shared conformance is still pending. |
| Bearer token lifecycle | implemented, Docker-tested | `convex.set_auth`, cleared by an empty string; unsafe header values are rejected. |
| Live subscriptions | implemented, Docker-tested | The exact example and deterministic fixture exercise initial and later values, errors, remove, reconnect, and bounded delivery. |
| Live reconnect and resend | implemented, Docker-tested | The session identifier is stable; the fixture proves five reconnects rebuild and rehydrate the active query set. |
| Earned capability badges | none | Badges come only from shared local and hosted evidence runs. |

## The canonical example

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

## Docker verification

Everything is built and run inside Docker; nothing is installed on the host.

```sh
./run test gleam           # format check, compilation, language-local tests
./run verify-example gleam # the example above, against a unique room
./run verify gleam         # example plus shared conformance, local backend
./run verify-hosted gleam  # the same, against the hosted drift target
./run verify-all gleam     # both deployment profiles from one built image

# On an approved Linux Docker host, isolate the real final adapter under its
# 128 MiB cgroup and stop its TCP output reader near the 8/9 MiB boundaries.
REPO_ROOT=$PWD gleam/client/tests/conformance/final_adapter_pressure_probe.sh
```

`test` proves the source compiles and that the codec, fixture-server, and
example-decoding tests pass inside the container. `verify-example` proves the
exact program printed above runs against a real deployment and produces the
shared transcript. `verify` adds the shared black-box conformance suite, and
`verify-hosted` repeats it against the drift target so protocol changes are
caught. Compilation is not example evidence, and example success is not
conformance.

The dedicated pressure probe builds the exact final `runtime` image plus two
test-only sibling images. It keeps the fixture and controller out of the
adapter's cgroup, runs `/usr/local/bin/convex-adapter` through its unchanged
default entrypoint, and measures only that process tree. A first process proves
a legal NDJSON command above 8 MiB but below the 9 MiB limit is rejected as an
unknown operation and the same parser recovers. Two fresh processes receive a
declared WebSocket frame above the conservative 7 MiB client limit but below 8
MiB, report that bounded protocol error, and reconnect for legal large values.
One resumes a physically stalled reader; the other remains stopped until the
one-second send deadline closes it. The fresh Bruce Docker run measured peaks
of 113,004,544, 107,626,496, and 118,751,232 bytes respectively, with no OOM
and zero retained output reservations at every shutdown.
The probe sets the adapter-only `ADAPTER_TEST_SEND_BUFFER` hook to 4 KiB so
kernel autotuning cannot turn the stopped reader into a false non-blocking
pass; public client connections never use the accepting-socket code path.

## How it fits together

| Module | Responsibility |
| --- | --- |
| `client/convex.gleam` | Public API: HTTP calls, auth, subscribe, close. |
| `client/convex_live.gleam` | The single sync owner: query set, transitions, reconnects, delivery. |
| `client/convex_ws.gleam` | RFC 6455 handshake and frame codec. |
| `client/convex_http.gleam` | HTTP/1.1 request and response, including chunked bodies. |
| `client/convex_json.gleam` | JSON parser and encoder, including Convex's integer spellings. |
| `client/convex_error.gleam` | The three failures a caller must tell apart. |
| `client/convex_sys.gleam` | Typed view of the OTP primitives in `convex_ffi.erl`. |

Three kinds of process cooperate for Live:

* **The owner** holds every piece of sync state. Query-set versions, each
  subscription's last value, and the reconnect schedule are only ever changed
  here, so a version cannot be written twice or skipped.
* **A connection process** owns one socket. It connects, upgrades, forwards raw
  bytes to the owner, and writes the frames the owner hands it. Frame decoding
  stays in the owner, which is why a read timeout part-way through a frame is
  harmless: the parser state is not in the process that timed out.
* **A relay per subscription** carries one event at a time, asks the owner for
  permission immediately before delivery, and waits for the consumer to
  acknowledge it before advancing. That makes unsubscribe and same-identifier
  replacement real barriers and prevents a stopped consumer from growing an
  unbounded BEAM mailbox.

## Conformance and protocol notes

The test-only executable under `client/tests/conformance/` implements NDJSON
adapter protocol v1. It reserves stdout for protocol events, sends diagnostics
to stderr, supports both stdin/stdout and the `ADAPTER_LISTEN` TCP mode, and
calls the real client for every operation. It also implements the adapter-only
`debugDisconnect` command so the shared controller can prove five real
reconnects; that command is declared in `manifest.yaml` and is not part of the
educational client API.

The sync profile is pinned in `manifest.yaml`. `/api/sync` is not a documented
or supported Convex interface, and nothing here should be read as implying it
is stable.

HTTP reads stream into an 8 MiB response bound. Convex error envelopes remain
structured function errors even when an HTTP intermediary changes the status;
a non-success status carrying a success-shaped envelope is protocol drift.
Live permits at most eight active subscriptions and 8 MiB of retained encoded
paths and arguments. The connection keeps one session identifier across
reconnects, limits each WebSocket message to 7 MiB, and abandons a partial
message if it cannot finish within three seconds.

## Limitations

* The shared local and hosted black-box conformance runs have not yet happened.
  That is why the manifest keeps its capability list empty despite the Docker
  and approved-local-backend checks described above.
* `client/manifest.toml` records the exact Hex package versions and content
  hashes used by the Docker build. Both the Gleam builder and Alpine runtime
  bases are digest-pinned.
* Gleam has no conditional compilation, so the relay pause point the
  deterministic tests use is an inert option rather than test-only code
  excluded from the build. `convex.new` never supplies one.
* Live authentication, WebSocket mutations and actions, and tagged Convex
  values are deferred.
* `TransitionChunk` assembly is deferred; receiving one is treated as protocol
  drift and reconnects.
* Delivery is bounded: at most eight active subscriptions; 16 newest
  undelivered events and 8 MiB of conservatively charged storage per
  subscription; one global 16-event and 12 MiB encoded output budget in the
  adapter; a 9 MiB NDJSON command limit; and a 7 MiB WebSocket message limit.
