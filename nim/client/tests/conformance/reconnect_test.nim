## Deterministic real-socket Live acceptance test used by the Nim Docker image.
## The debugDisconnect acknowledgement is deliberately the readiness barrier,
## so this test never sleeps to guess when Add replay has finished.

import std/[json, os, strformat, times]
import ../../convex

proc fail(message: string) =
  quit(message, 1)

proc countFrom(update: LiveUpdate): float =
  if update.isError:
    fail(update.errorName & ": " & update.errorMessage)
  let value = parseJson(update.value)
  if not value.hasKey("count"):
    fail("Live value omitted count")
  return integralCount(value["count"])

proc main() =
  let deployment = getEnv("CONVEX_URL")
  if deployment.len == 0:
    fail("CONVEX_URL is required")
  let room = "nim-reconnect-" & $epochTime()
  let client = newClient(deployment)
  defer: client.close()
  let subscription = client.subscribe("demo:state", %*{"room": room})
  defer: subscription.close()

  if countFrom(subscription.nextUpdate()) != 0:
    fail("expected initial Live count 0")

  ## Each acknowledgement means the old socket is retired and the replacement
  ## handshake plus active Add replay have completed on the single owner.
  for attempt in 1 .. 5:
    let errorMessage = client.debugDisconnectForAdapter()
    if errorMessage.len > 0:
      fail(fmt"disconnect {attempt} failed: {errorMessage}")

  ## Only after all five barriers does the one external mutation happen.  A
  ## value of 1 proves the final replay left this subscription active.
  let mutation = client.mutation("demo:increment", %*{
    "room": room,
    "language": "nim",
    "runId": fmt"nim-reconnect-{epochTime()}"
  })
  if not mutation.value["applied"].getBool:
    fail("reconnect mutation was not applied")
  if integralCount(mutation.value["state"]["count"]) != 1:
    fail("reconnect mutation did not produce count 1")
  if countFrom(subscription.nextUpdate()) != 1:
    fail("post-reconnect Live value was not 1")
  echo "five reconnects: initial 0 -> Live 1"

main()
