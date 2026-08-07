# Convex from FreeBASIC

FreeBASIC is a 2004 BASIC compiler with a C-like type system, real threads, and
direct access to the C ABI. This demonstration uses that access for TLS,
sockets, and a clock, and writes everything else — JSON, HTTP/1.1 framing, RFC
6455, the Convex envelopes, and the `/api/sync` state machine — in FreeBASIC.

The result talks to a Convex deployment two ways: one-shot queries, mutations,
and actions over HTTP, and Live queries that push a new value the moment the
data behind them changes.

## This is educational

This is an unofficial demonstration written to see how far a Convex client can
be pushed in an unusual language. It is not a Convex SDK, it is not supported
by Convex, and it is not meant to be depended on.

## Start here

The canonical example is [examples/basics/main.bas](examples/basics/main.bas).
It takes one room from 0 to 1 and refuses to claim success unless every step
agrees: read the counter over HTTP, start a Live subscription *before* changing
anything, apply one idempotent mutation, then check that the Live update
matches what the mutation reported.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action | Earned (`http`) |
| Live queries over `/api/sync` | Earned (`live`) |
| Bearer token lifecycle (HTTP) | Passing |
| Bearer token on the Live socket | Not implemented |
| Docker `test` / `runtime` images | Passing, including against real backends |

`http` and `live` were awarded by the shared result evaluator from a clean,
exact-head run of `./run verify-all freebasic`: 31/31 conformance checks
passed against both the local self-hosted backend and the dedicated hosted
drift target, from the same built image.

## The basic example

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

## Docker verification

    ./run test freebasic            # style gate, unit tests, adapter probes
    ./run verify-example freebasic  # runs the example above against a unique room
    ./run verify freebasic          # adds shared black-box conformance

`test` proves the source compiles and that the language-local suites pass
inside the container. `verify-example` proves the exact example above produces
the expected transcript against a real deployment. `verify` adds the shared
NDJSON conformance run, and only that run may award a capability badge.

## How it is put together

| File | Responsibility |
| --- | --- |
| `client/core.bas` | Byte buffer, base64, SHA-1, UTF-8 validation, clock, CSPRNG |
| `client/json.bas` | Strict RFC 8259 parser and serializer |
| `client/net.bas` | POSIX sockets and OpenSSL TLS with deadlines |
| `client/http.bas` | Incremental, bounded HTTP/1.1 response reader |
| `client/ws.bas` | RFC 6455 handshake, masking, framing, close handshake |
| `client/convex.bas` | Convex envelopes and the single-owner Live sync worker |

POSIX and OpenSSL entry points are declared directly against their documented C
ABI rather than through a bundled FreeBASIC binding, so the client depends only
on symbols the runtime image actually ships. `client/tests/core_test.bas`
asserts the `pollfd`, `sockaddr_in`, and `addrinfo` layouts, so an ABI drift
fails a unit test instead of corrupting a connect call.

### Bounds

Every input path is bounded, because an unbounded one is how a demonstration
turns into a memory bug:

- HTTP response bodies and Live messages: 2 MiB
- HTTP response headers: 64 KiB across at most 100 headers
- Adapter input lines: 2 MiB; adapter output lines: 3 MiB
- JSON: depth 64, 200,000 values
- WebSocket frame assembly: 5 seconds; fragmented message assembly: 10 seconds
- Live delivery: at most 16 active subscriptions, 16 updates each, and 8 MiB
  across all subscription mailboxes

Live delivery is a mailbox this client owns, not a runtime queue. A consumer
that stops reading loses its own oldest updates first, and the global byte
budget evicts the oldest update anywhere once the total is exceeded. A count
bound alone would not be a memory bound when a single value can approach the
maximum frame size, so both are enforced.

## Protocol notes

Live uses the unversioned `/api/sync` WebSocket protocol pinned in
`manifest.yaml` under `syncProfile`. It is not a documented, stable Convex API,
and this client tracks one observed revision of it.

