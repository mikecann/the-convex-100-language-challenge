<img src="logo.png" alt="Forth logo" width="64" height="64">
<!-- Logo source: https://forth-standard.org/images/forth.png -->

# Forth

Forth is a compact, stack-based language created by Charles Moore. Programs
are built from small named operations called *words*, and values usually move
between them through a data stack instead of function parameters. The
[Forth 2012 Standard](https://forth-standard.org/standard/foreword) describes
its roots in interactive development, extensibility, and direct access to
hardware, with standardisation beginning in the mid-1970s.

Today Forth is a specialist choice rather than a mainstream web language. It
still has an active standard and implementations such as
[Gforth](https://gforth.org/), which runs on desktop systems and also has an
embedded variant. That low-level niche makes a reactive cloud client an
interesting stretch: this repository implements JSON, HTTP, WebSocket framing,
and Convex behaviour in Forth, while a small C library supplies sockets, TLS,
polling, and a monotonic clock.

This is an educational, unofficial demonstration, not a production SDK and not
supported by Convex.

## Getting Started

Start with the canonical [`examples/basics/main.fth`](examples/basics/main.fth).
It queries `api.demo.state`, subscribes to that same state before changing it,
calls `api.demo.increment`, and checks that Live delivers the new count.

From the repository root, run:

```sh
./run verify-example forth
```

The command builds and runs the exact example in Docker against a unique room.
It proves the example's `0 -> 1` journey and compares its output with the shared
expected transcript. Nothing needs to be installed on the host.

## Interesting Parts

### The stack makes every argument explicit

In React, generated Convex bindings give the mutation typed arguments and a
typed result. This Forth client builds the same named arguments into JSON, then
walks the returned JSON document explicitly. The comments in parentheses show
the stack effect: values before `--` are consumed and values after it are left
for the next word.

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  async function handleClick() {
    const result = await increment({
      room: "readme-forth",
      language: "forth",
      runId: crypto.randomUUID(), // Fresh per click; retries reuse the call's ID.
    });
    console.log(result.state.count); // The generated API makes this type-safe.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Forth**

```forth
require convex.fth

\ Fail clearly instead of handing an empty deployment URL to the client.
: example-give-up ( addr u -- )
    note-line
    1 convex-exit ;

: open-example-client ( -- client )
    s" CONVEX_URL" getenv dup 0= if
        2drop s" CONVEX_URL is required" example-give-up
    then
    convex-open ;

\ Keep the document beside each child node while walking the returned object.
: field ( doc node key-addr key-u -- doc child )
    { doc node key-addr key-count }
    doc  doc node key-addr key-count json-get ;

\ Generate the mutation's idempotency key from unpredictable bytes.
64 buf-new constant run-id

: fresh-run-id ( -- addr u )
    run-id buf-reset
    16 run-id random-hex
    run-id buf-span ;

open-example-client constant client

client s" demo:increment"
client convex-args
    \ Each pair adds one property to the JSON argument object.
    s" room" s" readme-forth" convex-arg-string
    s" language" s" forth" convex-arg-string
    s" runId" fresh-run-id convex-arg-string
client convex-args-done
convex-mutation

\ convex-value leaves ( document root-node ); field narrows it to state.count.
client convex-value s" state" field s" count" field convex-integer . cr
client convex-free
```

Both snippets create a fresh idempotency key when they invoke the mutation. The
Forth helper uses the same `random-hex` path as the canonical example. Unlike
the generated TypeScript API, the Forth client has no compile-time knowledge of
the backend schema, so a misspelled field becomes a checked runtime error.

### React owns reactivity; the Forth caller pumps it

`useQuery` creates a subscription, updates the component, and cleans up when
the component unmounts. The command-line Forth API exposes those steps. Its
blocking `convex-live-wait` is a deliberate client design for a single-threaded
program, not a limitation of the Forth language.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "readme-forth" });

  if (state === undefined) return <p>Loading...</p>;
  return <p>Count: {state.count}</p>; // React rerenders on each Live update.
}
```

**Forth**

```forth
require convex.fth

