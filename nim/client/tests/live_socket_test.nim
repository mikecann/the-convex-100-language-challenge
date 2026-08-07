## Deterministic local TCP/WebSocket fixtures for the production Live owner.
## Channels are readiness barriers. The tests never sleep to guess when a
## handshake, Add, partial frame, reconnect, or peer retirement has happened.

import std/[base64, json, net, posix, sha1, strutils, times, unittest]
import ../convex

const
  websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  zeroTimestamp = "AAAAAAAAAAA="
  oneTimestamp = "AQAAAAAAAAA="
  twoTimestamp = "AgAAAAAAAAA="
  threeTimestamp = "AwAAAAAAAAA="
  fourTimestamp = "BAAAAAAAAAA="

type
  FixtureKind = enum
    fixtureLifecycle
    fixtureFiveReconnect
    fixturePartialClose
    fixturePartialRecovery
    fixtureOversizedFragment
    fixtureFailedAdd
    fixtureIdleClose
    fixtureFloodClose

  FixtureArgs = object
    kind: FixtureKind
    port: ptr Channel[int]
    ready: ptr Channel[bool]
    result: ptr Channel[string]

  Fixture = tuple[thread: ptr Thread[FixtureArgs], port: int,
    ready: ptr Channel[bool], result: ptr Channel[string]]

  Frame = object
    opcode: int
    payload: string

proc sharedChannel[T](capacity: int): ptr Channel[T] =
  result = cast[ptr Channel[T]](allocShared0(sizeof(Channel[T])))
  result[].open(capacity)

proc receiveExact(peer: Socket; length: int; timeout = 8_000): string =
  result = peer.recv(length, timeout)
  if result.len != length:
    raise newException(IOError, "fixture peer closed during frame")

proc websocketAccept(key: string): string =
  let digest = Sha1Digest(secureHash(key & websocketGuid))
  var raw = newString(digest.len)
  for index, value in digest:
    raw[index] = char(value)
  result = encode(raw)

proc acceptWebSocket(listener: Socket): Socket =
  var peer: owned(Socket)
  listener.accept(peer)
  discard peer.recvLine(timeout = 8_000)
  var key = ""
  while true:
    let line = peer.recvLine(timeout = 8_000)
    if line.len == 0:
      raise newException(IOError, "fixture handshake ended early")
    if line == "\r\n":
      break
    let pieces = line.split(":", maxsplit = 1)
    if pieces.len == 2 and pieces[0].toLowerAscii == "sec-websocket-key":
      key = pieces[1].strip
  if key.len == 0:
    raise newException(IOError, "fixture handshake omitted key")
  peer.send("HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & websocketAccept(key) & "\r\n\r\n")
  result = peer

proc receiveFrame(peer: Socket): Frame =
  let header = receiveExact(peer, 2)
  result.opcode = int(uint8(header[0]) and 0x0f)
  let masked = (uint8(header[1]) and 0x80) != 0
  var length = uint64(uint8(header[1]) and 0x7f)
  if length == 126:
    let encoded = receiveExact(peer, 2)
    length = (uint64(uint8(encoded[0])) shl 8) or uint64(uint8(encoded[1]))
  elif length == 127:
    let encoded = receiveExact(peer, 8)
    length = 0
    for value in encoded:
      length = (length shl 8) or uint64(uint8(value))
  if length > uint64(maxLiveValueBytes + 64 * 1024):
    raise newException(IOError, "fixture received oversized client frame")
  let mask = if masked: receiveExact(peer, 4) else: ""
  result.payload = receiveExact(peer, int(length))
  if masked:
    for index in 0 ..< result.payload.len:
      result.payload[index] = char(uint8(result.payload[index]) xor
        uint8(mask[index mod 4]))

proc receiveClientJson(peer: Socket): JsonNode =
  while true:
    let frame = receiveFrame(peer)
    if frame.opcode == 1:
      return parseJson(frame.payload)

proc frameHeader(final: bool; opcode, length: int): string =
  result.add(char((if final: 0x80 else: 0) or opcode))
  if length < 126:
    result.add(char(length))
  elif length <= 65_535:
    result.add(char(126))
    result.add(char((length shr 8) and 0xff))
    result.add(char(length and 0xff))
  else:
    result.add(char(127))
    for shift in countdown(56, 0, 8):
      result.add(char(int((uint64(length) shr shift) and 0xff)))

const raiseOnDisconnect: set[SocketFlag] = {}
  ## Nim's default {SafeDisconn} makes send() swallow EPIPE and then retry
  ## forever, because its retry loop never advances the written count.  A
  ## fixture that floods a closing client must observe the disconnect instead.

proc sendFrame(peer: Socket; final: bool; opcode: int; payload: string) =
  peer.send(frameHeader(final, opcode, payload.len) & payload,
    flags = raiseOnDisconnect)

proc sendJson(peer: Socket; value: JsonNode) =
  sendFrame(peer, true, 1, $value)

proc version(querySet: int; timestamp: string): JsonNode =
  %*{"querySet": querySet, "identity": 0, "ts": timestamp}

proc transition(startQuerySet, endQuerySet: int; startTimestamp,
    endTimestamp: string; modifications: JsonNode): JsonNode =
  %*{
    "type": "Transition",
    "startVersion": version(startQuerySet, startTimestamp),
    "endVersion": version(endQuerySet, endTimestamp),
    "modifications": modifications
  }

proc queryIdFromAdd(add: JsonNode): int =
  add["modifications"][0]["queryId"].getInt

proc waitForRemoveOrClose(peer: Socket) =
  while true:
    try:
      let message = receiveClientJson(peer)
      if message.hasKey("type") and message["type"].getStr ==
          "ModifyQuerySet" andmessage["modifications"][0]["type"].getStr == "Remove":
        return
    except CatchableError:
      return

proc waitForPeerClose(peer: Socket) =
  try:
    while peer.recv(1, 8_000).len > 0:
      discard
  except CatchableError:
    discard

proc sendRehydrationBarrier(peer: Socket; queryId: int) =
  ## A control Pong proves the owner committed the preceding unchanged value.
  ## The next mutation can then test suppression without a timing sleep.
  sendJson(peer, transition(0, 1, zeroTimestamp, oneTimestamp, %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": 0}, "logLines": []}
  ]))
  sendFrame(peer, true, 9, "rehydrated")
  while true:
    let frame = receiveFrame(peer)
    if frame.opcode == 10 and frame.payload == "rehydrated":
      return

