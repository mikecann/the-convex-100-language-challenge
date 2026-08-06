## Real HTTP peers prove response limits while bytes are arriving, including
## fixed, chunked, and connection-close bodies. A later valid request proves a
## rejected response does not poison the client.

import std/[json, net, os, strutils, unittest]
import ../convex

type HttpFixtureArgs = object
  port: ptr Channel[int]
  result: ptr Channel[string]

proc sharedChannel[T](capacity: int): ptr Channel[T] =
  result = cast[ptr Channel[T]](allocShared0(sizeof(Channel[T])))
  result[].open(capacity)

proc readRequest(peer: Socket): string =
  discard peer.recvLine(timeout = 8_000)
  var contentLength = 0
  while true:
    let line = peer.recvLine(timeout = 8_000)
    if line.len == 0 or line == "\r\n":
      break
    let pieces = line.split(":", maxsplit = 1)
    if pieces.len == 2 and pieces[0].toLowerAscii == "content-length":
      contentLength = parseInt(pieces[1].strip)
    if pieces.len == 2 and pieces[0].toLowerAscii == "authorization":
      result = pieces[1].strip
  if contentLength > 0:
    let body = peer.recv(contentLength, 8_000)
    if body.len != contentLength:
      raise newException(IOError, "HTTP fixture request body ended early")

proc serveHttpFixtures(args: HttpFixtureArgs) {.thread.} =
  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let (_, boundPort) = listener.getLocalAddr()
  args.port[].send(int(boundPort))
  var errorMessage = ""
  try:
    for scenario in 0 .. 7:
      var peer: owned(Socket)
      listener.accept(peer)
      discard readRequest(peer)
      try:
        case scenario
        of 0:
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Content-Length: " & $(maxResponseBytes + 1) &
            "\r\nConnection: close\r\n\r\n")
        of 1:
          peer.send("HTTP/1.1 200 OK\r\nX-Large: " &
            repeat("h", 64 * 1024) & "\r\n\r\n")
        of 2:
          # A full-width hexadecimal length used to overflow Nim's signed int
          # before the aggregate cap ran. No payload is needed for rejection.
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" &
            "FFFFFFFFFFFFFFFF\r\n")
        of 3:
          let chunk = repeat("x", 1_100_000)
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
          for _ in 0 .. 1:
            peer.send(toHex(chunk.len) & "\r\n" & chunk & "\r\n")
          peer.send("0\r\n\r\n")
        of 4:
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Connection: close\r\n\r\n" & repeat("y", maxResponseBytes + 1))
        of 5:
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Content-Length: 100\r\nConnection: close\r\n\r\n{")
          # The client must retire this partial body on its absolute deadline.
          while peer.recv(1, 8_000).len > 0:
            discard
        of 6:
          let body = $(%*{
            "status": "error",
            "errorMessage": "structured fixture failure 雪",
            "errorData": {"code": "FIXTURE"},
            "logLines": ["fixture log"]
          })
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Content-Length: " & $body.len &
            "\r\nConnection: close\r\n\r\n" & body)
        else:
          let body = $(%*{
            "status": "success",
            "value": {"count": 1},
            "logLines": []
          })
          peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
            "Content-Length: " & $body.len &
            "\r\nConnection: close\r\n\r\n" & body)
      except CatchableError:
        # Oversized cases deliberately close while the fixture is still
        # writing. The next independent connection is the recovery proof.
        discard
      peer.close()
  except CatchableError as error:
    errorMessage = error.msg
  listener.close()
  args.result[].send(errorMessage)

proc serveAuthFixtures(args: HttpFixtureArgs) {.thread.} =
  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let (_, boundPort) = listener.getLocalAddr()
  args.port[].send(int(boundPort))
  var errorMessage = ""
  try:
    for expected in ["Bearer first", "Bearer second", ""]:
      var peer: owned(Socket)
      listener.accept(peer)
      let observed = readRequest(peer)
      if observed != expected:
        raise newException(ValueError,
          "authorization lifecycle mismatch: " & observed)
      let body = $(%*{
        "status": "success", "value": {"count": 0}, "logLines": []
      })
      peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
        "Content-Length: " & $body.len &
        "\r\nConnection: close\r\n\r\n" & body)
      peer.close()
  except CatchableError as error:
    errorMessage = error.msg
  listener.close()
  args.result[].send(errorMessage)

suite "Nim bounded HTTP response stream":
  test "bearer authentication can be set, replaced, and cleared":
    let port = sharedChannel[int](1)
    let result = sharedChannel[string](1)
    var fixture: Thread[HttpFixtureArgs]
    createThread(fixture, serveAuthFixtures,
      HttpFixtureArgs(port: port, result: result))
    let client = newClient("http://127.0.0.1:" & $port[].recv(), "first")
    discard client.query("demo:state", %*{"room": "auth-first"})
    client.setAuth("second")
    discard client.query("demo:state", %*{"room": "auth-second"})
    client.setAuth("")
    discard client.query("demo:state", %*{"room": "auth-cleared"})
    client.close()
    let fixtureError = result[].recv()
    joinThread(fixture)
    check fixtureError.len == 0

  test "headers, body modes, dishonest lengths, and deadlines recover":
    let port = sharedChannel[int](1)
    let result = sharedChannel[string](1)
    var fixture: Thread[HttpFixtureArgs]
    createThread(fixture, serveHttpFixtures,
      HttpFixtureArgs(port: port, result: result))
    let client = newClient("http://127.0.0.1:" & $port[].recv())
    for _ in 0 .. 5:
      expect TransportError:
        discard client.query("demo:state", %*{"room": "oversized"})
    try:
      discard client.query("demo:state", %*{"room": "function-error"})
      check false
    except FunctionError as error:
      check error.msg == "structured fixture failure 雪"
      check error.hasData
      check error.data["code"].getStr == "FIXTURE"
      check error.logs == @["fixture log"]
    let recovered = client.query("demo:state", %*{"room": "recovered"})
    check recovered.value["count"].getInt == 1
    client.close()
    let fixtureError = result[].recv()
    joinThread(fixture)
    check fixtureError.len == 0
