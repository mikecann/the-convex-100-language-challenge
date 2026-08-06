# Convex from Nim

This educational demonstration uses a native Nim client to query a counter over HTTP, subscribe to the same query over Convex Live, apply an idempotent mutation, and verify the resulting update.

It is unofficial teaching material, not a production SDK or a published Nim package.

## Start here

Read the [canonical basic example](examples/basics/main.nim). It accepts a unique room as its first argument and prints the shared `0 -> 1` transcript only after HTTP and Live agree.

## What works

| Capability | Status | Evidence |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented in the client | Native `std/httpclient`, strict Convex response decoding, and structured errors |
| HTTP bearer authentication | Implemented in the client | `setAuth` and `CONVEX_AUTH_TOKEN` set or replace the Authorization header |
| Live subscriptions | Partial, unearned | Native initial and mutation updates work, and five hosted `debugDisconnect` acknowledgements complete; the reconnect-plus-mutation probe still fails to deliver the post-reconnect Live update, so shared evidence is not claimed |

The capability list in `manifest.yaml` remains empty until the root-owned shared verifier records evidence for this exact source commit. This checkpoint is not a complete Live handoff: reconnect replay needs further repair and deterministic adversarial fixtures are still pending.

## Canonical example

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

## Docker verification

Run these on Bruce, not on a development Mac:

```sh
./run test nim
./run verify-example nim
```

The `test` target type-checks the Nim sources and focused JSON/timestamp regression source, compiles the exact example and NDJSON adapter, and exercises the adapter hello path. `verify-example` runs the exact canonical source from its minimal amd64 image against a unique room. Root-owned `verify`, `verify-hosted`, and `verify-all` add the shared black-box evidence later.

The build pins Nim 2.2.4, treeform/ws 0.6.0, the dependency archive checksum, and the Debian runtime image digest. A small checked-in build script patches treeform/ws to send the Convex client header and to handle Ping/Pong/Close control frames between fragmented data frames. TLS verification uses the runtime CA bundle.

## Adapter and protocol notes

The test-only adapter speaks NDJSON protocol v1 over stdin/stdout or one TCP controller connection. It omits absent optional fields, reports structured `FunctionError`, `ProtocolError`, and `TransportError` values, and reserves `debugDisconnect` for the adapter build. Live state is owned by one worker, while four two-megabyte newest-value slots bound each subscription's queued data.

The Live implementation validates state versions and little-endian uint64 timestamps, replays active Add operations after reconnect, suppresses unchanged rehydration, and retires a connection when a bounded read slice expires so a partial frame is never reused.

## Limitations

This branch does not run the root shared conformance pilots or award badges. Live authentication, WebSocket mutations/actions, and `TransitionChunk` assembly are deferred. The pinned third-party WebSocket transport is patched in the Docker build, and reconnect replay currently needs repair because the hosted reconnect-plus-mutation probe did not produce the changed Live value. The language-local deterministic adversarial fixture suite for all reconnect, stale-relay, frame-deadline, and stopped-reader cases still needs independent reviewer execution.
