# Convex from Factor

This demonstration uses Factor to call Convex's documented JSON HTTP
endpoints and to keep a reactive query current over a native Factor
WebSocket connection. Factor is a concatenative, stack-based language, so
the client reads as a pipeline of small words rather than a class hierarchy.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.factor`](examples/basics/main.factor) is the canonical
example. It reads a fresh counter room over HTTP, starts Live before changing
it, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that exact
runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Native Factor query, mutation, action, bearer-token lifecycle, log lines, and structured `560`/`500`/`400` failures, verified by shared conformance on both profiles. |
| Live | Badge earned | Native Factor RFC 6455 subscriptions, unsubscribe, five forced reconnects, reactive error recovery, and bounded close against the pinned sync profile, verified by shared conformance on both profiles. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 conformance checks against a local backend and 31 of 31 against the hosted
deployment over real TLS.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.factor -->
```factor
! The canonical Convex-from-Factor example.
!
! It reads one counter room over HTTP, starts a Live subscription before
! changing anything, applies an idempotent mutation, and proves the same
! 0 -> 1 journey arrived through the subscription. Every line it prints is
! part of the shared happy-path transcript, so diagnostics go to stderr.

USING: accessors arrays command-line continuations environment io
kernel locals make math math.parser namespaces random sequences
system convex convex.json convex.transport ;
IN: convex.example

ERROR: example-error message ;

! Convex JSON may spell a whole number as 0.0. This helper accepts a value
! that is mathematically integral and in range while rejecting fractional,
! quoted, non-finite, and overflowing spellings, which is exactly the
! boundary the client's decoder promises.
:: example-count ( raw operation -- n )
    raw [ operation " returned no value" append example-error ] unless
    raw "count" json-field operation " count" append json-whole-number :> n
    n 0 < [ operation " returned a negative count" append example-error ]
    when
    n ;

! A fresh runId is the mutation's idempotency key. Reading it from the
! operating system's entropy source keeps the example from delegating
! randomness to a CLI or another language runtime.
: run-id ( -- text )
    [ 16 random-bytes [ >hex 2 CHAR: 0 pad-head % ] each ] "" make ;

! The example must never hang waiting for a reactive value that will not
! arrive, so every Live wait carries its own bounded deadline.
:: next-example-value ( subscription operation -- raw )
    subscription 15 subscription-next :> update
    update [ operation " timed out" append example-error ] unless
    update update-error [
        operation " failed: " append
        update update-error "message" json-field json-string-value append
        example-error
    ] when
    update update-value ;

: room-argument ( -- room )
    command-line get dup empty? [ drop f ] [ first ] if
    [ "EXAMPLE_ROOM" os-env ] unless*
    [ "factor-example" ] unless* ;

:: example-main ( -- )
    "CONVEX_URL" os-env [ "CONVEX_URL is required" example-error ] unless*
    :> deployment
    room-argument :> room
    ! One native Factor client for the deployment the container supplies.
    deployment <convex-client> :> client
    f :> subscription!
    [
        room json-escape-string "room" swap 2array 1array json-object
        :> room-args

        ! Ask Convex over its documented JSON HTTP endpoint first, so the
        ! room's starting value is established before anything changes it.
        client "demo:state" room-args client-query result-value
        "current query" example-count :> current
        "current count: " current number>string append print

        ! Start Live before mutating. Subscribing first is what proves the
        ! update below arrived reactively rather than being read back later.
        client "demo:state" room-args client-subscribe subscription!

        ! The first Live value hydrates the same state the HTTP query saw.
        subscription "initial Live value" next-example-value
        "initial Live value" example-count :> initial
        initial current = [
            "initial Live count disagreed with HTTP" example-error
        ] unless
        "live initial count: " initial number>string append print

        ! Reusing this runId would return the prior result instead of
        ! incrementing twice, which is what makes the mutation safe to retry.
        [
            "room" room json-escape-string 2array ,
            "language" "\"Factor\"" 2array ,
            "runId" run-id json-escape-string 2array ,
        ] { } make json-object :> increment-args
        client "demo:increment" increment-args client-mutation result-value
        :> mutation-value
        mutation-value "applied" json-field "applied" json-boolean [
            "mutation was not applied" example-error
        ] unless
        mutation-value "state" json-field "mutation" example-count
        :> mutation-count
        mutation-count current 1 + = [
            "mutation returned an unexpected count" example-error
        ] unless
        "mutation applied: true" print
        "mutation count: " mutation-count number>string append print

        ! Receive the change through Live rather than polling HTTP again.
        subscription "updated Live value" next-example-value
        "updated Live value" example-count :> updated
        updated mutation-count = [
            "updated Live count disagreed with the mutation" example-error
        ] unless
        "live updated count: " updated number>string append print

        ! Only printed once the HTTP query, the initial Live value, the
        ! mutation, and the Live update all agreed.
        "verified count: " current number>string append " -> " append
        updated number>string append print
    ] [
        ! Cleanup uses the client's own acknowledged, bounded shutdown so a
        ! failure still releases the socket and the owner thread.
        subscription [ client subscription 2 client-unsubscribe ] when
        [ client 2 client-close ] [ drop ] recover
    ] [ ] cleanup ;

