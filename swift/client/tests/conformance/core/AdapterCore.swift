@_spi(ConvexAdapter) import Convex
import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

public func encodeEvent(_ value: [String: Any]) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  return String(decoding: data, as: UTF8.self)
}

public func adapterErrorEvent(id: String?, subscriptionID: String? = nil, error: Error) -> [String:
  Any]
{
  let convex = error as? ConvexError
  var detail: [String: Any] = [
    "name": convex?.kind.rawValue ?? "TransportError",
    "message": convex?.message ?? error.localizedDescription,
  ]
  if let data = convex?.data { detail["data"] = data }
  var event: [String: Any] = [
    "type": subscriptionID == nil ? "error" : "subscription", "error": detail,
  ]
  if let id { event["id"] = id }
  if let subscriptionID { event["subscriptionId"] = subscriptionID }
  if let logs = convex?.logs, !logs.isEmpty { event["logs"] = logs }
  return event
}

public func resultEvent(id: String, result: ConvexResult) -> [String: Any] {
  var event: [String: Any] = ["type": "result", "id": id, "value": result.value]
  if !result.logs.isEmpty { event["logs"] = result.logs }
  return event
}

public struct ListenAddress: Equatable, Sendable {
  public let host: String
  public let port: UInt16

  public init(_ value: String) throws {
    let host: String
    let portText: String
    if value.hasPrefix("[") {
      guard let end = value.firstIndex(of: "]"), value.index(after: end) < value.endIndex,
        value[value.index(after: end)] == ":"
      else { throw AdapterIOError("ADAPTER_LISTEN must be host:port") }
      host = String(value[value.index(after: value.startIndex)..<end])
      portText = String(value[value.index(end, offsetBy: 2)...])
    } else {
      guard let separator = value.lastIndex(of: ":") else {
        throw AdapterIOError("ADAPTER_LISTEN must be host:port")
      }
      host = String(value[..<separator])
      portText = String(value[value.index(after: separator)...])
    }
    guard !host.isEmpty, let port = UInt16(portText), port > 0 else {
      throw AdapterIOError("ADAPTER_LISTEN must contain a host and nonzero port")
    }
    self.host = host
    self.port = port
  }
}

public struct AdapterIOError: Error, LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public final class LineConnection: @unchecked Sendable {
  public let input: Int32
  public let output: Int32
  private let writeLock = NSLock()
  private let ownsDescriptors: Bool

  public init(input: Int32, output: Int32, ownsDescriptors: Bool) {
    self.input = input
    self.output = output
    self.ownsDescriptors = ownsDescriptors
  }

  deinit {
    if ownsDescriptors {
      _ = systemClose(input)
      if output != input { _ = systemClose(output) }
    }
  }

  public func lines() -> AsyncStream<String> {
    AsyncStream { continuation in
      let input = self.input
      Task.detached {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = systemRead(input, &buffer, buffer.count)
          if count <= 0 { break }
          pending.append(buffer, count: count)
          while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            continuation.yield(
              String(decoding: line, as: UTF8.self).trimmingCharacters(
                in: .init(charactersIn: "\r")))
            pending.removeSubrange(...newline)
          }
          if pending.count > 2 * 1024 * 1024 { break }
        }
        continuation.finish()
      }
    }
  }

  public func write(event: [String: Any]) throws {
    let bytes = Array((try encodeEvent(event) + "\n").utf8)
    try writeLock.withLock {
      var written = 0
      while written < bytes.count {
        let count = bytes.withUnsafeBytes { pointer in
          systemWrite(output, pointer.baseAddress!.advanced(by: written), bytes.count - written)
        }
        guard count > 0 else { throw AdapterIOError("adapter output closed") }
        written += count
      }
    }
  }
}

