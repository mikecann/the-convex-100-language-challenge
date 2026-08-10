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

### A typed React result becomes an explicitly checked JSON tree

**TypeScript with React**

```tsx
import { api } from "../convex/_generated/api";
import { useQuery } from "convex/react";

export function Count() {
  const state = useQuery(api.demo.state, {
    room: "freebasic-readme-query",
  });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // `state` and `count` are type-safe here.
}
```

**FreeBASIC**

```freebasic
#include once "convex.bi"

' Configuration is explicit in a command-line program.
dim as string deploymentUrl = environ("CONVEX_URL")
dim as ConvexClient client  ' A UDT groups the client's connection state.
dim as ConvexFault fault
FaultClear(fault)
if len(deploymentUrl) = 0 orelse _
   not ConvexOpen(client, deploymentUrl, fault) then end 1

' Build the same { room: string } argument object by hand.
dim as JsonValue ptr args = JsonNew(JSON_OBJECT)
JsonSet(args, "room", JsonNewString("freebasic-readme-query"))

dim as ConvexResult result  ' Another UDT owns the returned JSON tree.
ConvexResultInit(result)
if not ConvexQuery(client, "demo:state", args, result, fault) then end 1

dim as longint count
if not JsonWholeNumber(JsonMember(result.value, "count"), count) then end 1
print count  ' `count` is typed only after the runtime shape check succeeds.

ConvexResultFree(result)  ' Free the result tree owned by the UDT.
JsonFree(args)
ConvexClose(client, 3000)
```

The React hook validates the generated function shape at compile time and stays
reactive. `ConvexQuery` is only a one-off HTTP read. FreeBASIC gives the decoded
number a concrete `longint`, but this client must first validate the dynamic
JSON value and the caller must explicitly release the owned trees.

### React manages reactivity; this client exposes the lifecycle

**TypeScript with React**

```tsx
import { api } from "../convex/_generated/api";
import { useMutation, useQuery } from "convex/react";

export function Counter({ room }: { room: string }) {
  // The caller supplies a fresh room for this run, just like the CLI argument.
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <button disabled>Loading...</button>;
  return (
    <button
      onClick={async () => {
        const result = await increment({
          room,
          language: "TypeScript",
          runId: crypto.randomUUID(),
        });
        console.log(result.state.count); // The mutation result is type-safe.
      }}
    >
      Count: {state.count}
    </button>
  ); // React re-renders when the subscribed value changes.
}
```

**FreeBASIC**

```freebasic
#include once "convex.bi"

dim as string deploymentUrl = environ("CONVEX_URL")
dim as string room = command(1)  ' Pass a fresh room ID on each run.
if len(deploymentUrl) = 0 orelse len(room) = 0 then end 1

dim as ConvexClient client
dim as ConvexFault fault
FaultClear(fault)
if not ConvexOpen(client, deploymentUrl, fault) then end 1

dim as JsonValue ptr roomArgs = JsonNew(JSON_OBJECT)
JsonSet(roomArgs, "room", JsonNewString(room))

' The handle and each delivery are explicit pointers owned by the caller.
dim as LiveSubscription ptr live = _
  ConvexSubscribe(client, "demo:state", roomArgs, fault)
if live = 0 then end 1
dim as LiveUpdate ptr initial = ConvexNext(client, live, 10000)
dim as longint initialCount
if initial = 0 orelse (not initial->hasValue) orelse _
   not JsonWholeNumber(JsonMember(initial->value, "count"), initialCount) then end 1
LiveUpdateFree(initial)

' Mutate only after subscribing, using the fresh room as an idempotency key.
dim as JsonValue ptr mutationArgs = JsonNew(JSON_OBJECT)
JsonSet(mutationArgs, "room", JsonNewString(room))
JsonSet(mutationArgs, "language", JsonNewString("FreeBASIC"))
JsonSet(mutationArgs, "runId", JsonNewString(room & "-once"))
dim as ConvexResult mutationResult
ConvexResultInit(mutationResult)
if not ConvexMutation( _
    client, "demo:increment", mutationArgs, mutationResult, fault) then end 1

' ConvexNext blocks until this client's mailbox has the reactive update.
dim as LiveUpdate ptr changed = ConvexNext(client, live, 10000)
dim as longint changedCount
if changed = 0 orelse (not changed->hasValue) orelse _
   not JsonWholeNumber(JsonMember(changed->value, "count"), changedCount) then end 1
print initialCount; " -> "; changedCount

LiveUpdateFree(changed)
ConvexResultFree(mutationResult)
ConvexUnsubscribe(client, live, 2000)
JsonFree(roomArgs)
JsonFree(mutationArgs)
ConvexClose(client, 3000)
```

FreeBASIC supports threads and callbacks. The blocking `ConvexNext` API is a
choice made by this command-line client, not a language restriction. It keeps
subscription ownership visible: subscribe, consume each owned update, then
unsubscribe and close. React performs the corresponding subscription cleanup
for the component.

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
