## One bounded owner for every adapter stdout or TCP write.
##
## Producers reserve both a record and its encoded byte cost before enqueueing.
## A stopped controller therefore causes a bounded write failure, never an
## unbounded queue or a command thread parked inside send while holding a lock.

import std/[atomics, locks, os, posix, tables, times]

# std/posix exports MSG_NOSIGNAL but not MSG_DONTWAIT.  The TCP controller
# descriptor is also the reader's descriptor, so this write path must ask for
# one non-blocking send instead of setting O_NONBLOCK on the shared fd.
let MSG_DONTWAIT {.importc: "MSG_DONTWAIT", header: "<sys/socket.h>".}: cint

const
  maxAdapterEventBytes* = 2 * 1024 * 1024 + 64 * 1024
  adapterOutputMaxRecords* = 16
  adapterOutputMaxBytes* = 10 * 1024 * 1024
  adapterRelayMaxRecords = 12
  adapterRelayMaxBytes = 9 * 1024 * 1024
  adapterOutputRecordOverhead = 1_024
  adapterWriteDeadlineMilliseconds = 500
  # At most sixteen reserved records can each consume one write deadline.
  # This deadline is therefore a completion bound, not a best-effort timeout.
  adapterCloseDeadlineMilliseconds =
    adapterOutputMaxRecords * adapterWriteDeadlineMilliseconds + 1_000

type
  OutputResult* = enum
    outputAccepted
    outputTooLarge
    outputBudgetExhausted
    outputClosed
    outputFailed

  OutputItemKind = enum
    itemEvent
    itemActivateRelay
    itemInvalidateRelay

  OutputItem = object
    kind: OutputItemKind
    encoded: string
    subscriptionId: string
    generation: uint64
    cost: int
    relayData: bool

  OutputBudget = object
    lock: Lock
    records: int
    bytes: int
    relayRecords: int
    relayBytes: int
    accepting: bool
    failed: bool

  OutputWriterArgs = object
    queue: ptr Channel[OutputItem]
    budget: ptr OutputBudget
    stop: ptr Atomic[bool]
    abort: ptr Atomic[bool]
    done: ptr Atomic[bool]
    descriptor: cint
    socketOutput: bool

  OutputProducer* = object
    queue: ptr Channel[OutputItem]
    budget: ptr OutputBudget
    abort: ptr Atomic[bool]

  AdapterOutput* = ref object
    producer*: OutputProducer
    stop: ptr Atomic[bool]
    done: ptr Atomic[bool]
    worker: Thread[OutputWriterArgs]
    joined: bool

  OutputStats* = object
    records*: int
    bytes*: int
    relayRecords*: int
    relayBytes*: int

proc sharedAtomic(initial: bool): ptr Atomic[bool] =
  result = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
  result[].store(initial)

proc sharedQueue(): ptr Channel[OutputItem] =
  result = cast[ptr Channel[OutputItem]](allocShared0(sizeof(Channel[OutputItem])))
  result[].open(adapterOutputMaxRecords)

proc sharedBudget(): ptr OutputBudget =
  result = cast[ptr OutputBudget](allocShared0(sizeof(OutputBudget)))
  initLock(result[].lock)
  result[].accepting = true

proc release(budget: ptr OutputBudget; item: OutputItem) {.gcsafe.} =
  acquire(budget[].lock)
  budget[].records.dec
  budget[].bytes -= item.cost
  if item.relayData:
    budget[].relayRecords.dec
    budget[].relayBytes -= item.cost
  release(budget[].lock)

proc markFailed(budget: ptr OutputBudget) {.gcsafe.} =
  acquire(budget[].lock)
  budget[].failed = true
  budget[].accepting = false
  release(budget[].lock)

proc enqueue(output: OutputProducer; item: OutputItem): OutputResult {.gcsafe.} =
  acquire(output.budget[].lock)
  defer: release(output.budget[].lock)
  if output.budget[].failed:
    return outputFailed
  if not output.budget[].accepting:
    return outputClosed
  if output.budget[].records >= adapterOutputMaxRecords or
      item.cost > adapterOutputMaxBytes - output.budget[].bytes:
    return outputBudgetExhausted
  if item.relayData and
      (output.budget[].relayRecords >= adapterRelayMaxRecords or
      item.cost > adapterRelayMaxBytes - output.budget[].relayBytes):
    return outputBudgetExhausted
  output.budget[].records.inc
  output.budget[].bytes += item.cost
  if item.relayData:
    output.budget[].relayRecords.inc
    output.budget[].relayBytes += item.cost
  if not output.queue[].trySend(item):
    output.budget[].records.dec
    output.budget[].bytes -= item.cost
    if item.relayData:
      output.budget[].relayRecords.dec
      output.budget[].relayBytes -= item.cost
    return outputBudgetExhausted
  result = outputAccepted

proc enqueueEvent*(output: OutputProducer; encoded, subscriptionId: string;
    generation: uint64; relayData: bool): OutputResult {.gcsafe.} =
  if encoded.len > maxAdapterEventBytes:
    return outputTooLarge
  result = output.enqueue(OutputItem(kind: itemEvent, encoded: encoded,
    subscriptionId: subscriptionId, generation: generation,
    cost: encoded.len + adapterOutputRecordOverhead, relayData: relayData))

proc activateRelay*(output: OutputProducer; subscriptionId: string;
    generation: uint64): OutputResult =
  output.enqueue(OutputItem(kind: itemActivateRelay,
    subscriptionId: subscriptionId, generation: generation,
    cost: adapterOutputRecordOverhead))

