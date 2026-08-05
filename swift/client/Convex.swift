import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// JSON values stay as Foundation values so null, nested arrays and objects make
// the same round trip through Convex that they do on the wire.
public typealias JSON = Any

public struct ConvexResult { public let value: JSON; public let logs: [String] }
public struct ConvexError: Error, LocalizedError {
  public enum Kind: String { case function = "FunctionError", transport = "TransportError", protocolError = "ProtocolError" }
  public let kind: Kind; public let message: String; public let data: JSON?; public let logs: [String]
  public var errorDescription: String? { message }
}

public final class ConvexClient {
  private let base: URL; private let session: URLSession; private let lock = NSLock()
  private var token = ""; private var closed = false
  public init(_ deployment: String) throws {
    guard let url = URL(string: deployment), ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil else { throw ConvexError(kind: .protocolError, message: "Convex deployment URL must be http(s), have a host, and omit user info", data: nil, logs: []) }
    base = url; session = URLSession(configuration: .ephemeral)
  }
  public func setAuth(_ value: String) throws { lock.lock(); defer { lock.unlock() }; guard !closed else { throw ConvexError(kind: .transport, message: "client is closed", data: nil, logs: []) }; token = value }
  public func query(_ path: String, _ args: [String: JSON]) async throws -> ConvexResult { try await call("query", path, args) }
  public func mutation(_ path: String, _ args: [String: JSON]) async throws -> ConvexResult { try await call("mutation", path, args) }
  public func action(_ path: String, _ args: [String: JSON]) async throws -> ConvexResult { try await call("action", path, args) }
  private func call(_ operation: String, _ path: String, _ args: [String: JSON]) async throws -> ConvexResult {
    guard !path.isEmpty else { throw ConvexError(kind: .protocolError, message: "Convex function path is required", data: nil, logs: []) }
    lock.lock(); let auth = token; let isClosed = closed; lock.unlock(); if isClosed { throw ConvexError(kind: .transport, message: "client is closed", data: nil, logs: []) }
    var request = URLRequest(url: base.appendingPathComponent("api/\(operation)")); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("swift-0.1.0", forHTTPHeaderField: "Convex-Client"); if !auth.isEmpty { request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "args": args, "format": "json"])
    let data: Data
    do { (data, _) = try await session.data(for: request) } catch { throw ConvexError(kind: .transport, message: error.localizedDescription, data: nil, logs: []) }
    guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: JSON], let status = decoded["status"] as? String else { throw ConvexError(kind: .transport, message: "HTTP returned a non-Convex response", data: nil, logs: []) }
    let logs = decoded["logLines"] as? [String] ?? []
    if status == "success" { guard let value = decoded["value"] else { throw ConvexError(kind: .protocolError, message: "success response omitted value", data: nil, logs: []) }; return ConvexResult(value: value, logs: logs) }
    if status == "error" { throw ConvexError(kind: .function, message: decoded["errorMessage"] as? String ?? "Convex function failed", data: decoded["errorData"], logs: logs) }
    throw ConvexError(kind: .protocolError, message: "unknown Convex response status", data: nil, logs: [])
  }
  public func close() { lock.lock(); closed = true; lock.unlock(); session.invalidateAndCancel() }
}

