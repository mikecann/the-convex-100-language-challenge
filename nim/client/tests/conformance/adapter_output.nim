## One bounded owner for every adapter stdout or TCP write.
##
## Producers reserve both a record and its encoded byte cost before enqueueing.
## A stopped controller therefore causes a bounded write failure, never an
## unbounded queue or a command thread parked inside send while holding a lock.
##
## Nothing the Nim runtime manages crosses this thread boundary, because under
## `--mm:orc --threads:on` it cannot cross safely.  A `string` payload belongs
## to the thread-local `MemRegion` of whichever thread allocated it, and
## `system/channels_builtin` moves a message as raw bits rather than deep
## copying it, so a queued `string` was released by the writer through the
## producing relay's region.  Relays are joined as soon as their subscription
## stops, so that region had usually already died with its thread: freeing a
## foreign chunk writes through the chunk's recorded owner, and a dead owner
## means a wild write and an eventual SIGSEGV inside the allocator.
##
## Queue payloads are libc `malloc` storage instead.  It has no thread
## affinity, so the writer may release bytes long after their producer exited,
## and the queue itself is a bounded ring guarded by the same lock that owns
## the reservation counters.

import std/[atomics, locks, os, posix, tables, times]

# std/posix exports MSG_NOSIGNAL but not MSG_DONTWAIT.  The TCP controller
# descriptor is also the reader's descriptor, so this write path must ask for
# one non-blocking send instead of setting O_NONBLOCK on the shared fd.
let MSG_DONTWAIT {.importc: "MSG_DONTWAIT", header: "<sys/socket.h>".}: cint

# Nim's allocShared is the calling thread's own allocator under --mm:orc, so it
# cannot own a payload whose producer may exit first.  libc owns these bytes.
proc mallocStorage(size: csize_t): pointer {.importc: "malloc",
    header: "<stdlib.h>", gcsafe.}
proc freeStorage(storage: pointer) {.importc: "free", header: "<stdlib.h>",
    gcsafe.}

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

  OwnedBytes* = object
    ## Payload storage with no thread affinity.  `data` is nil exactly when
    ## `len` is zero, so an empty payload never needs an allocation.
    data: ptr UncheckedArray[char]
    len: int

  OutputItemKind = enum
    itemEvent
    itemActivateRelay
    itemInvalidateRelay

  OutputItem = object
    kind: OutputItemKind
    encoded: OwnedBytes
    subscriptionId: OwnedBytes
    generation: uint64
    cost: int
    relayData: bool

  OutputQueue = object
    ## The reservation counters and the ring are one lock-guarded unit, so a
    ## reserved record always has a slot waiting for it and an accepted record
    ## can never be rejected afterwards.  `records` counts a record from
    ## acceptance until the writer has finished with it, so it can exceed the
    ## number of slots currently occupied by exactly the one in-flight write.
    lock: Lock
    slots: array[adapterOutputMaxRecords, OutputItem]
    readIndex: uint64
    writeIndex: uint64
    records: int
    bytes: int
    relayRecords: int
    relayBytes: int
    accepting: bool
    failed: bool

  OutputWriterArgs = object
    queue: ptr OutputQueue
    stop: ptr Atomic[bool]
    abort: ptr Atomic[bool]
    done: ptr Atomic[bool]
    descriptor: cint
    socketOutput: bool

  OutputProducer* = object
    queue: ptr OutputQueue
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

proc newOwnedBytes*(value: string; allocated: var bool): OwnedBytes {.gcsafe.} =
  ## Copies `value` into storage that outlives the calling thread.  `allocated`
  ## is cleared when the copy could not be made, so a caller can refuse to
  ## publish a silently truncated payload instead of emitting one.
  result.len = value.len
  if value.len == 0:
    return
  result.data = cast[ptr UncheckedArray[char]](mallocStorage(csize_t(value.len)))
  if result.data.isNil:
    result.len = 0
    allocated = false
    return
  copyMem(result.data, value.cstring, value.len)

proc releaseOwnedBytes*(value: var OwnedBytes) {.gcsafe.} =
  if not value.data.isNil:
    freeStorage(value.data)
    value.data = nil
  value.len = 0

proc ownedString*(value: OwnedBytes): string {.gcsafe.} =
  if value.len == 0:
    return ""
  result = newString(value.len)
  copyMem(result[0].addr, value.data, value.len)

proc releaseItem(item: var OutputItem) {.gcsafe.} =
  releaseOwnedBytes(item.encoded)
  releaseOwnedBytes(item.subscriptionId)

proc sharedAtomic(initial: bool): ptr Atomic[bool] =
  result = cast[ptr Atomic[bool]](mallocStorage(csize_t(sizeof(Atomic[bool]))))
  doAssert not result.isNil, "adapter output control block allocation failed"
  zeroMem(result, sizeof(Atomic[bool]))
  result[].store(initial)

