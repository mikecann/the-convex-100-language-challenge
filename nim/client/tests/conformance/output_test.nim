## Real file-descriptor tests for the adapter output owner.  The stopped-reader
## case fills a pipe with near-maximum schema-valid events and never drains it.
##
## Nothing here returns a Nim `string` across a thread boundary.  Under
## `--mm:orc` such a payload belongs to the allocating thread's own region, and
## releasing it after that thread has exited corrupts the allocator, so the
## fixtures hand out plain bytes in buffers the main thread owns.

import std/[atomics, json, os, posix, strutils, times, unittest]
import ./adapter_output

const
  # Enough producers, rounds, and records that a queued payload is routinely
  # still in flight when the thread that allocated it exits.
  stormRounds = 64
  stormThreads = 4
  stormEventsPerThread = 4
  stormValueBytes = 1_024

type ReaderArgs = object
  descriptor: cint
  start: ptr Channel[bool]
  collected: ptr UncheckedArray[char]
  capacity: int
  length: ptr Atomic[int]

type PausedRelayArgs = object
  output: OutputProducer
  caseId: int
  generation: uint64
  dequeued: ptr Channel[bool]
  resume: ptr Channel[bool]
  result: ptr Channel[OutputResult]

type StormArgs = object
  output: OutputProducer
  events: int
  accepted: ptr Atomic[int]
  rejected: ptr Atomic[int]
  unexpected: ptr Atomic[int]

proc sharedChannel[T](capacity: int): ptr Channel[T] =
  ## Only channels of plain values are used here.  A channel move copies raw
  ## bits, so a message that owns heap storage would change owning thread
  ## without changing owning allocator.
  result = cast[ptr Channel[T]](allocShared0(sizeof(Channel[T])))
  result[].open(capacity)

proc sharedBuffer(capacity: int): ptr UncheckedArray[char] =
  ## Allocated and released by the test's own thread; worker threads only
  ## write into it.
  cast[ptr UncheckedArray[char]](allocShared0(capacity))

proc sharedAtomicInt(): ptr Atomic[int] =
  result = cast[ptr Atomic[int]](allocShared0(sizeof(Atomic[int])))
  result[].store(0)

proc bufferString(data: ptr UncheckedArray[char]; length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc readerWorker(args: ReaderArgs) {.thread.} =
  discard args.start[].recv()
  var total = 0
  var buffer = newString(64 * 1024)
  while total < args.capacity:
    let count = posix.read(args.descriptor, buffer[0].addr, buffer.len)
    if count <= 0:
      break
    let copied = min(int(count), args.capacity - total)
    copyMem(addr args.collected[total], buffer[0].addr, copied)
    total += copied
  args.length[].store(total)

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

proc stormProducer(args: StormArgs) {.thread.} =
  ## Publish, then exit at once.  Every record still queued at that moment is
  ## owned by a thread that no longer exists, which is precisely the lifetime
  ## a moved Nim string could not survive.
  for _ in 0 ..< args.events:
    let event = "{\"type\":\"subscription\",\"subscriptionId\":\"storm\"," &
      "\"value\":\"" & repeat("s", stormValueBytes) & "\"}\n"
    case args.output.enqueueEvent(event, "storm", 1, true)
    of outputAccepted:
      discard args.accepted[].fetchAdd(1)
    of outputBudgetExhausted:
      discard args.rejected[].fetchAdd(1)
    else:
      discard args.unexpected[].fetchAdd(1)

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

  test "records outlive the producer threads that queued them":
    # A producer thread that exits while its record is still queued used to
    # leave the owner releasing bytes through a dead thread's allocator.  The
    # loop below does that thousands of times with no sleep anywhere in it.
    var descriptors: array[2, cint]
    check pipe(descriptors) == 0
    let capacity = 8 * 1024 * 1024
    let collected = sharedBuffer(capacity)
    let length = sharedAtomicInt()
    let start = sharedChannel[bool](1)
    var reader: Thread[ReaderArgs]
    createThread(reader, readerWorker, ReaderArgs(descriptor: descriptors[0],
      start: start, collected: collected, capacity: capacity, length: length))
    start[].send(true)
    let output = newAdapterOutput(descriptors[1], false)
    let producer = output.producer
    check producer.activateRelay("storm", 1) == outputAccepted
    let accepted = sharedAtomicInt()
    let rejected = sharedAtomicInt()
    let unexpected = sharedAtomicInt()
    for _ in 1 .. stormRounds:
      var producers: array[stormThreads, Thread[StormArgs]]
      for index in 0 ..< stormThreads:
        createThread(producers[index], stormProducer, StormArgs(
          output: producer, events: stormEventsPerThread, accepted: accepted,
          rejected: rejected, unexpected: unexpected))
      # Joining inside the round is the whole point: every producer is gone
      # while the owner may still hold, write, and release the bytes it made.
      for index in 0 ..< stormThreads:
        joinThread(producers[index])
    check unexpected[].load == 0
    check accepted[].load + rejected[].load ==
      stormRounds * stormThreads * stormEventsPerThread
    check accepted[].load > 0
    # Every reservation returns to exactly zero while the owner is still open.
    check waitUntil(proc (): bool = output.stats().records == 0, 10.0)
    let drained = output.stats()
    check drained.records == 0
    check drained.bytes == 0
    check drained.relayRecords == 0
    check drained.relayBytes == 0
    check not output.failed()
    # The owner still accepts and delivers after the storm.
    check producer.enqueueEvent(
      "{\"type\":\"subscription\",\"subscriptionId\":\"storm\"," &
      "\"value\":\"recovered\"}\n", "storm", 1, true) == outputAccepted
    check producer.invalidateRelay("storm", 1) == outputAccepted
    check output.close()
    let afterClose = output.stats()
    check afterClose.records == 0
    check afterClose.bytes == 0
    check afterClose.relayRecords == 0
    check afterClose.relayBytes == 0
    discard posix.close(descriptors[1])
    joinThread(reader)
    discard posix.close(descriptors[0])
    let transcript = bufferString(collected, length[].load)
    check transcript.contains("\"value\":\"recovered\"")
    check transcript.count("\"subscriptionId\":\"storm\"") == accepted[].load + 1
    output.releaseAdapterOutput()
    deallocShared(collected)
    deallocShared(length)
    deallocShared(accepted)
    deallocShared(rejected)
    deallocShared(unexpected)

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
    check afterClose.relayRecords == 0
    check afterClose.relayBytes == 0
    discard posix.close(descriptors[1])
    discard posix.close(descriptors[0])

  test "a reader can resume before the deadline without corrupting output":
    var descriptors: array[2, cint]
    check pipe(descriptors) == 0
    let capacity = 8 * 1024 * 1024
    let collected = sharedBuffer(capacity)
    let length = sharedAtomicInt()
    let start = sharedChannel[bool](1)
    var reader: Thread[ReaderArgs]
    createThread(reader, readerWorker, ReaderArgs(descriptor: descriptors[0],
      start: start, collected: collected, capacity: capacity, length: length))
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
    joinThread(reader)
    discard posix.close(descriptors[0])
    let transcript = bufferString(collected, length[].load)
    check transcript.contains("\"subscriptionId\":\"resume\"")
    check transcript.contains("\"id\":\"after\"")
    check not output.failed()
    deallocShared(collected)
    deallocShared(length)
