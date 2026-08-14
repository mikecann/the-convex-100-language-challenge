<img src="logo.png" alt="Factor programming language logo" width="520">
<!-- Logo source: https://factorcode.org/logo.png -->

# Factor

[Factor](https://factorcode.org/) is a dynamic, concatenative, stack-based
language invented by Slava Pestov. It [began in
2003](https://concatenative.org/wiki/view/Factor/History) as a scripting
language for a Java game, then grew into a native, general-purpose system with
an optimising compiler, interactive development tools, garbage collection, and
a large standard library. It is in the spirit of Forth and Joy, but aims at
high-level application work such as scripts, servers, games, parsers, and
desktop software. Today it occupies a small, active niche among people
interested in language design and stack-oriented programming.

This repository's client is an educational, unofficial experiment. It is not
a production SDK, an officially sanctioned Convex client, or a package meant
for publication.

## Getting Started

[`examples/basics/main.factor`](examples/basics/main.factor) is the canonical
example. It queries a fresh counter room, starts a Live subscription before
changing anything, applies an idempotent mutation, and observes the `0 -> 1`
update through that subscription.

From the repository root, run it in its pinned Docker environment:

```sh
./run verify-example factor
```

That builds the minimal example image, runs the exact source shown later in
this README against an approved test deployment, and checks its output against
the shared expected transcript. You do not need Factor installed on your host.

## Interesting Parts

### The compiler checks the stack, not just the syntax

Factor calls its functions "words", and every word declares a stack effect
such as `( client path args -- result )`: what it consumes, what it leaves
behind. These are not comments — the compiler rejects any word whose body
does not balance its declared effect. Inside a lexical-locals word (`::`),
the `:>` word names whatever is on top of the stack, so a Convex query reads
as a left-to-right pipeline.

```factor
:: read-count ( deployment room -- count )
    deployment <convex-client> :> client
    room json-escape-string "room" swap 2array 1array json-object :> args

    ! TypeScript: const state = useQuery(api.demo.state, { room })
    client "demo:state" args client-query result-value
    "count" json-field "count" json-whole-number ;
```

Each word consumes what the one before it left: the query result feeds
`result-value`, the raw JSON feeds `json-field`, and the field feeds the
whole-number decoder.

### The comma is a word, and it builds the mutation's JSON

`[ ... ] { } make` runs a quotation with an implicit sequence growing behind
the scenes, and `,` is an ordinary word that appends to it. The client uses
this beloved Factor idiom to assemble mutation arguments pair by pair — and
the string variant (`"" make` with `%`) to format a fresh idempotency key
from 16 random bytes.

```factor
! TypeScript: await increment({ room, language: "Factor", runId })
[
    "room" room json-escape-string 2array ,
    "language" "\"Factor\"" 2array ,
    "runId" run-id json-escape-string 2array ,
] { } make json-object :> increment-args
client "demo:increment" increment-args client-mutation drop
```

### A reactive update is a value you wait for, with a deadline

Convex's signature move is the Live subscription: subscribe first, mutate,
and the new state is pushed to you. Here the push surfaces as
`subscription-next`, a bounded wait that returns the next delivery or `f`
once the deadline passes. Underneath, one owner thread owns the WebSocket
and every other green thread talks to it by posting messages through
Factor's `concurrency.mailboxes` — a design straight from the actor
playbook.

```factor
! Subscribe before mutating, so the update below must arrive reactively.
client "demo:state" args client-subscribe :> subscription
subscription 15 subscription-next update-value
"count" json-field "count" json-whole-number :> before

client "demo:increment" increment-args client-mutation drop

! TypeScript: useQuery(api.demo.state, { room }) would rerender here.
subscription 15 subscription-next update-value
"count" json-field "count" json-whole-number :> after
```

The `15` is seconds: no Live wait in the canonical example can hang forever.

### Try/finally is three quotations and one word

Quotations — the `[ ... ]` blocks — are first-class values, so control flow
arrives as ordinary words that consume them. `cleanup` takes a body, a
quotation that always runs, and one reserved for errors; `recover` is
try/catch. The canonical example leans on both so a failure still releases
the socket and its owner thread.

```factor
[
    ! ... query, subscribe, mutate, observe the 0 -> 1 update ...
] [
    subscription [ client subscription 2 client-unsubscribe ] when
    [ client 2 client-close ] [ drop ] recover
] [ ] cleanup
```

No keywords were harmed: `if`, `while`, and `cleanup` are all just words.

## Status

| Capability | Current state | Evidence-backed meaning |
| --- | --- | --- |
| HTTP | Badge earned | Native Factor query, mutation, action, bearer-token lifecycle, log lines, and structured `560`/`500`/`400` failures passed shared conformance on both deployment profiles. |
| Live | Badge earned | Native Factor RFC 6455 subscriptions, unsubscribe, five forced reconnects, reactive error recovery, and bounded close passed shared conformance on both deployment profiles. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against the local backend and 31 of 31 against the hosted deployment
over real TLS. This README edit does not claim a new verification run.

## Example

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

## Implementation Notes

This is a native Factor implementation. Convex-specific HTTP, JSON scanning,
WebSocket framing, and Live state management live under [`client/`](client/).
It uses Factor's standard TCP, TLS, threading, SHA-1, Base64, and random-number
vocabularies for ordinary platform services. It does not delegate requests to
Node.js, Python, `curl`, the Convex CLI, or another Convex client.

HTTP calls use Convex's documented `format: "json"` endpoints. Each call opens
its own connection and supports Content-Length, chunked, or close-delimited
responses up to 2 MiB. Successful values and log lines remain raw JSON text,
while function, protocol, and transport failures keep distinct Factor error
types. The JSON scanner accepts the subset this experiment needs and the
canonical example deliberately checks that `0.0` is an integral count rather
than assuming Convex will spell it `0`.

Live uses a native RFC 6455 WebSocket and pins the experimental sync profile
`convex-rs-0.10.4-unversioned-sync` at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. One owner thread controls reads,
writes, reconnects, and query-set versions. Each subscription keeps the newest
16 events inside an 8 MiB byte budget, so a stalled consumer cannot grow memory
without bound. Reads use absolute deadlines once a record starts, which stops a
peer from keeping a connection alive forever by sending one byte at a time.

Factor 0.101 is pinned in the Dockerfile. Its `deploy` tool turns the example
and conformance adapter into standalone x86-64 executables containing the
Factor VM and a stripped image. The minimal runtime keeps the required TLS
closure and POSIX verification tools, runs as `65532:65532`, and exposes no
interactive `factor` command.

For the full Docker-only test layers, use:

```sh
./run test factor
./run verify-example factor
./run verify factor
./run verify-hosted factor
./run verify-all factor
```

`test` checks presentation rules, compiles every vocabulary so Factor verifies
its stack effects, and runs language-local socket, TLS, JSON, Live, adapter, and
example tests. The remaining commands add the canonical example and shared
local or hosted conformance gates. Those shared gates are coordinator-owned.

## Known Issues

1. Live authentication and `TransitionChunk` assembly are not implemented. A
   chunk is treated as recoverable protocol drift.
2. Convex values are limited to the JSON-safe subset. Tagged Int64, bytes,
   special floats, negative zero, and exponent-form JSON numbers are outside
   scope.
3. Mutations and actions use HTTP. Optimistic updates, journals, mutation
   replay, and WebSocket writes are deferred.
4. HTTP does not reuse persistent connections, and input and response bodies
   are bounded at 2 MiB.
5. The test adapter reports its pinned Factor runtime string rather than asking
   the VM for the version at runtime.
