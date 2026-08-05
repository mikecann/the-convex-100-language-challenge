import AdapterCore
@_spi(ConvexAdapter) @testable import Convex
import Foundation
import XCTest

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let response = try Self.lock.withLock { try Self.handler!(request) }
      client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: response.1)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

final class FakeSocket: LiveSocket, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var sent: [String] = []
  private let text: @Sendable (String) -> Void
  private let binary: @Sendable () -> Void
  private let closedCallback: @Sendable () -> Void
  private(set) var isClosed = false
  init(
    text: @Sendable @escaping (String) -> Void, binary: @Sendable @escaping () -> Void,
    close: @Sendable @escaping () -> Void
  ) {
    self.text = text
    self.binary = binary
    self.closedCallback = close
  }
  func send(_ text: String) async throws { lock.withLock { sent.append(text) } }
  func close() { lock.withLock { isClosed = true } }
  func emit(_ object: [String: Any]) {
    text(String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
  }
  func emitText(_ value: String) { text(value) }
  func emitBinary() { binary() }
  func disconnect() { closedCallback() }
}

final class FakeFactory: LiveSocketFactory, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var sockets: [FakeSocket] = []
  var failures = 0
  func connect(
    url: URL, onText: @Sendable @escaping (String) -> Void,
    onBinary: @Sendable @escaping () -> Void, onClose: @Sendable @escaping () -> Void
  ) async throws -> any LiveSocket {
    if lock.withLock({
      if failures > 0 {
        failures -= 1
        return true
      }
      return false
    }) {
      throw TestFailure.message("connect failed")
    }
    let socket = FakeSocket(text: onText, binary: onBinary, close: onClose)
    lock.withLock { sockets.append(socket) }
    return socket
  }
  func shutdown() async {}
  func socket(_ index: Int) -> FakeSocket { lock.withLock { sockets[index] } }
  var count: Int { lock.withLock { sockets.count } }
}

enum TestFailure: Error { case message(String) }

