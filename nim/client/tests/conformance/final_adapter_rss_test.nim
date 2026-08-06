## Process-level stopped-reader regression for the exact adapter executable.
## A tiny valid query receives a near-maximum HTTP value. After the ready event
## this controller deliberately stops reading adapter stdout and verifies that
## the bounded output owner closes cleanly below the runtime memory policy.

import std/[os, osproc, streams, strtabs, strutils, times, unittest]

proc rssKiB(processId: int): int =
  let statusPath = "/proc/" & $processId & "/status"
  if not fileExists(statusPath):
    return 0
  for line in lines(statusPath):
    if line.startsWith("VmRSS:"):
      let fields = line.splitWhitespace()
      if fields.len >= 2:
        return parseInt(fields[1])

suite "Nim final adapter stopped-reader process":
  test "a real near-limit response remains below 128 MiB and terminates":
    when defined(linux):
      let fixtureEnvironment = newStringTable(modeCaseSensitive)
      fixtureEnvironment["FIXTURE_LISTEN"] = "127.0.0.1:0"
      fixtureEnvironment["FIXTURE_REQUESTS"] = "8"
      let fixture = startProcess("/out-large-value-fixture",
        env = fixtureEnvironment)
      let ready = fixture.outputStream.readLine()
      check ready.startsWith("fixture-ready:")
      let port = parseInt(ready.split(":")[^1])

      let adapterEnvironment = newStringTable(modeCaseSensitive)
      adapterEnvironment["CONVEX_URL"] = "http://127.0.0.1:" & $port
      let adapter = startProcess("/out-convex-adapter",
        env = adapterEnvironment)
      adapter.inputStream.writeLine(
        "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}")
      adapter.inputStream.flush()
      let adapterReady = adapter.outputStream.readLine()
      check adapterReady.contains("\"type\":\"ready\"")

      for request in 0 ..< 8:
        adapter.inputStream.writeLine(
          "{\"id\":\"large-" & $request &
          "\",\"op\":\"query\",\"path\":\"demo:large\",\"args\":{}}")
      adapter.inputStream.flush()

      var peakRssKiB = 0
      let deadline = epochTime() + 8.0
      while epochTime() < deadline and adapter.peekExitCode() < 0:
        peakRssKiB = max(peakRssKiB, rssKiB(adapter.processID))
        sleep(1)
      let adapterExit = adapter.peekExitCode()
      check adapterExit == 0
      check peakRssKiB > 0
      check peakRssKiB < 128 * 1024
      echo "stopped-reader peak RSS KiB: " & $peakRssKiB
      # This marker proves the adapter actually consumed a schema-valid small
      # request and received the near-limit response before its reader stopped.
      check fixture.outputStream.readLine() == "served"
      adapter.close()
      fixture.terminate()
      discard fixture.waitForExit(2_000)
      fixture.close()
    else:
      skip()
