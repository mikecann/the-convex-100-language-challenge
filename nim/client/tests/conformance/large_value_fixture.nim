## HTTP fixture for final-adapter stopped-reader evidence.
## A tiny query request returns a schema-valid value close to the client's
## maximum, so output memory is exercised by real encoded responses rather than
## by an oversized command rejected before the adapter can echo anything.

import std/[json, net, os, strutils]
import ../../convex

let listenAddress = getEnv("FIXTURE_LISTEN", "127.0.0.1:19091")
let pieces = listenAddress.rsplit(":", maxsplit = 1)
let requestCount = parseInt(getEnv("FIXTURE_REQUESTS", "32"))
let listener = newSocket()
listener.setSockOpt(OptReuseAddr, true)
listener.bindAddr(Port(parseInt(pieces[^1])), pieces[0])
listener.listen()
let (_, boundPort) = listener.getLocalAddr()
stdout.writeLine("fixture-ready:" & $int(boundPort))
stdout.flushFile()

let payload = $(%*{
  "status": "success",
  "value": {"blob": repeat("x", maxResponseBytes - 8_192)},
  "logLines": []
})

for _ in 0 ..< requestCount:
  var peer: owned(Socket)
  listener.accept(peer)
  discard peer.recvLine(timeout = 8_000)
  var contentLength = 0
  while true:
    let line = peer.recvLine(timeout = 8_000)
    if line.len == 0 or line == "\r\n":
      break
    let header = line.split(":", maxsplit = 1)
    if header.len == 2 and header[0].toLowerAscii == "content-length":
      contentLength = parseInt(header[1].strip)
  if contentLength > 0:
    discard peer.recv(contentLength, 8_000)
  peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
    "Content-Length: " & $payload.len &
    "\r\nConnection: close\r\n\r\n" & payload)
  peer.close()
  stdout.writeLine("served")
  stdout.flushFile()

listener.close()
