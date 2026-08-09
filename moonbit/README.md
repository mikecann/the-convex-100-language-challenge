# Convex from MoonBit

This is a small Convex client written in MoonBit and compiled with MoonBit's
native backend. It talks to a Convex deployment two ways: it calls queries,
mutations, and actions over Convex's documented HTTP function endpoints, and it
subscribes to reactive queries over the Convex sync WebSocket, so a change made
by anyone shows up without polling.

It is educational and unofficial. It is not a Convex SDK, it is not published to
any registry, and it is not supported. It exists to answer one question - can
this language hold a useful Convex client? - and to show the answer as readable
source.

## Start here

Read [`examples/basics/main.mbt`](examples/basics/main.mbt). It takes one room
from `0` to `1` and makes every surface agree about it:

1. read the count over HTTP,
2. open a Live subscription **before** changing anything, so the update cannot
   be missed,
3. apply a mutation with an idempotency key,
4. wait for the reactive update the mutation caused,
5. print the verified journey only once all of them agree.

If any step disagrees, the example fails instead of printing a tidy transcript.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Verified locally and hosted | `POST /api/{query,mutation,action}` with the `format=json` encoding. |
| Structured function errors | Verified locally and hosted | Convex `errorData` is forwarded untouched, separately from protocol and transport failures. |
| Bearer token auth | Verified locally and hosted | Sent per request, so clearing it takes effect immediately. |
| TLS | Verified locally and hosted | Certificate chain and hostname verified against the system trust store. |
| Live subscriptions | Verified locally and hosted | Sync WebSocket, one owner, reconnect with rehydration suppression. |
| Live auth, optimistic updates, WebSocket mutations and actions | Not implemented | Deferred; see the limitations below. |
| Tagged Convex value types | Not implemented | The JSON-safe subset only. |

The root-owned shared result evaluator passed against local and hosted
deployments, earning HTTP and Live.

## The canonical example