proc readHttpRequest(peer: Socket): string =
  result = peer.recvLine(timeout = 8_000)
  var contentLength = 0
  while true:
    let line = peer.recvLine(timeout = 8_000)
    if line.len == 0 or line == "\r\n":
      break
    let pieces = line.split(":", maxsplit = 1)
    if pieces.len == 2 and pieces[0].toLowerAscii == "content-length":
      contentLength = parseInt(pieces[1].strip)
  if contentLength > 0:
    let body = peer.recv(contentLength, 8_000)
    if body.len != contentLength:
      raise newException(IOError, "fixture HTTP body ended early")

proc fiveReconnectFixture(listener: Socket; args: FixtureArgs) =
  var peer = acceptWebSocket(listener)
  let initialConnect = receiveClientJson(peer)
  if initialConnect["connectionCount"].getInt != 0:
    raise newException(ValueError, "initial connectionCount was not zero")
  let queryId = queryIdFromAdd(receiveClientJson(peer))
  sendJson(peer, transition(0, 1, zeroTimestamp, oneTimestamp, %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": 0}, "logLines": []}
  ]))

  for attempt in 1 .. 5:
    waitForPeerClose(peer)
    peer.close()
    peer = acceptWebSocket(listener)
    let reconnect = receiveClientJson(peer)
    let replayId = queryIdFromAdd(receiveClientJson(peer))
    if reconnect["connectionCount"].getInt != attempt:
      raise newException(ValueError, "reconnect connectionCount was wrong")
    if replayId != queryId:
      raise newException(ValueError, "reconnect changed the active query id")

  # The fifth debug acknowledgement is now allowed to return. Before accepting
  # its HTTP mutation, prove the owner committed an unchanged rehydration.
  sendRehydrationBarrier(peer, queryId)
  var httpPeer: owned(Socket)
  listener.accept(httpPeer)
  let requestLine = readHttpRequest(httpPeer)
  if not requestLine.contains("POST /api/mutation"):
    raise newException(ValueError, "fixture expected the final mutation")
  let responseBody = $(%*{
    "status": "success",
    "value": {"applied": true, "state": {"count": 1}},
    "logLines": []
  })
  httpPeer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
    "Content-Length: " & $responseBody.len &
    "\r\nConnection: close\r\n\r\n" & responseBody)
  httpPeer.close()

  sendJson(peer, transition(1, 2, oneTimestamp, twoTimestamp, %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": 1}, "logLines": []}
  ]))
  waitForRemoveOrClose(peer)
  peer.close()