proc invalidateRelay*(output: OutputProducer; subscriptionId: string;
    generation: uint64): OutputResult =
  output.enqueue(OutputItem(kind: itemInvalidateRelay,
    subscriptionId: subscriptionId, generation: generation,
    cost: adapterOutputRecordOverhead))

proc millisecondsRemaining(deadline: float): cint {.gcsafe.} =
  let remaining = int((deadline - epochTime()) * 1_000.0)
  if remaining <= 0:
    return 0
  result = cint(min(remaining, adapterWriteDeadlineMilliseconds))

proc writeWithDeadline(args: OutputWriterArgs; value: string): bool {.gcsafe.} =
  if not args.socketOutput:
    let originalFlags = fcntl(args.descriptor, F_GETFL)
    if originalFlags < 0 or
        fcntl(args.descriptor, F_SETFL, originalFlags or O_NONBLOCK) < 0:
      return false
  let deadline = epochTime() + adapterWriteDeadlineMilliseconds.float / 1_000.0
  var offset = 0
  while offset < value.len:
    let address = unsafeAddr value[offset]
    let written = if args.socketOutput:
      posix.send(SocketHandle(args.descriptor), address, value.len - offset,
        MSG_NOSIGNAL or MSG_DONTWAIT)
    else:
      posix.write(args.descriptor, address, value.len - offset)
    if written > 0:
      offset += written
      continue
    if written == 0:
      return false
    if errno == EINTR:
      continue
    if errno != EAGAIN and errno != EWOULDBLOCK:
      return false
    var descriptor = TPollfd(fd: args.descriptor, events: POLLOUT)
    let timeout = millisecondsRemaining(deadline)
    if timeout == 0 or poll(addr descriptor, Tnfds(1), timeout) <= 0 or
        (descriptor.revents and (POLLERR or POLLHUP)) != 0:
      return false
  result = true

proc outputWriter(args: OutputWriterArgs) {.thread.} =
  var activeRelays = initTable[string, uint64]()
  var failed = false
  while true:
    if args.abort[].load and not failed:
      failed = true
      markFailed(args.budget)
      if args.socketOutput:
        discard posix.shutdown(SocketHandle(args.descriptor), SHUT_RDWR)
    let received = args.queue[].tryRecv()
    if not received[0]:
      if args.stop[].load:
        if args.queue[].peek == 0:
          break
        continue
      os.sleep(1)
      continue
    let item = received[1]
    if not failed:
      case item.kind
      of itemActivateRelay:
        activeRelays[item.subscriptionId] = item.generation
      of itemInvalidateRelay:
        if activeRelays.getOrDefault(item.subscriptionId) == item.generation:
          activeRelays.del(item.subscriptionId)
      of itemEvent:
        let stale = item.generation != 0 and
          activeRelays.getOrDefault(item.subscriptionId) != item.generation
        if not stale and not writeWithDeadline(args, item.encoded):
          failed = true
          markFailed(args.budget)
          if args.socketOutput:
            discard posix.shutdown(SocketHandle(args.descriptor), SHUT_RDWR)
    release(args.budget, item)

  # A failed or closing writer owns cleanup of every reservation still queued.
  while true:
    let received = args.queue[].tryRecv()
    if not received[0]:
      if args.queue[].peek == 0:
        break
      continue
    release(args.budget, received[1])
  args.done[].store(true)

proc newAdapterOutput*(descriptor: cint; socketOutput: bool): AdapterOutput =
  let abort = sharedAtomic(false)
  let producer = OutputProducer(queue: sharedQueue(), budget: sharedBudget(),
    abort: abort)
  result = AdapterOutput(producer: producer, stop: sharedAtomic(false),
    done: sharedAtomic(false))
  createThread(result.worker, outputWriter, OutputWriterArgs(queue: producer.queue,
    budget: producer.budget, stop: result.stop, done: result.done,
    abort: abort, descriptor: descriptor, socketOutput: socketOutput))

proc failOutput*(output: OutputProducer) {.gcsafe.} =
  ## A producer that cannot publish its structured fallback asks the output
  ## owner to terminate the stream. This is preferable to leaving a controller
  ## with a live-looking subscription that can never produce another event.
  markFailed(output.budget)
  output.abort[].store(true)

proc close*(output: AdapterOutput): bool =
  if output.isNil:
    return true
  acquire(output.producer.budget[].lock)
  output.producer.budget[].accepting = false
  release(output.producer.budget[].lock)
  output.stop[].store(true)
  let deadline = epochTime() + adapterCloseDeadlineMilliseconds.float / 1_000.0
  while epochTime() < deadline and not output.done[].load:
    os.sleep(1)
  if output.done[].load and not output.joined:
    joinThread(output.worker)
    output.joined = true
  result = output.done[].load

proc failed*(output: AdapterOutput): bool =
  acquire(output.producer.budget[].lock)
  result = output.producer.budget[].failed
  release(output.producer.budget[].lock)

proc stats*(output: AdapterOutput): OutputStats =
  acquire(output.producer.budget[].lock)
  result = OutputStats(records: output.producer.budget[].records,
    bytes: output.producer.budget[].bytes,
    relayRecords: output.producer.budget[].relayRecords,
    relayBytes: output.producer.budget[].relayBytes)
  release(output.producer.budget[].lock)
