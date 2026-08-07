## Native Convex client used by the Nim educational demonstration.
##
## The HTTP request envelope, response errors, and Live transition state machine
## are implemented here.  Nim's standard HTTP/TLS/JSON libraries and the
## pinned treeform/ws transport are only transport helpers.

import std/[algorithm, asyncdispatch, asyncstreams, atomics, httpclient, json,
  locks, math, net, os, strutils, tables, times, uri]
import ws
import ./protocol

export protocol

# Under `--mm:orc` Nim's allocShared is the calling thread's own allocator, not
# a process-wide heap, and releasing a chunk from another thread writes through
# the allocating thread's region.  Delivery payloads therefore use libc
# storage, which no thread owns, so a frame outlives the socket owner that
# produced it without the release order having to guarantee anything.
proc mallocStorage(size: csize_t): pointer {.importc: "malloc",
    header: "<stdlib.h>", gcsafe.}
proc freeStorage(storage: pointer) {.importc: "free", header: "<stdlib.h>",
    gcsafe.}

const
  clientVersion* = "nim-0.2.0"
  maxResponseBytes* = 2 * 1024 * 1024
  maxRequestBytes* = 2 * 1024 * 1024 + 64 * 1024
  maxLiveValueBytes* = 2 * 1024 * 1024
  liveQueueSlots* = 4
  initialTimestamp = "AAAAAAAAAAA="
  reconnectInitialSeconds = 0.1
  reconnectMaximumSeconds = 15.0
  socketReadSliceMilliseconds = 100
  socketRetirementTimeoutMilliseconds = 1_000
  socketHandshakeTimeoutMilliseconds = 6_000
  socketWriteTimeoutMilliseconds = 2_000
  httpHeadersTimeoutMilliseconds = 30_000
  httpBodySliceTimeoutMilliseconds = 5_000
  liveCommandTimeoutSeconds = 8.0
  maxLiveSubscriptions = 16
  maxLiveModifications = 1_024
  maxLiveLogBytes = 64 * 1024
  maxFunctionPathBytes = 64 * 1024
  maxAuthTokenBytes = 2 * 1024 * 1024
  liveGlobalQueueRecords = 16
  liveGlobalQueueBytes* = 8 * 1024 * 1024
  liveFrameOverheadBytes = 1_024
  # Every command has an encoded 2 MiB argument ceiling, so a fixed eight-slot
  # owner queue also gives command traffic an explicit byte upper bound.
  liveCommandQueueSlots = 8

when defined(nimtesthooks):
  const httpBodyDeadlineSeconds = 1.0
else:
  const httpBodyDeadlineSeconds = 30.0

type
  ConvexError* = object of CatchableError
  TransportError* = object of ConvexError
  ProtocolError* = object of ConvexError
  FunctionError* = object of ConvexError
    data*: JsonNode
    hasData*: bool
    logs*: seq[string]

  Result* = object
    value*: JsonNode
    logs*: seq[string]

  LiveUpdate* = object
    ## Strings cross the Nim thread boundary deliberately.  This keeps JSON
    ## ownership local to the WebSocket owner and makes the byte budget clear.
    value*: string
    isError*: bool
    errorName*: string
    errorMessage*: string
    errorData*: string
    logs*: string

  SharedText = object
    data: ptr UncheckedArray[char]
    len: int

  LiveQueueBudget = object
    lock: Lock
    records: int
    bytes: int

  LiveFrame* = object
    ## Only libc pointers cross a Nim thread boundary.  A Channel moves a
    ## message as raw bits, so a managed string in one would change owning
    ## thread without changing owning allocator, and whichever thread released
    ## it last would write through the producer's region.  That was the
    ## reconnect crash this frame fixes, and libc storage removes the need for
    ## any argument about which thread happens to die first.
    value: SharedText
    errorName: SharedText
    errorMessage: SharedText
    errorData: SharedText
    logs: SharedText
    isError: bool
    budget: ptr LiveQueueBudget
    cost: int

  LiveMailbox* = object
    ## A single-producer/single-consumer ring avoids Nim Channel's third-thread
    ## receive race.  When full, the producer drops the incoming newest frame
    ## rather than mutating a slot the consumer may currently be reading.
    writeIndex: Atomic[uint64]
    readIndex: Atomic[uint64]
    overflowed: Atomic[bool]
    budget: ptr LiveQueueBudget
    slots: array[liveQueueSlots, LiveFrame]

  LiveManager = ref object
    commands: ptr Channel[LiveCommand]
    stopped: ptr Atomic[bool]
    done: ptr Channel[bool]
    workerWsUrl: SharedText
    worker: Thread[LiveWorkerArgs]
    joined: bool
    queueBudget: ptr LiveQueueBudget

  LiveSubscription* = ref object
    updates*: ptr LiveMailbox
    manager: LiveManager
    queryId: uint32
    closed*: ptr Atomic[bool]
    externalRelay: bool
    storageReleased: bool

  LiveState = ref object
    updates: ptr LiveMailbox
    closed: ptr Atomic[bool]
    path: string
    args: string
    lastValue: string
    lastSuccess: bool
    hasLast: bool
    awaitingRehydration: bool
    activationResponse: ptr Channel[LiveResponse]

  LiveCommand = object
    kind: string
    path: string
    args: string
    queryId: uint32
    updates: ptr LiveMailbox
    closed: ptr Atomic[bool]
    response: ptr Channel[LiveResponse]

  LiveResponse = object
    ok: bool
    message: string

  LiveWorkerArgs = object
    commands: ptr Channel[LiveCommand]
    stopped: ptr Atomic[bool]
    done: ptr Channel[bool]
    wsUrl: SharedText

  WireVersion = object
    querySet: int
    identity: int
    timestamp: string

  PlannedLiveState = object
    queryId: uint32
    lastValue: string
    lastSuccess: bool
    hasLast: bool
    awaitingRehydration: bool

  PlannedTransition = object
    endVersion: WireVersion
    maximumTimestamp: string
    states: Table[uint32, PlannedLiveState]
    deliveries: Table[uint32, LiveUpdate]

  LivePacketStatus = enum
    packetWaiting
    packetReady

  Client* = ref object
    deploymentUrl*: string
    authToken*: string
    clientVersion*: string
    closed: ptr Atomic[bool]
    live: LiveManager
    nextQueryId: uint32

proc sharedChannel[T](capacity: int): ptr Channel[T] =
  ## A channel a Thread points at must sit at a fixed address that ORC does
  ## not own, so it is allocated raw rather than as a ref.  Only the client
  ## thread allocates and releases these, and only while the owner thread is
  ## still alive, because a channel grown by the owner holds a buffer from the
  ## owner's own allocator.
  result = cast[ptr Channel[T]](allocShared0(sizeof(Channel[T])))
  result[].open(capacity)

