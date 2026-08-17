<img src="logo.png" alt="Nim crown logo" width="160">
<!-- Logo source: https://raw.githubusercontent.com/nim-lang/assets/master/Art/logo-crown.png -->

# Nim

[Nim](https://nim-lang.org/) is a statically typed, compiled systems language with indentation-based syntax that will feel familiar to a Python developer. It can generate small native executables without a virtual machine, supports C, C++, and JavaScript backends, and deliberately mixes ideas from Python, Ada, and Modula. The project began under the name Nimrod, [became Nim in 2014](https://nim-lang.org/blog/2014/12/29/version-0102-released.html), and reached [version 1.0 in 2019](https://nim-lang.org/blog/2019/09/23/version-100-released.html).

Today Nim is a niche alternative for command-line tools, games, embedded work, and other systems software where developers want compact source and native executables. This repository uses it to build a native Convex client. The client is educational and unofficial, not a production SDK or a published Nim package.

## Getting Started

Read the [canonical basic example](examples/basics/main.nim) to see an HTTP query, a Live subscription, an idempotent mutation, and the resulting reactive update. From the repository root, run the exact example in its pinned Docker environment:

```sh
./run verify-example nim
```

The command supplies a fresh room, runs `/usr/local/bin/convex-example` from the minimal `linux/amd64` image, and checks the shared `0 -> 1` output. It is an example check, not the full conformance suite.

## Interesting Parts

### A macro writes the JSON tree, before your program even runs

Nim's standard `json` module ships `%*`, a macro that takes what looks like an ordinary curly-brace literal and rewrites it, at compile time, into the calls that build a `JsonNode`. There is no dictionary type hiding underneath — the compiler has already turned the syntax into tree-building code by the time it runs.

```nim
# TypeScript: await client.mutation("demo:increment", { room, language, runId })
let mutation = client.mutation("demo:increment", %*{
  "room": room,
  "language": "nim",
  "runId": fmt"nim-{getTime().toUnix}-{epochTime()}"
})
```

The literal reads like a typed object, but everything past the macro is dynamic JSON again — Nim's compile-time checking stops exactly at the boundary the macro draws.

### A Live update is something you pull, not something that calls you

There's no callback here, and no component to rerender. `subscribe` hands back a subscription, and `nextUpdate()` blocks the calling thread until the single worker that owns the WebSocket delivers the next value — the very first call simply returns whatever is current right now.

```nim
let subscription = client.subscribe("demo:state", %*{"room": room})
defer: subscription.close() # this program owns the subscription's lifecycle

let initial = subscription.nextUpdate() # first delivery is the current value
echo parseJson(initial.value)["count"]

# TypeScript: useQuery reruns your component; here the call just blocks
let updated = subscription.nextUpdate()
echo parseJson(updated.value)["count"]
```

Reactivity is a loop you write yourself here, not a hook React writes for you.

### One `!=` catches a NaN before it reaches your counter

JSON has exactly one numeric type, so every count Convex sends back arrives as a 64-bit float. Rather than cast it straight to an integer, the client's `integralCount` leans on one of floating point's oldest tricks — a NaN is the only float that is never equal to itself — alongside a `floor` check and JavaScript's own safe-integer ceiling.

```nim
proc integralCount*(node: JsonNode): float =
  if node.kind notin {JInt, JFloat}:
    raise newException(ValueError, "count must be a JSON number")
  let value = node.getFloat
  if value != value or value != floor(value) or
      abs(value) > 9_007_199_254_740_991.0:
    raise newException(ValueError, "count must be finite and integral")
  return value
```

Counting up from `count` to `count + 1` only makes sense once you know `count` was never a fraction to begin with.

## Status

| Capability | Status | Evidence |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented in the client | Native bounded `std/httpclient` streaming, strict Convex response decoding, and structured errors |
| HTTP bearer authentication | Implemented in the client | `setAuth` and `CONVEX_AUTH_TOKEN` set or replace the Authorization header |
| Live subscriptions | Verified by shared local and hosted conformance | One socket owner, Add replay across five real reconnects, transactional transitions, strict timestamp ordering, and a bounded delivery mailbox whose overflow is tested |

The root-owned shared verifier earned both HTTP and Live for the reviewed source commit. These are the capabilities recorded in `manifest.yaml`; this README edit does not claim a new verification run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.nim -->
```nim
## A small, runnable journey through the native Nim Convex client.

import std/[json, os, strformat, times]
import ../../client/convex

proc expectCount(operation: string; actual, expected: float) =
  if actual != expected:
    raise newException(ValueError,
      fmt"{operation} count was {actual}, expected {expected}")

proc countText(value: float): string =
  $int(value)

proc valueFrom(update: LiveUpdate): JsonNode =
  ## A QueryFailed update is an explicit failure, not a missing value.  The
  ## example stops rather than accidentally printing a successful transcript.
  if update.isError:
    raise newException(ProtocolError, update.errorName & ": " &
        update.errorMessage)
  parseJson(update.value)

proc main() =
  let deployment = getEnv("CONVEX_URL")
  if deployment.len == 0:
    quit("CONVEX_URL is required", 2)
  let room = if paramCount() > 0: paramStr(1) else: "nim-example"
  let client = newClient(deployment)
  defer: client.close()

  ## Query the unique room over Convex's documented HTTP query endpoint.
  let state = client.query("demo:state", %*{"room": room})
  let count = integralCount(state.value["count"])
  echo "current count: " & countText(count)

  ## Start Live before the mutation, so its initial value can be compared with
  ## the HTTP snapshot rather than being mistaken for the later update.
  let subscription = client.subscribe("demo:state", %*{"room": room})
  defer: subscription.close()
  let initial = valueFrom(subscription.nextUpdate())
  let initialCount = integralCount(initial["count"])
  if initialCount != count:
    raise newException(ValueError, "Live initial value disagreed with HTTP query")
  echo "live initial count: " & countText(initialCount)

  ## The idempotency key makes a retry of this mutation safe for this room.
  let mutation = client.mutation("demo:increment", %*{
    "room": room,
    "language": "nim",
    "runId": fmt"nim-{getTime().toUnix}-{epochTime()}"
  })
  if not mutation.value["applied"].getBool:
    raise newException(ValueError, "mutation was not applied")
  echo "mutation applied: true"
  let mutationCount = integralCount(mutation.value["state"]["count"])
  expectCount("mutation", mutationCount, count + 1)
  echo "mutation count: " & countText(mutationCount)

  ## The single Live owner receives the resulting Transition and publishes the
  ## changed value after committing its version and timestamp.
  let updated = valueFrom(subscription.nextUpdate())
  let updatedCount = integralCount(updated["count"])
  expectCount("updated Live value", updatedCount, count + 1)
  echo "live updated count: " & countText(updatedCount)
  echo "verified count: " & countText(count) & " -> " & countText(updatedCount)

main()
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native Nim implementation. Convex-specific HTTP envelopes, response errors, Live query bookkeeping, reconnection, and transition validation live in [the client](client/convex.nim). Ordinary HTTP, TLS, and JSON use Nim's standard library. WebSocket transport comes from `treeform/ws` 0.6.0, pinned by archive checksum in the Dockerfile. It does not delegate Convex behaviour to a JavaScript client, the Convex CLI, `curl`, or another language runtime.

The Docker build uses Nim 2.2.4 with threads and the [ORC memory manager](https://nim-lang.org/1.6.20/mm.html). One worker owns the Live socket while the caller consumes updates from a deliberately small mailbox. Crossing that thread boundary turned out to be the particularly Nim-specific problem: the implementation stores delivery strings in C-allocated memory so they are not accidentally freed through the wrong thread's allocator. Each subscription has four slots, and all subscriptions together are limited to 16 records and 8 MiB. If a slow consumer fills the mailbox, the newest update is dropped and a `TransportError` is delivered after the already-buffered values.

The build patches both Nim's HTTP parser and the pinned WebSocket source before compiling. Those patches reject oversized data before it is fully materialised, make failed socket writes observable, bound handshakes and frames, and correctly accept control frames between message fragments. The Live state machine validates a whole server transition before committing any part of it, replays active subscriptions after reconnect, and suppresses an unchanged value during rehydration.

For local source, compilation, and language-specific tests, use:

```sh
./run test nim
```

That Docker target compiles the canonical example and test-only conformance adapter, then runs focused tests for decoding, HTTP bounds, Live state, fragmented frames, reconnect behaviour, shutdown deadlines, and bounded output. Full local and hosted conformance are separate root-owned evidence runs.

## Known Issues

1. Live authentication is not implemented. Bearer authentication applies only to HTTP calls.
2. Mutations and actions use HTTP. The Live socket supports subscriptions, not WebSocket mutations or actions.
3. `TransitionChunk` assembly is deferred, so the client handles complete `Transition` messages only.
4. The exact awarded build ran as genuine `linux/amd64` under Docker Desktop's Rosetta emulation on Apple Silicon, not on a native x86_64 host. Heavy Nim compilation can hit unrelated `gcc` crashes in that emulated lane.
