# Convex from Swift

This is a small, native Swift demonstration of Convex HTTP functions and a pinned experimental Live WebSocket profile. On Linux, WebSocketKit 2.15.0 supplies the low-level SwiftNIO TLS and RFC 6455 transport.

It is educational, unofficial, and not a production SDK.

## Start here

[`examples/basics/main.swift`](examples/basics/main.swift) queries a counter, starts Live before it changes the counter, performs one idempotent mutation, and verifies the Live update.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action | Implemented, awaiting shared evidence |
| Live query updates | Implemented against the pinned profile, awaiting shared evidence |
| Authentication | HTTP bearer token only |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.swift -->
```text
import Convex
import Foundation

@main struct BasicExample {
  static func main() async {
    guard let url = ProcessInfo.processInfo.environment["CONVEX_URL"] else {
      FileHandle.standardError.write(Data("CONVEX_URL is required\n".utf8))
      exit(2)
    }
    let room = CommandLine.arguments.dropFirst().first ?? "swift-example"
    var live: LiveClient?
    var client: ConvexClient?
    do {
      // CONVEX_URL selects the dedicated deployment used by both HTTP and Live.
      let http = try ConvexClient(url)
      client = http
      // Query the room over HTTP before beginning the Live journey.
      let before = try await http.query("demo:state", ["room": room])
      let current = count(before.value)
      print("current count: \(current)")
      // Start Live before mutating, so its first value is an independent snapshot.
      let liveClient = try LiveClient(url)
      live = liveClient
      let sub = try await liveClient.subscribe("demo:state", ["room": room])
      var updates = sub.stream.makeAsyncIterator()
      guard let initial = await updates.next() else {
        throw ExampleError("Live closed before initial value")
      }
      guard initial.error == nil, count(initial.value!) == current else {
        throw ExampleError("unexpected initial Live value")
      }
      print("live initial count: \(current)")
      // The random runId is an idempotency key: retrying this logical mutation will not double increment.
      let mutation = try await http.mutation(
        "demo:increment", ["room": room, "language": "swift", "runId": UUID().uuidString])
      guard let object = mutation.value as? [String: Any], object["applied"] as? Bool == true else {
        throw ExampleError("mutation was not applied")
      }
      let after = count(object["state"]!)
      guard after == current + 1 else { throw ExampleError("unexpected mutation count") }
      print("mutation applied: true")
      print("mutation count: \(after)")
      // Read the Live update caused by the mutation instead of issuing another query.
      guard let updated = await updates.next(), updated.error == nil, count(updated.value!) == after
      else { throw ExampleError("unexpected Live update") }
      print("live updated count: \(after)")
      print("verified count: \(current) -> \(after)")
      // Await Live shutdown so no socket or event-loop work escapes the example.
      await live?.close()
      client?.close()
    } catch {
      await live?.close()
      client?.close()
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }
  // Decode only the count teaching value while retaining the client's full JSON fidelity.
  static func count(_ value: Any) -> Int {
    ((value as? [String: Any])?["count"] as? NSNumber)?.intValue ?? -999
  }
  struct ExampleError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
  }
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test swift` compiles the native client and test adapter in Docker. `./run verify-example swift` exercises this exact example. `./run verify-all swift` is the root-owned local and hosted conformance gate.

## Protocol notes

The adapter speaks NDJSON protocol v1 on stdin/stdout or the single TCP controller specified by `ADAPTER_LISTEN`. `debugDisconnect` is adapter-only. A single actor owns the socket. Ordered transport callbacks use a bounded 64-event mailbox; overflow is reported as a protocol error and reconnects. Subscriptions use a newest-16 buffer, dropping old intermediate updates for a slow consumer.

## Limitations

Live auth, actions and mutations, optimistic updates, journals, replay, and transition-chunk assembly are intentionally deferred. The sync wire profile is undocumented and pinned for testing, not promised as stable.
