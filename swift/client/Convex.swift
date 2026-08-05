import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public typealias JSON = Any

public struct ConvexResult: @unchecked Sendable {
  public let value: JSON
  public let logs: [String]
}

public struct ConvexError: Error, LocalizedError, @unchecked Sendable {
  public enum Kind: String, Sendable {
    case function = "FunctionError"
    case transport = "TransportError"
    case protocolError = "ProtocolError"
  }

  public let kind: Kind
  public let message: String
  public let data: JSON?
  public let logs: [String]
  public var errorDescription: String? { message }
}

/// Native Swift implementation of Convex's documented JSON HTTP functions API.
public final class ConvexClient: @unchecked Sendable {
  private let base: URL
  private let session: URLSession
  private let state = NSLock()
  private var token = ""
  private var closed = false

  public init(_ deployment: String, session: URLSession? = nil) throws {
    guard
      let url = URL(string: deployment),
      ["http", "https"].contains(url.scheme),
      url.host != nil,
      url.user == nil
    else {
      throw ConvexError(
        kind: .protocolError,
        message: "Convex deployment URL must be http(s), have a host, and omit user info",
        data: nil, logs: [])
    }
    self.base = url
    self.session = session ?? URLSession(configuration: .ephemeral)
  }

  public func setAuth(_ value: String) throws {
    try state.withLock {
      guard !closed else { throw closedError() }
      token = value
    }
  }

  public func query(_ path: String, _ args: [String: JSON]) async throws -> ConvexResult {
    try await call("query", path, args)
  }

  public func mutation(_ path: String, _ args: [String: JSON]) async throws -> ConvexResult {
    try await call("mutation", path, args)
  }

  public func action(_ path: String, _ args: [String: JSON]) async throws -> ConvexResult {
    try await call("action", path, args)
  }

  private func call(_ operation: String, _ path: String, _ args: [String: JSON]) async throws
    -> ConvexResult
  {
    guard !path.isEmpty else {
      throw ConvexError(
        kind: .protocolError, message: "Convex function path is required", data: nil, logs: [])
    }
    let auth = try state.withLock { () throws -> String in
      guard !closed else { throw closedError() }
      return token
    }
    guard JSONSerialization.isValidJSONObject(args) else {
      throw ConvexError(
        kind: .protocolError, message: "Convex arguments must be a JSON object", data: nil, logs: []
      )
    }

    var request = URLRequest(url: base.appendingPathComponent("api/\(operation)"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("swift-0.1.0", forHTTPHeaderField: "Convex-Client")
    if !auth.isEmpty { request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "path": path, "args": args, "format": "json",
    ])

    let data: Data
    do {
      let response = try await session.data(for: request)
      guard response.0.count <= 2 * 1024 * 1024 else {
        throw ConvexError(
          kind: .transport, message: "HTTP response exceeds 2097152 bytes", data: nil, logs: [])
      }
      data = response.0
    } catch let error as ConvexError {
      throw error
    } catch {
      throw ConvexError(kind: .transport, message: error.localizedDescription, data: nil, logs: [])
    }

    guard
      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: JSON],
      let status = decoded["status"] as? String
    else {
      throw ConvexError(
        kind: .transport, message: "HTTP returned a non-Convex response", data: nil, logs: [])
    }
    let logs = decoded["logLines"] as? [String] ?? []
    switch status {
    case "success":
      guard let value = decoded["value"] else {
        throw ConvexError(
          kind: .protocolError, message: "success response omitted value", data: nil, logs: [])
      }
      return ConvexResult(value: value, logs: logs)
    case "error":
      throw ConvexError(
        kind: .function,
        message: decoded["errorMessage"] as? String ?? "Convex function failed",
        data: decoded["errorData"],
        logs: logs
      )
    default:
      throw ConvexError(
        kind: .protocolError, message: "unknown Convex response status \(status)", data: nil,
        logs: [])
    }
  }

  public func close() {
    state.withLock { closed = true }
    session.invalidateAndCancel()
  }

  private func closedError() -> ConvexError {
    ConvexError(kind: .transport, message: "client is closed", data: nil, logs: [])
  }
}
