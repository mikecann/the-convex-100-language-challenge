# Convex from Awk

This is a Convex client written in GNU Awk. It reads a counter over Convex's
documented JSON HTTP API, subscribes to the same query over a WebSocket, and
watches its own increment arrive on that subscription.

Awk has no sockets, no TLS, and no binary framing, so the demonstration adds one
small compiled gawk extension, `client/convexext.c`, loaded in process with
`@load`. It provides exactly what an ordinary language runtime would already
offer: deadline-bounded TCP and TLS sockets, a monotonic clock, SHA-1, base64,
randomness, unsigned 64-bit timestamp comparison, and RFC6455 frame encode and
decode. Everything that makes it a *Convex* client — the HTTP envelope, the JSON
reader and writer, the pinned sync profile, the single-owner Live state machine
with its reconnect and replay, the NDJSON test adapter, and the example — is
Awk. Nothing shells out to curl, websocat, Node, or Python; that would make this
a bridge rather than a native client.

It is an educational demonstration, not an official Convex SDK, and not a
package to depend on. Convex's realtime sync protocol is not a documented,
stable third-party API, so the profile it implements is pinned to one inspected
revision and recorded in `manifest.yaml`.

## Start here

[`examples/basics/main.awk`](examples/basics/main.awk) is the canonical example.
It queries `demo:state` over HTTP, subscribes before mutating so no update can
be missed, increments the counter once with a random idempotency key, and then
proves the same `0 -> 1` change arrived over Live. Every value is checked, so
the example fails rather than printing a transcript it did not earn.

## What works

The shared black-box controller passed against local and hosted deployments,
earning HTTP and Live.

