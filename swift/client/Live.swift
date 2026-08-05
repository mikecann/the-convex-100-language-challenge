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
  func shutdown() async
}

private final class NIOSocket: LiveSocket, @unchecked Sendable {
  let socket: WebSocket
  init(_ socket: WebSocket) { self.socket = socket }
  var isClosed: Bool { socket.isClosed }
  func send(_ text: String) async throws { try await socket.send(text) }
  func close() { socket.close(promise: nil) }
}

private final class NIOSocketFactory: LiveSocketFactory, @unchecked Sendable {
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

  func connect(
    url: URL,
    onText: @Sendable @escaping (String) -> Void,
    onBinary: @Sendable @escaping () -> Void,
    onClose: @Sendable @escaping () -> Void
  ) async throws -> any LiveSocket {
    let connected = group.next().makePromise(of: WebSocket.self)
    var configuration = WebSocketClient.Configuration(maxFrameSize: 64 * 1024)
    configuration.minNonFinalFragmentSize = 1
    configuration.maxAccumulatedFrameCount = 64
    configuration.maxAccumulatedFrameSize = 2 * 1024 * 1024
    let headers: HTTPHeaders = ["Convex-Client": "swift-0.1.0"]
    do {
      let connectionFuture: EventLoopFuture<Void> = WebSocket.connect(
        to: url,
        headers: headers,
        configuration: configuration,
        on: group
      ) { socket in
        socket.onText { _, text in onText(text) }
        socket.onBinary { _, _ in onBinary() }
        socket.onClose.whenComplete { _ in onClose() }
        connected.succeed(socket)
      }
      try await connectionFuture.get()
      return NIOSocket(try await connected.futureResult.get())
    } catch { throw error }
  }

  func shutdown() async {
    try? await group.shutdownGracefully()
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
      self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation = $0 }
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
  private var socket: (any LiveSocket)?
  private var subscriptions: [Int: Entry] = [:]
  private var nextID = 0
  private var querySet = 0
  private var connectionCount = 0
  private var generation = 0
  private var closed = false
  private var reconnectTask: Task<Void, Never>?
  private var intentionalDisconnect = false
  private var backoffMilliseconds = 100
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
    let args = boxedArguments.value
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
        try await connect()
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
    guard subscriptions.removeValue(forKey: subscription.id) != nil else { return }
    subscription.continuation.finish()
    if socket != nil { try? await modify([["type": "Remove", "queryId": subscription.id]]) }
  }

  @_spi(ConvexAdapter) public func debugDisconnectForAdapter() async throws {
    guard let previous = socket else { throw transportError("Live WebSocket is not connected") }
    intentionalDisconnect = true
    generation += 1
    socket = nil
    previous.close()
    connectionCount += 1
    resetRemoteState()
    try await Task.sleep(for: .milliseconds(100))
    intentionalDisconnect = false
    if !closed && !subscriptions.isEmpty { try await connect() }
  }

  public func close() async {
    guard !closed else { return }
    closed = true
    reconnectTask?.cancel()
    generation += 1
    let previous = socket
    socket = nil
    previous?.close()
    for entry in subscriptions.values { entry.subscription.continuation.finish() }
    subscriptions.removeAll()
    await factory.shutdown()
  }

  private func connect() async throws {
    generation += 1
    let currentGeneration = generation
    let connected: any LiveSocket
    do {
      connected = try await factory.connect(
        url: endpoint,
        onText: { [weak self] text in
          Task { await self?.received(text, generation: currentGeneration) }
        },
        onBinary: { [weak self] in
          Task {
            await self?.protocolFailure(
              "Live server sent a binary message", generation: currentGeneration)
          }
        },
        onClose: { [weak self] in Task { await self?.socketClosed(generation: currentGeneration) } }
      )
    } catch {
      throw transportError("Live connect failed: \(error.localizedDescription)")
    }
    guard !closed, currentGeneration == generation else {
      connected.close()
      throw transportError("Live connection became stale")
    }
    socket = connected
    querySet = 0
    version = Self.zeroVersion()
    var connect: [String: JSON] = [
      "type": "Connect",
      "sessionId": UUID().uuidString,
      "connectionCount": connectionCount,
      "lastCloseReason": connectionCount == 0 ? "InitialConnect" : "TransportError",
      "clientTs": 0,
    ]
    if let maxObservedTimestamp { connect["maxObservedTimestamp"] = maxObservedTimestamp }
    try await send(connect)
    if !subscriptions.isEmpty {
      try await modify(
        subscriptions.values.map {
          ["type": "Add", "queryId": $0.subscription.id, "udfPath": $0.path, "args": [$0.args]]
        })
    }
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
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
      throw protocolError("could not encode Live message")
    }
    do { try await socket.send(text) } catch {
      throw transportError("Live send failed: \(error.localizedDescription)")
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
    case "Ping", "MutationResponse", "ActionResponse":
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
      else {
        throw protocolError("Live modification omitted type or queryId")
      }
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
    guard closedGeneration == generation, !closed, !intentionalDisconnect else { return }
    deliver(transportError("Live WebSocket closed unexpectedly"))
    await detachAndReconnect(reason: "TransportError")
  }

  private func detachAndReconnect(reason: String) async {
    generation += 1
    let previous = socket
    socket = nil
    previous?.close()
    connectionCount += 1
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
    reconnectTask = nil
    guard !closed, socket == nil, !subscriptions.isEmpty else { return }
    do { try await connect() } catch {
      deliver(transportError("Live reconnect failed: \(error.localizedDescription)"))
      scheduleReconnect()
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
