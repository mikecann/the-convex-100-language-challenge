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