proc releaseSharedChannel[T](channel: ptr Channel[T]) =
  if channel.isNil:
    return
  channel[].close()
  deallocShared(channel)

proc sharedAtomicBool(initial: bool): ptr Atomic[bool] =
  result = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
  result[].store(initial)

proc releaseLiveFrame*(frame: var LiveFrame) {.gcsafe.}
proc makeLiveFrame*(update: LiveUpdate): LiveFrame {.gcsafe.}

proc sharedLiveBudget(): ptr LiveQueueBudget =
  result = cast[ptr LiveQueueBudget](allocShared0(sizeof(LiveQueueBudget)))
  initLock(result[].lock)

proc sharedMailbox(budget: ptr LiveQueueBudget): ptr LiveMailbox =
  result = cast[ptr LiveMailbox](allocShared0(sizeof(LiveMailbox)))
  result[].writeIndex.store(0)
  result[].readIndex.store(0)
  result[].overflowed.store(false)
  result[].budget = budget

proc reserveLiveFrame(budget: ptr LiveQueueBudget; cost: int): bool {.gcsafe.} =
  acquire(budget[].lock)
  defer: release(budget[].lock)
  if budget[].records >= liveGlobalQueueRecords or
      cost > liveGlobalQueueBytes - budget[].bytes:
    return false
  budget[].records.inc
  budget[].bytes += cost
  result = true

proc releaseLiveReservation(frame: var LiveFrame) {.gcsafe.} =
  if frame.budget.isNil or frame.cost == 0:
    return
  acquire(frame.budget[].lock)
  frame.budget[].records.dec
  frame.budget[].bytes -= frame.cost
  release(frame.budget[].lock)
  frame.budget = nil
  frame.cost = 0

proc sendLiveFrame*(mailbox: ptr LiveMailbox; frame: LiveFrame) {.gcsafe.} =
  var owned = frame
  owned.cost = liveFrameOverheadBytes + owned.value.len + owned.errorName.len +
    owned.errorMessage.len + owned.errorData.len + owned.logs.len
  if owned.cost > liveGlobalQueueBytes or
      not reserveLiveFrame(mailbox[].budget, owned.cost):
    mailbox[].overflowed.store(true)
    releaseLiveFrame(owned)
    return
  owned.budget = mailbox[].budget
  let writeIndex = mailbox[].writeIndex.load
  let readIndex = mailbox[].readIndex.load
  if writeIndex - readIndex >= uint64(liveQueueSlots):
    mailbox[].overflowed.store(true)
    releaseLiveFrame(owned)
    return
  mailbox[].slots[int(writeIndex mod uint64(liveQueueSlots))] = owned
  mailbox[].writeIndex.store(writeIndex + 1)

proc recvLiveFrame*(mailbox: ptr LiveMailbox; closed: ptr Atomic[bool]): tuple[
    available: bool, frame: LiveFrame] {.gcsafe.} =
  while true:
    let readIndex = mailbox[].readIndex.load
    if readIndex < mailbox[].writeIndex.load:
      result.frame = mailbox[].slots[int(readIndex mod uint64(liveQueueSlots))]
      mailbox[].readIndex.store(readIndex + 1)
      result.available = true
      return
    # Report the drop only once every buffered value has been delivered, so the
    # overflow notice can never overtake the values it actually followed.
    if mailbox[].overflowed.exchange(false):
      return (true, makeLiveFrame(LiveUpdate(isError: true,
        errorName: "TransportError",
        errorMessage: "Live delivery buffer overflowed", logs: "[]")))
    if not closed.isNil and closed[].load:
      return (false, LiveFrame())
    sleep(1)

proc drainLiveMailbox*(mailbox: ptr LiveMailbox) {.gcsafe.} =
  while true:
    let readIndex = mailbox[].readIndex.load
    if readIndex >= mailbox[].writeIndex.load:
      return
    var frame = mailbox[].slots[int(readIndex mod uint64(liveQueueSlots))]
    mailbox[].readIndex.store(readIndex + 1)
    releaseLiveFrame(frame)

proc sharedText(value: string): SharedText {.gcsafe.} =
  result.len = value.len
  if value.len > 0:
    result.data = cast[ptr UncheckedArray[char]](
      mallocStorage(csize_t(value.len)))
    doAssert not result.data.isNil, "Live frame payload allocation failed"
    copyMem(result.data, value.cstring, value.len)

proc releaseSharedText(value: var SharedText) {.gcsafe.} =
  if not value.data.isNil:
    freeStorage(value.data)
    value.data = nil
    value.len = 0

proc sharedTextString(value: SharedText): string {.gcsafe.} =
  if value.len == 0:
    return ""
  result = newString(value.len)
  copyMem(result[0].addr, value.data, value.len)

proc makeLiveFrame*(update: LiveUpdate): LiveFrame {.gcsafe.} =
  result = LiveFrame(
    value: sharedText(update.value),
    errorName: sharedText(update.errorName),
    errorMessage: sharedText(update.errorMessage),
    errorData: sharedText(update.errorData),
    logs: sharedText(update.logs),
    isError: update.isError)

proc releaseLiveFrame*(frame: var LiveFrame) {.gcsafe.} =
  releaseSharedText(frame.value)
  releaseSharedText(frame.errorName)
  releaseSharedText(frame.errorMessage)
  releaseSharedText(frame.errorData)
  releaseSharedText(frame.logs)
  releaseLiveReservation(frame)

proc liveUpdateFromFrame*(frame: LiveFrame): LiveUpdate {.gcsafe.} =
  result = LiveUpdate(
    value: sharedTextString(frame.value),
    isError: frame.isError,
    errorName: sharedTextString(frame.errorName),
    errorMessage: sharedTextString(frame.errorMessage),
    errorData: sharedTextString(frame.errorData),
    logs: sharedTextString(frame.logs))

proc jsonObjectArgs(args: JsonNode): JsonNode =
  if args.isNil:
    return newJObject()
  if args.kind != JObject:
    raise newException(ValueError, "Convex arguments must be a named JSON object")
  return args

proc parseLogs(node: JsonNode): seq[string] =
  if not node.hasKey("logLines"):
    return @[]
  let logs = node["logLines"]
  if logs.kind != JArray:
    raise newException(ProtocolError, "Convex logLines must be an array")
  for item in logs.getElems:
    if item.kind != JString:
      raise newException(ProtocolError, "Convex logLines must contain strings")
    result.add(item.getStr)
  if len($logs) > maxLiveLogBytes:
    raise newException(ProtocolError, "Convex logLines exceed 64 KiB")