\ Fail clearly instead of handing an empty deployment URL to the client.
: example-give-up ( addr u -- )
    note-line
    1 convex-exit ;

: open-example-client ( -- client )
    s" CONVEX_URL" getenv dup 0= if
        2drop s" CONVEX_URL is required" example-give-up
    then
    convex-open ;

: read-one-update ( client subscription -- )
    { client subscription }
    \ Waiting pumps the one socket owner until this subscription has a value.
    client subscription 10000 convex-live-wait
    dup convex-live-none = if
        drop s" no Live value arrived" note-line exit
    then
    convex-live-error = if
        client convex-live-error-message@ note-line
        client convex-live-release exit
    then
    client convex-live-value@ type cr  \ The delivery is JSON text here.
    client convex-live-release ;       \ Release bounded queue storage promptly.

open-example-client constant client
client s" demo:state"
client convex-args
    s" room" s" readme-forth" convex-arg-string
client convex-args-done
convex-subscribe constant subscription

client subscription read-one-update
client subscription convex-unsubscribe  \ React normally hides this lifecycle.
client convex-free
```

This snippet shows one delivery, not a background component subscription. The
full [canonical example](examples/basics/main.fth) parses the value, subscribes
before mutating so there is no update gap, and checks the reactive count.

### Decimal JSON numbers are checked without floating point

JavaScript has one ordinary `number` type, so a Convex count written as `0` or
`0.0` arrives as the same value. This implementation intentionally avoids a
floating-point detour. `convex-integer` analyses the JSON number's decimal text
and accepts it only when it is mathematically integral and fits a signed
64-bit Forth cell.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CountLogger() {
  const state = useQuery(api.demo.state, { room: "readme-forth" });

  if (state !== undefined) {
    console.log(state.count); // Both JSON 0 and 0.0 become the number 0.
  }
  return null;
}
```

**Forth**

```forth
require convex.fth

\ Fail clearly instead of handing an empty deployment URL to the client.
: example-give-up ( addr u -- )
    note-line
    1 convex-exit ;

: open-example-client ( -- client )
    s" CONVEX_URL" getenv dup 0= if
        2drop s" CONVEX_URL is required" example-give-up
    then
    convex-open ;

: state-count ( doc state-node -- count )
    { doc state }
    \ Keep the document with the child node, then require an exact integer.
    doc  doc state s" count" json-get convex-integer ;

open-example-client constant client
client s" demo:state"
client convex-args
    s" room" s" readme-forth" convex-arg-string
client convex-args-done
convex-query

client convex-value state-count . cr
client convex-free
```

Fractional, quoted, non-finite, and overflowing values fail instead of being
silently rounded. The focused regression lives in
[`client/tests/json-test.fth`](client/tests/json-test.fth).

## Status

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented, Docker gate green | Convex request and response behaviour is written in Forth |
| Structured Convex errors | Implemented, Docker gate green | `FunctionError`, `ProtocolError`, and `TransportError` preserve useful detail |
| TLS certificate and hostname verification | Implemented, Docker gate green | Tested against trusted, untrusted, and wrong-hostname fixtures |
| Live subscribe, update, unsubscribe | Implemented, Docker gate green | WebSocket framing and Live state management are written in Forth |
| Live reconnect and rehydration | Implemented, Docker gate green | Real reconnects are tested and unchanged rehydration is suppressed |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented | Deferred; see Known Issues |
| Earned capabilities | **HTTP and Live** | Shared local and hosted conformance passed |

