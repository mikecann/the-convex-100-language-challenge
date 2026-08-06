## Native Convex client used by the Nim educational demonstration.
##
## The HTTP request envelope, response errors, and Live transition state machine
## are implemented here.  Nim's standard HTTP/TLS/JSON libraries and the
## pinned treeform/ws transport are only transport helpers.

import std/[algorithm, asyncdispatch, atomics, httpclient, json, math,
  net, os, strutils, tables, times, uri]
import ws
import ./protocol

export protocol

const
  clientVersion* = "nim-0.2.0"
  maxResponseBytes* = 2 * 1024 * 1024
  maxLiveValueBytes* = 2 * 1024 * 1024
  liveQueueSlots* = 4
  initialTimestamp = "AAAAAAAAAAA="
  reconnectInitialSeconds = 0.1
  reconnectMaximumSeconds = 15.0
  socketReadSliceMilliseconds = 100
  socketHandshakeTimeoutMilliseconds = 10_000

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

  LiveManager = ref object
    commands: ptr Channel[LiveCommand]
    stopped: ptr Atomic[bool]
    done: ptr Channel[bool]
    wsUrl: string
    clientVersion: string
    authToken: string
    worker: Thread[LiveWorkerArgs]

  LiveSubscription* = ref object
    updates*: ptr Channel[LiveUpdate]
    manager: LiveManager
    queryId: uint32
    closed*: ptr Atomic[bool]

  LiveState = ref object
    updates: ptr Channel[LiveUpdate]
    closed: ptr Atomic[bool]
    path: string
    args: string
    lastValue: string
    lastSuccess: bool
    hasLast: bool
    awaitingRehydration: bool

  LiveCommand = object
    kind: string
    path: string
    args: string
    queryId: uint32
    updates: ptr Channel[LiveUpdate]
    closed: ptr Atomic[bool]
    response: ptr Channel[LiveResponse]

  LiveResponse = object
    ok: bool
    message: string

  LiveWorkerArgs = object
    manager: LiveManager

  Client* = ref object
    deploymentUrl*: string
    authToken*: string
    clientVersion*: string
    http: HttpClient
    closed: ptr Atomic[bool]
    live: LiveManager
    nextQueryId: uint32

proc sharedChannel[T](capacity: int): ptr Channel[T] =
  ## Nim channels must live in the process-wide shared heap when a pointer to
  ## them crosses a Thread boundary.  A ref Channel allocates thread-local
  ## memory and is unsafe under ARC.
  result = cast[ptr Channel[T]](allocShared0(sizeof(Channel[T])))
  result[].open(capacity)

proc sharedAtomicBool(initial: bool): ptr Atomic[bool] =
  result = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
  result[].store(initial)

proc jsonObjectArgs(args: JsonNode): JsonNode =
  if args.isNil:
    return newJObject()
  if args.kind != JObject:
    raise newException(ValueError, "Convex arguments must be a named JSON object")
  return args

proc parseLogs(node: JsonNode): seq[string] =
  if not node.hasKey("logLines"):
    return @[]
  if node["logLines"].kind != JArray:
    raise newException(ProtocolError, "Convex logLines must be an array")
  for item in node["logLines"].getElems:
    if item.kind != JString:
      raise newException(ProtocolError, "Convex logLines must contain strings")
    result.add(item.getStr)

proc newClient*(deploymentUrl: string; authToken = ""): Client =
  let parsed = parseUri(deploymentUrl)
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
    raise newException(ValueError,
      "Convex deployment URL must use http or https and include a host")
  var base = parsed
  base.query = ""
  base.anchor = ""
  result = Client(
    deploymentUrl: ($base).strip(leading = false, chars = {'/'}),
    authToken: authToken,
    clientVersion: clientVersion
  )
  result.closed = sharedAtomicBool(false)
  result.http = newHttpClient()
  result.http.timeout = 30_000

proc ensureOpen(client: Client) =
  if client.isNil or client.closed[].load:
    raise newException(ConvexError, "client is closed")

proc setAuth*(client: Client; token: string) =
  client.ensureOpen()
  client.authToken = token

