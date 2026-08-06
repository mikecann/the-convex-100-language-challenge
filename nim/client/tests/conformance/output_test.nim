## Real file-descriptor tests for the adapter output owner.  The stopped-reader
## case fills a pipe with near-maximum schema-valid events and never drains it.

import std/[json, os, posix, strutils, times, unittest]
import ./adapter_output

type ReaderArgs = object
  descriptor: cint
  start: ptr Channel[bool]
  data: ptr Channel[string]

type PausedRelayArgs = object
  output: OutputProducer
  caseId: int
  generation: uint64
  dequeued: ptr Channel[bool]
  resume: ptr Channel[bool]
  result: ptr Channel[OutputResult]

proc sharedChannel[T](capacity: int): ptr Channel[T] =
  result = cast[ptr Channel[T]](allocShared0(sizeof(Channel[T])))
  result[].open(capacity)

proc readerWorker(args: ReaderArgs) {.thread.} =
  discard args.start[].recv()
  var collected = ""
  var buffer = newString(64 * 1024)
  while true:
    let count = posix.read(args.descriptor, buffer[0].addr, buffer.len)
    if count <= 0:
      break
    collected.add(buffer[0 ..< int(count)])
  args.data[].send(collected)

proc pausedRelay(args: PausedRelayArgs) {.thread.} =
  ## This barrier represents the exact dangerous point: the old relay owns a
  ## dequeued update but has not handed it to the output owner yet.
  args.dequeued[].send(true)
  discard args.resume[].recv()
  let subscriptionId = if args.caseId == 1: "unsub" else: "same"
  let value = if args.caseId == 1: "stale-unsubscribe" else: "stale-replace"
  args.result[].send(args.output.enqueueEvent(
    "{\"type\":\"subscription\",\"subscriptionId\":\"" &
      subscriptionId & "\",\"value\":\"" & value & "\"}\n",
    subscriptionId, args.generation, true))

proc startPausedRelay(output: OutputProducer; caseId: int;
    generation: uint64): tuple[worker: ptr Thread[PausedRelayArgs],
    resume: ptr Channel[bool], result: ptr Channel[OutputResult]] =
  let dequeued = sharedChannel[bool](1)
  result.resume = sharedChannel[bool](1)
  result.result = sharedChannel[OutputResult](1)
  result.worker = cast[ptr Thread[PausedRelayArgs]](
    allocShared0(sizeof(Thread[PausedRelayArgs])))
  createThread(result.worker[], pausedRelay, PausedRelayArgs(output: output,
    caseId: caseId, generation: generation, dequeued: dequeued,
    resume: result.resume, result: result.result))
  discard dequeued[].recv()

proc waitUntil(predicate: proc (): bool; timeoutSeconds: float): bool =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if predicate():
      return true
    os.sleep(1)

suite "Nim adapter output owner":
  test "paused stale relays cannot cross unsubscribe or replacement acks":
    var descriptors: array[2, cint]
    check pipe(descriptors) == 0
    let output = newAdapterOutput(descriptors[1], false)
    let producer = output.producer
    check producer.activateRelay("unsub", 1) == outputAccepted
    var unsubscribeRelay = startPausedRelay(producer, 1, 1)
    check producer.invalidateRelay("unsub", 1) == outputAccepted
    check producer.enqueueEvent("{\"id\":\"unsub\",\"type\":\"ack\"}\n",
      "", 0, false) == outputAccepted
    unsubscribeRelay.resume[].send(true)
    check unsubscribeRelay.result[].recv() == outputAccepted
    joinThread(unsubscribeRelay.worker[])
    deallocShared(unsubscribeRelay.worker)

    check producer.activateRelay("same", 10) == outputAccepted
    var replacementRelay = startPausedRelay(producer, 2, 10)
    check producer.invalidateRelay("same", 10) == outputAccepted
    check producer.activateRelay("same", 11) == outputAccepted
    check producer.enqueueEvent(
      "{\"id\":\"replace\",\"type\":\"ack\"}\n",
      "", 0, false) == outputAccepted
    replacementRelay.resume[].send(true)
    check replacementRelay.result[].recv() == outputAccepted
    joinThread(replacementRelay.worker[])
    deallocShared(replacementRelay.worker)
    check producer.enqueueEvent(
      "{\"type\":\"subscription\",\"subscriptionId\":\"same\",\"value\":\"current\"}\n",
      "same", 11, true) == outputAccepted
    check output.close()
    check producer.enqueueEvent("{\"type\":\"error\"}\n", "", 0,
      false) == outputClosed
    discard posix.close(descriptors[1])
    var buffer = newString(4_096)
    let count = posix.read(descriptors[0], buffer[0].addr, buffer.len)
    discard posix.close(descriptors[0])
    check count > 0
    buffer.setLen(count)
    check buffer.contains("\"id\":\"unsub\"")
    check buffer.contains("\"id\":\"replace\"")
    check not buffer.contains("stale-unsubscribe")
    check not buffer.contains("stale-replace")
    check buffer.contains("\"value\":\"current\"")

  test "count and encoded-byte reservations bound a stopped reader":
    var descriptors: array[2, cint]
    check pipe(descriptors) == 0
    let output = newAdapterOutput(descriptors[1], false)
    let producer = output.producer
    # The owner discards events whose relay generation is not active, so the
    # fixture must activate this relay exactly as a real subscription does.
    # Without it the writer would never reach the pipe and never block.
    check producer.activateRelay("large", 1) == outputAccepted
    let value = repeat("x", (2 * 1024 * 1024) - 8_192)
    let event = $(%*{
      "type": "subscription",
      "subscriptionId": "large",
      "value": value
    }) & "\n"
    var accepted = 0
    while true:
      let outcome = producer.enqueueEvent(event, "large", 1, true)
      if outcome != outputAccepted:
        check outcome in {outputBudgetExhausted, outputFailed}
        break
      accepted.inc
    check accepted > 0
    let beforeClose = output.stats()
    check beforeClose.records <= adapterOutputMaxRecords
    check beforeClose.bytes <= adapterOutputMaxBytes
    check waitUntil(proc (): bool = output.failed(), 2.0)
    check output.close()
    let afterClose = output.stats()
    check afterClose.records == 0
    check afterClose.bytes == 0
    discard posix.close(descriptors[1])
    discard posix.close(descriptors[0])

  test "a reader can resume before the deadline without corrupting output":
    var descriptors: array[2, cint]
    check pipe(descriptors) == 0
    let start = sharedChannel[bool](1)
    let data = sharedChannel[string](1)
    var reader: Thread[ReaderArgs]
    createThread(reader, readerWorker,
      ReaderArgs(descriptor: descriptors[0], start: start, data: data))
    let output = newAdapterOutput(descriptors[1], false)
    let producer = output.producer
    check producer.activateRelay("resume", 1) == outputAccepted
    let value = repeat("r", (2 * 1024 * 1024) - 8_192)
    let event = $(%*{
      "type": "subscription",
      "subscriptionId": "resume",
      "value": value
    }) & "\n"
    check producer.enqueueEvent(event, "resume", 1, true) == outputAccepted
    start[].send(true)
    check producer.enqueueEvent("{\"id\":\"after\",\"type\":\"ack\"}\n",
      "", 0, false) == outputAccepted
    check output.close()
    discard posix.close(descriptors[1])
    let collected = data[].recv()
    joinThread(reader)
    discard posix.close(descriptors[0])
    check collected.contains("\"subscriptionId\":\"resume\"")
    check collected.contains("\"id\":\"after\"")
    check not output.failed()