This block is generated from the runnable source file, so the repository, the
README, and the website always show the same code.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.mbt -->
```moonbit
// Convex from MoonBit: the shared counter demonstration.
//
// One room goes from 0 to 1 and every surface agrees about it. The example
// reads the count over Convex's HTTP function endpoint, opens a Live
// subscription over the sync WebSocket, applies a mutation, and then waits for
// the reactive update that the mutation caused. If any of those disagree the
// program fails instead of printing a happy transcript.

///|
/// Build the shared demo's argument object.
///
/// `demo:state` only needs the room. `demo:increment` also takes the language
/// label it records and the idempotency key that makes a retry safe, so those
/// are optional here rather than being two nearly identical builders.
fn room_args(room : String, language? : String, run_id? : String) -> Json {
  let members : Map[String, Json] = Map::new()
  members["room"] = Json::string(room)
  match language {
    Some(value) => members["language"] = Json::string(value)
    None => ()
  }
  match run_id {
    Some(value) => members["runId"] = Json::string(value)
    None => ()
  }
  Json::object(members)
}

///|
/// A random idempotency key for this run.
///
/// `demo:increment` refuses to apply the same `runId` twice, so a retry after a
/// timeout cannot double-count. Falling back to a fixed key would silently turn
/// the mutation into a no-op on a second run against the same room, which is
/// why the failure is loud.
fn fresh_run_id() -> String raise {
  guard @env.rand(16) is Some(raw) else {
    fail("this platform provides no entropy source for an idempotency key")
  }
  let digits = "0123456789abcdef"
  let out = StringBuilder::StringBuilder(size_hint=32)
  for index = 0; index < raw.length(); index = index + 1 {
    let byte = raw[index].to_int()
    out.write_char(digits.unsafe_char_at((byte >> 4) & 0x0f))
    out.write_char(digits.unsafe_char_at(byte & 0x0f))
  }
  out.to_string()
}

///|
/// Read `count` out of a `demo:state` value.
///
/// `@convex.integer_value` accepts an integral number in either `0` or `0.0`
/// form, which Convex's JSON encoding may use interchangeably, and rejects
/// fractional, quoted, non-finite, or overflowing input. Wrapping it here keeps
/// the failure message pointed at the operation that produced the value.
fn count_of(value : Json, what : String) -> Int64 raise {
  @convex.integer_value(
    @convex.required_field(value, "count", what),
    what + " count",
  )
}

///|
/// Wait for the next Live value, refusing to treat a reactive failure as data.
///
/// A Live subscription can deliver a structured failure instead of a value -
/// the query threw, the socket dropped, the server drifted - and a demo that
/// silently retried past one of those would be claiming a reactive guarantee it
/// had not observed.
async fn next_live_count(
  subscription : @convex.Subscription,
  what : String,
) -> Int64 {
  guard subscription.next(timeout_ms=20000) is Some(update) else {
    fail(what + " did not arrive before the deadline")
  }
  match update.error {
    Some(info) =>
      fail(what + " failed: " + info.kind.to_string() + ": " + info.message)
    None => ()
  }
  guard update.value is Some(value) else { fail(what + " carried no value") }
  count_of(value, what)
}

///|
async fn run(url : String, room : String) -> Unit {
  @convex.with_client(url, client => {
    // Read the current count through Convex's documented HTTP endpoint. This
    // is a plain request/response call: no socket, no subscription.
    let current = count_of(
      client.query("demo:state", room_args(room)).value,
      "current",
    )

    // The demonstration is only meaningful from a room nobody has touched.
    guard current == 0L else {
      fail("expected a fresh room, but it already had a count")
    }
    println("current count: " + current.to_string())

    // Subscribe before mutating. Convex delivers the value that is current when
    // the subscription is established and then every value after it, so opening
    // the subscription first is what guarantees the update caused by the
    // mutation below cannot be missed.
    let subscription = client.subscribe("demo:state", room_args(room))

    // The first Live value is the room as it is now, and it has to agree with
    // what HTTP just reported.
    let initial = next_live_count(subscription, "initial Live value")
    guard initial == current else {
      fail("the initial Live value disagreed with the HTTP query")
    }
    println("live initial count: " + initial.to_string())

    // Apply the mutation. The idempotency key is what makes this safe to retry:
    // Convex records it and answers a repeat with `applied: false`.
    let mutation = client.mutation(
        "demo:increment",
        room_args(room, language="MoonBit", run_id=fresh_run_id()),
      ).value
    guard @convex.json_field(mutation, "applied") is Some(True) else {
      fail("the mutation was not applied")
    }
    let mutated = count_of(
      @convex.required_field(mutation, "state", "mutation"),
      "mutation",
    )
    guard mutated == current + 1L else {
      fail("the mutation returned an unexpected count")
    }
    println("mutation applied: true")
    println("mutation count: " + mutated.to_string())

    // The mutation changed data the subscription is watching, so Convex pushes
    // the new value over the same socket. This is the reactive half of the
    // demonstration: nothing polled for it.
    let updated = next_live_count(subscription, "updated Live value")
    guard updated == mutated else {
      fail("the Live update disagreed with the mutation")
    }
    println("live updated count: " + updated.to_string())

    // Retire the subscription now that the proof is complete. Closing the
    // client would do it too, but doing it explicitly is the honest shape for
    // a long-lived program.
    client.unsubscribe(subscription)

    // Only now, with every operation agreeing, is the journey verified.
    println(
      "verified count: " + current.to_string() + " -> " + updated.to_string(),
    )
  })
}

///|
async fn main {
  // Docker supplies the deployment; the verifier supplies a room nobody else is
  // using as the first argument.
  guard @env.get_env_var("CONVEX_URL") is Some(url) else {
    @stdio.stderr.write("MoonBit example failed: CONVEX_URL is required\n") catch {
      _ => ()
    }
    panic()
  }
  let arguments = @env.args()
  let room = if arguments.length() > 1 {
    arguments[1]
  } else {
    // A friendly default for someone running the image by hand.
    match @env.get_env_var("EXAMPLE_ROOM") {
      Some(value) => value
      None => "moonbit-example"
    }
  }
  // A whole-run deadline turns a stalled deployment into a reported failure
  // instead of a container that never exits.
  @async.with_timeout(60000, () => run(url, room)) catch {
    error => {
      @stdio.stderr.write("MoonBit example failed: \{error}\n") catch {
        _ => ()
      }
      panic()
    }
  }
}
```
<!-- END GENERATED EXAMPLE -->

## Verifying it in Docker

Everything builds and runs inside Docker; nothing is installed on the host.

```sh
./run test moonbit
```

Formats, type checks, and runs the MoonBit test suite, then builds the
conformance adapter and the canonical example. The suite includes hostile
fixtures: HTTP peers that answer with the wrong status, an oversized body,
invalid UTF-8, and a truncated envelope; WebSocket peers that answer the
handshake with the wrong `Sec-WebSocket-Accept`, send a binary frame, send a
message larger than the assembly limit, stop dead halfway through a frame, and
never stop talking at all. A recording HTTP peer reads the raw request to prove
that a configured token reaches the wire byte for byte as
`Authorization: Bearer <token>` and that clearing it removes the header rather
than blanking it. The same stage proves the real adapter binary stays far below
the shared 128 MiB limit while a controller stops reading and near-maximum
values keep arriving.

Peer-side checks are recorded and asserted after the client finishes, not
asserted inside the fixture. A scripted peer has to tolerate the client tearing
its connection down, and that tolerance would otherwise swallow a failed
assertion, leaving a test that cannot fail.

```sh
./run verify-example moonbit
```