proc close*(client: Client) =
  if client.isNil:
    return
  if client.closed[].exchange(true):
    return
  if not client.live.isNil:
    ## Stop is atomic and the owner checks it between bounded receive slices.
    ## Do not enqueue a shutdown command here: the caller may be unwinding from
    ## a failed subscribe before the worker has finished constructing its
    ## socket state.  The owner closes its socket and update channels on exit.
    client.live.stopped[].store(true)
  client.http.close()

proc call*(client: Client; operation, path: string; args: JsonNode): Result =
  client.ensureOpen()
  if path.len == 0:
    raise newException(ValueError, "Convex function path is required")
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

  let http = newHttpClient()
  http.timeout = 30_000
  defer: http.close()
  let response = try:
    http.request(client.deploymentUrl & "/api/" & operation,
      httpMethod = HttpPost, body = $request, headers = headers)
  except CatchableError as error:
    raise newException(TransportError, operation & ": " & error.msg)
  if response.code.int < 200 or response.code.int >= 300:
    raise newException(TransportError,
      operation & ": HTTP status " & $response.code.int)
  let body = response.body
  if body.len > maxResponseBytes:
    raise newException(TransportError, "response exceeds 2 MiB")

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
    let message = if decoded.hasKey("errorMessage") and
        decoded["errorMessage"].kind == JString:
      decoded["errorMessage"].getStr
    else:
      "Convex function failed"
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

proc stateVersion(querySet, identity: int; timestamp: string): JsonNode =
  result = %*{
    "querySet": querySet,
    "identity": identity,
    "ts": timestamp
  }

proc versionMatches(left, right: JsonNode): bool =
  left.kind == JObject and right.kind == JObject and
    left.hasKey("querySet") and left.hasKey("identity") and left.hasKey("ts") and
    right.hasKey("querySet") and right.hasKey("identity") and right.hasKey("ts") and
    left["querySet"].getInt == right["querySet"].getInt and
    left["identity"].getInt == right["identity"].getInt and
    left["ts"].getStr == right["ts"].getStr

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

proc newSessionId(): string =
  ## Convex validates this field as a UUID.  Use a version-4-shaped identifier
  ## with a time-derived suffix, avoiding a delegated UUID or RNG package.
  let stamp = uint64(epochTime() * 1_000_000.0)
  result = "00000000-0000-4000-8000-" & toHex(stamp, 12)

proc sendLive(socket: WebSocket; value: JsonNode) =
  try:
    waitFor socket.send($value)
  except CatchableError as error:
    raise newException(TransportError, "Live write: " & error.msg)

proc closeLiveSocket(socket: WebSocket) =
  if socket.isNil:
    return
  try:
    socket.hangup()
  except CatchableError:
    discard

proc nextLivePacket(socket: WebSocket; pending: var Future[string]): tuple[
    ready: bool, value: string] =
  ## Polling the same future lets the owner process Add/Remove/debugDisconnect
  ## commands while a peer is quiet.  On a deadline we abandon this socket,
  ## which also abandons any half-read frame instead of restarting at a false
  ## frame boundary on the next connection.
  if pending.isNil:
    pending = socket.receiveStrPacket()
  if not waitFor pending.withTimeout(socketReadSliceMilliseconds):
    return (false, "")
  try:
    result = (true, waitFor pending)
  finally:
    pending = nil

proc deliver(state: LiveState; update: LiveUpdate) =
  ## Four slots and a 2 MiB per-value ceiling bound queued Live data to about
  ## 8 MiB, including the encoded message bytes.  A slow consumer observes the
  ## newest current value, not an unbounded history of stale values.
  if update.value.len > maxLiveValueBytes:
    return
  if not state.updates[].trySend(update):
    discard state.updates[].tryRecv()
    discard state.updates[].trySend(update)

proc wakeClosed(state: LiveState) =
  ## Wake an adapter relay without closing the shared channel under a blocked
  ## receiver.  The relay checks the atomic flag before decoding this marker.
  let marker = LiveUpdate(isError: true, errorName: "__closed__")
  if not state.updates[].trySend(marker):
    discard state.updates[].tryRecv()
    discard state.updates[].trySend(marker)

proc respond(command: LiveCommand; ok: bool; message = "") =
  if not command.response.isNil:
    command.response[].send(LiveResponse(ok: ok, message: message))

