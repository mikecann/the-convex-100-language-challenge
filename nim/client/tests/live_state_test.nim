import std/[json, strutils, unittest]
import ../convex

const
  zeroTimestamp = "AAAAAAAAAAA="
  oneTimestamp = "AQAAAAAAAAA="
  twoTimestamp = "AgAAAAAAAAA="

proc version(timestamp: string): JsonNode =
  %*{"querySet": 0, "identity": 0, "ts": timestamp}

proc transition(endTimestamp: string; modifications: JsonNode): string =
  $(%*{
    "type": "Transition",
    "startVersion": version(zeroTimestamp),
    "endVersion": version(endTimestamp),
    "modifications": modifications
  })

suite "Nim Live transition transaction":
  test "a later malformed modification commits no earlier value or timestamp":
    let malformed = transition(twoTimestamp, %*[
      {"type": "QueryUpdated", "queryId": 0,
        "value": {"count": 9}, "logLines": []},
      {"type": "QueryFailed", "queryId": 0,
        "errorData": {"code": "missing-message"}, "logLines": []}
    ])
    let inspected = probeTransition("{\"count\":0}", zeroTimestamp, malformed)
    check not inspected.accepted
    check inspected.lastValue == "{\"count\":0}"
    check inspected.lastSuccess
    check inspected.maximumTimestamp == zeroTimestamp
    check inspected.deliveryValue.len == 0

  test "the same subscription accepts a later wholly valid transition":
    let valid = transition(oneTimestamp, %*[
      {"type": "QueryUpdated", "queryId": 0,
        "value": {"count": 1}, "logLines": ["recovered"]}
    ])
    let inspected = probeTransition("{\"count\":0}", zeroTimestamp, valid)
    check inspected.accepted
    check inspected.lastValue == "{\"count\":1}"
    check inspected.deliveryValue == "{\"count\":1}"
    check inspected.maximumTimestamp == oneTimestamp

  test "wrong diagnostics and out-of-range IDs are rejected atomically":
    let wrongLogs = transition(oneTimestamp, %*[
      {"type": "QueryUpdated", "queryId": 0,
        "value": {"count": 1}, "logLines": "not-an-array"}
    ])
    check not probeTransition("{\"count\":0}", zeroTimestamp,
      wrongLogs).accepted
    let badId = transition(oneTimestamp,
      parseJson("[{\"type\":\"QueryUpdated\",\"queryId\":4294967296," &
        "\"value\":0,\"logLines\":[]}]") )
    check not probeTransition("{\"count\":0}", zeroTimestamp, badId).accepted

  test "unexpected fields and malformed version shapes commit nothing":
    let extra = transition(oneTimestamp, %*[
      {"type": "QueryUpdated", "queryId": 0, "value": {"count": 1},
        "logLines": [], "unexpected": true}
    ])
    let extraResult = probeTransition("{\"count\":0}", zeroTimestamp, extra)
    check not extraResult.accepted
    check extraResult.lastValue == "{\"count\":0}"
    check extraResult.maximumTimestamp == zeroTimestamp
    let badVersion = $(%*{
      "type": "Transition",
      "startVersion": version(zeroTimestamp),
      "endVersion": {"querySet": 1.0, "identity": 0, "ts": oneTimestamp},
      "modifications": newJArray()
    })
    check not probeTransition("{\"count\":0}", zeroTimestamp,
      badVersion).accepted

  test "a deployment transition carrying clock diagnostics is accepted":
    ## A real deployment sends clientClockSkew and serverTs beside the four
    ## fields this client acts on, and stamps each modification with a
    ## journal.  Rejecting any of them broke the hosted example while every
    ## minimal fixture here kept passing.
    let deployment = $(%*{
      "type": "Transition",
      "startVersion": version(zeroTimestamp),
      "endVersion": version(oneTimestamp),
      "modifications": [
        {"type": "QueryUpdated", "queryId": 0, "value": {"count": 1},
          "logLines": [], "journal": nil}
      ],
      "clientClockSkew": 0.0,
      "serverTs": oneTimestamp
    })
    let inspected = probeTransition("{\"count\":0}", zeroTimestamp, deployment)
    check inspected.accepted
    check inspected.deliveryValue == "{\"count\":1}"

  test "a genuinely unknown transition field is still rejected":
    let unknown = $(%*{
      "type": "Transition",
      "startVersion": version(zeroTimestamp),
      "endVersion": version(oneTimestamp),
      "modifications": newJArray(),
      "somethingElse": true
    })
    check not probeTransition("{\"count\":0}", zeroTimestamp, unknown).accepted

suite "Nim Live delivery mailbox":
  test "a full mailbox drops the newest value and reports it in order":
    let mailbox = newMailboxProbe()
    for index in 0 ..< liveQueueSlots:
      mailbox.sendUpdateProbe(LiveUpdate(value: $index, logs: "[]"))
    ## The slot count is the whole bound, so this newest value is dropped
    ## rather than overwriting a value the consumer has not read yet.
    mailbox.sendUpdateProbe(LiveUpdate(value: "dropped", logs: "[]"))
    for index in 0 ..< liveQueueSlots:
      let update = mailbox.recvUpdateProbe()
      check not update.isError
      check update.value == $index
    ## Only after every buffered value does the consumer learn about the drop.
    let overflow = mailbox.recvUpdateProbe()
    check overflow.isError
    check overflow.errorName == "TransportError"
    check overflow.errorMessage == "Live delivery buffer overflowed"
    ## The notice is reported once, and the drained mailbox accepts again.
    mailbox.sendUpdateProbe(LiveUpdate(value: "after", logs: "[]"))
    let recovered = mailbox.recvUpdateProbe()
    check not recovered.isError
    check recovered.value == "after"
    mailbox.releaseMailboxProbe()

  test "a value beyond the global byte budget is refused, not queued":
    let mailbox = newMailboxProbe()
    ## One value larger than the whole 8 MiB delivery budget can never be
    ## reserved, so it must be dropped instead of materialised in a slot.
    mailbox.sendUpdateProbe(LiveUpdate(value: repeat("x", liveGlobalQueueBytes),
      logs: "[]"))
    let overflow = mailbox.recvUpdateProbe()
    check overflow.isError
    check overflow.errorName == "TransportError"
    mailbox.releaseMailboxProbe()
