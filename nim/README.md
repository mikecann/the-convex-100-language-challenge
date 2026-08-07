# Convex from Nim

This educational demonstration uses a native Nim client to query a counter over HTTP, subscribe to the same query over Convex Live, apply an idempotent mutation, and verify the resulting update.

It is unofficial teaching material, not a production SDK or a published Nim package.

## Start here

Read the [canonical basic example](examples/basics/main.nim). It accepts a unique room as its first argument and prints the shared `0 -> 1` transcript only after HTTP and Live agree.

## What works

| Capability | Status | Evidence |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented in the client | Native bounded `std/httpclient` streaming, strict Convex response decoding, and structured errors |
| HTTP bearer authentication | Implemented in the client | `setAuth` and `CONVEX_AUTH_TOKEN` set or replace the Authorization header |
| Live subscriptions | Implemented; the canonical example completes its journey against a real deployment | One socket owner, Add replay across five real reconnects, transactional transitions, strict timestamp ordering, and a bounded delivery mailbox whose overflow is tested; shared conformance evidence is not claimed |

The capability list in `manifest.yaml` remains empty until the root-owned shared verifier records evidence for the reviewed source commit.

## Canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.nim -->
```text
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
    raise newException(ProtocolError, update.errorName & ": " & update.errorMessage)
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

## Docker verification

Run these on a genuine x86_64 Docker lane, not on a development Mac:

```sh
./run test nim
./run verify-example nim
```

The `test` target executes strict adapter-schema serialization, exact stdin and TCP adapter modes, atomic Live transition recovery, fragmented Unicode/control/oversize frames, a failed Add against a stalled peer, idle/flood/half-frame close deadlines, bounded HTTP streams, stale relay generations, count-plus-byte output limits, the bounded Live delivery mailbox and its overflow ordering, and the real stopped-reader process fixture. It also compiles the exact example, adapter, and hosted five-reconnect test. Run the reconnect executable with `CONVEX_URL` to prove the hosted five-barrier sequence. `verify-example` runs the exact canonical source from its pinned amd64 runtime image against a unique room. Root-owned `verify`, `verify-hosted`, and `verify-all` add shared black-box evidence later.

Each binary compiles in its own Docker layer. The commands and assertions are the same as one combined step; the split simply lets an emulated amd64 lane whose `gcc` crashes at random resume from the last good binary.

The build pins Nim 2.2.4, treeform/ws 0.6.0, the dependency archive checksum, and the non-scratch Debian runtime image digest. Checked-in build scripts patch Nim's native HTTP parser and treeform/ws before compilation, enforcing response/frame limits before unbounded materialisation, exposing failed writes, and handling control frames between fragments. Nim's asynchronous sockets default to `SafeDisconn`, which completes a write to a reset peer without raising; the patch drops that flag so a Live `Add` that never reached the server fails activation instead of being acknowledged. The final image remains based on that pinned Debian digest while pruning its filesystem to the exact native binary, approved POSIX commands, TLS libraries, OpenSSL configuration/provider modules, CA bundle, and name-resolution closure. It explicitly removes the `openssl` and `perl` commands and checks the complete final command surface in both runtime targets.

## Adapter and protocol notes

The test-only adapter speaks NDJSON protocol v1 over stdin/stdout or one TCP controller connection. It validates every command before field access, rejects additional properties and wrong types, omits absent optional fields, reports structured `FunctionError`, `ProtocolError`, and `TransportError` values, and reserves `debugDisconnect` for the adapter build.

A Transition from a real deployment also carries `clientClockSkew` and `serverTs` beside the four fields this client acts on. Both are accepted by name and ignored, so the field allow-list still rejects genuinely unknown fields.

The Live implementation validates a complete Transition into temporary state before commit, replays active Add operations after reconnect, suppresses unchanged rehydration, and abandons the entire connection after a frame deadline so consumed partial bytes are never reused. A global 16-record, 8 MiB Live-delivery budget complements each four-slot mailbox. One adapter output owner reserves at most 16 records and 10 MiB, invalidates stale relay generations in queue order, and applies a bounded write deadline.

## Limitations

This branch does not run root shared conformance or award badges. Live authentication, WebSocket mutations/actions, and `TransitionChunk` assembly are deferred. The pinned third-party WebSocket transport is patched during the Docker build.

The evidence for this head was produced on Apple Silicon through Docker Desktop's Rosetta `linux/amd64` emulation. The images are genuine `linux/amd64` — the build fails unless `uname -m` reports `x86_64` — but no native x86_64 host has executed this exact source commit, and Rosetta's `gcc` segfaults at random during compilation. Read every timing-sensitive result here as emulated rather than native.