proc newClient*(deploymentUrl: string; authToken = ""): Client =
  let parsed = parseUri(deploymentUrl)
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
    raise newException(ValueError,
      "Convex deployment URL must use http or https and include a host")
  if authToken.len > maxAuthTokenBytes:
    raise newException(ValueError, "Convex auth token exceeds 2 MiB")
  var base = parsed
  base.query = ""
  base.anchor = ""
  result = Client(
    deploymentUrl: ($base).strip(leading = false, chars = {'/'}),
    authToken: authToken,
    clientVersion: clientVersion
  )
  result.closed = sharedAtomicBool(false)

proc ensureOpen(client: Client) =
  if client.isNil or client.closed[].load:
    raise newException(ConvexError, "client is closed")

proc setAuth*(client: Client; token: string) =
  client.ensureOpen()
  if token.len > maxAuthTokenBytes:
    raise newException(ValueError, "Convex auth token exceeds 2 MiB")
  client.authToken = token

proc enqueueCommand(manager: LiveManager; command: LiveCommand): bool
proc awaitResponse(channel: ptr Channel[LiveResponse]): tuple[
  received: bool, answer: LiveResponse]
proc awaitOwnerDone(manager: LiveManager): bool

proc close*(client: Client) =
  if client.isNil:
    return
  if client.closed[].exchange(true):
    return
  if not client.live.isNil:
    let manager = client.live
    let response = sharedChannel[LiveResponse](1)
    var closeError = ""
    if enqueueCommand(manager, LiveCommand(kind: "close", response: response)):
      let reply = awaitResponse(response)
      if reply.received:
        # Released while the owner is still running, which is the only time a
        # buffer the owner may have grown can be handed back safely.  The
        # message is copied out here for the same reason: `reply` is destroyed
        # at the end of this branch, before the owner is joined below.
        releaseSharedChannel(response)
        if not reply.answer.ok:
          closeError = reply.answer.message
      else:
        # The owner may still hold this pointer until its completion barrier,
        # and a late answer would have grown the channel's buffer from the
        # owner's own allocator.  Under --mm:orc that buffer can only be
        # released while the owner thread is alive, so a timed-out close
        # deliberately leaks one small channel rather than write through a
        # region that died with the owner.
        manager.stopped[].store(true)
    else:
      # The owner never dequeued the command, so it never grew this channel.
      releaseSharedChannel(response)
      manager.stopped[].store(true)
    if awaitOwnerDone(manager):
      if not manager.joined:
        joinThread(manager.worker)
        manager.joined = true
        releaseSharedText(manager.workerWsUrl)
      if closeError.len > 0:
        raise newException(TransportError, closeError)
    else:
      raise newException(TransportError, "Live owner did not stop before deadline")

proc boundedHttpBody(http: AsyncHttpClient; response: AsyncResponse): string =
  ## AsyncHttpClient exposes body chunks as they arrive.  Check the declared
  ## size before reading, then enforce the same cap on every chunk so fixed,
  ## chunked, and dishonest responses never materialise an unbounded body.
  let declared = response.headers.getOrDefault("Content-Length")
  if declared.len > 0:
    let declaredBytes = try:
      parseBiggestInt(declared)
    except CatchableError as error:
      raise newException(ProtocolError,
        "invalid HTTP Content-Length: " & error.msg)
    if declaredBytes < 0 or declaredBytes > maxResponseBytes:
      raise newException(TransportError, "response exceeds 2 MiB")

  let deadline = epochTime() + httpBodyDeadlineSeconds
  while true:
    let remainingMilliseconds = int((deadline - epochTime()) * 1_000.0)
    if remainingMilliseconds <= 0:
      http.close()
      raise newException(TransportError, "HTTP response body timed out")
    let readFuture = response.bodyStream.read()
    let waitMilliseconds = min(httpBodySliceTimeoutMilliseconds,
      remainingMilliseconds)
    # The patched parser fails this stream when a response breaks a byte limit,
    # and withTimeout re-raises that failure.  A truncated transport is a
    # TransportError; letting it escape here reported it as malformed JSON.
    let ready = try:
      waitFor readFuture.withTimeout(waitMilliseconds)
    except CatchableError as error:
      http.close()
      raise newException(TransportError, "HTTP response body: " & error.msg)
    if not ready:
      http.close()
      var retired = true
      try:
        retired = waitFor readFuture.withTimeout(
          socketRetirementTimeoutMilliseconds)
      except CatchableError:
        # A read that failed after closure has retired; only a still-pending
        # callback means the connection could not be abandoned safely.
        retired = true
      if retired:
        try:
          discard waitFor readFuture
        except CatchableError:
          discard
      else:
        raise newException(TransportError,
          "HTTP body read did not retire after connection closure")
      raise newException(TransportError, "HTTP response body timed out")
    let piece = try:
      waitFor readFuture
    except CatchableError as error:
      raise newException(TransportError, "HTTP response body: " & error.msg)
    if not piece[0]:
      break
    if piece[1].len > maxResponseBytes - result.len:
      http.close()
      raise newException(TransportError, "response exceeds 2 MiB")
    result.add(piece[1])