proc liveWorker(args: LiveWorkerArgs) {.thread.} =
  let manager = args.manager
  var active = initTable[uint32, LiveState]()
  var socket: WebSocket
  var pending: Future[string]
  var querySetVersion = 0
  var remoteVersion = stateVersion(0, 0, initialTimestamp)
  var maximumTimestamp = initialTimestamp
  var connectionCount = 0
  var lastCloseReason = "InitialConnect"
  var retryDelay = reconnectInitialSeconds
  var reconnectAt = epochTime()

  proc retire(reason: string; schedule: bool) =
    closeLiveSocket(socket)
    socket = nil
    pending = nil
    querySetVersion = 0
    remoteVersion = stateVersion(0, 0, initialTimestamp)
    connectionCount.inc
    lastCloseReason = reason
    if schedule and active.len > 0:
      reconnectAt = epochTime() + retryDelay
      retryDelay = min(retryDelay * 2.0, reconnectMaximumSeconds)

  proc connect(): bool =
    try:
      let future = newWebSocket(manager.wsUrl)
      if not waitFor future.withTimeout(socketHandshakeTimeoutMilliseconds):
        raise newException(TransportError, "Live handshake timed out")
      socket = waitFor future
      remoteVersion = stateVersion(0, 0, initialTimestamp)
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
      result = true
    except CatchableError as error:
      retire(error.msg, true)
      result = false

  proc handleTransition(message: JsonNode) =
    if not message.hasKey("startVersion") or not message.hasKey("endVersion") or
        not message.hasKey("modifications") or
        message["modifications"].kind != JArray:
      raise newException(ProtocolError, "Transition omitted required fields")
    if not versionMatches(message["startVersion"], remoteVersion):
      raise newException(ProtocolError, "Transition start version disagreed")
    let endVersion = message["endVersion"]
    discard liveTimestampBytes(endVersion["ts"].getStr)
    var changed = initTable[uint32, LiveUpdate]()
    for modification in message["modifications"].getElems:
      if not modification.hasKey("type") or not modification.hasKey("queryId"):
        raise newException(ProtocolError, "Transition modification is incomplete")
      let queryId = uint32(modification["queryId"].getInt)
      case modification["type"].getStr
      of "QueryUpdated":
        if not modification.hasKey("value"):
          raise newException(ProtocolError, "QueryUpdated omitted value")
        let value = $modification["value"]
        if value.len > maxLiveValueBytes:
          raise newException(ProtocolError, "Live value exceeds 2 MiB")
        let logs = if modification.hasKey("logLines"): $modification["logLines"] else: "[]"
        if active.hasKey(queryId):
          let state = active[queryId]
          let wasAwaitingRehydration = state.awaitingRehydration
          state.awaitingRehydration = false
          if state.hasLast and state.lastSuccess and wasAwaitingRehydration and
              state.lastValue == value:
            discard
          else:
            changed[queryId] = LiveUpdate(value: value, logs: logs)
          state.lastValue = value
          state.lastSuccess = true
          state.hasLast = true
      of "QueryFailed":
        let messageText = if modification.hasKey("errorMessage"):
          modification["errorMessage"].getStr else: "Convex query failed"
        let data = if modification.hasKey("errorData"):
          $modification["errorData"] else: ""
        let logs = if modification.hasKey("logLines"): $modification["logLines"] else: "[]"
        if active.hasKey(queryId):
          let state = active[queryId]
          state.awaitingRehydration = false
          state.lastSuccess = false
          state.hasLast = true
          changed[queryId] = LiveUpdate(isError: true, errorName: "FunctionError",
            errorMessage: messageText, errorData: data, logs: logs)
      of "QueryRemoved":
        if active.hasKey(queryId):
          active[queryId].awaitingRehydration = false
      else:
        raise newException(ProtocolError,
          "unknown Transition modification: " & modification["type"].getStr)

    remoteVersion = endVersion
    updateMaxTimestamp(maximumTimestamp, endVersion["ts"].getStr)
    var ids: seq[uint32] = @[]
    for queryId in changed.keys:
      ids.add(queryId)
    ids.sort()
    for queryId in ids:
      if active.hasKey(queryId):
        deliver(active[queryId], changed[queryId])

  while not manager.stopped[].load:
    var command: LiveCommand
    let received = manager.commands[].tryRecv()
    if received[0]:
      command = received[1]
      case command.kind
      of "subscribe":
        active[command.queryId] = LiveState(
          updates: command.updates, closed: command.closed,
          path: command.path, args: command.args)
        respond(command, true)
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
          except CatchableError as error:
            retire(error.msg, true)
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
              retire(error.msg, true)
        respond(command, true)
        if active.len == 0:
          retire("NoActiveSubscriptions", false)
      of "debugDisconnect":
        if socket.isNil:
          respond(command, false, "Live WebSocket is not connected")
        else:
          retire("DebugDisconnect", true)
          reconnectAt = epochTime()
          respond(command, true)
      of "close":
        manager.stopped[].store(true)
        retire("ClientClosed", false)
        for state in active.values:
          state.closed[].store(true)
          wakeClosed(state)
        active.clear()
        respond(command, true)
      else:
        respond(command, false, "unknown Live command")

    if manager.stopped[].load:
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

    let packet = nextLivePacket(socket, pending)
    if packet.ready:
      if packet.value.len == 0:
        continue
      try:
        let message = parseJson(packet.value)
        if not message.hasKey("type"):
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
          state.lastSuccess = false
          state.hasLast = true
        retire(error.msg, true)
    elif pending.isNil and not socket.isNil:
      # A read deadline is a transport failure.  The socket has already been
      # abandoned by nextLivePacket, so no partial frame is reused.
      retire("Live read deadline", true)

  closeLiveSocket(socket)
  for state in active.values:
    state.closed[].store(true)
    wakeClosed(state)
  if not manager.done[].trySend(true):
    discard