| Capability | State | Notes |
| --- | --- | --- |
| Builds in Docker | `./run test awk` passes | gawk 5.3.2 and the extension build from source inside Docker; the runtime and example images build and pass their in-image policy probes. |
| HTTP query, mutation, action | Implemented, local tests pass | Verified by shared local and hosted conformance |
| Live subscriptions | Implemented, local tests pass | Verified by shared local and hosted conformance |
| Language-local tests | Passing | Seven suites drive the real socket path against an Awk fixture peer inside the `test` image. |
| Earned capability badges | HTTP and Live | Shared local and hosted conformance passed. |

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.awk -->
```awk
# Convex from Awk: the shared counter journey.
#
# The program reads a room's counter over Convex's documented HTTP API, starts
# a Live subscription, increments the counter once, and proves that the Live
# subscription reported the same change without polling.
#
# Run it with:  CONVEX_URL=https://<deployment>.convex.cloud convex-example <room>

@include "convex.awk"

BEGIN {
    # The example test includes this file to check its decoding rules directly.
    # Running the program normally is the default; nothing else changes.
    if (EXAMPLE_LIBRARY_ONLY != 1) {
        exit example_main()
    }
}

# Convex returns the room state as a JSON object. This narrows it to the
# non-negative integer the output contract needs, and refuses anything else.
function example_count(value, operation,    mark, root, node, literal, count) {
    mark = cx_json_mark()
    root = cx_json_parse(value, 0)
    if (root < 0 || cx_json_type(root) != "object") {
        cx_json_release(mark)
        return example_fail(operation " did not return a Convex object")
    }
    node = cx_json_find(root, "count")
    if (node < 0 || cx_json_type(node) != "number") {
        cx_json_release(mark)
        return example_fail(operation " returned no count")
    }
    literal = cx_json_text(node)
    cx_json_release(mark)
    # Convex JSON may encode an integral number as 0 or as 0.0. Both are
    # accepted; fractional, non-finite, and out-of-range values are not.
    if (!convex_integral(literal) || literal + 0 < 0) {
        return example_fail(operation " returned a non-integral or negative count")
    }
    count = literal + 0
    return count
}

# One failure channel. Diagnostics belong on stderr so that stdout stays the
# exact shared transcript.
function example_fail(message) {
    EXAMPLE_FAILED = 1
    print "Awk example failed: " message > "/dev/stderr"
    fflush("/dev/stderr")
    return -1
}

# Wait for the next value this subscription publishes, and surface a reactive
# query failure as a failure rather than as a missing value.
function example_next(operation, update) {
    if (!convex_wait_update("counter", 15000, update)) {
        return example_fail(operation ": " convex_error_message())
    }
    if (update["errorName"] != "") {
        return example_fail(operation ": " update["errorMessage"])
    }
    return example_count(update["value"], operation)
}

function example_main(    url, room, arguments, response, current, initial, updated, expected, mutation, mark, root, node, applied, state, state_count) {
    url = ENVIRON["CONVEX_URL"]
    if (url == "") {
        return example_fail("CONVEX_URL is required")
    }
    # The verifier passes a unique room as the first argument; the environment
    # variable and the literal default only make a hand run convenient.
    room = ARGV[1]
    if (room == "") {
        room = ENVIRON["EXAMPLE_ROOM"]
    }
    if (room == "") {
        room = "awk-example"
    }

    # Configure one native Awk client for the deployment the container names.
    if (!convex_open(url, "awk-0.1.0")) {
        return example_fail(convex_error_message())
    }
    arguments = "{\"room\":" convex_quote(room) "}"

    # Read the current value through Convex's documented HTTP query endpoint.
    if (!convex_query("demo:state", arguments, response)) {
        return example_shutdown(example_fail("query: " convex_error_message()))
    }
    current = example_count(response["value"], "current query")
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    printf "current count: %d\n", current

    # Start Live before mutating. Subscribing first is what makes the update
    # below an observation rather than a race.
    if (!convex_subscribe("counter", "demo:state", arguments)) {
        return example_shutdown(example_fail("subscribe: " convex_error_message()))
    }

    # The first Live value hydrates the same state the HTTP query returned.
    initial = example_next("initial Live value", response)
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    if (initial != current) {
        return example_shutdown(example_fail("the initial Live count disagreed with HTTP"))
    }
    printf "live initial count: %d\n", initial

    # runId is the mutation's idempotency key. Convex records it, so a repeated
    # run of the same key returns the previous result instead of incrementing
    # twice. A fresh random key means this run really applies its increment.
    mutation = "{\"room\":" convex_quote(room) ",\"language\":\"awk\",\"runId\":" \
        convex_quote(convex_random_hex(16)) "}"
    if (!convex_mutation("demo:increment", mutation, response)) {
        return example_shutdown(example_fail("mutation: " convex_error_message()))
    }

    mark = cx_json_mark()
    root = cx_json_parse(response["value"], 0)
    node = (root < 0) ? -1 : cx_json_find(root, "applied")
    applied = (node >= 0) ? cx_json_type(node) : ""
    node = (root < 0) ? -1 : cx_json_find(root, "state")
    state = (node >= 0) ? cx_json_encode(node) : ""
    cx_json_release(mark)
    if (applied != "true") {
        return example_shutdown(example_fail("the mutation was not applied"))
    }

    expected = current + 1
    state_count = example_count(state, "mutation")
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    if (state_count != expected) {
        return example_shutdown(example_fail("the mutation returned an unexpected count"))
    }
    print "mutation applied: true"
    printf "mutation count: %d\n", state_count

    # Receive the same change over Live, without polling HTTP again.
    updated = example_next("updated Live value", response)
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    if (updated != expected) {
        return example_shutdown(example_fail("the updated Live count disagreed with the mutation"))
    }
    printf "live updated count: %d\n", updated

    # Every operation agreed before this proof line is printed.
    printf "verified count: %d -> %d\n", current, updated
    return example_shutdown(0)
}

# Close the Live socket and drop every subscription within a bounded budget, so
# a stalled deployment cannot keep the example running.
function example_shutdown(status) {
    convex_close_live(2000)
    fflush("/dev/stdout")
    return status < 0 ? 1 : status
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test awk             # builds gawk and the extension from source, runs every local suite
./run verify-example awk   # runs the exact example above against a unique room
./run verify awk           # adds shared black-box conformance against the local backend
./run verify-hosted awk    # repeats both against the hosted drift target
```

