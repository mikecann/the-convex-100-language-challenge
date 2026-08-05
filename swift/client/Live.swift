import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import WebSocketKit

protocol LiveSocket: AnyObject, Sendable {
  var isClosed: Bool { get }
  func send(_ text: String) async throws
  func close()
}

protocol LiveSocketFactory: Sendable {
  func connect(
    url: URL,
    onText: @Sendable @escaping (String) -> Void,
    onBinary: @Sendable @escaping () -> Void,
    onClose: @Sendable @escaping () -> Void
  ) async throws -> any LiveSocket
  func cancelPendingConnects()
  func shutdown() async
}

private final class NIOSocket: LiveSocket, @unchecked Sendable {
  let socket: WebSocket
  private let retire: @Sendable () -> Void
  init(_ socket: WebSocket, retire: @Sendable @escaping () -> Void) {
    self.socket = socket
    self.retire = retire
  }
  var isClosed: Bool { socket.isClosed }
  func send(_ text: String) async throws { try await socket.send(text) }
  func close() {
    socket.close(promise: nil)
    retire()
  }
}

final class NIOSocketFactory: LiveSocketFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [ObjectIdentifier: ActiveConnection] = [:]

  func connect(
    url: URL,
    onText: @Sendable @escaping (String) -> Void,
    onBinary: @Sendable @escaping () -> Void,
    onClose: @Sendable @escaping () -> Void
  ) async throws -> any LiveSocket {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let identifier = ObjectIdentifier(group)
    var configuration = WebSocketClient.Configuration(maxFrameSize: 64 * 1024)
    configuration.minNonFinalFragmentSize = 1
    configuration.maxAccumulatedFrameCount = 64
    configuration.maxAccumulatedFrameSize = 2 * 1024 * 1024
    let headers: HTTPHeaders = ["Convex-Client": "swift-0.1.0"]

    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<any LiveSocket, Error>) in
      let race = ConnectionRace(continuation)
      let active = ActiveConnection(group: group, race: race)
      lock.withLock { connections[identifier] = active }
      let future: EventLoopFuture<Void> = WebSocket.connect(
        to: url, headers: headers, configuration: configuration, on: group
      ) { [weak self] socket in
        guard let self else {
          socket.close(promise: nil)
          return
        }
        let retire: @Sendable () -> Void = { [weak self] in
          self?.retire(identifier, group: group)
        }
        socket.onText { _, text in onText(text) }
        socket.onBinary { _, _ in onBinary() }
        socket.onClose.whenComplete { _ in
          onClose()
          retire()
        }
        guard race.resolve(.success(NIOSocket(socket, retire: retire))) else {
          socket.close(promise: nil)
          retire()
          return
        }
      }
      future.whenFailure { [weak self] error in
        _ = race.resolve(.failure(error))
        self?.retire(identifier, group: group)
      }
      Task {
        try? await Task.sleep(for: .seconds(3))
        if race.resolve(.failure(transportError("Live HTTP upgrade timed out"))) {
          self.retire(identifier, group: group)
        }
      }
    }
  }

  func cancelPendingConnects() {
    let active = lock.withLock { Array(connections) }
    for (identifier, connection) in active {
      _ = connection.race.resolve(.failure(transportError("Live connect cancelled")))
      retire(identifier, group: connection.group)
    }
  }

  func shutdown() async {
    let active = lock.withLock { () -> [MultiThreadedEventLoopGroup] in
      defer { connections.removeAll() }
      return connections.values.map(\.group)
    }
    for group in active { try? await group.shutdownGracefully() }
  }

  var activeGroupCount: Int { lock.withLock { connections.count } }

  private func retire(
    _ identifier: ObjectIdentifier, group expected: MultiThreadedEventLoopGroup
  ) {
    let removed = lock.withLock { () -> MultiThreadedEventLoopGroup? in
      guard connections[identifier]?.group === expected else { return nil }
      return connections.removeValue(forKey: identifier)?.group
    }
    removed?.shutdownGracefully { _ in }
  }
}

private final class ActiveConnection: @unchecked Sendable {
  let group: MultiThreadedEventLoopGroup
  let race: ConnectionRace
  init(group: MultiThreadedEventLoopGroup, race: ConnectionRace) {
    self.group = group
    self.race = race
  }
}

private final class ConnectionRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<any LiveSocket, Error>?
  init(_ continuation: CheckedContinuation<any LiveSocket, Error>) {
    self.continuation = continuation
  }
  func resolve(_ result: Result<any LiveSocket, Error>) -> Bool {
    lock.withLock {
      guard let continuation else { return false }
      self.continuation = nil
      continuation.resume(with: result)
      return true
    }
  }
}

private actor ProtocolGate {
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func lock() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
  func unlock() {
    if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
  }
}

