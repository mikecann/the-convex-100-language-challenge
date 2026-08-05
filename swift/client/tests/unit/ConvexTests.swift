import AdapterCore
@_spi(ConvexAdapter) @testable import Convex
import Crypto
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
  var sendFailures = 0
  private(set) var activeSends = 0
  private(set) var maxActiveSends = 0
  var sendDelayMilliseconds = 2
  init(
    text: @Sendable @escaping (String) -> Void, binary: @Sendable @escaping () -> Void,
    close: @Sendable @escaping () -> Void
  ) {
    self.text = text
    self.binary = binary
    self.closedCallback = close
  }
  func send(_ text: String) async throws {
    let shouldFail = lock.withLock { () -> Bool in
      activeSends += 1
      maxActiveSends = max(maxActiveSends, activeSends)
      if sendFailures > 0 {
        sendFailures -= 1
        activeSends -= 1
        return true
      }
      sent.append(text)
      return false
    }
    if shouldFail { throw TestFailure.message("send failed") }
    try? await Task.sleep(for: .milliseconds(sendDelayMilliseconds))
    lock.withLock { activeSends -= 1 }
  }
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
  var nextSocketSendFailures = 0
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
    socket.sendFailures = lock.withLock {
      defer { nextSocketSendFailures = 0 }
      return nextSocketSendFailures
    }
    lock.withLock { sockets.append(socket) }
    return socket
  }
  func cancelPendingConnects() {}
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
    try await eventually { factory.count == 2 }
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
      try await eventually { factory.count == expectedSocketCount }
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

  func testDebugDisconnectAcknowledgesBeforeFiveFailedOrdinaryRetries() async throws {
    let factory = FakeFactory()
    let live = try LiveClient("http://fixture", factory: factory)
    _ = try await live.subscribe("demo:state", [:])
    factory.failures = 5
    let clock = ContinuousClock()
    let started = clock.now
    try await live.debugDisconnectForAdapter()
    XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(50))
    try await eventually(timeout: 8_000) { factory.count == 2 }
    await live.close()
  }

  func testFailedInitialSendClosesCandidateAndDoesNotPublishIt() async throws {
    let factory = FakeFactory()
    factory.nextSocketSendFailures = 1
    let live = try LiveClient("http://fixture", factory: factory)
    do {
      _ = try await live.subscribe("demo:state", [:])
      XCTFail("expected send failure")
    } catch let error as ConvexError {
      XCTAssertEqual(error.kind, .transport)
    }
    XCTAssertTrue(factory.socket(0).isClosed)
    _ = try await live.subscribe("demo:state", [:])
    XCTAssertEqual(factory.count, 2)
    await live.close()
  }

  func testConcurrentSubscriptionsSerializeProtocolSends() async throws {
    let factory = FakeFactory()
    let live = try LiveClient("http://fixture", factory: factory)
    _ = try await live.subscribe("demo:first", [:])
    async let second = live.subscribe("demo:second", [:])
    async let third = live.subscribe("demo:third", [:])
    _ = try await (second, third)
    XCTAssertEqual(factory.socket(0).maxActiveSends, 1)
    await live.close()
  }

  func testInboundMailboxOverflowIsStructuredAndReconnects() async throws {
    let factory = FakeFactory()
    let live = try LiveClient("http://fixture", factory: factory)
    let first = try await live.subscribe("demo:first", [:])
    var iterator = first.stream.makeAsyncIterator()
    factory.socket(0).sendDelayMilliseconds = 100
    let adding = Task { try await live.subscribe("demo:second", [:]) }
    try await eventually { factory.socket(0).activeSends == 1 }
    for _ in 0..<100 { factory.socket(0).emit(["type": "Ping"]) }
    _ = try await adding.value
    let overflow = try await next(&iterator)
    XCTAssertEqual(overflow.error?.kind, .protocolError)
    XCTAssertTrue(overflow.error?.message.contains("mailbox overflow") == true)
    try await eventually { factory.count == 2 }
    await live.close()
  }

  func testNIOEventLoopGroupsRetireAcrossManyConnectionFailures() async throws {
    let factory = NIOSocketFactory()
    let threadsBefore = linuxThreadCount()
    for _ in 0..<40 {
      do {
        _ = try await factory.connect(
          url: URL(string: "ws://127.0.0.1:1/api/sync")!, onText: { _ in }, onBinary: {},
          onClose: {})
        XCTFail("expected connection failure")
      } catch {}
    }
    try await eventually(timeout: 2_000) { factory.activeGroupCount == 0 }
    await factory.shutdown()
    if let threadsBefore {
      try await eventually(timeout: 2_000) {
        guard let current = self.linuxThreadCount() else { return false }
        return current <= threadsBefore + 2
      }
    }
  }

  func testStalledUpgradeCanBeClosedWellInsideAdapterDeadline() async throws {
    let server = try StalledHTTPServer()
    let factory = NIOSocketFactory()
    let live = try LiveClient("http://127.0.0.1:\(server.port)", factory: factory)
    let subscribe = Task { try await live.subscribe("demo:state", [:]) }
    try await server.waitUntilAccepted()
    let clock = ContinuousClock()
    let started = clock.now
    await live.close()
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
    do {
      _ = try await subscribe.value
      XCTFail("expected cancelled upgrade")
    } catch {}
    try await eventually { factory.activeGroupCount == 0 }
  }

  func testAdapterCloseAfterStalledUpgradeBeatsControllerDeadlineAndEmitsClosed() async throws {
    let server = try StalledHTTPServer()
    var commands: [Int32] = [0, 0]
    var events: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&commands), 0)
    XCTAssertEqual(pipe(&events), 0)
    defer {
      close(commands[0])
      close(commands[1])
      close(events[0])
      close(events[1])
    }
    let connection = LineConnection(input: commands[0], output: events[1], ownsDescriptors: false)
    let adapter = Task {
      await runAdapter(connection: connection, deploymentURL: "http://127.0.0.1:\(server.port)")
    }
    let input =
      "{\"id\":\"sub\",\"op\":\"subscribe\",\"subscriptionId\":\"s\",\"path\":\"demo:state\",\"args\":{}}\n"
      + "{\"id\":\"close\",\"op\":\"close\"}\n"
    _ = input.withCString { write(commands[1], $0, input.utf8.count) }
    let clock = ContinuousClock()
    let started = clock.now
    var iterator = LineConnection(input: events[0], output: events[0], ownsDescriptors: false)
      .lines().makeAsyncIterator()
    var sawClosed = false
    for _ in 0..<3 {
      guard let line = await iterator.next() else { break }
      if line.contains("\"type\":\"closed\"") && line.contains("\"id\":\"close\"") {
        sawClosed = true
        break
      }
    }
    XCTAssertTrue(sawClosed)
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(6))
    await adapter.value
  }

  func testReplacementAndRemovalWaitForRelayStopBarriers() async throws {
    let registry = SubscriptionRegistry()
    let first = LiveClient.Subscription(1)
    let second = LiveClient.Subscription(2)
    _ = await registry.replace("same", with: first)
    let replacementGate = AsyncStream<Void>.makeStream()
    let replacementFinished = CompletionFlag()
    let replacing = Task {
      let token = await replaceRelay(registry: registry, id: "same", with: second) { _ in
        for await _ in replacementGate.stream { break }
      }
      replacementFinished.finish()
      return token
    }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(replacementFinished.isFinished)
    replacementGate.continuation.yield()
    replacementGate.continuation.finish()
    _ = await replacing.value

    let removalGate = AsyncStream<Void>.makeStream()
    let removalFinished = CompletionFlag()
    let removing = Task {
      await removeRelay(registry: registry, id: "same") { _ in
        for await _ in removalGate.stream { break }
      }
      removalFinished.finish()
    }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(removalFinished.isFinished)
    removalGate.continuation.yield()
    removalGate.continuation.finish()
    await removing.value
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

  func testRealWebSocketTransportReassemblesFragmentsAcrossPingControlFrame() async throws {
    let transition = transition(
      start: version(0), end: version(1),
      modifications: [
        ["type": "QueryUpdated", "queryId": 0, "value": ["count": 41, "label": "split-🙂-scalar"]]
      ])
    let payload = String(
      data: try JSONSerialization.data(withJSONObject: transition, options: [.sortedKeys]),
      encoding: .utf8)!
    let server = try RawWebSocketServer(fragmentedText: payload)
    let live = try LiveClient("http://127.0.0.1:\(server.port)")
    let subscription = try await live.subscribe("demo:state", [:])
    var iterator = subscription.stream.makeAsyncIterator()
    let update = try await next(&iterator)
    XCTAssertEqual(count(update), 41)
    async let second = live.subscribe("demo:second", [:])
    async let third = live.subscribe("demo:third", [:])
    _ = try await (second, third)
    let receivedPong = try await server.waitForPong()
    XCTAssertTrue(receivedPong)
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
    XCTAssertEqual(
      try encodeEvent(["type": "closed", "id": "close"]), "{\"id\":\"close\",\"type\":\"closed\"}")
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
  private func eventually(timeout: Int = 500, _ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<(timeout / 10) {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.message("condition not met")
  }

  private func linuxThreadCount() -> Int? {
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
      let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Threads:") })
    else { return nil }
    return Int(line.split(whereSeparator: \Character.isWhitespace).last ?? "")
  }

}

extension ListenAddress {
  fileprivate init(host: String, port: UInt16) {
    self = try! ListenAddress("\(host.contains(":") ? "[\(host)]" : host):\(port)")
  }
}

/// A deliberately tiny RFC 6455 fixture. It exercises WebSocketKit itself,
/// including masked client frames, fragmented server text and an interleaved ping.
private final class RawWebSocketServer: @unchecked Sendable {
  let port: UInt16
  private let descriptor: Int32
  private let result: RawServerResult

  init(fragmentedText: String) throws {
    #if os(Linux)
      let socketDescriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
      let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard socketDescriptor >= 0 else { throw TestFailure.message("socket failed") }
    var yes: Int32 = 1
    let yesSize = socklen_t(MemoryLayout<Int32>.size)
    _ = withUnsafePointer(to: &yes) {
      setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, $0, yesSize)
    }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(socketDescriptor, 1) == 0 else {
      close(socketDescriptor)
      throw TestFailure.message("bind failed")
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketDescriptor, $0, &length)
      }
    }
    descriptor = socketDescriptor
    port = UInt16(bigEndian: actual.sin_port)
    result = RawServerResult()
    let serverResult = result
    Thread.detachNewThread { [socketDescriptor, serverResult] in
      serverResult.complete(Self.serve(socketDescriptor, fragmentedText))
    }
  }

  deinit { close(descriptor) }

  func waitForPong() async throws -> Bool {
    for _ in 0..<100 {
      if let value = result.value { return value }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.message("raw WebSocket fixture timed out")
  }

  private static func serve(_ listening: Int32, _ text: String) -> Bool {
    let client = accept(listening, nil, nil)
    guard client >= 0 else { return false }
    defer { close(client) }
    guard let request = readHTTP(client),
      let keyLine = request.split(separator: "\r\n").first(where: {
        $0.lowercased().hasPrefix("sec-websocket-key:")
      })
    else { return false }
    let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
    let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    let acceptValue = Data(digest).base64EncodedString()
    let response =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptValue)\r\n\r\n"
    guard writeAll(client, Array(response.utf8)) else { return false }
    guard let connect = readFrame(client), let add = readFrame(client), connect.masked, add.masked
    else { return false }
    let bytes = Array(text.utf8)
    // Split after the first byte of a four-byte scalar. A correct WebSocket
    // implementation reassembles bytes before asking Swift to decode UTF-8.
    guard let scalarStart = bytes.firstIndex(where: { $0 >= 0xF0 }) else { return false }
    let split = scalarStart + 1
    guard writeFrame(client, fin: false, opcode: 1, payload: Array(bytes[..<split])),
      writeFrame(client, fin: true, opcode: 9, payload: Array("probe".utf8)),
      writeFrame(client, fin: true, opcode: 0, payload: Array(bytes[split...]))
    else { return false }
    guard let pong = readFrame(client), pong.opcode == 10, pong.masked else { return false }
    // Two concurrent subscriptions must still arrive as two complete frames.
    guard let second = readFrame(client), let third = readFrame(client) else { return false }
    return second.opcode == 1 && second.masked && third.opcode == 1 && third.masked
  }

  private static func readHTTP(_ descriptor: Int32) -> String? {
    var bytes: [UInt8] = []
    while bytes.count < 16_384 {
      var byte: UInt8 = 0
      guard read(descriptor, &byte, 1) == 1 else { return nil }
      bytes.append(byte)
      if bytes.suffix(4) == [13, 10, 13, 10] { return String(bytes: bytes, encoding: .utf8) }
    }
    return nil
  }

  private static func readFrame(_ descriptor: Int32) -> (
    opcode: UInt8, payload: [UInt8], masked: Bool
  )? {
    guard let header = readExact(descriptor, 2) else { return nil }
    let opcode = header[0] & 0x0f
    var count = Int(header[1] & 0x7f)
    if count == 126 {
      guard let extended = readExact(descriptor, 2) else { return nil }
      count = Int(extended[0]) << 8 | Int(extended[1])
    }
    let masked = header[1] & 0x80 != 0
    let mask = masked ? readExact(descriptor, 4) : []
    guard mask != nil, var payload = readExact(descriptor, count) else { return nil }
    if let mask, masked {
      for index in payload.indices { payload[index] ^= mask[index % 4] }
    }
    return (opcode, payload, masked)
  }

  private static func writeFrame(
    _ descriptor: Int32, fin: Bool, opcode: UInt8, payload: [UInt8]
  ) -> Bool {
    let first = (fin ? 0x80 : 0) | opcode
    let header: [UInt8]
    if payload.count < 126 {
      header = [first, UInt8(payload.count)]
    } else if payload.count <= Int(UInt16.max) {
      header = [first, 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
    } else {
      return false
    }
    return writeAll(descriptor, header + payload)
  }

  private static func readExact(_ descriptor: Int32, _ count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let amount = bytes.withUnsafeMutableBytes {
        read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
      }
      guard amount > 0 else { return nil }
      offset += amount
    }
    return bytes
  }

  private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let amount = bytes.withUnsafeBytes {
        write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      guard amount > 0 else { return false }
      offset += amount
    }
    return true
  }
}