`./run test awk` proves that the pinned gawk source builds, that the extension
compiles and loads, that every Awk source parses, and that the local suites
pass. It proves nothing about a real deployment. `./run verify-example awk` runs
the canonical example itself against Convex and compares its stdout with the
shared transcript. `./run verify awk` adds the shared controller, which is the
only thing that can award HTTP or Live.

## How it is put together

| File | Role |
| --- | --- |
| `client/convex.awk` | The client: JSON, the HTTP envelope, the Live owner and state machine, the bounded delivery queue. |
| `client/convexext.c` | The gawk extension: sockets, TLS, deadlines, digests, randomness, RFC6455 framing. |
| `client/Makefile` | Builds the runtime extension and a test build that adds a TLS server hook. |
| `client/tests/` | Language-local suites and the fixture peer they run against. |
| `client/tests/conformance/adapter.awk` | Test-only NDJSON adapter v1 for the shared controller. |
| `examples/basics/main.awk` | The canonical example, projected into this README verbatim. |

### Live

One worker owns the WebSocket. Awk runs a single thread, so the adapter loop
*is* that owner: it alternates between pumping the socket and taking one
controller command, and every step is bounded by a monotonic deadline from the
extension. Subscriptions never touch the socket themselves; they queue
commands for the owner and read from a bounded delivery queue.

- Each connection sends `Connect` with the session id, connection count, last
  close reason, and `maxObservedTimestamp`, then replays the whole active query
  set as `Add` modifications. That is what restores subscriptions after a drop.
- A `Transition` is validated in full — state versions, timestamp ordering, and
  every modification — before any part of it is published.
- A repeated identical value is suppressed, so a reconnect's rehydration does
  not masquerade as a new update.
- `QueryFailed` becomes a typed `FunctionError` event that leaves the
  subscription active; transport and protocol faults become `TransportError` and
  `ProtocolError` events, and the same subscription still delivers later values
  after the reconnect.
- Unsubscribe and same-id replacement invalidate the old relay and purge its
  queued deliveries *before* returning, so no stale value can cross either
  acknowledgement.
- Sixty-four bit sync timestamps are compared in the extension, because an Awk
  double cannot hold a nanosecond timestamp without losing its low bits.
- Partial WebSocket frames retain their parser state across short owner time
  slices, but an absolute 5 second frame deadline prevents endless dribbling.

### Buffering

The client owns its update queue, so both bounds are explicit: the newest 8
deliveries within 4 MiB, and the newest 8 encoded adapter events within 4 MiB
including one in-flight write. Subscription events are droppable and are dropped
oldest first; responses are not, and if only responses remain when the budget is
crossed the adapter fails loudly instead of growing. A single delivery larger
than the whole budget is refused rather than emptying the queue for it. These
bounds are far below the shared 128 MiB adapter limit because Awk holds whole
values in memory.

Active subscription definitions are separately capped at 64 entries and 768
KiB of charged state. That leaves headroom when every Add is serialized into
the single replay frame sent after a reconnect.

### The adapter

`client/tests/conformance/adapter.awk` implements NDJSON adapter protocol v1. It
is test infrastructure, not public client code: it reserves stdout for protocol
events, sends diagnostics to stderr, works over stdin/stdout or the
`ADAPTER_LISTEN` TCP socket, and calls the real client for every operation. It
implements the adapter-only `debugDisconnect` command, which is declared in
`manifest.yaml` and deliberately absent from the educational client API.

Optional members are omitted rather than serialized as null, because the shared
controller validates every line against `_shared/schemas/adapter.schema.json`.
`client/tests/adapter_test.awk` asserts the exact bytes of every event shape and
then drives the real adapter end to end over its NDJSON stream.

## Tests

Every suite runs inside the `test` image. They use the same extension the
runtime images ship, except the TLS suite, which needs the test build's TLS
server hook.

