<img src="logo.png" alt="FreeBASIC logo" width="120">
<!-- Logo source: https://www.freebasic.net/images/logo.png -->

# FreeBASIC

[FreeBASIC](https://www.freebasic.net/) is a free, open source BASIC compiler
for Windows, DOS, and Linux. André Victor started it in 2004 as a
QuickBASIC-compatible compiler, and it grew into a self-hosting language with
procedural and object-oriented features, threads, and direct access to C
libraries. Its strongest present-day niche is the community that wants familiar
BASIC syntax without giving up native executables or lower-level systems access.

This repository uses that C interoperability for OpenSSL and POSIX sockets,
then implements JSON, HTTP, WebSockets, and the Convex-specific behaviour in
FreeBASIC itself. This is an educational, unofficial demonstration, not a
production SDK, and it is not supported by Convex or the FreeBASIC project.

## Getting Started

The [canonical example](examples/basics/main.bas) reads a fresh counter, starts
a Live subscription before changing it, applies one mutation, and confirms the
reactive update from `0` to `1`.

```sh
./run verify-example freebasic
```

Run that command from the repository root. Docker builds the pinned FreeBASIC
toolchain and minimal example image, then runs this exact example against a
unique room on an approved test deployment.

## Interesting Parts

### The mutation is QuickBASIC on the surface, C underneath

FreeBASIC began in 2004 as a QuickBASIC-compatible compiler, so a Convex call
still reads like the BASIC of the early 90s — `dim as`, `end if`, string
concatenation with `&`. But there is no garbage collector: the argument object
is a heap-owned JSON tree you build node by node and free yourself, and every
call reports failure through a `ConvexFault` UDT passed `byref` instead of an
exception.

```freebasic
dim as JsonValue ptr args = JsonNew(JSON_OBJECT)
JsonSet(args, "room", JsonNewString(room))
JsonSet(args, "language", JsonNewString("FreeBASIC"))
JsonSet(args, "runId", JsonNewString(room & "-once"))

' TypeScript: const result = await increment({ room, language, runId })
dim as ConvexResult mutated
ConvexResultInit(mutated)
if not ConvexMutation(client, "demo:increment", args, mutated, fault) then
  Fail(fault.message)
end if

ConvexResultFree(mutated)
JsonFree(args)
```

BASIC nostalgia with C-style resource management — both halves are genuine.

### `orelse` is the short-circuit QuickBASIC never had

Classic BASIC's `or` is bitwise and always evaluates both sides. FreeBASIC
added `andalso` and `orelse`, and this client leans on them to chain a JSON
shape check with a range check in one guard — decoding Convex's `count` field,
which may legally arrive spelled `1` or `1.0`.

```freebasic
' Accept a whole counter spelled 1 or 1.0; reject fractions and wrong types.
function CounterFrom(byval state as JsonValue ptr, byref operation as string) as longint
  dim as longint counted
  if not JsonWholeNumber(JsonMember(state, "count"), counted) orelse counted < 0 then
    Fail(operation & " did not return a whole nonnegative count")
  end if
  return counted
end function
```

`JsonWholeNumber` fills a `byref` out-parameter and returns `false` rather
than a default, so a missing `count` can never be mistaken for zero — and the
`orelse` guarantees the range check only runs once the decode has succeeded.

### A Live update is a pointer — in a BASIC

FreeBASIC bolted C-style pointers onto BASIC, `->` dereference and all. This
client uses them to make Convex's reactive side explicit: `ConvexSubscribe`
returns a `LiveSubscription ptr`, and each WebSocket delivery is a
`LiveUpdate ptr` you take with a blocking `ConvexNext`, read through `->`,
and free.

```freebasic
' TypeScript: useQuery(api.demo.state, { room }) re-renders on each update.
dim as LiveSubscription ptr live = ConvexSubscribe(client, "demo:state", roomArgs, fault)

dim as LiveUpdate ptr updated = ConvexNext(client, live, 10000)
if updated = 0 orelse (not updated->hasValue) then
  Fail("the Live update did not arrive")
end if
print CounterFrom(updated->value, "the Live update")

LiveUpdateFree(updated)
ConvexUnsubscribe(client, live, 2000)
```

A worker thread owns the socket and each subscription's bounded mailbox; your
code just takes one owned update at a time, in program order.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action | Earned (`http`) |
| Live queries over `/api/sync` | Earned (`live`) |
| Bearer token lifecycle (HTTP) | Passing |
| Bearer token on the Live socket | Not implemented |
| Docker `test` / `runtime` images | Passing, including against real backends |

`http` and `live` were awarded by the shared result evaluator from a clean,
exact-head run of `./run verify-all freebasic`: 31/31 conformance checks passed
against both the local self-hosted backend and the dedicated hosted drift
target, from the same built image.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.bas -->
```freebasic
' Convex from FreeBASIC: one room, counted from 0 to 1.
'
' The journey is deliberately small. Read the counter over HTTP, start a Live
' subscription before changing anything, apply one idempotent mutation, and
' only claim success once HTTP and Live agree.

#include once "convex.bi"

' Diagnostics go to stderr because stdout is the transcript the shared
' verifier compares line for line.
sub Fail(byref message as string)
  dim as integer handle = freefile
  open err for output as #handle
  print #handle, "convex example failed: " & message
  close #handle
  end 1
end sub

' Convex may spell a whole counter as 1 or as 1.0. Accept both, and reject a
' fraction, a quoted number, or anything out of range, so a wrong shape fails
' the example instead of quietly reading as zero.
function CounterFrom(byval state as JsonValue ptr, byref operation as string) as longint
  dim as longint counted
  if not JsonWholeNumber(JsonMember(state, "count"), counted) orelse counted < 0 then
    Fail(operation & " did not return a whole nonnegative count")
  end if
  return counted
end function

' The shared verifier passes a unique room as the first argument; the default
' only exists so the image is pleasant to run by hand.
dim as string room = command(1)
if len(room) = 0 then
  room = "freebasic-basic-example"
end if

' The deployment to talk to. Never a hardcoded URL, so the same binary can be
' pointed at the local backend or the hosted drift target.
dim as string deploymentUrl = environ("CONVEX_URL")
if len(deploymentUrl) = 0 then
  Fail("CONVEX_URL is required")
end if

' Create the native FreeBASIC client. Nothing has touched the network yet.
dim as ConvexClient client
dim as ConvexFault fault
FaultClear(fault)
if not ConvexOpen(client, deploymentUrl, fault) then
  Fail(fault.message)
end if

' Every Convex call takes a JSON object of named arguments.
dim as JsonValue ptr roomArgs = JsonNew(JSON_OBJECT)
JsonSet(roomArgs, "room", JsonNewString(room))

' Read the current counter over Convex's documented HTTP query endpoint.
dim as ConvexResult current
ConvexResultInit(current)
if not ConvexQuery(client, "demo:state", roomArgs, current, fault) then
  Fail(fault.message)
end if
dim as longint before = CounterFrom(current.value, "the HTTP query")
if before <> 0 then
  Fail("expected a fresh room to start at zero")
end if
ConvexResultFree(current)
print "current count: 0"

' Start Live before mutating. Subscribing first is what makes the later update
' evidence of a reactive WebSocket rather than a second HTTP read.
dim as LiveSubscription ptr live = ConvexSubscribe(client, "demo:state", roomArgs, fault)
if live = 0 then
  Fail(fault.message)
end if

' The first Live delivery is the current value, so it must agree with HTTP.
dim as LiveUpdate ptr initial = ConvexNext(client, live, 10000)
if initial = 0 orelse (not initial->hasValue) then
  Fail("the initial Live value did not arrive")
end if
if CounterFrom(initial->value, "the initial Live value") <> before then
  Fail("the initial Live value disagreed with the HTTP query")
end if
LiveUpdateFree(initial)
print "live initial count: 0"

' Increment once. runId is the idempotency key: because the room is unique to
' this run, a retry after a lost response still counts exactly one increment.
dim as JsonValue ptr incrementArgs = JsonNew(JSON_OBJECT)
JsonSet(incrementArgs, "room", JsonNewString(room))
JsonSet(incrementArgs, "language", JsonNewString("FreeBASIC"))
JsonSet(incrementArgs, "runId", JsonNewString(room & "-once"))

dim as ConvexResult mutated
ConvexResultInit(mutated)
if not ConvexMutation(client, "demo:increment", incrementArgs, mutated, fault) then
  Fail(fault.message)
end if
dim as JsonValue ptr applied = JsonMember(mutated.value, "applied")
if applied = 0 orelse applied->kind <> JSON_BOOL orelse (not applied->boolValue) then
  Fail("the mutation was not applied")
end if
dim as longint after = CounterFrom(JsonMember(mutated.value, "state"), "the mutation")
if after <> before + 1 then
  Fail("the mutation did not increment exactly once")
end if
ConvexResultFree(mutated)
print "mutation applied: true"
print "mutation count: 1"

' The mutation should now arrive over the same Live subscription.
dim as LiveUpdate ptr updated = ConvexNext(client, live, 10000)
if updated = 0 orelse (not updated->hasValue) then
  Fail("the Live update did not arrive")
end if
if CounterFrom(updated->value, "the Live update") <> after then
  Fail("the Live update disagreed with the mutation")
end if
LiveUpdateFree(updated)
print "live updated count: 1"

' Release the subscription, then the client and its Live owner thread.
ConvexUnsubscribe(client, live, 2000)
JsonFree(roomArgs)
JsonFree(incrementArgs)
ConvexClose(client, 3000)

' Only claim the journey once HTTP and Live have agreed on every step.
print "verified count: 0 -> 1"
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

- This is a native client. OpenSSL supplies TLS and cryptographic randomness,
  and libc supplies sockets, the monotonic clock, and number formatting through
  direct C ABI declarations. The Convex behaviour, strict JSON parser,
  HTTP/1.1 reader, and RFC 6455 WebSocket implementation are FreeBASIC code.
- The Docker build bootstraps the pinned FreeBASIC 1.10.1 compiler from its
  official source release. FreeBASIC is self-hosting, so a small compiler built
  from pre-generated C first builds the full compiler and runtime.
- One worker thread owns Live socket reads, writes, reconnects, and query-set
  changes. Each `LiveSubscription` UDT has a bounded mailbox, while callers use
  `ConvexNext` to take ownership of deliveries one at a time.
- The public examples use UDTs such as `ConvexClient`, `ConvexResult`, and
  `LiveUpdate`, plus typed pointers to heap-owned JSON trees. This is closer to
  C-style resource management than garbage-collected JavaScript.
- Live follows the unversioned `/api/sync` profile pinned in `manifest.yaml`.
  The lower-level adapter in `client/tests/conformance/` is test infrastructure,
  not part of the educational API.

## Known Issues

1. `ConvexSetAuth` covers HTTP only. Live authentication is not implemented.
2. A slow Live consumer can lose its oldest queued updates. Mailboxes are
   deliberately capped at 16 updates each and 8 MiB across all subscriptions.
3. DNS resolution is synchronous, so a stalled system resolver can outlive the
   requested connection timeout.
4. FreeBASIC has no standard formatter. The Docker test image runs the
   repository's deterministic style checker instead.
5. The Live owner and adapter relay request explicit 8 MiB stacks because the
   FreeBASIC thread default was too small for the real TLS and JSON call chain.
