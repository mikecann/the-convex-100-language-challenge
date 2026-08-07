## Process-level proof for the exact adapter TCP entrypoint.
## The adapter publishes its bound ephemeral port on stderr, leaving the
## accepted socket as the only NDJSON protocol stream.

import std/[json, net, osproc, streams, strtabs, strutils, unittest]

suite "Nim exact adapter TCP mode":
  test "hello and close are serialized over one accepted controller socket":
    let environment = newStringTable(modeCaseSensitive)
    environment["ADAPTER_LISTEN"] = "127.0.0.1:0"
    let adapter = startProcess("/out-convex-adapter", env = environment,
      options = {poStdErrToStdOut})
    let listening = adapter.outputStream.readLine()
    check listening.startsWith("adapter-listening:")
    let port = parseInt(listening.split(":")[^1])

    let controller = newSocket()
    controller.connect("127.0.0.1", Port(port))
    controller.send(
      "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n" &
      "{\"id\":\"close\",\"op\":\"close\"}\n")
    let ready = parseJson(controller.recvLine(timeout = 8_000))
    let closed = parseJson(controller.recvLine(timeout = 8_000))
    check ready["id"].getStr == "hello"
    check ready["type"].getStr == "ready"
    check closed["id"].getStr == "close"
    check closed["type"].getStr == "closed"
    check controller.recv(1, 8_000).len == 0
    controller.close()

    check adapter.waitForExit(8_000) == 0
    adapter.close()