Builds the minimal example image and runs the exact
`/usr/local/bin/convex-example` entrypoint against a unique room on the approved
local deployment, comparing stdout to the shared expected transcript.

```sh
./run verify moonbit
```

Adds the final-image policy checks and the shared black-box conformance run:
the same NDJSON adapter protocol every other language implements, driven by the
shared controller over TCP.

```sh
./run verify-hosted moonbit
./run verify-all moonbit
```

Repeat the same checks against the dedicated hosted drift target, and run both
deployment profiles from one build.

## Conformance and protocol notes

The conformance executable under
[`client/tests/conformance/`](client/tests/conformance/) is test infrastructure,
not client code. It implements NDJSON adapter protocol v1, reserves stdout for
protocol events, sends diagnostics to stderr, and calls the real client for
every operation. It serves stdin/stdout by default and a single controller
connection over TCP when `ADAPTER_LISTEN` is set.

- **One writer.** Command handlers and subscription relays produce events
  concurrently; exactly one task writes them. The queue is bounded in bytes as
  well as in count, so a controller that stops reading applies backpressure
  instead of growing the process.
- **No stale events.** Unsubscribing, or re-using a subscription id, invalidates
  the old relay before the acknowledgement is even queued, and the writer checks
  the subscription generation again before a line reaches the socket. A relay
  paused anywhere between those points cannot publish across the
  acknowledgement.
- **Bounded input.** Commands are parsed incrementally. A line longer than
  4 MiB is refused with a structured error and skipped without being retained,
  and the stream resynchronises on the next newline.
- **`debugDisconnect`** is declared in `manifest.yaml` under
  `adapter.adapterOnlyCommands`. It is compiled into debug builds only. The
  canonical example ships from a release build, and the Docker build proves the
  hook is genuinely absent there by asserting that a release build of the
  adapter fails to compile.

The sync protocol is not a published, versioned API. `manifest.yaml` pins the
upstream revision this encoding was read from under `syncProfile`. Do not read
this client as evidence that the protocol is stable or officially supported.

Live behaviour worth knowing:

- One worker owns the socket, the query-set version counter, and the reconnect
  schedule. Everything else sends it commands and waits for an acknowledgement.
- Every connection starts from query-set version zero and resends the active
  `Add` operations.
- A transition whose start version does not chain onto the local version means
  an update was lost, so the connection is abandoned and rebuilt rather than
  applied from a guess.
- After a reconnect, a replayed value identical to the one the consumer already
  holds is suppressed; a replayed value after a failure is always delivered.
- `connectionCount`, `lastCloseReason`, and `maxObservedTimestamp` are carried
  into each `Connect`. Only a connection that completed its handshake is
  numbered, so a refused attempt does not tell the server about a connection it
  never saw. A close reason can quote text the peer chose, so an implausibly
  long one is replaced rather than reflected back at the deployment.
- Reconnect backoff resets after a successful handshake or a valid server
  transition, so a healthy connection does not inherit a delay an earlier bad
  run earned.
- Writes, connects, command handoff, and command acknowledgements all run under
  absolute deadlines, so an idle, chatty, or half-frame-stalled peer cannot make
  `unsubscribe` or `close` hang. The tests assert those bounds rather than
  trusting the fixture peer to close politely.

## Limitations and deferred behaviour

- Live authentication is deferred. `setAuth` affects HTTP calls only.
- Optimistic updates, WebSocket mutations, and WebSocket actions are deferred.
  Mutations and actions always use the HTTP endpoints.
- Values are the JSON-safe subset requested with `format=json`. Tagged Convex
  value types are deferred.
- `TransitionChunk` assembly is deferred and treated as protocol drift that
  reconnects.
- Each subscription retains at most 16 updates and at most 1 Mi string units of
  serialised payload, and the process retains at most 8 Mi across all
  subscriptions. A MoonBit string unit is a UTF-16 code unit, so those ceilings
  are 2 MiB and 16 MiB of memory in the worst case; measuring real UTF-8 bytes
  would mean encoding every value twice, so the unit is stated rather than
  hidden. The oldest update is dropped first, and the drop is counted rather
  than hidden. A single update too large for the budget is replaced by a
  structured refusal, so a consumer never waits forever for a value that was
  silently discarded.
- A Live message larger than 2 MiB, or an HTTP response body larger than 2 MiB,
  is refused rather than assembled.
- A read that stops part way through a WebSocket frame abandons the connection.
  The parser is never resumed from a state it cannot trust, and it never
  restarts at a false frame boundary.
- Ordinary transport - sockets, TLS, HTTP/1.1, and WebSocket framing - comes
  from `moonbitlang/async`, which is a normal library for this language. It is
  named in `manifest.yaml`. No Convex client in any other language is involved.
- MoonBit source has no syntax highlighting in the shared website generator
  yet, so the block above renders as plain text. That is a shared-infrastructure
  change, not a language one.