proc sendFragmentedUnicodeInitial(peer: Socket; queryId: int) =
  let payload = $transition(0, 1, zeroTimestamp, oneTimestamp, %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": 0, "note": "fragmented 雪"}, "logLines": []}
  ])
  let unicodeAt = payload.find("雪")
  if unicodeAt < 0:
    raise newException(ValueError, "fixture Unicode marker missing")
  let splitAt = unicodeAt + 1
  sendFrame(peer, false, 1, payload[0 ..< splitAt])
  sendFrame(peer, true, 9, "control")
  sendFrame(peer, true, 0, payload[splitAt .. ^1])

proc lifecycleFixture(listener: Socket; args: FixtureArgs) =
  let first = acceptWebSocket(listener)
  discard receiveClientJson(first) # Connect
  let add = receiveClientJson(first)
  let queryId = queryIdFromAdd(add)
  sendFragmentedUnicodeInitial(first, queryId)
  sendJson(first, transition(1, 2, oneTimestamp, twoTimestamp, %*[
    {"type": "QueryFailed", "queryId": queryId,
      "errorMessage": "fixture failure", "errorData": {"code": "BROKEN"},
      "logLines": ["failed"]}
  ]))
  sendJson(first, transition(2, 3, twoTimestamp, threeTimestamp, %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": 1}, "logLines": ["recovered"]}
  ]))
  # The first modification is valid, but the later QueryFailed is malformed.
  # Atomic parsing must commit neither the value nor the end timestamp.
  sendJson(first, transition(3, 4, threeTimestamp, "ZAAAAAAAAAA=", %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": 9}, "logLines": []},
    {"type": "QueryFailed", "queryId": queryId,
      "errorData": {"code": "NO_MESSAGE"}, "logLines": []}
  ]))
  waitForPeerClose(first)
  first.close()

  let second = acceptWebSocket(listener)
  let reconnect = receiveClientJson(second)
  let replay = receiveClientJson(second)
  let replayId = queryIdFromAdd(replay)
  if reconnect["maxObservedTimestamp"].getStr != threeTimestamp:
    raise newException(ValueError,
      "malformed transition advanced maxObservedTimestamp")
  sendJson(second, transition(0, 1, zeroTimestamp, fourTimestamp, %*[
    {"type": "QueryUpdated", "queryId": replayId,
      "value": {"count": 2}, "logLines": []}
  ]))
  waitForRemoveOrClose(second)
  second.close()

proc partialPayload(queryId, count: int): string =
  $transition(0, 1, zeroTimestamp, oneTimestamp, %*[
    {"type": "QueryUpdated", "queryId": queryId,
      "value": {"count": count}, "logLines": []}
  ])

proc sendHalfFrame(peer: Socket; payload: string) =
  peer.send(frameHeader(true, 1, payload.len) & payload[0 ..<
      payload.len div 2])

proc partialCloseFixture(listener: Socket; args: FixtureArgs) =
  let peer = acceptWebSocket(listener)
  discard receiveClientJson(peer)
  let queryId = queryIdFromAdd(receiveClientJson(peer))
  sendHalfFrame(peer, partialPayload(queryId, 0))
  args.ready[].send(true)
  waitForPeerClose(peer)
  peer.close()

proc partialRecoveryFixture(listener: Socket; args: FixtureArgs) =
  let first = acceptWebSocket(listener)
  discard receiveClientJson(first)
  let queryId = queryIdFromAdd(receiveClientJson(first))
  sendHalfFrame(first, partialPayload(queryId, 0))
  args.ready[].send(true)
  waitForPeerClose(first)
  first.close()

  let second = acceptWebSocket(listener)
  discard receiveClientJson(second)
  let replayId = queryIdFromAdd(receiveClientJson(second))
  sendJson(second, transition(0, 1, zeroTimestamp, twoTimestamp, %*[
    {"type": "QueryUpdated", "queryId": replayId,
      "value": {"count": 7}, "logLines": []}
  ]))
  waitForRemoveOrClose(second)
  second.close()