proc call*(client: Client; operation, path: string; args: JsonNode): Result =
  client.ensureOpen()
  if path.len == 0:
    raise newException(ValueError, "Convex function path is required")
  if path.len > maxFunctionPathBytes:
    raise newException(ValueError, "Convex function path exceeds 64 KiB")
  if operation notin ["query", "mutation", "action"]:
    raise newException(ValueError, "unsupported Convex operation: " & operation)

  var request = newJObject()
  request["path"] = %path
  request["args"] = jsonObjectArgs(args)
  request["format"] = %"json"
  var headers = newHttpHeaders({
    "Accept": "application/json",
    "Content-Type": "application/json",
    "Convex-Client": client.clientVersion
  })
  if client.authToken.len > 0:
    headers["Authorization"] = "Bearer " & client.authToken

  let requestBody = $request
  if requestBody.len > maxRequestBytes:
    raise newException(ValueError, "Convex request exceeds encoded byte limit")

  let http = newAsyncHttpClient(maxRedirects = 0)
  defer: http.close()
  let requestFuture = http.request(client.deploymentUrl & "/api/" & operation,
    httpMethod = HttpPost, body = requestBody, headers = headers)
  # The patched parser rejects oversized headers by failing this request, and
  # withTimeout re-raises that failure rather than returning false.
  let headersReady = try:
    waitFor requestFuture.withTimeout(httpHeadersTimeoutMilliseconds)
  except CatchableError as error:
    http.close()
    raise newException(TransportError, operation & ": " & error.msg)
  if not headersReady:
    http.close()
    var retired = true
    try:
      retired = waitFor requestFuture.withTimeout(
        socketRetirementTimeoutMilliseconds)
    except CatchableError:
      retired = true
    if retired:
      try:
        discard waitFor requestFuture
      except CatchableError:
        discard
    else:
      raise newException(TransportError,
        operation & ": HTTP header read did not retire after closure")
    raise newException(TransportError, operation & ": HTTP headers timed out")
  let response = try:
    waitFor requestFuture
  except CatchableError as error:
    raise newException(TransportError, operation & ": " & error.msg)
  # Drain every status through the same bounded stream. This completes the
  # parser before the fresh per-call connection is retired, including errors.
  let body = boundedHttpBody(http, response)
  if response.code.int < 200 or response.code.int >= 300:
    raise newException(TransportError,
      operation & ": HTTP status " & $response.code.int)

  let decoded = try:
    parseJson(body)
  except CatchableError as error:
    raise newException(ProtocolError, "non-Convex JSON response: " & error.msg)
  if decoded.kind != JObject or not decoded.hasKey("status") or
      decoded["status"].kind != JString:
    raise newException(ProtocolError, "response omitted string status")

  result.logs = parseLogs(decoded)
  case decoded["status"].getStr
  of "success":
    if not decoded.hasKey("value"):
      raise newException(ProtocolError, "success response omitted value")
    result.value = decoded["value"]
  of "error":
    if not decoded.hasKey("errorMessage") or
        decoded["errorMessage"].kind != JString:
      raise newException(ProtocolError,
        "error response omitted string errorMessage")
    let message = decoded["errorMessage"].getStr
    if message.len == 0 or message.len > maxLiveLogBytes:
      raise newException(ProtocolError,
        "error response message is empty or too large")
    let error = newException(FunctionError, message)
    error.logs = result.logs
    if decoded.hasKey("errorData"):
      error.data = decoded["errorData"]
      error.hasData = true
    raise error
  else:
    raise newException(ProtocolError,
      "unknown Convex response status: " & decoded["status"].getStr)

proc query*(client: Client; path: string; args: JsonNode): Result =
  client.call("query", path, args)

proc mutation*(client: Client; path: string; args: JsonNode): Result =
  client.call("mutation", path, args)

proc action*(client: Client; path: string; args: JsonNode): Result =
  client.call("action", path, args)

proc liveTimestampBytes(value: string): string =
  try:
    return timestampBytes(value)
  except CatchableError as error:
    raise newException(ProtocolError, error.msg)

proc initialVersion(): WireVersion =
  WireVersion(querySet: 0, identity: 0, timestamp: initialTimestamp)

proc parseWireVersion(node: JsonNode; label: string): WireVersion =
  if node.isNil or node.kind != JObject or node.len != 3 or
      not node.hasKey("querySet") or not node.hasKey("identity") or
      not node.hasKey("ts"):
    raise newException(ProtocolError, label & " must contain querySet, identity, and ts")
  if node["querySet"].kind != JInt or node["identity"].kind != JInt or
      node["ts"].kind != JString:
    raise newException(ProtocolError, label & " fields have invalid types")
  let querySet = node["querySet"].getBiggestInt
  let identity = node["identity"].getBiggestInt
  if querySet < 0 or uint64(querySet) > uint64(high(uint32)) or
      identity < 0 or uint64(identity) > uint64(high(uint32)):
    raise newException(ProtocolError, label & " fields are out of range")
  let timestamp = node["ts"].getStr
  discard liveTimestampBytes(timestamp)
  result = WireVersion(querySet: int(querySet), identity: int(identity),
    timestamp: timestamp)

proc versionMatches(left, right: WireVersion): bool =
  left.querySet == right.querySet and left.identity == right.identity and
    left.timestamp == right.timestamp

proc queryIdFrom(node: JsonNode): uint32 =
  if node.isNil or node.kind != JInt:
    raise newException(ProtocolError, "Transition queryId must be an integer")
  let value = node.getBiggestInt
  if value < 0 or uint64(value) > uint64(high(uint32)):
    raise newException(ProtocolError, "Transition queryId is out of range")
  result = uint32(value)

proc encodedLiveLogs(modification: JsonNode): string =
  if not modification.hasKey("logLines"):
    return "[]"
  let logs = modification["logLines"]
  if logs.kind != JArray:
    raise newException(ProtocolError, "Transition logLines must be an array")
  for line in logs.getElems:
    if line.kind != JString:
      raise newException(ProtocolError, "Transition logLines must contain strings")
  result = $logs
  if result.len > maxLiveLogBytes:
    raise newException(ProtocolError, "Transition logLines exceed 64 KiB")

proc snapshot(state: LiveState; queryId: uint32): PlannedLiveState =
  PlannedLiveState(queryId: queryId, lastValue: state.lastValue,
    lastSuccess: state.lastSuccess, hasLast: state.hasLast,
    awaitingRehydration: state.awaitingRehydration)

proc updateMaxTimestamp(maximum: var string; candidate: string) =
  discard liveTimestampBytes(candidate)
  if maximum.len == 0:
    maximum = candidate
    return
  let comparison = try:
    compareTimestamps(candidate, maximum)
  except CatchableError as error:
    raise newException(ProtocolError, error.msg)
  if comparison > 0:
    maximum = candidate

proc requireOnlyKeys(node: JsonNode; allowed: openArray[string];
    label: string) =
  for key, _ in node.pairs:
    var accepted = false
    for candidate in allowed:
      if key == candidate:
        accepted = true
        break
    if not accepted:
      raise newException(ProtocolError, label & " has unexpected field " & key)