private final class StalledHTTPServer: @unchecked Sendable {
  let port: UInt16
  private let descriptor: Int32
  private let accepted = CompletionFlag()

  init() throws {
    #if os(Linux)
      let socketDescriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
      let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard socketDescriptor >= 0 else { throw TestFailure.message("socket failed") }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(socketDescriptor, 2) == 0 else {
      close(socketDescriptor)
      throw TestFailure.message("bind failed")
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketDescriptor, $0, &length)
      }
    }
    descriptor = socketDescriptor
    port = UInt16(bigEndian: actual.sin_port)
    let signal = accepted
    Thread.detachNewThread { [socketDescriptor, signal] in
      while true {
        let client = accept(socketDescriptor, nil, nil)
        guard client >= 0 else { return }
        signal.finish()
        var byte: UInt8 = 0
        while read(client, &byte, 1) > 0 {}
        close(client)
      }
    }
  }

  deinit { close(descriptor) }

  func waitUntilAccepted() async throws {
    for _ in 0..<100 {
      if accepted.isFinished { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.message("stalled server did not accept")
  }
}

private final class RawServerResult: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool?
  var value: Bool? { lock.withLock { stored } }
  func complete(_ value: Bool) { lock.withLock { stored = value } }
}

private final class CompletionFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  var isFinished: Bool { lock.withLock { finished } }
  func finish() { lock.withLock { finished = true } }
}