proc oversizedFragmentFixture(listener: Socket; args: FixtureArgs) =
  let first = acceptWebSocket(listener)
  discard receiveClientJson(first)
  let queryId = queryIdFromAdd(receiveClientJson(first))

  # Fill all but one byte of the complete-message allowance, then advertise a
  # two-byte continuation without sending its payload. The client must reject
  # the declared continuation before allocation or a payload read can block.
  sendFrame(first, false, 1,
    repeat(" ", maxLiveValueBytes + 64 * 1024 - 1))
  first.send(frameHeader(true, 0, 2))
  waitForPeerClose(first)
  first.close()

  let second = acceptWebSocket(listener)
  discard receiveClientJson(second)
  let replayId = queryIdFromAdd(receiveClientJson(second))
  if replayId != queryId:
    raise newException(ValueError,
      "oversized fragment reconnect changed the active query id")
  sendJson(second, transition(0, 1, zeroTimestamp, twoTimestamp, %*[
    {"type": "QueryUpdated", "queryId": replayId,
      "value": {"count": 8}, "logLines": []}
  ]))
  waitForRemoveOrClose(second)
  second.close()

proc failedAddFixture(listener: Socket; args: FixtureArgs) =
  ## Accept the handshake and the Connect frame, then reset the connection so
  ## the following Add is written to a dead peer.  asyncnet would otherwise
  ## complete that write silently, so this fixture is what proves the patched
  ## transport reports the disconnect instead of acknowledging a lost Add.
  let peer = acceptWebSocket(listener)
  discard receiveClientJson(peer)
  var linger = TLinger(l_onoff: 1, l_linger: 0)
  discard setsockopt(peer.getFd, SOL_SOCKET, SO_LINGER, addr linger,
    SockLen(sizeof(linger)))
  peer.close()

proc idleCloseFixture(listener: Socket; args: FixtureArgs) =
  let peer = acceptWebSocket(listener)
  discard receiveClientJson(peer)
  discard receiveClientJson(peer)
  args.ready[].send(true)
  waitForPeerClose(peer)
  peer.close()

proc floodCloseFixture(listener: Socket; args: FixtureArgs) =
  let peer = acceptWebSocket(listener)
  discard receiveClientJson(peer)
  discard receiveClientJson(peer)
  args.ready[].send(true)
  try:
    while true:
      sendFrame(peer, true, 9, "flood")
  except CatchableError:
    discard
  peer.close()

proc fixtureWorker(args: FixtureArgs) {.thread.} =
  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let (_, boundPort) = listener.getLocalAddr()
  args.port[].send(int(boundPort))
  var errorMessage = ""
  try:
    case args.kind
    of fixtureLifecycle: lifecycleFixture(listener, args)
    of fixtureFiveReconnect: fiveReconnectFixture(listener, args)
    of fixturePartialClose: partialCloseFixture(listener, args)
    of fixturePartialRecovery: partialRecoveryFixture(listener, args)
    of fixtureOversizedFragment: oversizedFragmentFixture(listener, args)
    of fixtureFailedAdd: failedAddFixture(listener, args)
    of fixtureIdleClose: idleCloseFixture(listener, args)
    of fixtureFloodClose: floodCloseFixture(listener, args)
  except CatchableError as error:
    errorMessage = error.msg
  listener.close()
  args.result[].send(errorMessage)

proc startFixture(kind: FixtureKind): Fixture =
  let port = sharedChannel[int](1)
  result.ready = sharedChannel[bool](1)
  result.result = sharedChannel[string](1)
  result.thread = cast[ptr Thread[FixtureArgs]](
    allocShared0(sizeof(Thread[FixtureArgs])))
  createThread(result.thread[], fixtureWorker,
    FixtureArgs(kind: kind, port: port, ready: result.ready,
      result: result.result))
  result.port = port[].recv()

