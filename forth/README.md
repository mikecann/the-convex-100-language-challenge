# Convex from Forth

This is a Convex client written in Forth. It reads a shared counter over
Convex's documented JSON HTTP endpoint, subscribes to the same query over
Convex Live, applies a mutation, and shows the change arriving reactively —
all from a language with no strings, no exceptions that carry data, and no
sockets.

It is educational, unofficial, and not a production SDK. It exists to answer
one question honestly: can Forth support a useful Convex client? Nothing here
is supported by Convex, and no capability is claimed until the shared
black-box conformance suite says so.

## Start here

The whole demonstration is one file: [`examples/basics/main.fth`](examples/basics/main.fth).

It walks a single journey and refuses to print its final line unless every
step agrees:

1. Query `demo:state` over HTTP and read the current count.
2. Subscribe to the same query over Live, **before** mutating, so no update
   can fall into the gap.
3. Check that the first Live value hydrates the same count the HTTP query
   returned.
4. Apply `demo:increment` with a fresh idempotency key.
5. Receive the new count over Live, with no second HTTP request.

Against a fresh room, that is the `0 -> 1` journey printed below.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented, Docker gate green | Written in Forth over the native transport layer |
| Structured Convex errors | Implemented, Docker gate green | `FunctionError`, `ProtocolError` and `TransportError` keep name, message, data and log lines |
| TLS with certificate and hostname verification | Implemented, Docker gate green | Verified against a private CA in the Docker test stage |
| Live subscribe, update, unsubscribe | Implemented, Docker gate green | RFC 6455 framing written in Forth |
| Live reconnect and rehydration | Implemented, Docker gate green | Adapter-only `debugDisconnect`, unchanged rehydration suppressed |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented | Deferred; see limitations |
| Earned badges | **None** | Shared and hosted conformance have not been run |

Every row above says "Docker gate green" deliberately, not "verified": the
code is complete, the language-local suites are written, and the Docker test
stage (build, every `client/tests/*.fth` suite and the example run) passes on
a remote builder for this checkpoint — but the shared black-box conformance
suite has not been run against it, so `capabilities` in `manifest.yaml` stays
empty until that suite says so.

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.fth -->
```text
\ Convex from Forth: read a shared counter over HTTP, watch it over Live, and
\ prove a mutation arrives on both. Against a fresh room the journey is 0 -> 1.

require convex.fth

\ json-get returns only the child index, so this keeps the document beside it
\ and lets the example walk into a nested field without losing its place.
: example-field ( doc node key-addr key-u -- doc node )
    {: doc node key-addr key-count :}
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
    {: client sub what-addr what-count | kind :}
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
    {: | client subscription current initial expected applied count :}
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

['] example-run catch ?dup if
    cvx-adopt-fault
    s" the Forth example failed" note-line
    report-error
    example-cleanup
    1 convex-exit
then
example-cleanup
0 convex-exit
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

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

## How it is put together

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

### What the native library is, and is not

Standard Forth has no sockets, no TLS and no monotonic clock, so
`client/convexrt.c` supplies exactly those. It is a little over five hundred
lines and it contains no HTTP, no WebSocket framing, no JSON, no retry policy
and no Convex knowledge. Every loop, deadline and bound is driven from Forth,
which is what keeps this a native client rather than a binding.

TLS verification is switched on inside that file rather than from Forth,
because a mistake there fails silently: peer verification, the default CA
bundle and `SSL_set1_host` hostname checking are all set together. The Docker
test stage proves it by connecting three ways to a local TLS server — trusted,
untrusted issuer, and wrong hostname — and only the first may succeed.

### Numbers without floating point

Convex may encode an integral number in decimal form, so `0` and `0.0` mean
the same count. Rather than routing that through a float, the parser analyses
a number as text and combines its digits, decimal point and exponent exactly.
A value is accepted only when it is mathematically integral and fits a signed
64-bit cell; fractional, quoted, non-finite and overflowing values are
rejected at the point of use.

### One owner, and the barriers around it

Exactly one worker may touch the WebSocket, change the query-set version or
decide to reconnect. This client is single threaded, so that worker is the set
of owner words in `client/convex-live.fth`, driven by `live-pump`. Callers
never write to the socket: they record what they want, pump the owner, and
read the result.

Every Live delivery carries three stamps — its subscription, that
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

### Framing that survives a timeout

The WebSocket codec never consumes a byte until the whole frame is buffered.
That one rule is what makes a mid-frame timeout safe: the partial frame stays
in the stream buffer and the next attempt resumes at the same offset instead
of re-synchronising on a byte that only looks like a frame header. A frame's
declared payload length is checked against the configured ceiling before any
payload byte is requested, so an inflated length header cannot make the client
reserve memory on a peer's behalf. `client/tests/live-test.fth` stops in the
middle of a frame, lets the deadline expire, and continues.

### Deadlines

Every operation captures an absolute deadline before its first byte, so no
amount of slow progress can extend it. Reads additionally carry a dribble
bound: once a message is partly consumed, a peer that stops making forward
progress fails on the dribble bound long before the absolute one. Closing and
unsubscribing are bounded the same way, and the tests assert the deadline
rather than relying on a cooperative peer.

## Conformance and protocol notes

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

## Limitations and deferred behaviour

- **Shared conformance has not been run.** The Docker test stage — build,
  every language-local suite and the example run — passes on a remote builder
  for this checkpoint, but the shared black-box conformance suite has not, so
  no capability is claimed.
- Live is driven by the caller. Because the client is single threaded,
  reactive updates arrive while a caller is inside `convex-live-wait`, the
  adapter's event loop, or another client word — not on a background thread.
- Live authentication, optimistic updates, WebSocket mutations, WebSocket
  actions, journals and `TransitionChunk` assembly are deferred.
- Live values cover Convex's JSON-safe subset; tagged Convex value conversions
  are deferred.
- IPv6 literal deployment URLs are rejected rather than partially supported.
- The exact gforth patch version is asserted to be in the 0.7 series at build
  time and recorded into the image. It must be pinned exactly once a build has
  reported it.