proc planTransition(message: JsonNode; active: Table[uint32, LiveState];
    remoteVersion: WireVersion; maximumTimestamp: string): PlannedTransition =
  ## Parse the whole transition into temporary snapshots.  Nothing in the
  ## active query set changes until every version, modification, diagnostic,
  ## and size bound has passed validation.
  if message.isNil or message.kind != JObject or
      not message.hasKey("type") or message["type"].kind != JString or
      message["type"].getStr != "Transition" or
      not message.hasKey("startVersion") or not message.hasKey("endVersion") or
      not message.hasKey("modifications") or
      message["modifications"].kind != JArray:
    var present: seq[string] = @[]
    if not message.isNil and message.kind == JObject:
      for key, _ in message.pairs:
        present.add(key)
    raise newException(ProtocolError,
      "Transition omitted required fields; received: " & present.join(", "))
  # A live deployment also sends clientClockSkew and serverTs alongside the
  # four fields this client acts on.  Accept them by name so the allow-list
  # still rejects genuinely unknown fields, and keep ignoring their values.
  requireOnlyKeys(message,
    ["type", "startVersion", "endVersion", "modifications", "clientClockSkew",
      "serverTs"], "Transition")
  if message["modifications"].len > maxLiveModifications:
    raise newException(ProtocolError, "Transition has too many modifications")

  let startVersion = parseWireVersion(message["startVersion"],
    "Transition startVersion")
  if not versionMatches(startVersion, remoteVersion):
    raise newException(ProtocolError, "Transition start version disagreed")
  result.endVersion = parseWireVersion(message["endVersion"],
    "Transition endVersion")
  result.maximumTimestamp = maximumTimestamp
  updateMaxTimestamp(result.maximumTimestamp, result.endVersion.timestamp)
  result.states = initTable[uint32, PlannedLiveState]()
  result.deliveries = initTable[uint32, LiveUpdate]()

  for modification in message["modifications"].getElems:
    if modification.kind != JObject or not modification.hasKey("type") or
        modification["type"].kind != JString or
        not modification.hasKey("queryId"):
      raise newException(ProtocolError, "Transition modification is incomplete")
    let queryId = queryIdFrom(modification["queryId"])
    let kind = modification["type"].getStr
    var current: PlannedLiveState
    let tracked = active.hasKey(queryId)
    if tracked:
      current = if result.states.hasKey(queryId): result.states[queryId]
        else: snapshot(active[queryId], queryId)

    case kind
    of "QueryUpdated":
      # A deployment also stamps each modification with an opaque journal.
      requireOnlyKeys(modification,
        ["type", "queryId", "value", "logLines", "journal"], "QueryUpdated")
      let logs = encodedLiveLogs(modification)
      if not modification.hasKey("value"):
        raise newException(ProtocolError, "QueryUpdated omitted value")
      let value = $modification["value"]
      if value.len > maxLiveValueBytes:
        raise newException(ProtocolError, "Live value exceeds 2 MiB")
      if tracked:
        let suppress = current.hasLast and current.lastSuccess and
          current.awaitingRehydration and current.lastValue == value
        current.awaitingRehydration = false
        current.lastValue = value
        current.lastSuccess = true
        current.hasLast = true
        result.states[queryId] = current
        if suppress:
          result.deliveries.del(queryId)
        else:
          result.deliveries[queryId] = LiveUpdate(value: value, logs: logs)
    of "QueryFailed":
      requireOnlyKeys(modification,
        ["type", "queryId", "errorMessage", "errorData", "logLines",
          "journal"],
        "QueryFailed")
      let logs = encodedLiveLogs(modification)
      if not modification.hasKey("errorMessage") or
          modification["errorMessage"].kind != JString:
        raise newException(ProtocolError,
          "QueryFailed errorMessage must be a string")
      let messageText = modification["errorMessage"].getStr
      if messageText.len == 0 or messageText.len > maxLiveLogBytes:
        raise newException(ProtocolError,
          "QueryFailed errorMessage is empty or too large")
      let data = if modification.hasKey("errorData"):
        $modification["errorData"] else: ""
      if data.len > maxLiveValueBytes:
        raise newException(ProtocolError, "QueryFailed errorData exceeds 2 MiB")
      if tracked:
        current.awaitingRehydration = false
        current.lastSuccess = false
        current.hasLast = true
        result.states[queryId] = current
        result.deliveries[queryId] = LiveUpdate(isError: true,
          errorName: "FunctionError", errorMessage: messageText,
          errorData: data, logs: logs)
    of "QueryRemoved":
      requireOnlyKeys(modification, ["type", "queryId"], "QueryRemoved")
      if tracked:
        current.awaitingRehydration = false
        result.states[queryId] = current
        result.deliveries.del(queryId)
    else:
      raise newException(ProtocolError,
        "unknown Transition modification: " & kind)

when defined(nimtesthooks):
  proc newMailboxProbe*(): ptr LiveMailbox =
    ## Exercise the exact production delivery mailbox, including its shared
    ## byte budget, without starting a socket owner.
    sharedMailbox(sharedLiveBudget())

  proc releaseMailboxProbe*(mailbox: ptr LiveMailbox) =
    drainLiveMailbox(mailbox)
    deallocShared(mailbox[].budget)
    deallocShared(mailbox)

  proc sendUpdateProbe*(mailbox: ptr LiveMailbox; update: LiveUpdate) =
    sendLiveFrame(mailbox, makeLiveFrame(update))

  proc recvUpdateProbe*(mailbox: ptr LiveMailbox): LiveUpdate =
    var received = recvLiveFrame(mailbox, nil)
    result = liveUpdateFromFrame(received.frame)
    releaseLiveFrame(received.frame)

  type TransitionProbe* = object
    accepted*: bool
    lastValue*: string
    lastSuccess*: bool
    maximumTimestamp*: string
    deliveryValue*: string
    errorMessage*: string

  proc probeTransition*(priorValue, maximumTimestamp,
      encodedTransition: string): TransitionProbe =
    ## Exercise the exact production planner with one tracked query.  A failed
    ## plan returns the untouched prior state and timestamp for regression tests.
    let state = LiveState(lastValue: priorValue, lastSuccess: true,
      hasLast: priorValue.len > 0)
    var active = initTable[uint32, LiveState]()
    active[0] = state
    result.lastValue = state.lastValue
    result.lastSuccess = state.lastSuccess
    result.maximumTimestamp = maximumTimestamp
    try:
      let planned = planTransition(parseJson(encodedTransition), active,
        initialVersion(), maximumTimestamp)
      result.accepted = true
      result.maximumTimestamp = planned.maximumTimestamp
      if planned.states.hasKey(0):
        result.lastValue = planned.states[0].lastValue
        result.lastSuccess = planned.states[0].lastSuccess
      if planned.deliveries.hasKey(0):
        result.deliveryValue = planned.deliveries[0].value
    except CatchableError as error:
      result.errorMessage = error.msg

proc newSessionId(): string =
  ## Convex validates this field as a UUID.  Use a version-4-shaped identifier
  ## with a time-derived suffix, avoiding a delegated UUID or RNG package.
  let stamp = uint64(epochTime() * 1_000_000.0)
  result = "00000000-0000-4000-8000-" & toHex(stamp, 12)