proc newLiveManager(client: Client): LiveManager =
  let parsed = parseUri(client.deploymentUrl)
  var scheme = if parsed.scheme == "https": "wss" else: "ws"
  var host = parsed.hostname
  if parsed.port.len > 0:
    host &= ":" & parsed.port
  let commands = sharedChannel[LiveCommand](64)
  let stopped = sharedAtomicBool(false)
  let done = sharedChannel[bool](1)
  result = LiveManager(
    commands: commands,
    stopped: stopped,
    done: done,
    wsUrl: scheme & "://" & host & "/api/sync",
    clientVersion: client.clientVersion,
    authToken: client.authToken
  )
  createThread(result.worker, liveWorker, LiveWorkerArgs(manager: result))

proc subscribe*(client: Client; path: string; args: JsonNode): LiveSubscription =
  client.ensureOpen()
  if path.len == 0:
    raise newException(ValueError, "Convex function path is required")
  if client.live.isNil:
    client.live = newLiveManager(client)
  new(result)
  result.updates = sharedChannel[LiveUpdate](liveQueueSlots)
  result.closed = sharedAtomicBool(false)
  result.manager = client.live
  result.queryId = client.nextQueryId
  client.nextQueryId.inc
  let response = sharedChannel[LiveResponse](1)
  let command = LiveCommand(kind: "subscribe", path: path,
    args: $jsonObjectArgs(args), queryId: result.queryId, updates: result.updates,
    closed: result.closed, response: response)
  result.manager.commands[].send(command)
  let answer = response[].recv()
  if not answer.ok:
    raise newException(TransportError, answer.message)

proc nextUpdate*(subscription: LiveSubscription): LiveUpdate =
  if subscription.isNil or subscription.closed[].load:
    raise newException(ConvexError, "subscription is closed")
  return subscription.updates[].recv()

proc close*(subscription: LiveSubscription) =
  if subscription.isNil or subscription.closed[].exchange(true):
    return
  let response = sharedChannel[LiveResponse](1)
  subscription.manager.commands[].send(LiveCommand(kind: "unsubscribe",
    queryId: subscription.queryId, response: response))
  discard response[].recv()

when defined(convexadapter):
  proc debugDisconnectForAdapter*(client: Client): string =
    client.ensureOpen()
    if client.live.isNil:
      return "Live WebSocket has not been started"
    let response = sharedChannel[LiveResponse](1)
    client.live.commands[].send(LiveCommand(kind: "debugDisconnect", response: response))
    let answer = response[].recv()
    if not answer.ok: return answer.message
    return ""