private enum InboundEvent: @unchecked Sendable {
  case text(String, Int)
  case binary(Int)
  case closed(Int)
  case overflow(Int)

  var generation: Int {
    switch self {
    case .text(_, let generation), .binary(let generation), .closed(let generation),
      .overflow(let generation):
      return generation
    }
  }
}

/// WebSocket callbacks may arrive on different event loops. This mailbox gives
/// the protocol actor one ordered input rather than creating one Task per event.
private final class InboundMailbox: @unchecked Sendable {
  private static let capacity = 8
  private let lock = NSLock()
  private var values: [InboundEvent] = []
  private var draining = false

  func enqueue(_ value: InboundEvent) -> Bool {
    lock.withLock {
      if values.count >= Self.capacity {
        values.removeAll(keepingCapacity: true)
        values.append(.overflow(value.generation))
      } else {
        values.append(value)
      }
      guard !draining else { return false }
      draining = true
      return true
    }
  }

  func dequeue() -> InboundEvent? {
    lock.withLock {
      guard !values.isEmpty else {
        draining = false
        return nil
      }
      return values.removeFirst()
    }
  }
}

/// One actor owns the WebSocket, query set and reconnect lifecycle.
public actor LiveClient {
  public struct Update: @unchecked Sendable {
    public let value: JSON?
    public let error: ConvexError?
    public let logs: [String]
  }

  public final class Subscription: @unchecked Sendable {
    fileprivate let id: Int
    public let stream: AsyncStream<Update>
    fileprivate let continuation: AsyncStream<Update>.Continuation

    init(_ id: Int) {
      self.id = id
      var continuation: AsyncStream<Update>.Continuation!
      stream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation = $0 }
      self.continuation = continuation
    }
  }

  private struct Entry: @unchecked Sendable {
    let path: String
    let args: [String: JSON]
    let subscription: Subscription
    var lastDelivered: Data?
  }

  private let endpoint: URL
  private let factory: any LiveSocketFactory
  private let protocolGate = ProtocolGate()
  private let inbound = InboundMailbox()
  private var socket: (any LiveSocket)?
  private var subscriptions: [Int: Entry] = [:]
  private var nextID = 0
  private var querySet = 0
  private var connectionCount = 0
  private var generation = 0
  private var closed = false
  private var reconnectTask: Task<Void, Never>?
  private var backoffMilliseconds = 100
  private var lastCloseReason = "InitialConnect"
  private var version: [String: JSON] = LiveClient.zeroVersion()
  private var maxObservedTimestamp: String?

  public init(_ deployment: String) throws {
    try self.init(deployment, factory: NIOSocketFactory())
  }

  init(_ deployment: String, factory: any LiveSocketFactory) throws {
    guard var components = URLComponents(string: deployment), let scheme = components.scheme else {
      throw protocolError("invalid deployment URL")
    }
    components.scheme = scheme == "https" ? "wss" : "ws"
    components.path =
      components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/sync"
    guard let url = components.url else { throw protocolError("invalid deployment URL") }
    endpoint = url
    self.factory = factory
  }

  public nonisolated func subscribe(
    _ path: String, _ args: [String: JSON]
  ) async throws -> Subscription {
    try await subscribeIsolated(path, JSONArguments(args))
  }

  private func subscribeIsolated(
    _ path: String, _ boxedArguments: JSONArguments
  ) async throws -> Subscription {
    try await gated { try await subscribeLocked(path, boxedArguments.value) }
  }

  private func subscribeLocked(_ path: String, _ args: [String: JSON]) async throws -> Subscription
  {
    guard !closed else { throw transportError("Live client is closed") }
    guard !path.isEmpty, JSONSerialization.isValidJSONObject(args) else {
      throw protocolError("invalid Live query")
    }
    let subscription = Subscription(nextID)
    nextID += 1
    subscriptions[subscription.id] = Entry(
      path: path, args: args, subscription: subscription, lastDelivered: nil)
    do {
      if socket == nil {
        try await connectLocked()
      } else {
        try await modify([
          ["type": "Add", "queryId": subscription.id, "udfPath": path, "args": [args]]
        ])
      }
    } catch {
      subscriptions.removeValue(forKey: subscription.id)
      subscription.continuation.finish()
      throw error
    }
    return subscription
  }

  public func unsubscribe(_ subscription: Subscription) async {
    await gated {
      guard subscriptions.removeValue(forKey: subscription.id) != nil else { return }
      subscription.continuation.finish()
      if socket != nil { try? await modify([["type": "Remove", "queryId": subscription.id]]) }
    }
  }

  @_spi(ConvexAdapter) public func debugDisconnectForAdapter() async throws {
    try await gated {
      guard let previous = socket else { throw transportError("Live WebSocket is not connected") }
      generation += 1
      socket = nil
      previous.close()
      connectionCount += 1
      lastCloseReason = "DebugDisconnect"
      resetRemoteState()
      // Return once the disconnect is committed. The adapter can acknowledge it
      // before ordinary retry work starts, even when several retries fail.
      scheduleReconnect()
    }
  }

  public func close() async {
    // Interrupt a stalled HTTP upgrade before waiting for the gate it holds.
    factory.cancelPendingConnects()
    await gated {
      guard !closed else { return }
      closed = true
      reconnectTask?.cancel()
      reconnectTask = nil
      generation += 1
      let previous = socket
      socket = nil
      previous?.close()
      for entry in subscriptions.values { entry.subscription.continuation.finish() }
      subscriptions.removeAll()
    }
    await factory.shutdown()
  }

  /// A candidate is not published until Connect and the initial query set have
  /// both reached the transport. A failed setup cannot leak half-connected state.
  private func connectLocked() async throws {
    generation += 1
    let currentGeneration = generation
    let candidate: any LiveSocket
    do {
      candidate = try await factory.connect(
        url: endpoint,
        onText: { [weak self] text in self?.enqueue(.text(text, currentGeneration)) },
        onBinary: { [weak self] in self?.enqueue(.binary(currentGeneration)) },
        onClose: { [weak self] in self?.enqueue(.closed(currentGeneration)) }
      )
    } catch {
      throw transportError("Live connect failed: \(error.localizedDescription)")
    }
    guard !closed, currentGeneration == generation else {
      candidate.close()
      throw transportError("Live connection became stale")
    }
    var connect: [String: JSON] = [
      "type": "Connect",
      "sessionId": UUID().uuidString,
      "connectionCount": connectionCount,
      "lastCloseReason": lastCloseReason,
      "clientTs": 0,
    ]
    if let maxObservedTimestamp { connect["maxObservedTimestamp"] = maxObservedTimestamp }
    do {
      try await send(connect, on: candidate)
      if !subscriptions.isEmpty {
        try await send(
          [
            "type": "ModifyQuerySet", "baseVersion": 0, "newVersion": 1,
            "modifications": subscriptions.values.map {
              ["type": "Add", "queryId": $0.subscription.id, "udfPath": $0.path, "args": [$0.args]]
            },
          ], on: candidate)
      }
    } catch {
      candidate.close()
      generation += 1
      resetRemoteState()
      throw error
    }
    guard !closed, currentGeneration == generation, !candidate.isClosed else {
      candidate.close()
      throw transportError("Live connection became stale during setup")
    }
    socket = candidate
    querySet = subscriptions.isEmpty ? 0 : 1
    version = Self.zeroVersion()
  }

  private func modify(_ modifications: [[String: JSON]]) async throws {
    try await send([
      "type": "ModifyQuerySet",
      "baseVersion": querySet,
      "newVersion": querySet + 1,
      "modifications": modifications,
    ])
    querySet += 1
  }

  private func send(_ object: [String: JSON]) async throws {
    guard let socket else { throw transportError("Live WebSocket is not connected") }
    try await send(object, on: socket)
  }

  private func send(_ object: [String: JSON], on target: any LiveSocket) async throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
      throw protocolError("could not encode Live message")
    }
    do { try await target.send(text) } catch {
      throw transportError("Live send failed: \(error.localizedDescription)")
    }
  }

  nonisolated private func enqueue(_ event: InboundEvent) {
    if inbound.enqueue(event) { Task { await self.drainInbound() } }
  }

  private func drainInbound() async {
    while let event = inbound.dequeue() {
      await gated {
        switch event {
        case .text(let text, let eventGeneration):
          await received(text, generation: eventGeneration)
        case .binary(let eventGeneration):
          await protocolFailure("Live server sent a binary message", generation: eventGeneration)
        case .closed(let eventGeneration):
          await socketClosed(generation: eventGeneration)
        case .overflow(let eventGeneration):
          await protocolFailure("Live inbound mailbox overflow", generation: eventGeneration)
        }
      }
    }
  }

  private func received(_ text: String, generation messageGeneration: Int) async {
    guard messageGeneration == generation, socket != nil else { return }
    guard text.utf8.count <= 2 * 1024 * 1024,
      let data = text.data(using: .utf8),
      let message = try? JSONSerialization.jsonObject(with: data) as? [String: JSON],
      let type = message["type"] as? String
    else {
      await protocolFailure("invalid or oversized Live message", generation: messageGeneration)
      return
    }
    switch type {
    case "Transition":
      do { try handleTransition(message) } catch let error as ConvexError {
        await protocolFailure(error.message, generation: messageGeneration)
      } catch { await protocolFailure(error.localizedDescription, generation: messageGeneration) }
    case "Ping":
      backoffMilliseconds = 100
    case "MutationResponse", "ActionResponse":
      break
    default:
      await protocolFailure("unsupported Live message: \(type)", generation: messageGeneration)
    }
  }

  private func handleTransition(_ message: [String: JSON]) throws {
    guard let start = message["startVersion"] as? [String: JSON],
      let end = message["endVersion"] as? [String: JSON],
      let modifications = message["modifications"] as? [[String: JSON]],
      jsonEqual(start, version)
    else { throw protocolError("Live transition version mismatch or missing fields") }

    var deliveries: [(Int, Update, Data?)] = []
    for modification in modifications {
      guard let queryID = number(modification["queryId"]),
        let modificationType = modification["type"] as? String
      else { throw protocolError("Live modification omitted type or queryId") }
      let logs = modification["logLines"] as? [String] ?? []
      switch modificationType {
      case "QueryUpdated":
        guard let value = modification["value"] else {
          throw protocolError("QueryUpdated omitted value")
        }
        let fingerprint = try JSONSerialization.data(
          withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        deliveries.append((queryID, Update(value: value, error: nil, logs: logs), fingerprint))
      case "QueryFailed":
        deliveries.append(
          (
            queryID,
            Update(
              value: nil,
              error: ConvexError(
                kind: .function, message: modification["errorMessage"] as? String ?? "query failed",
                data: modification["errorData"], logs: logs), logs: logs), nil
          ))
      case "QueryRemoved":
        break
      default:
        throw protocolError("unsupported Live modification: \(modificationType)")
      }
    }

    version = end
    maxObservedTimestamp = end["ts"] as? String
    backoffMilliseconds = 100
    for (queryID, update, fingerprint) in deliveries {
      guard var entry = subscriptions[queryID] else { continue }
      if let fingerprint, fingerprint == entry.lastDelivered { continue }
      entry.lastDelivered = fingerprint
      subscriptions[queryID] = entry
      entry.subscription.continuation.yield(update)
    }
  }

  private func protocolFailure(_ message: String, generation failedGeneration: Int) async {
    guard failedGeneration == generation else { return }
    deliver(ConvexError(kind: .protocolError, message: message, data: nil, logs: []))
    await detachAndReconnect(reason: "ProtocolError")
  }

  private func socketClosed(generation closedGeneration: Int) async {
    guard closedGeneration == generation, !closed else { return }
    deliver(transportError("Live WebSocket closed unexpectedly"))
    await detachAndReconnect(reason: "TransportError")
  }

  private func detachAndReconnect(reason: String) async {
    generation += 1
    let previous = socket
    socket = nil
    previous?.close()
    connectionCount += 1
    lastCloseReason = reason
    resetRemoteState()
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard reconnectTask == nil, !closed, !subscriptions.isEmpty else { return }
    let delay = backoffMilliseconds
    backoffMilliseconds = min(backoffMilliseconds * 2, 15_000)
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(delay))
      await self?.reconnectNow()
    }
  }

  private func reconnectNow() async {
    await gated {
      reconnectTask = nil
      guard !closed, socket == nil, !subscriptions.isEmpty else { return }
      do { try await connectLocked() } catch {
        lastCloseReason = "TransportError"
        deliver(transportError("Live reconnect failed: \(error.localizedDescription)"))
        scheduleReconnect()
      }
    }
  }

  private func gated<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
    await protocolGate.lock()
    do {
      let value = try await operation()
      await protocolGate.unlock()
      return value
    } catch {
      await protocolGate.unlock()
      throw error
    }
  }

  private func deliver(_ error: ConvexError) {
    for entry in subscriptions.values {
      entry.subscription.continuation.yield(Update(value: nil, error: error, logs: error.logs))
    }
  }

  private func resetRemoteState() {
    querySet = 0
    version = Self.zeroVersion()
  }

  private static func zeroVersion() -> [String: JSON] {
    ["querySet": 0, "identity": 0, "ts": "AAAAAAAAAAA="]
  }
}

private struct JSONArguments: @unchecked Sendable {
  let value: [String: JSON]
  init(_ value: [String: JSON]) { self.value = value }
}

private func number(_ value: JSON?) -> Int? {
  (value as? NSNumber)?.intValue
}

private func jsonEqual(_ lhs: JSON, _ rhs: JSON) -> Bool {
  guard
    let left = try? JSONSerialization.data(
      withJSONObject: lhs, options: [.sortedKeys, .fragmentsAllowed]),
    let right = try? JSONSerialization.data(
      withJSONObject: rhs, options: [.sortedKeys, .fragmentsAllowed])
  else { return false }
  return left == right
}

private func protocolError(_ message: String) -> ConvexError {
  ConvexError(kind: .protocolError, message: message, data: nil, logs: [])
}

private func transportError(_ message: String) -> ConvexError {
  ConvexError(kind: .transport, message: message, data: nil, logs: [])
}