The manifest records the earned HTTP and Live capabilities. These claims come
from the existing repository evidence; this README change does not rerun shared
verification.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.fth -->
```forth
\ Convex from Forth: read a shared counter over HTTP, watch it over Live, and
\ prove a mutation arrives on both. Against a fresh room the journey is 0 -> 1.

require convex.fth

\ json-get returns only the child index, so this keeps the document beside it
\ and lets the example walk into a nested field without losing its place.
: example-field ( doc node key-addr key-u -- doc node )
    { doc node key-addr key-count }
    doc  doc node key-addr key-count json-get ;

\ Convex's demo functions return a record. This narrows one to the single field
\ the example promises and insists on a whole number: Convex may encode an
\ integral count as 0 or as 0.0, and convex-integer accepts both while still
\ rejecting a fractional, quoted or out-of-range value.
: example-count ( doc node -- count )
    s" count" example-field convex-integer ;

\ The verifier passes a unique room as the first argument of
\ /usr/local/bin/convex-example, which forwards it in EXAMPLE_ROOM. Running the
\ image by hand without one still works.
: example-room ( -- addr u )
    s" EXAMPLE_ROOM" getenv dup 0= if 2drop s" forth-example" then ;

\ runId is the mutation's idempotency key: Convex replays the earlier result
\ rather than counting twice when the same key arrives again. It must therefore
\ be fresh for every run and must not come from a predictable source.
64 buf-new constant run-id

: fresh-run-id ( -- addr u )
    run-id buf-reset
    16 run-id random-hex
    run-id buf-span ;

\ Every Live wait is bounded. A missing update is a failed demonstration, not
\ something to keep waiting for.
10000 constant example-live-timeout

: example-give-up ( addr u -- )
    note-line
    1 convex-exit ;

\ Take the next Live delivery and hand back the parsed value. A delivery is the
\ exact bytes Convex sent, so it goes through the same strict reader as an HTTP
\ response instead of a looser Live-only path.
: example-live-value ( client sub what-addr what-u -- doc node )
    0 { client sub what-addr what-count kind }
    client sub example-live-timeout convex-live-wait to kind
    kind convex-live-none = if
        what-addr what-count note
        s"  did not arrive before the deadline" example-give-up
    then
    kind convex-live-error = if
        what-addr what-count note s" : " note
        client convex-live-error-message@ example-give-up
    then
    client convex-live-value@ client client-doc json-parse
    client convex-live-release
    client client-doc dup doc-root ;

variable example-client
variable example-subscription

: example-run ( -- )
    0 0 0 0 0 0 0 { client subscription current initial expected applied count }
    \ Configure one client for the deployment this container was given.
    s" CONVEX_URL" getenv dup 0= if
        2drop s" CONVEX_URL is required" example-give-up
    then
    convex-open to client
    client example-client !

    \ Ask Convex for the current state through its documented HTTP endpoint.
    client s" demo:state"
    client convex-args
        s" room" example-room convex-arg-string
    client convex-args-done
    convex-query
    client convex-value example-count to current
    s" current count: " type current u-type cr

    \ Subscribe before mutating, so no reactive update can fall into the gap.
    client s" demo:state"
    client convex-args
        s" room" example-room convex-arg-string
    client convex-args-done
    convex-subscribe to subscription
    subscription example-subscription !

    \ The first Live value hydrates the same state the HTTP query just read.
    client subscription s" the initial Live value" example-live-value
    example-count to initial
    initial current <> if
        s" the initial Live count disagreed with HTTP" example-give-up
    then
    s" live initial count: " type initial u-type cr

    \ Apply the mutation, keyed so that a retry stays safe.
    client s" demo:increment"
    client convex-args
        s" room" example-room convex-arg-string
        s" language" s" forth" convex-arg-string
        s" runId" fresh-run-id convex-arg-string
    client convex-args-done
    convex-mutation
    current 1+ to expected
    client convex-value s" applied" example-field to applied drop
    client client-doc applied json-true? 0= if
        s" the mutation was not applied" example-give-up
    then
    client convex-value s" state" example-field example-count to count
    count expected <> if
        s" the mutation returned an unexpected count" example-give-up
    then
    s" mutation applied: true" type cr
    s" mutation count: " type count u-type cr

    \ Receive the same change reactively, with no second HTTP request.
    client subscription s" the updated Live value" example-live-value
    example-count to count
    count expected <> if
        s" the updated Live count disagreed with the mutation" example-give-up
    then
    s" live updated count: " type count u-type cr

    \ Only now, with all three operations agreeing, print the proof line.
    s" verified count: " type current u-type s"  -> " type count u-type cr ;

\ Cleanup is bounded: unsubscribe and close use the client's own deadlines
\ rather than waiting on a peer that may never answer.
: example-cleanup ( -- )
    example-client @ 0= if exit then
    example-subscription @ 0< 0= if
        example-client @ example-subscription @ convex-unsubscribe
    then
    example-client @ convex-close ;

-1 example-subscription !

\ IF and THEN are compile-only, so this catch/if/then dispatch has to live in
\ a word instead of directly at top level. Tick compiled into a word body
\ would parse a name from the input stream at run time and find none there;
\ bracket-tick resolves the execution token during compilation instead.
: example-main ( -- )
    ['] example-run catch ?dup if
        cvx-adopt-fault
        s" the Forth example failed" note-line
        report-error
        example-cleanup
        1 convex-exit
    then
    example-cleanup
    0 convex-exit ;

example-main
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

### Docker verification

Everything builds and runs inside Docker; nothing is installed on the host.

```sh
./run test forth
```

Runs the style gate, compiles the native support library, and executes the
language-local suites: strict JSON and the number rules, HTTP framing and the
Convex envelope, the WebSocket codec and the sync protocol, the adapter's wire
shapes, and TLS verification against a private CA. It also proves the example
fails cleanly with no deployment configured and prints nothing on stdout when
it does.

```sh
./run verify-example forth
```

Builds the minimal example image and runs the exact canonical example against
a unique room, comparing stdout byte for byte with the shared transcript.

```sh
./run verify forth
./run verify-hosted forth
./run verify-all forth
```

Add shared black-box conformance against the approved local backend, then the
hosted drift target, then both from the same built source. Only the shared
result evaluator may award a badge.

### How it is put together

The client is layered, innermost first:

| File | Responsibility |
| --- | --- |
| `client/convex-config.fth` | Every size and time bound in one place |
| `client/convex-error.fth` | A structured Convex failure that survives `THROW` |
| `client/convex-buffer.fth` | Growable byte buffers and string helpers |
| `client/convex-json.fth` | A strict JSON reader and writer, with no floating point |
| `client/convex-io.fth` | The native transport boundary and absolute deadlines |
| `client/convex-http.fth` | Convex's documented JSON HTTP functions |
| `client/convex-ws.fth` | RFC 6455 framing, SHA-1 and base64 |
| `client/convex-live.fth` | The sync profile, its single socket owner and its queue |
| `client/convexrt.c` | The only native code: sockets, TLS, poll, clock |

#### What the native library is, and is not

Standard Forth has no sockets, no TLS and no monotonic clock, so
`client/convexrt.c` supplies exactly those. It is a little over five hundred
lines and it contains no HTTP, no WebSocket framing, no JSON, no retry policy
and no Convex knowledge. Every loop, deadline and bound is driven from Forth,
which is what keeps this a native client rather than a binding.

TLS verification is switched on inside that file rather than from Forth,
because a mistake there fails silently: peer verification, the default CA
bundle and `SSL_set1_host` hostname checking are all set together. The Docker
test stage proves it by connecting three ways to a local TLS server: trusted,
untrusted issuer, and wrong hostname. Only the first may succeed.

#### Numbers without floating point

Convex may encode an integral number in decimal form, so `0` and `0.0` mean
the same count. Rather than routing that through a float, the parser analyses
a number as text and combines its digits, decimal point and exponent exactly.
A value is accepted only when it is mathematically integral and fits a signed
64-bit cell; fractional, quoted, non-finite and overflowing values are
rejected at the point of use.

#### One owner, and the barriers around it

Exactly one worker may touch the WebSocket, change the query-set version or
decide to reconnect. This client is single threaded, so that worker is the set
of owner words in `client/convex-live.fth`, driven by `live-pump`. Callers
never write to the socket: they record what they want, pump the owner, and
read the result.

Every Live delivery carries three stamps: its subscription, that
subscription's epoch, and the manager generation. Unsubscribing or replacing a
subscription bumps its epoch and purges its queued deliveries before the
acknowledgement is published, and consumers re-check the epoch after dequeue.
Retiring a connection bumps the generation, and `debugDisconnect` also purges
the queue, so nothing from a retired socket can cross its acknowledgement.

After a reconnect the server resends the current value of every active query.
Publishing that unchanged value would turn one logical update into two, so
each subscription remembers the exact bytes it last published and suppresses
an identical rehydration. Publishing an error clears that memory, which is
what lets a `QueryFailed` be followed by the same value again and still read
as a recovery.

#### Framing that survives a timeout

The WebSocket codec never consumes a byte until the whole frame is buffered.
That one rule is what makes a mid-frame timeout safe: the partial frame stays
in the stream buffer and the next attempt resumes at the same offset instead
of re-synchronising on a byte that only looks like a frame header. A frame's
declared payload length is checked against the configured ceiling before any
payload byte is requested, so an inflated length header cannot make the client
reserve memory on a peer's behalf. `client/tests/live-test.fth` stops in the
middle of a frame, lets the deadline expire, and continues.

#### Deadlines

Every operation captures an absolute deadline before its first byte, so no
amount of slow progress can extend it. Reads additionally carry a dribble
bound: once a message is partly consumed, a peer that stops making forward
progress fails on the dribble bound long before the absolute one. Closing and
unsubscribing are bounded the same way, and the tests assert the deadline
rather than relying on a cooperative peer.

### Conformance and protocol notes

`client/tests/conformance/adapter.fth` is test infrastructure, not public
client code. It speaks NDJSON adapter protocol v1 over stdin and stdout, or
over one accepted TCP connection when `ADAPTER_LISTEN` is set, and calls the
real client for every operation. Stdout carries protocol events only; every
diagnostic goes to stderr.

It implements the adapter-only `debugDisconnect` command, declared in
`manifest.yaml` under `adapter.adapterOnlyCommands`, so the shared controller
can prove real reconnects. That command is not part of the educational client
API.

Optional fields are omitted rather than serialized as null: an absent command
id, an absent error `data` and an absent value never appear as `null`.
`client/tests/adapter-test.fth` checks those shapes locally, so a mismatch is
caught next to the code that caused it instead of as an opaque schema failure
during shared conformance.

Outbound events are queued in a bounded outbox: the newest sixteen encoded
events within six megabytes, counting the event being written. When the
controller stops reading, the adapter flushes first and only then drops the
oldest subscription update, recording the drop. A reply to a command is never
dropped.

The pinned sync profile is recorded in `manifest.yaml`. It is an undocumented
protocol, and nothing here implies it is stable or officially supported.

## Known Issues

1. Live is driven by the caller. Because the client is single threaded,
  reactive updates arrive while a caller is inside `convex-live-wait`, the
  adapter's event loop, or another client word, not on a background thread.
2. Live authentication, optimistic updates, WebSocket mutations, WebSocket
  actions, journals and `TransitionChunk` assembly are deferred.
3. Live values cover Convex's JSON-safe subset; tagged Convex value conversions
  are deferred.
4. IPv6 literal deployment URLs are rejected rather than partially supported.
5. JSON input is bounded to 2 MiB, 128 nesting levels, 8,192 nodes, and 256
   keys per object. Active subscriptions and delivery queues also have explicit
   count and byte budgets.
6. The exact Gforth patch version is asserted to be in the 0.7 series at build
  time and recorded into the image. It must be pinned exactly once a build has
  reported it.