proc finishFixture(fixture: var Fixture) =
  let errorMessage = fixture.result[].recv()
  joinThread(fixture.thread[])
  deallocShared(fixture.thread)
  fixture.thread = nil
  check errorMessage.len == 0

proc liveCount(update: LiveUpdate): int =
  if update.isError:
    raise newException(ValueError, update.errorName & ": " &
        update.errorMessage)
  result = parseJson(update.value)["count"].getInt

suite "Nim real-socket Live owner":
  test "five retirement and Add barriers preserve the final mutation update":
    var fixture = startFixture(fixtureFiveReconnect)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    let subscription = client.subscribe("demo:state", %*{"room": "five"})
    check liveCount(subscription.nextUpdate()) == 0
    for _ in 1 .. 5:
      check client.debugDisconnectForAdapter().len == 0
    let mutation = client.mutation("demo:increment", %*{
      "room": "five", "language": "nim", "runId": "fixture"
    })
    check mutation.value["applied"].getBool
    check mutation.value["state"]["count"].getInt == 1
    # If unchanged rehydration leaked, this would observe 0 instead of 1.
    check liveCount(subscription.nextUpdate()) == 1
    subscription.close()
    client.close()
    finishFixture(fixture)

  test "fragmented Unicode, QueryFailed, malformed transition, and recovery":
    var fixture = startFixture(fixtureLifecycle)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    let subscription = client.subscribe("demo:state", %*{"room": "fixture"})
    let initial = subscription.nextUpdate()
    check liveCount(initial) == 0
    check parseJson(initial.value)["note"].getStr == "fragmented 雪"
    let failed = subscription.nextUpdate()
    check failed.isError
    check failed.errorName == "FunctionError"
    check parseJson(failed.errorData)["code"].getStr == "BROKEN"
    check liveCount(subscription.nextUpdate()) == 1
    let malformed = subscription.nextUpdate()
    check malformed.isError
    check malformed.errorName == "ProtocolError"
    check liveCount(subscription.nextUpdate()) == 2
    subscription.close()
    client.close()
    finishFixture(fixture)

  test "close retires an idle half-frame and joins the owner":
    var fixture = startFixture(fixturePartialClose)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    discard client.subscribe("demo:state", %*{"room": "partial-close"})
    discard fixture.ready[].recv()
    let started = epochTime()
    client.close()
    check epochTime() - started < 2.0
    finishFixture(fixture)

  test "close is bounded while the peer is idle":
    var fixture = startFixture(fixtureIdleClose)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    discard client.subscribe("demo:state", %*{"room": "idle-close"})
    discard fixture.ready[].recv()
    let started = epochTime()
    client.close()
    check epochTime() - started < 2.0
    finishFixture(fixture)

  test "close is bounded while control frames flood":
    var fixture = startFixture(fixtureFloodClose)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    discard client.subscribe("demo:state", %*{"room": "flood-close"})
    discard fixture.ready[].recv()
    let started = epochTime()
    client.close()
    check epochTime() - started < 2.0
    finishFixture(fixture)

  test "a half-frame deadline emits TransportError and reconnects":
    var fixture = startFixture(fixturePartialRecovery)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    let subscription = client.subscribe("demo:state", %*{
        "room": "partial-recovery"})
    discard fixture.ready[].recv()
    let failed = subscription.nextUpdate()
    check failed.isError
    check failed.errorName == "TransportError"
    check liveCount(subscription.nextUpdate()) == 7
    subscription.close()
    client.close()
    finishFixture(fixture)

  test "fragment aggregation rejects before append and then reconnects":
    var fixture = startFixture(fixtureOversizedFragment)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    let subscription = client.subscribe("demo:state", %*{
      "room": "oversized-fragment"
    })
    let failed = subscription.nextUpdate()
    check failed.isError
    check failed.errorName == "TransportError"
    check liveCount(subscription.nextUpdate()) == 8
    subscription.close()
    client.close()
    finishFixture(fixture)

  test "a failed Add returns an activation error instead of an acknowledgement":
    var fixture = startFixture(fixtureFailedAdd)
    let client = newClient("http://127.0.0.1:" & $fixture.port)
    expect TransportError:
      discard client.subscribe("demo:state", %*{
        "room": "failed-add",
        "blob": repeat("x", 1_500_000)
      })
    client.close()
    finishFixture(fixture)