public func acceptConnection(at address: ListenAddress) throws -> LineConnection {
  var hints = addrinfo(
    ai_flags: AI_PASSIVE,
    ai_family: AF_UNSPEC,
    ai_socktype: socketStreamType,
    ai_protocol: Int32(IPPROTO_TCP),
    ai_addrlen: 0,
    ai_addr: nil,
    ai_canonname: nil,
    ai_next: nil
  )
  var result: UnsafeMutablePointer<addrinfo>?
  let status = getaddrinfo(address.host, String(address.port), &hints, &result)
  guard status == 0, let first = result else {
    throw AdapterIOError("cannot resolve ADAPTER_LISTEN host \(address.host)")
  }
  defer { freeaddrinfo(first) }
  var cursor: UnsafeMutablePointer<addrinfo>? = first
  var listener: Int32 = -1
  while let info = cursor {
    listener = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    if listener >= 0 {
      var enabled: Int32 = 1
      _ = setsockopt(
        listener, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
      if bind(listener, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0,
        listen(listener, 1) == 0
      {
        break
      }
      _ = systemClose(listener)
      listener = -1
    }
    cursor = info.pointee.ai_next
  }
  guard listener >= 0 else {
    throw AdapterIOError("cannot bind ADAPTER_LISTEN \(address.host):\(address.port)")
  }
  defer { _ = systemClose(listener) }
  let peer = accept(listener, nil, nil)
  guard peer >= 0 else { throw AdapterIOError("cannot accept adapter controller") }
  return LineConnection(input: peer, output: peer, ownsDescriptors: true)
}

public actor SubscriptionRegistry {
  private struct Active {
    let token: UUID
    let subscription: LiveClient.Subscription
  }
  private var values: [String: Active] = [:]

  public init() {}

  public func replace(_ id: String, with subscription: LiveClient.Subscription) -> (
    UUID, LiveClient.Subscription?
  ) {
    let token = UUID()
    let previous = values.updateValue(Active(token: token, subscription: subscription), forKey: id)?
      .subscription
    return (token, previous)
  }

  public func remove(_ id: String) -> LiveClient.Subscription? {
    values.removeValue(forKey: id)?.subscription
  }
  public func isCurrent(_ id: String, token: UUID) -> Bool { values[id]?.token == token }
  public func removeAll() -> [LiveClient.Subscription] {
    defer { values.removeAll() }
    return values.values.map(\.subscription)
  }
}

/// Replacement and removal return only after the old relay has been stopped.
/// The adapter writes its acknowledgement after these barriers complete, so a
/// controller never observes an ack while a stale relay can still emit events.
public func replaceRelay(
  registry: SubscriptionRegistry, id: String, with subscription: LiveClient.Subscription,
  stop: @Sendable (LiveClient.Subscription) async -> Void
) async -> UUID {
  let (token, previous) = await registry.replace(id, with: subscription)
  if let previous { await stop(previous) }
  return token
}

public func removeRelay(
  registry: SubscriptionRegistry, id: String,
  stop: @Sendable (LiveClient.Subscription) async -> Void
) async {
  if let subscription = await registry.remove(id) { await stop(subscription) }
}

public actor AdapterOutput {
  private let connection: LineConnection
  private var closed = false
  public init(_ connection: LineConnection) { self.connection = connection }
  public func write(_ event: [String: Any]) {
    guard !closed else { return }
    try? connection.write(event: event)
  }
  public func writeIf(_ predicate: @Sendable () async -> Bool, _ event: [String: Any]) async {
    guard !closed, await predicate() else { return }
    try? connection.write(event: event)
  }
  public func writeIf(
    _ predicate: @Sendable () async -> Bool, boxed event: UnsafeEvent
  ) async {
    guard !closed, await predicate() else { return }
    try? connection.write(event: event.value)
  }
  public func finish(id: String?) {
    guard !closed else { return }
    closed = true
    var event: [String: Any] = ["type": "closed"]
    if let id { event["id"] = id }
    try? connection.write(event: event)
  }
}

public struct UnsafeEvent: @unchecked Sendable {
  public let value: [String: Any]
  public init(_ value: [String: Any]) { self.value = value }
}

public func runAdapter(connection: LineConnection, deploymentURL: String?) async {
  let output = AdapterOutput(connection)
  let registry = SubscriptionRegistry()
  var client: ConvexClient?
  var live: LiveClient?
  for await line in connection.lines() {
    guard let data = line.data(using: .utf8),
      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      await output.write(
        adapterErrorEvent(id: nil, error: AdapterIOError("command is not an object")))
      continue
    }
    let id = command["id"] as? String
    let operation = command["op"] as? String
    do {
      if operation == "hello" {
        guard (command["protocolVersion"] as? NSNumber)?.intValue == 1 else {
          throw AdapterIOError("unsupported adapter protocol version")
        }
        await output.write([
          "type": "ready", "id": id ?? "hello", "protocolVersion": 1, "language": "swift",
          "implementation": "native-swift-foundation-websocket-kit", "runtime": "Swift 6.1.2",
        ])
        continue
      }
      if operation == "close" {
        for subscription in await registry.removeAll() { await live?.unsubscribe(subscription) }
        await live?.close()
        client?.close()
        await output.finish(id: id)
        return
      }
      guard let deploymentURL, !deploymentURL.isEmpty else {
        throw AdapterIOError("CONVEX_URL is required")
      }
      if client == nil { client = try ConvexClient(deploymentURL) }
      switch operation {
      case "setAuth":
        try client!.setAuth(command["token"] as? String ?? "")
        await output.write(["type": "ack", "id": id ?? ""])
      case "query", "mutation", "action":
        let path = command["path"] as? String ?? ""
        let args = command["args"] as? [String: Any] ?? [:]
        let result: ConvexResult
        if operation == "query" {
          result = try await client!.query(path, args)
        } else if operation == "mutation" {
          result = try await client!.mutation(path, args)
        } else {
          result = try await client!.action(path, args)
        }
        await output.write(resultEvent(id: id ?? "", result: result))
      case "subscribe":
        guard let subscriptionID = command["subscriptionId"] as? String, !subscriptionID.isEmpty
        else { throw AdapterIOError("subscriptionId is required") }
        if live == nil { live = try LiveClient(deploymentURL) }
        let activeLive = live!
        let subscription = try await activeLive.subscribe(
          command["path"] as? String ?? "", command["args"] as? [String: Any] ?? [:])
        let token = await replaceRelay(registry: registry, id: subscriptionID, with: subscription) {
          await activeLive.unsubscribe($0)
        }
        await output.write(["type": "ack", "id": id ?? ""])
        Task {
          for await update in subscription.stream {
            let current = await registry.isCurrent(subscriptionID, token: token)
            guard current else { return }
            if let error = update.error {
              await output.writeIf(
                { await registry.isCurrent(subscriptionID, token: token) },
                adapterErrorEvent(id: nil, subscriptionID: subscriptionID, error: error))
            } else if let value = update.value {
              var event: [String: Any] = [
                "type": "subscription", "subscriptionId": subscriptionID, "value": value,
              ]
              if !update.logs.isEmpty { event["logs"] = update.logs }
              await output.writeIf(
                { await registry.isCurrent(subscriptionID, token: token) },
                boxed: UnsafeEvent(event))
            }
          }
        }
      case "unsubscribe":
        if let subscriptionID = command["subscriptionId"] as? String, let activeLive = live {
          await removeRelay(registry: registry, id: subscriptionID) {
            await activeLive.unsubscribe($0)
          }
        }
        await output.write(["type": "ack", "id": id ?? ""])
      case "debugDisconnect":
        guard let live else { throw AdapterIOError("Live WebSocket is not connected") }
        try await live.debugDisconnectForAdapter()
        await output.write(["type": "ack", "id": id ?? ""])
      default:
        throw AdapterIOError("unknown operation: \(operation ?? "")")
      }
    } catch {
      await output.write(adapterErrorEvent(id: id, error: error))
    }
  }
  for subscription in await registry.removeAll() { await live?.unsubscribe(subscription) }
  await live?.close()
  client?.close()
}

#if os(Linux)
  private let socketStreamType = Int32(SOCK_STREAM.rawValue)
  private let systemRead = Glibc.read
  private let systemWrite = Glibc.write
  private let systemClose = Glibc.close
#else
  private let socketStreamType = SOCK_STREAM
  private let systemRead = Darwin.read
  private let systemWrite = Darwin.write
  private let systemClose = Darwin.close
#endif