proc newOutputQueue(): ptr OutputQueue =
  result = cast[ptr OutputQueue](mallocStorage(csize_t(sizeof(OutputQueue))))
  doAssert not result.isNil, "adapter output queue allocation failed"
  zeroMem(result, sizeof(OutputQueue))
  initLock(result[].lock)
  result[].accepting = true

proc admit(queue: ptr OutputQueue; item: OutputItem): OutputResult {.gcsafe.} =
  ## The caller holds `queue[].lock`.  Occupied slots never exceed `records`,
  ## and `records` is below the slot count here, so the ring always has room.
  if queue[].failed:
    return outputFailed
  if not queue[].accepting:
    return outputClosed
  if queue[].records >= adapterOutputMaxRecords or
      item.cost > adapterOutputMaxBytes - queue[].bytes:
    return outputBudgetExhausted
  if item.relayData and
      (queue[].relayRecords >= adapterRelayMaxRecords or
      item.cost > adapterRelayMaxBytes - queue[].relayBytes):
    return outputBudgetExhausted
  queue[].slots[int(queue[].writeIndex mod uint64(adapterOutputMaxRecords))] = item
  queue[].writeIndex.inc
  queue[].records.inc
  queue[].bytes += item.cost
  if item.relayData:
    queue[].relayRecords.inc
    queue[].relayBytes += item.cost
  result = outputAccepted

proc enqueue(output: OutputProducer; item: OutputItem): OutputResult {.gcsafe.} =
  ## Takes ownership of `item`.  Every rejection releases the payload here, so
  ## no caller has to reason about partially transferred ownership.
  var owned = item
  acquire(output.queue[].lock)
  result = admit(output.queue, owned)
  release(output.queue[].lock)
  if result != outputAccepted:
    releaseItem(owned)

proc enqueueEvent*(output: OutputProducer; encoded, subscriptionId: string;
    generation: uint64; relayData: bool): OutputResult {.gcsafe.} =
  if encoded.len > maxAdapterEventBytes:
    return outputTooLarge
  var allocated = true
  var item = OutputItem(kind: itemEvent,
    encoded: newOwnedBytes(encoded, allocated),
    subscriptionId: newOwnedBytes(subscriptionId, allocated),
    generation: generation,
    cost: encoded.len + adapterOutputRecordOverhead, relayData: relayData)
  if not allocated:
    # Refusing the record is the honest answer: the caller then publishes its
    # structured fallback or terminates the stream rather than writing a
    # truncated event.
    releaseItem(item)
    return outputFailed
  result = output.enqueue(item)

proc activateRelay*(output: OutputProducer; subscriptionId: string;
    generation: uint64): OutputResult {.gcsafe.} =
  var allocated = true
  var item = OutputItem(kind: itemActivateRelay,
    subscriptionId: newOwnedBytes(subscriptionId, allocated),
    generation: generation, cost: adapterOutputRecordOverhead)
  if not allocated:
    releaseItem(item)
    return outputFailed
  result = output.enqueue(item)

proc invalidateRelay*(output: OutputProducer; subscriptionId: string;
    generation: uint64): OutputResult {.gcsafe.} =
  var allocated = true
  var item = OutputItem(kind: itemInvalidateRelay,
    subscriptionId: newOwnedBytes(subscriptionId, allocated),
    generation: generation, cost: adapterOutputRecordOverhead)
  if not allocated:
    releaseItem(item)
    return outputFailed
  result = output.enqueue(item)

proc tryPop(queue: ptr OutputQueue): tuple[available: bool,
    item: OutputItem] {.gcsafe.} =
  ## Removes the oldest record from the ring but keeps its reservation, so an
  ## in-flight write still counts against the process-wide budget.
  acquire(queue[].lock)
  if queue[].writeIndex != queue[].readIndex:
    let slot = int(queue[].readIndex mod uint64(adapterOutputMaxRecords))
    result.item = queue[].slots[slot]
    queue[].slots[slot] = OutputItem()
    queue[].readIndex.inc
    result.available = true
  release(queue[].lock)

proc queuedRecords(queue: ptr OutputQueue): int {.gcsafe.} =
  acquire(queue[].lock)
  result = int(queue[].writeIndex - queue[].readIndex)
  release(queue[].lock)

proc releaseReservation(queue: ptr OutputQueue;
    item: OutputItem) {.gcsafe.} =
  acquire(queue[].lock)
  queue[].records.dec
  queue[].bytes -= item.cost
  if item.relayData:
    queue[].relayRecords.dec
    queue[].relayBytes -= item.cost
  release(queue[].lock)

proc markFailed(queue: ptr OutputQueue) {.gcsafe.} =
  acquire(queue[].lock)
  queue[].failed = true
  queue[].accepting = false
  release(queue[].lock)