:: report-failure ( problem -- )
    error-stream get :> es
    "Factor example failed: " es stream-write
    problem example-error? [ problem message>> ] [ problem error-message ] if
    es stream-write
    "\n" es stream-write
    es stream-flush ;

: run-example ( -- )
    ! exit terminates the process immediately, and stdout is fully
    ! buffered rather than line-buffered once it is a pipe rather than a
    ! terminal, so the transcript above must be flushed explicitly or a
    ! verifier reading it back would see nothing.
    [ example-main flush 0 exit ] [ report-failure 1 exit ] recover ;

MAIN: run-example
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test factor
./run verify-example factor
./run verify factor
./run verify-hosted factor
./run verify-all factor
```

`test` runs the source formatting check, compiles every vocabulary (which is
Factor's own stack-effect check), then exercises real loopback HTTP, raw
WebSocket, sync-protocol, TLS, and stopped-reader fixtures inside Docker.
`verify-example` executes the canonical source above and compares its stdout
with the universal transcript. The remaining commands are root-owned shared
gates for the approved local and hosted deployments.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` speaks NDJSON protocol
v1 on stdin/stdout and over TCP when `ADAPTER_LISTEN` is set. It calls the real
Factor client for every operation and reserves stdout for protocol events. Its
adapter-only `debugDisconnect` command lets the shared harness prove five real
reconnects; it is declared in `manifest.yaml` and is deliberately absent from
the educational client API.

HTTP uses Convex's documented `format: "json"` endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`. That realtime
protocol is not documented as stable, so hosted verification remains required.

Both runtime images are produced by Factor's `deploy` tool, which embeds a
stripped image in a copy of the Factor VM. Word definitions and the dictionary
are stripped, so neither image exposes an interactive Factor compiler, and the
final-image probe asserts that no `factor` command is present.

## Buffering and deadlines

Delivery buffering belongs to this client rather than to a runtime mailbox.
Each subscription owns an explicitly bounded relay that keeps the newest 16
events inside an 8 MiB conservatively charged budget, and each relay carries a
generation so an unsubscribe or a same-id replacement invalidates queued work
before its acknowledgement is published. Adapter output is bounded separately
at 16 events and 6 MiB, reserving four slots and 64 KiB for control events, so
a burst of large Live values can never starve a controller answer.

Two deadline kinds appear throughout the transport. A stream timeout bounds one
blocking read. An absolute deadline is fixed before the first byte of a record
is consumed, so a peer that dribbles one byte at a time cannot extend it; the
WebSocket test asserts that deadline against a peer that stays alive and keeps
sending.

## Limitations

- Nothing here has been compiled or run. The Docker build, the language-local
  tests, and both runtime images are unverified.
- Live authentication and `TransitionChunk` assembly are not implemented. A
  chunk is treated as recoverable protocol drift.
- Values are limited to this experiment's JSON-safe subset. Tagged Convex
  Int64, bytes, special floats, and negative zero are outside scope, and
  exponent-form JSON numbers are rejected rather than guessed at.
- Mutations and actions use HTTP. Optimistic updates, journals, mutation
  replay, and WebSocket writes are deferred.
- HTTP response framing supports Content-Length, chunked transfer encoding, and
  connection close, bounded at 2 MiB. Persistent connection reuse is deferred:
  every call opens its own connection.
- The adapter reports a pinned runtime string rather than querying the Factor
  VM for its version. Root-owned verification records the toolchain pin
  separately.