// One actor owns the socket and serialises Add/Remove/reconnect work. URLSession
// handles RFC6455 framing; received text is still size-bounded before JSON parse.
public actor LiveClient {
  public struct Update { public let value: JSON?; public let error: ConvexError?; public let logs: [String] }
  public final class Subscription { fileprivate let id: Int; public let stream: AsyncStream<Update>; fileprivate let continuation: AsyncStream<Update>.Continuation; fileprivate init(_ id: Int) { self.id=id; var c: AsyncStream<Update>.Continuation!; stream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { c = $0 }; continuation = c } }
  private let endpoint: URL; private let session = URLSession(configuration: .ephemeral); private var socket: URLSessionWebSocketTask?; private var subscriptions: [Int: (String, [String: JSON], Subscription)] = [:]; private var nextID=0; private var querySet=0; private var connectionCount=0; private var reconnecting=false; private var closed=false
  public init(_ deployment: String) throws { guard var c = URLComponents(string: deployment), let scheme = c.scheme else { throw ConvexError(kind: .protocolError, message: "invalid deployment", data:nil, logs:[]) }; c.scheme = scheme == "https" ? "wss" : "ws"; c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/sync"; guard let url=c.url else { throw ConvexError(kind:.protocolError,message:"invalid deployment",data:nil,logs:[]) }; endpoint=url }
  public func subscribe(_ path: String, _ args: [String: JSON]) async throws -> Subscription { guard !closed else { throw ConvexError(kind:.transport,message:"Live client is closed",data:nil,logs:[]) }; let s=Subscription(nextID); nextID += 1; subscriptions[s.id]=(path,args,s); if socket == nil { try await connect() } else { try await modify([["type":"Add","queryId":s.id,"udfPath":path,"args":[args]]]) }; return s }
  public func unsubscribe(_ s: Subscription) async { guard subscriptions.removeValue(forKey:s.id) != nil else{return}; s.continuation.finish(); if socket != nil { try? await modify([["type":"Remove","queryId":s.id]]) } }
  public func debugDisconnectForAdapter() async throws { guard socket != nil else { throw ConvexError(kind:.transport,message:"Live WebSocket is not connected",data:nil,logs:[]) }; socket?.cancel(with: .goingAway, reason:nil); socket=nil; connectionCount += 1; try await Task.sleep(for: .milliseconds(100)); if !closed && !subscriptions.isEmpty { try await connect() } }
  public func close() { closed=true; socket?.cancel(with:.goingAway,reason:nil); socket=nil; for (_,_,s) in subscriptions.values { s.continuation.finish() }; subscriptions.removeAll() }
  private func connect() async throws { let task=session.webSocketTask(with:endpoint); socket=task; task.resume(); querySet=0; try await send(["type":"Connect","sessionId":UUID().uuidString,"connectionCount":connectionCount,"lastCloseReason":connectionCount == 0 ? "InitialConnect" : "TransportError","clientTs":0]); if !subscriptions.isEmpty { try await modify(subscriptions.values.map { ["type":"Add","queryId":$0.2.id,"udfPath":$0.0,"args":[$0.1]] }) }; Task { await receiveLoop(task) } }
  private func modify(_ changes: [[String: JSON]]) async throws { try await send(["type":"ModifyQuerySet","baseVersion":querySet,"newVersion":querySet+1,"modifications":changes]); querySet += 1 }
  private func send(_ object: [String: JSON]) async throws { guard let socket else { throw ConvexError(kind:.transport,message:"Live WebSocket is not connected",data:nil,logs:[]) }; do { try await socket.send(.data(try JSONSerialization.data(withJSONObject:object))) } catch { throw ConvexError(kind:.transport,message:error.localizedDescription,data:nil,logs:[]) } }
  private func receiveLoop(_ task: URLSessionWebSocketTask) async { while !closed && socket === task { do { let message=try await task.receive(); let data: Data; switch message { case .data(let d): data=d; case .string(let s): data=Data(s.utf8); @unknown default: return }; guard data.count <= 2*1024*1024, let object=try JSONSerialization.jsonObject(with:data) as? [String:JSON] else { throw ConvexError(kind:.protocolError,message:"invalid Live frame",data:nil,logs:[]) }; try handle(object) } catch { if socket === task && !closed { socket=nil; connectionCount += 1; try? await Task.sleep(for:.milliseconds(100)); if !subscriptions.isEmpty { try? await connect() } }; return } } }
  private func handle(_ message:[String:JSON]) throws { guard message["type"] as? String == "Transition" else { return }; for item in message["modifications"] as? [[String:JSON]] ?? [] { guard let id=item["queryId"] as? Int, let (_,_,s)=subscriptions[id] else { continue }; let logs=item["logLines"] as? [String] ?? []; if item["type"] as? String == "QueryUpdated", let value=item["value"] { s.continuation.yield(Update(value:value,error:nil,logs:logs)) } else if item["type"] as? String == "QueryFailed" { s.continuation.yield(Update(value:nil,error:ConvexError(kind:.function,message:item["errorMessage"] as? String ?? "query failed",data:item["errorData"],logs:logs),logs:logs)) } } }
}