proc millisecondsRemaining(deadline: float): cint {.gcsafe.} =
  let remaining = int((deadline - epochTime()) * 1_000.0)
  if remaining <= 0:
    return 0
  result = cint(min(remaining, adapterWriteDeadlineMilliseconds))

proc writeWithDeadline(args: OutputWriterArgs;
    value: OwnedBytes): bool {.gcsafe.} =
  if not args.socketOutput:
    let originalFlags = fcntl(args.descriptor, F_GETFL)
    if originalFlags < 0 or
        fcntl(args.descriptor, F_SETFL, originalFlags or O_NONBLOCK) < 0:
      return false
  let deadline = epochTime() + adapterWriteDeadlineMilliseconds.float / 1_000.0
  var offset = 0
  while offset < value.len:
    let address = addr value.data[offset]
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
      markFailed(args.queue)
      if args.socketOutput:
        discard posix.shutdown(SocketHandle(args.descriptor), SHUT_RDWR)
    var received = tryPop(args.queue)
    if not received.available:
      if args.stop[].load:
        # Re-check emptiness only after observing stop.  close clears
        # accepting under the same lock before it sets stop, so a producer
        # that passed the accepting check had already published its record.
        if queuedRecords(args.queue) == 0:
          break
        continue
      os.sleep(1)
      continue
    if not failed:
      let subscriptionId = ownedString(received.item.subscriptionId)
      case received.item.kind
      of itemActivateRelay:
        activeRelays[subscriptionId] = received.item.generation
      of itemInvalidateRelay:
        if activeRelays.getOrDefault(subscriptionId) == received.item.generation:
          activeRelays.del(subscriptionId)
      of itemEvent:
        let stale = received.item.generation != 0 and
          activeRelays.getOrDefault(subscriptionId) != received.item.generation
        if not stale and not writeWithDeadline(args, received.item.encoded):
          failed = true
          markFailed(args.queue)
          if args.socketOutput:
            discard posix.shutdown(SocketHandle(args.descriptor), SHUT_RDWR)
    releaseReservation(args.queue, received.item)
    releaseItem(received.item)

  # A failed or closing writer owns cleanup of every reservation still queued.
  while true:
    var received = tryPop(args.queue)
    if not received.available:
      break
    releaseReservation(args.queue, received.item)
    releaseItem(received.item)
  args.done[].store(true)

proc newAdapterOutput*(descriptor: cint; socketOutput: bool): AdapterOutput =
  let abort = sharedAtomic(false)
  let queue = newOutputQueue()
  let producer = OutputProducer(queue: queue, abort: abort)
  result = AdapterOutput(producer: producer, stop: sharedAtomic(false),
    done: sharedAtomic(false))
  createThread(result.worker, outputWriter, OutputWriterArgs(queue: queue,
    stop: result.stop, done: result.done, abort: abort,
    descriptor: descriptor, socketOutput: socketOutput))

proc failOutput*(output: OutputProducer) {.gcsafe.} =
  ## A producer that cannot publish its structured fallback asks the output
  ## owner to terminate the stream. This is preferable to leaving a controller
  ## with a live-looking subscription that can never produce another event.
  markFailed(output.queue)
  output.abort[].store(true)

proc close*(output: AdapterOutput): bool =
  if output.isNil:
    return true
  acquire(output.producer.queue[].lock)
  output.producer.queue[].accepting = false
  release(output.producer.queue[].lock)
  output.stop[].store(true)
  let deadline = epochTime() + adapterCloseDeadlineMilliseconds.float / 1_000.0
  while epochTime() < deadline and not output.done[].load:
    os.sleep(1)
  if output.done[].load and not output.joined:
    joinThread(output.worker)
    output.joined = true
  result = output.done[].load

proc failed*(output: AdapterOutput): bool =
  acquire(output.producer.queue[].lock)
  result = output.producer.queue[].failed
  release(output.producer.queue[].lock)

proc stats*(output: AdapterOutput): OutputStats =
  acquire(output.producer.queue[].lock)
  result = OutputStats(records: output.producer.queue[].records,
    bytes: output.producer.queue[].bytes,
    relayRecords: output.producer.queue[].relayRecords,
    relayBytes: output.producer.queue[].relayBytes)
  release(output.producer.queue[].lock)

proc releaseAdapterOutput*(output: AdapterOutput) =
  ## Only safe once `close` has returned true, because that is what joins the
  ## writer.  Copies of `producer` taken before this call must not be reused.
  if output.isNil or not output.joined:
    return
  deinitLock(output.producer.queue[].lock)
  freeStorage(output.producer.queue)
  freeStorage(output.producer.abort)
  freeStorage(output.stop)
  freeStorage(output.done)
  output.producer = OutputProducer()
  output.stop = nil
  output.done = nil