proc closeLiveSocket(socket: WebSocket) =
  if socket.isNil:
    return
  try:
    socket.hangup()
  except CatchableError:
    discard

proc sendLive(socket: WebSocket; value: JsonNode) =
  try:
    let writeFuture = socket.send($value)
    if not waitFor writeFuture.withTimeout(socketWriteTimeoutMilliseconds):
      closeLiveSocket(socket)
      if not waitFor writeFuture.withTimeout(
          socketRetirementTimeoutMilliseconds):
        raise newException(TransportError,
          "Live write timed out and did not retire after socket closure")
      try:
        waitFor writeFuture
      except CatchableError:
        discard
      raise newException(TransportError, "Live write timed out")
    waitFor writeFuture
  except CatchableError as error:
    raise newException(TransportError, "Live write: " & error.msg)

proc nextLivePacket(socket: WebSocket; pending: var Future[string];
    connectionGeneration: uint64;
    pendingGeneration: var uint64): tuple[status: LivePacketStatus,
    value: string, generation: uint64] =
  ## Polling the same future lets the owner process Add/Remove/debugDisconnect
  ## commands while a peer is quiet. Frame-progress deadlines live inside the
  ## transport, so a timeout abandons the connection rather than restarting at
  ## a false frame boundary.
  if pending.isNil:
    pending = socket.receiveStrPacket()
    pendingGeneration = connectionGeneration
  if not waitFor pending.withTimeout(socketReadSliceMilliseconds):
    return (packetWaiting, "", pendingGeneration)
  try:
    result = (packetReady, waitFor pending, pendingGeneration)
  finally:
    pending = nil
    pendingGeneration = 0

proc deliver(state: LiveState; update: LiveUpdate) =
  ## Four slots and a 2 MiB per-value ceiling bound queued Live data to about
  ## 8 MiB, including the encoded message bytes.  A slow consumer never grows
  ## an unbounded history of stale values; a full mailbox drops the new frame.
  if update.value.len > maxLiveValueBytes:
    sendLiveFrame(state.updates, makeLiveFrame(LiveUpdate(isError: true,
      errorName: "ProtocolError", errorMessage: "Live value exceeds 2 MiB",
      logs: "[]")))
    return
  sendLiveFrame(state.updates, makeLiveFrame(update))

proc wakeClosed(state: LiveState) =
  ## Receivers poll the shared closed flag, so shutdown cannot be lost merely
  ## because the bounded mailbox was already full.
  state.closed[].store(true)

proc respond(command: LiveCommand; ok: bool; message = "") =
  if not command.response.isNil:
    discard command.response[].trySend(LiveResponse(ok: ok, message: message))

proc respond(channel: ptr Channel[LiveResponse]; ok: bool; message = "") =
  if not channel.isNil:
    discard channel[].trySend(LiveResponse(ok: ok, message: message))

proc enqueueCommand(manager: LiveManager; command: LiveCommand): bool =
  let deadline = epochTime() + liveCommandTimeoutSeconds
  while epochTime() < deadline:
    if manager.done[].peek > 0:
      return false
    if manager.commands[].trySend(command):
      return true
    sleep(1)

proc awaitResponse(channel: ptr Channel[LiveResponse]): tuple[
    received: bool, answer: LiveResponse] =
  let deadline = epochTime() + liveCommandTimeoutSeconds
  while epochTime() < deadline:
    let received = channel[].tryRecv()
    if received[0]:
      return (true, received[1])
    sleep(1)
  result = (false, LiveResponse(ok: false,
    message: "Live owner response timed out"))

proc awaitOwnerDone(manager: LiveManager): bool =
  let deadline = epochTime() + liveCommandTimeoutSeconds
  while epochTime() < deadline:
    if manager.done[].peek > 0:
      discard manager.done[].recv()
      return true
    sleep(1)