final class ConvexTests: XCTestCase {
  func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
  func response(_ object: Any) -> (HTTPURLResponse, Data) {
    (
      HTTPURLResponse(
        url: URL(string: "http://fixture")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      try! JSONSerialization.data(withJSONObject: object)
    )
  }

  func testHTTPResultNullBearerAndFunctionErrorFidelity() async throws {
    var calls = 0
    MockURLProtocol.handler = { [self] request in
      calls += 1
      if calls == 1 {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        return response(["status": "success", "value": NSNull(), "logLines": ["ok"]])
      }
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      return response([
        "status": "error", "errorMessage": "nope", "errorData": ["nested": [1, NSNull()]],
        "logLines": ["bad"],
      ])
    }
    let client = try ConvexClient("http://fixture", session: session())
    try client.setAuth("secret")
    let success = try await client.query("demo:null", [:])
    XCTAssertTrue(success.value is NSNull)
    XCTAssertEqual(success.logs, ["ok"])
    try client.setAuth("")
    do {
      _ = try await client.mutation("demo:fail", [:])
      XCTFail("expected function error")
    } catch let error as ConvexError {
      XCTAssertEqual(error.kind, .function)
      XCTAssertEqual(error.message, "nope")
      XCTAssertEqual(error.logs, ["bad"])
      XCTAssertNotNil(error.data)
    }
  }

  func testLiveUpdateFailureRecoveryReconnectAndHydrationDedup() async throws {
    let factory = FakeFactory()
    let live = try LiveClient("http://fixture", factory: factory)
    let subscription = try await live.subscribe("demo:state", ["room": "one"])
    var iterator = subscription.stream.makeAsyncIterator()
    factory.socket(0).emit(
      transition(
        start: version(0), end: version(1),
        modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": 0]]]))
    let initial = try await next(&iterator)
    XCTAssertEqual(count(initial), 0)
    factory.socket(0).emit(
      transition(
        start: version(1), end: version(2),
        modifications: [
          [
            "type": "QueryFailed", "queryId": 0, "errorMessage": "temporary",
            "errorData": ["code": 7],
          ]
        ]))
    let failed = try await next(&iterator)
    XCTAssertEqual(failed.error?.kind, .function)
    factory.socket(0).emit(
      transition(
        start: version(2), end: version(3),
        modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": 1]]]))
    let recovered = try await next(&iterator)
    XCTAssertEqual(count(recovered), 1)
    try await live.debugDisconnectForAdapter()
    XCTAssertEqual(factory.count, 2)
    factory.socket(1).emit(
      transition(
        start: version(0), end: version(1),
        modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": 1]]]))
    try await Task.sleep(for: .milliseconds(10))
    factory.socket(1).emit(
      transition(
        start: version(1), end: version(2),
        modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": 2]]]))
    let changed = try await next(&iterator)
    XCTAssertEqual(count(changed), 2)
    for expectedSocketCount in 3...6 {
      try await live.debugDisconnectForAdapter()
      XCTAssertEqual(factory.count, expectedSocketCount)
      factory.socket(expectedSocketCount - 1).emit(
        transition(
          start: version(0), end: version(1),
          modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": 2]]]))
      try await Task.sleep(for: .milliseconds(10))
    }
    factory.socket(5).emit(
      transition(
        start: version(1), end: version(2),
        modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": 3]]]))
    let afterFiveReconnects = try await next(&iterator)
    XCTAssertEqual(count(afterFiveReconnects), 3)
    await live.close()
  }

  func testSubscriptionRegistryRejectsStaleReplacementAndUnsubscribeRelays() async {
    let registry = SubscriptionRegistry()
    let first = LiveClient.Subscription(1)
    let second = LiveClient.Subscription(2)
    let (firstToken, _) = await registry.replace("same", with: first)
    let (secondToken, replaced) = await registry.replace("same", with: second)
    XCTAssertTrue(replaced === first)
    let firstIsCurrent = await registry.isCurrent("same", token: firstToken)
    let secondIsCurrent = await registry.isCurrent("same", token: secondToken)
    let removed = await registry.remove("same")
    let remainsCurrent = await registry.isCurrent("same", token: secondToken)
    XCTAssertFalse(firstIsCurrent)
    XCTAssertTrue(secondIsCurrent)
    XCTAssertTrue(removed === second)
    XCTAssertFalse(remainsCurrent)
  }

  func testNewest16DropsOldestForSlowConsumer() async throws {
    let factory = FakeFactory()
    let live = try LiveClient("http://fixture", factory: factory)
    let subscription = try await live.subscribe("demo:state", [:])
    for value in 0..<20 {
      factory.socket(0).emit(
        transition(
          start: version(value), end: version(value + 1),
          modifications: [["type": "QueryUpdated", "queryId": 0, "value": ["count": value]]]))
      try await Task.sleep(for: .milliseconds(2))
    }
    try await Task.sleep(for: .milliseconds(50))
    var iterator = subscription.stream.makeAsyncIterator()
    var values: [Int] = []
    for _ in 0..<16 { values.append(count(try await next(&iterator))) }
    XCTAssertEqual(values, Array(4..<20))
    await live.close()
  }

  func testUnknownMessageAndBinaryProduceProtocolErrorThenReconnect() async throws {
    let factory = FakeFactory()
    let live = try LiveClient("http://fixture", factory: factory)
    let subscription = try await live.subscribe("demo:state", [:])
    var iterator = subscription.stream.makeAsyncIterator()
    factory.socket(0).emit(["type": "Mystery"])
    let unknown = try await next(&iterator)
    XCTAssertEqual(unknown.error?.kind, .protocolError)
    try await eventually { factory.count == 2 }
    factory.socket(1).emitBinary()
    let binary = try await next(&iterator)
    XCTAssertEqual(binary.error?.kind, .protocolError)
    await live.close()
  }

  func testAdapterSerializationShapesAndAddressParsing() throws {
    XCTAssertEqual(try ListenAddress("0.0.0.0:9876"), ListenAddress(host: "0.0.0.0", port: 9876))
    XCTAssertEqual(try ListenAddress("[::1]:9876"), ListenAddress(host: "::1", port: 9876))
    let result = try encodeEvent(
      resultEvent(id: "q", result: ConvexResult(value: NSNull(), logs: ["line"])))
    XCTAssertTrue(result.contains("\"value\":null"))
    XCTAssertTrue(result.contains("\"logs\":[\"line\"]"))
    let function = ConvexError(kind: .function, message: "bad", data: ["x": 1], logs: ["log"])
    let error = try encodeEvent(adapterErrorEvent(id: "q", error: function))
    XCTAssertTrue(error.contains("FunctionError"))
    XCTAssertTrue(error.contains("\"data\""))
    let subscription = try encodeEvent(
      adapterErrorEvent(id: nil, subscriptionID: "s", error: function))
    XCTAssertFalse(subscription.contains("\"id\""))
    XCTAssertTrue(subscription.contains("\"subscriptionId\":\"s\""))
  }

  func testLineReaderBoundsPartialFrameAndCloses() async throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    let connection = LineConnection(
      input: descriptors[0], output: descriptors[0], ownsDescriptors: true)
    _ = "partial".withCString { write(descriptors[1], $0, 7) }
    close(descriptors[1])
    var iterator = connection.lines().makeAsyncIterator()
    let value = await iterator.next()
    XCTAssertNil(value)
  }

  private func version(_ querySet: Int) -> [String: Any] {
    [
      "querySet": querySet, "identity": 0,
      "ts": querySet == 0 ? "AAAAAAAAAAA=" : "ts-\(querySet)",
    ]
  }
  private func transition(start: [String: Any], end: [String: Any], modifications: [[String: Any]])
    -> [String: Any]
  {
    [
      "type": "Transition", "startVersion": start, "endVersion": end,
      "modifications": modifications,
    ]
  }
  private func count(_ update: LiveClient.Update) -> Int {
    ((update.value as? [String: Any])?["count"] as? NSNumber)?.intValue ?? -1
  }
  private func next(_ iterator: inout AsyncStream<LiveClient.Update>.Iterator) async throws
    -> LiveClient.Update
  {
    guard let value = await iterator.next() else { throw TestFailure.message("stream closed") }
    return value
  }
  private func eventually(_ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<50 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.message("condition not met")
  }
}

extension ListenAddress {
  fileprivate init(host: String, port: UInt16) {
    self = try! ListenAddress("\(host.contains(":") ? "[\(host)]" : host):\(port)")
  }
}