One worker thread owns the socket, the reconnect schedule, and the query-set
version. Subscriber threads take the manager mutex only to post intent and to
drain their own mailbox; they never touch the socket. A reconnect resends every
active `Add`, and a replay of an unchanged value is suppressed so the observable
sequence stays initial value, disconnect, change — not initial, replay, change.
Exponential backoff resets after a completed handshake, so a healthy connection
in the middle of a bad run does not inherit an old maximum delay.

## Conformance executable

`client/tests/conformance/` holds test-only infrastructure, not public client
code. It speaks NDJSON adapter protocol v1 over stdin/stdout, or over one
accepted TCP connection when `ADAPTER_LISTEN` is set, and calls the real client
for every operation. Its `debugDisconnect` command exists only in that build:
it is declared in `manifest.yaml` under `adapter.adapterOnlyCommands`, guarded
by the `CONVEX_ADAPTER` define, and the Docker build asserts the symbol is
absent from the example binary.

A single output gate owns every physical write and a per-subscription
generation counter. Unsubscribing or replacing a subscription bumps that
generation under the gate mutex, so an event dequeued a moment earlier cannot
cross the acknowledgement.

## Limitations and what is deferred

- **The toolchain builds itself.** Debian does not package FreeBASIC, so the
  Dockerfile builds `fbc` from the official bootstrap source release: a
  pre-generated-C bootstrap compiler builds first, then that compiler builds
  the real self-hosted `fbc` from FreeBASIC source. The archive is
  URL-and-SHA-256 pinned and the whole toolchain stage is now proven to build
  unattended, but getting there took two real upstream-makefile fixes: the
  bootstrap compiler's own `./bin` directory is never added to `PATH` before
  the makefile shells out to `fbc` by bare name for the second half of the
  build, and the compiler's own `.bas` sources need `-i inc` (their own
  `file.bi` and friends) that `ALLFBCFLAGS` never supplies on its own.
- **No standard formatter exists for FreeBASIC.**
  `client/tests/style_check.bas` enforces line length, indentation, tabs,
  trailing whitespace, line endings, and the absence of colon statement
  separators. It fails the build rather than rewriting source.
- **Live authentication is absent.** `setAuth` applies to the HTTP endpoints.
  The Live socket sends no `Authenticate` message, which is enough for the
  shared suite but is not a complete client.
- **HTTP connections are not pooled.** Every call opens one connection and
  sends `Connection: close`, which keeps framing unambiguous at the cost of a
  handshake per call.
- **DNS resolution is synchronous.** Socket, TLS, write, frame, and message
  operations have absolute deadlines, but the libc resolver can outlive the
  requested connect timeout on a broken host resolver.
- **JSON strings hold arbitrary bytes.** FreeBASIC strings are length counted,
  so an embedded NUL survives; `client/tests/core_test.bas` and
  `client/tests/json_test.bas` assert that rather than assuming it.
- **The Live owner thread needs an explicit stack size.** `ThreadCreate`'s
  default stack was not enough for a real subscription's call chain (TLS,
  JSON parsing, string handling) against a real backend: the canonical
  example segfaulted every time, right after its first successful HTTP
  query, with the crash address a handful of bytes from the stack pointer
  inside `libc.so.6` -- a stack-overflow guard page, not a null pointer or
  heap bug. It never reproduced against the local unit tests' scripted peer,
  whose fixture responses are smaller than a real deployment's. Both the
  Live owner and the adapter's relay thread now request an explicit 8 MiB.
- **The runtime image has to point OpenSSL at its own CA bundle.** This
  build's OpenSSL has `OPENSSLDIR=/usr/lib/ssl` compiled in, so
  `SSL_CTX_set_default_verify_paths` looks there by default and finds
  nothing, while the actual CA bundle is copied to Debian's conventional
  `/etc/ssl/certs/ca-certificates.crt`. The runtime image sets
  `SSL_CERT_FILE`/`SSL_CERT_DIR` explicitly so verification actually
  succeeds. The self-hosted backend is plain `http://`, so this only
  surfaced against the real hosted TLS endpoint.