proc liveWorker(args: LiveWorkerArgs) {.thread.} =
  let commands = args.commands
  let stopped = args.stopped
  let done = args.done
  let wsUrl = sharedTextString(args.wsUrl)
  var active = initTable[uint32, LiveState]()
  var socket: WebSocket
  var pending: Future[string]
  var pendingGeneration: uint64 = 0
  var connectionGeneration: uint64 = 0
  var querySetVersion = 0
  var remoteVersion = initialVersion()
  var maximumTimestamp = initialTimestamp
  var connectionCount = 0
  var lastCloseReason = "InitialConnect"
  var retryDelay = reconnectInitialSeconds
  var reconnectAt = epochTime()
  var pendingDebugResponse: ptr Channel[LiveResponse]

  proc failPendingActivations(message: string) =
    var failedIds: seq[uint32] = @[]
    for queryId, state in active:
      if not state.activationResponse.isNil:
        respond(state.activationResponse, false, message)
        state.activationResponse = nil
        state.closed[].store(true)
        wakeClosed(state)
        failedIds.add(queryId)
    for queryId in failedIds:
      active.del(queryId)

  proc retire(reason: string; schedule: bool): bool =
    ## Closing the descriptor is only the first half of retirement. Consume
    ## the old connection's pending receive before changing generations, so no
    ## callback from that socket can outlive a debug or close acknowledgement.
    closeLiveSocket(socket)
    var readRetired = true
    if not pending.isNil:
      let oldRead = pending
      # Closing the descriptor usually makes the pending read fail rather than
      # complete, and withTimeout re-raises that failure.  A failed read has
      # still retired, so only a genuine deadline leaves the callback pending.
      var retiredNow = true
      try:
        retiredNow = waitFor oldRead.withTimeout(
          socketRetirementTimeoutMilliseconds)
      except CatchableError:
        retiredNow = true
      if retiredNow:
        try:
          discard waitFor oldRead
        except CatchableError:
          discard
      else:
        readRetired = false
    socket = nil
    pending = nil
    pendingGeneration = 0
    querySetVersion = 0
    remoteVersion = initialVersion()
    connectionCount.inc
    lastCloseReason = reason
    if readRetired and schedule and active.len > 0:
      reconnectAt = epochTime() + retryDelay
      retryDelay = min(retryDelay * 2.0, reconnectMaximumSeconds)
    if not readRetired:
      lastCloseReason &= ": pending read did not retire"
      stopped[].store(true)
    result = readRetired

  proc connect(): bool =
    try:
      let future = newWebSocket(wsUrl)
      if not waitFor future.withTimeout(socketHandshakeTimeoutMilliseconds):
        raise newException(TransportError, "Live handshake timed out")
      socket = waitFor future
      connectionGeneration.inc
      remoteVersion = initialVersion()
      querySetVersion = 0
      var connectMessage = %*{
        "type": "Connect",
        "sessionId": newSessionId(),
        "connectionCount": connectionCount,
        "lastCloseReason": lastCloseReason,
        "maxObservedTimestamp": maximumTimestamp,
        "clientTs": 0
      }
      sendLive(socket, connectMessage)
      var ids: seq[uint32] = @[]
      for queryId in active.keys:
        ids.add(queryId)
      ids.sort()
      var modifications = newJArray()
      for queryId in ids:
        let state = active[queryId]
        if state.hasLast and state.lastSuccess:
          state.awaitingRehydration = true
        modifications.add(%*{
          "type": "Add",
          "queryId": queryId,
          "udfPath": state.path,
          "args": [parseJson(state.args)]
        })
      if modifications.len > 0:
        sendLive(socket, %*{
          "type": "ModifyQuerySet",
          "baseVersion": 0,
          "newVersion": 1,
          "modifications": modifications
        })
        querySetVersion = 1
      for state in active.values:
        if not state.activationResponse.isNil:
          respond(state.activationResponse, true)
          state.activationResponse = nil
      if not pendingDebugResponse.isNil:
        respond(pendingDebugResponse, true)
        pendingDebugResponse = nil
      result = true
    except CatchableError as error:
      discard retire(error.msg, true)
      failPendingActivations("Live activation failed: " & error.msg)
      if not pendingDebugResponse.isNil:
        respond(pendingDebugResponse, false,
          "Live Add replay failed: " & error.msg)
        pendingDebugResponse = nil
      result = false

  proc handleTransition(message: JsonNode) =
    let planned = planTransition(message, active, remoteVersion,
      maximumTimestamp)
    remoteVersion = planned.endVersion
    maximumTimestamp = planned.maximumTimestamp
    for queryId, statePlan in planned.states:
      if active.hasKey(queryId):
        let state = active[queryId]
        state.lastValue = statePlan.lastValue
        state.lastSuccess = statePlan.lastSuccess
        state.hasLast = statePlan.hasLast
        state.awaitingRehydration = statePlan.awaitingRehydration
    var ids: seq[uint32] = @[]
    for queryId in planned.deliveries.keys:
      ids.add(queryId)
    ids.sort()
    for queryId in ids:
      if active.hasKey(queryId):
        deliver(active[queryId], planned.deliveries[queryId])

  while not stopped[].load:
    var command: LiveCommand
    let received = commands[].tryRecv()
    if received[0]:
      command = received[1]
      case command.kind
      of "subscribe":
        if active.len >= maxLiveSubscriptions:
          respond(command, false, "Live subscription limit reached")
          continue
        active[command.queryId] = LiveState(
          updates: command.updates, closed: command.closed,
          path: command.path, args: command.args,
          activationResponse: command.response)
        if not socket.isNil:
          try:
            sendLive(socket, %*{
              "type": "ModifyQuerySet",
              "baseVersion": querySetVersion,
              "newVersion": querySetVersion + 1,
              "modifications": [%*{
                "type": "Add", "queryId": command.queryId,
                "udfPath": command.path, "args": [parseJson(command.args)]
              }]
            })
            querySetVersion.inc
            active[command.queryId].activationResponse = nil
            respond(command, true)
          except CatchableError as error:
            let failed = active[command.queryId]
            active.del(command.queryId)
            failed.closed[].store(true)
            wakeClosed(failed)
            respond(command, false, "Live Add failed: " & error.msg)
            discard retire(error.msg, true)
      of "unsubscribe":
        if active.hasKey(command.queryId):
          let state = active[command.queryId]
          active.del(command.queryId)
          state.closed[].store(true)
          wakeClosed(state)
          if not socket.isNil:
            try:
              sendLive(socket, %*{
                "type": "ModifyQuerySet",
                "baseVersion": querySetVersion,
                "newVersion": querySetVersion + 1,
                "modifications": [%*{
                  "type": "Remove", "queryId": command.queryId
                }]
              })
              querySetVersion.inc
            except CatchableError as error:
              respond(command, false, "Live Remove failed: " & error.msg)
              discard retire(error.msg, true)
              continue
        respond(command, true)
        if active.len == 0:
          discard retire("NoActiveSubscriptions", false)
      of "debugDisconnect":
        if socket.isNil:
          respond(command, false, "Live WebSocket is not connected")
        else:
          if retire("DebugDisconnect", true):
            reconnectAt = epochTime()
            ## Keep the adapter command blocked until the replacement handshake
            ## and every active Add have been sent.  The next controller command
            ## can then be an external mutation without a timing race.
            pendingDebugResponse = command.response
          else:
            respond(command, false,
              "old Live receive did not retire after socket closure")
      of "close":
        stopped[].store(true)
        let retired = retire("ClientClosed", false)
        if not pendingDebugResponse.isNil:
          respond(pendingDebugResponse, false, "client closed during reconnect")
          pendingDebugResponse = nil
        failPendingActivations("client closed during activation")
        for state in active.values:
          state.closed[].store(true)
          wakeClosed(state)
        active.clear()
        respond(command, retired,
          if retired: "" else: "old Live receive did not retire after closure")
      else:
        respond(command, false, "unknown Live command")

    if stopped[].load:
      break
    if socket.isNil:
      if active.len == 0:
        sleep(10)
      elif epochTime() >= reconnectAt:
        if connect():
          retryDelay = reconnectInitialSeconds
        else:
          sleep(20)
      else:
        sleep(20)
      continue

    var packet: tuple[status: LivePacketStatus, value: string,
      generation: uint64]
    try:
      packet = nextLivePacket(socket, pending, connectionGeneration,
        pendingGeneration)
    except CatchableError as error:
      for state in active.values:
        deliver(state, LiveUpdate(isError: true, errorName: "TransportError",
          errorMessage: "Live read: " & error.msg, logs: "[]"))
      discard retire("Live read: " & error.msg, true)
      continue
    if packet.generation != connectionGeneration:
      continue
    if packet.status == packetReady:
      if packet.value.len == 0:
        continue
      try:
        let message = parseJson(packet.value)
        if message.kind != JObject or not message.hasKey("type") or
            message["type"].kind != JString:
          raise newException(ProtocolError, "Live message omitted type")
        case message["type"].getStr
        of "Transition":
          handleTransition(message)
          retryDelay = reconnectInitialSeconds
        of "Ping", "MutationResponse", "ActionResponse":
          retryDelay = reconnectInitialSeconds
        of "FatalError", "AuthError":
          raise newException(ProtocolError,
            message["type"].getStr & ": " &
            (if message.hasKey("error"): message["error"].getStr else: "server error"))
        of "TransitionChunk":
          raise newException(ProtocolError, "TransitionChunk is not supported")
        else:
          raise newException(ProtocolError,
            "unknown Live message: " & message["type"].getStr)
      except CatchableError as error:
        for state in active.values:
          deliver(state, LiveUpdate(isError: true, errorName: "ProtocolError",
            errorMessage: error.msg, logs: "[]"))
        discard retire(error.msg, true)

  closeLiveSocket(socket)
  for state in active.values:
    state.closed[].store(true)
    wakeClosed(state)
  if not done[].trySend(true):
    discard

