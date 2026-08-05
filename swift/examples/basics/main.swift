import Convex
import Foundation

@main struct BasicExample {
  static func main() async {
    guard let url = ProcessInfo.processInfo.environment["CONVEX_URL"] else {
      FileHandle.standardError.write(Data("CONVEX_URL is required\n".utf8))
      exit(2)
    }
    let room = CommandLine.arguments.dropFirst().first ?? "swift-example"
    do {
      // Create a native Swift client pointed at the dedicated Convex deployment.
      let client = try ConvexClient(url)
      defer { client.close() }
      // Query the room over HTTP before beginning the Live journey.
      let before = try await client.query("demo:state", ["room": room])
      let current = count(before.value)
      print("current count: \(current)")
      // Start Live before mutating, so its first value is an independent snapshot.
      let live = try LiveClient(url)
      let sub = try await live.subscribe("demo:state", ["room": room])
      defer { Task { await live.close() } }
      var updates = sub.stream.makeAsyncIterator()
      guard let initial = await updates.next() else {
        throw ExampleError("Live closed before initial value")
      }
      guard initial.error == nil, count(initial.value!) == current else {
        throw ExampleError("unexpected initial Live value")
      }
      print("live initial count: \(current)")
      // The random runId is an idempotency key: retrying this logical mutation will not double increment.
      let mutation = try await client.mutation(
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
    } catch {
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