| Suite | What it covers |
| --- | --- |
| `ext_test.awk` | Clock, digests, randomness, UTF-8 validation, uint64 timestamps, and RFC6455 framing over a real loopback pair, including 64-bit lengths, control frames, masking rules in both directions, and a partly delivered message that survives two read timeouts. |
| `json_test.awk` | Round trips, verbatim number literals, escapes and surrogate pairs, every rejection, and URL parsing. |
| `http_test.awk` | The Convex envelope, `logLines`, structured errors, chunked and close-framed bodies, the exact `Authorization: Bearer` header, and a stalled peer that only the client's own deadline can end. |
| `live_test.awk` | Add and Remove, initial and external values, suppression, `QueryFailed` then recovery, fragmentation, the unsubscribe barrier, same-id replacement, five real `debugDisconnect` reconnects with Add replay, stale-generation retirement, transport and protocol recovery, connection bookkeeping, and bounded close. |
| `adapter_test.awk` | Exact event shapes, both queue bounds, and a full NDJSON session against the fixture. |
| `tls_test.awk` | A real TLS handshake against a certificate authority created in the build, plus the rejection of a certificate issued for another name. |
| `examples/basics/main_test.awk` | The example's own integral-count rules, its behaviour without `CONVEX_URL`, and a full `0 -> 1` journey against a fixture deployment. |

The fixture in `client/tests/fixture.awk` is an independent Awk implementation of
the other half of each exchange: HTTP responder, scripted sync server, TLS
peer, and a miniature counter deployment. Its server-side RFC6455 framing is
also written in Awk over raw extension sockets, rather than calling the client's
C frame parser. Tests start it as a co-process and drive it command by command,
so the cases are deterministic rather than timed.

## Known limitations and honest risks

`./run test awk` passes: the gawk source build, the extension, every
language-local suite, and the runtime/example image policy probes all run
green inside Docker. The canonical example plus shared local and hosted
conformance also passed, earning HTTP and Live.

- The gawk tarball is pinned to 5.3.2, not the newer 5.4.x series. A
  from-source 5.4.1 build was tried first and miscompiled a common `if`
  pattern that combines two array-subscript comparisons with `&&` (verified in
  isolation against Debian's packaged 5.2.1 and Alpine's packaged 5.3.2, which
  both evaluate the same program correctly, and against a from-source 5.3.2
  build, which also does not reproduce it, at multiple optimization levels).
  That looks like an upstream regression in the very new 5.4 series rather
  than anything in this build, so the toolchain stays on the last version
  confirmed correct. The pinned `xz-utils` version is deliberately absent
  while every other apt package is pinned; and the runtime closure is staged
  from `ldd` output rather than a hand-checked list, which is safer but still
  worth another look.
- The test stage performs a verified TLS exchange and hostname-mismatch check.
  The final pruned image currently proves that its exact trust store loads, but
  its first real TLS handshake still needs the final-image runtime probe.
- The sync profile assumes a reconnecting client restarts from the zero state
  version, which is what the pinned `convex-rs` revision does. Only a run
  against a real deployment can confirm that the server agrees.
- The example's `0 -> 1` journey is currently proved against a fixture
  deployment written in Awk, not against Convex. `./run verify-example awk` is
  the run that turns that into evidence.
- RFC6455 framing and masking are in the extension, not in Awk. The Live
  protocol, its state machine, and its recovery are Awk.
- The client is single threaded. A long HTTP call delays Live reads until that
  call's deadline expires.
- WebSocket mutations and actions, Live authentication, optimistic updates,
  journals, and `TransitionChunk` assembly are not implemented.
- Yellow proves bearer-token transport, not identity-provider integration. No
  signed JWT is exercised.
- Values are limited to Convex's JSON-safe subset. Int64, bytes, special floats,
  and negative zero are not claimed, and strings containing U+0000 are refused
  because Awk cannot carry them safely.
- Bracketed IPv6 deployment URLs are refused rather than mis-parsed.
- Syntax highlighting for the example block falls back to plain text, because
  the shared README projector has no `.awk` fence mapping.