proc newLiveManager(client: Client): LiveManager =
  let parsed = parseUri(client.deploymentUrl)
  var scheme = if parsed.scheme == "https": "wss" else: "ws"
  var host = parsed.hostname
  if parsed.port.len > 0:
    host &= ":" & parsed.port
  let commands = sharedChannel[LiveCommand](liveCommandQueueSlots)
  let stopped = sharedAtomicBool(false)
  let done = sharedChannel[bool](1)
  result = LiveManager(
    commands: commands,
    stopped: stopped,
    done: done,
    workerWsUrl: sharedText(scheme & "://" & host & "/api/sync"),
    queueBudget: sharedLiveBudget()
  )
  createThread(result.worker, liveWorker, LiveWorkerArgs(commands: commands,
    stopped: stopped, done: done, wsUrl: result.workerWsUrl))

proc subscribe*(client: Client; path: string; args: JsonNode): LiveSubscription =
  client.ensureOpen()
  if path.len == 0:
    raise newException(ValueError, "Convex function path is required")
  if path.len > maxFunctionPathBytes:
    raise newException(ValueError, "Convex function path exceeds 64 KiB")
  let encodedArgs = $jsonObjectArgs(args)
  if encodedArgs.len > maxRequestBytes:
    raise newException(ValueError,
      "Convex Live arguments exceed encoded byte limit")
  if client.live.isNil:
    client.live = newLiveManager(client)
  if client.nextQueryId == high(uint32):
    raise newException(TransportError, "Live query id space is exhausted")
  new(result)
  result.updates = sharedMailbox(client.live.queueBudget)
  result.closed = sharedAtomicBool(false)
  result.manager = client.live
  result.queryId = client.nextQueryId
  client.nextQueryId.inc
  let response = sharedChannel[LiveResponse](1)
  let command = LiveCommand(kind: "subscribe", path: path,
    args: encodedArgs, queryId: result.queryId, updates: result.updates,
    closed: result.closed, response: response)
  if not enqueueCommand(result.manager, command):
    releaseSharedChannel(response)
    deallocShared(result.updates)
    deallocShared(result.closed)
    result.updates = nil
    result.closed = nil
    result.storageReleased = true
    raise newException(TransportError, "Live owner command queue is unavailable")
  let reply = awaitResponse(response)
  if reply.received:
    releaseSharedChannel(response)
  if not reply.received:
    # The owner may still hold the response and mailbox pointers. Mark this
    # abandoned handle closed, but leak its bounded storage rather than race a
    # late Add acknowledgement or delivery with deallocation.
    result.closed[].store(true)
    discard enqueueCommand(result.manager, LiveCommand(kind: "unsubscribe",
      queryId: result.queryId))
    result.storageReleased = true
    raise newException(TransportError, reply.answer.message)
  if not reply.answer.ok:
    drainLiveMailbox(result.updates)
    deallocShared(result.updates)
    deallocShared(result.closed)
    result.updates = nil
    result.closed = nil
    result.storageReleased = true
    raise newException(TransportError, reply.answer.message)

proc nextUpdate*(subscription: LiveSubscription): LiveUpdate =
  if subscription.isNil or subscription.storageReleased or
      subscription.closed[].load:
    raise newException(ConvexError, "subscription is closed")
  var received = recvLiveFrame(subscription.updates, subscription.closed)
  if not received.available:
    raise newException(ConvexError, "subscription is closed")
  result = liveUpdateFromFrame(received.frame)
  releaseLiveFrame(received.frame)

proc releaseSubscriptionStorage(subscription: LiveSubscription) =
  if subscription.isNil or subscription.storageReleased:
    return
  drainLiveMailbox(subscription.updates)
  deallocShared(subscription.updates)
  deallocShared(subscription.closed)
  subscription.updates = nil
  subscription.closed = nil
  subscription.storageReleased = true

proc close*(subscription: LiveSubscription) =
  if subscription.isNil or subscription.storageReleased:
    return
  if subscription.closed[].exchange(true):
    # Client.close may have already retired the owner. The public handle still
    # owns its mailbox and releases it here after observing the closed flag.
    if not subscription.externalRelay:
      releaseSubscriptionStorage(subscription)
    return
  let response = sharedChannel[LiveResponse](1)
  if not enqueueCommand(subscription.manager, LiveCommand(kind: "unsubscribe",
      queryId: subscription.queryId, response: response)):
    releaseSharedChannel(response)
    raise newException(TransportError, "Live owner command queue is unavailable")
  let reply = awaitResponse(response)
  if reply.received:
    releaseSharedChannel(response)
  if not reply.received:
    # As with activation, a timed-out owner may still touch these pointers.
    # Keep the bounded storage alive instead of creating a shutdown UAF.
    raise newException(TransportError, reply.answer.message)
  if not reply.answer.ok:
    if not subscription.externalRelay:
      releaseSubscriptionStorage(subscription)
    raise newException(TransportError, reply.answer.message)
  if not subscription.externalRelay:
    releaseSubscriptionStorage(subscription)

when defined(convexadapter):
  proc markAdapterRelay*(subscription: LiveSubscription) =
    if subscription.isNil or subscription.storageReleased:
      raise newException(ConvexError, "subscription is closed")
    subscription.externalRelay = true

  proc releaseAdapterSubscription*(subscription: LiveSubscription) =
    releaseSubscriptionStorage(subscription)

  proc debugDisconnectForAdapter*(client: Client): string =
    client.ensureOpen()
    if client.live.isNil:
      return "Live WebSocket has not been started"
    let response = sharedChannel[LiveResponse](1)
    if not enqueueCommand(client.live,
        LiveCommand(kind: "debugDisconnect", response: response)):
      releaseSharedChannel(response)
      return "Live owner command queue is unavailable"
    let reply = awaitResponse(response)
    if reply.received:
      releaseSharedChannel(response)
    if not reply.received or not reply.answer.ok:
      return reply.answer.message
    return ""
