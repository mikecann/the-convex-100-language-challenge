import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// Test-only NDJSON adapter v1. Its protocol output is deliberately isolated
// from diagnostics so the shared controller can parse stdout without guesswork.
func encode(_ value: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
func errorEvent(_ id: String?, _ sid: String? = nil, _ error: Error) -> [String: Any] { let e = error as? ConvexError; var v:[String:Any] = ["type": sid == nil ? "error" : "subscription", "error":["name": e?.kind.rawValue ?? "TransportError", "message": e?.message ?? error.localizedDescription]]; if let id {v["id"]=id}; if let sid {v["subscriptionId"]=sid}; if let e, let data=e.data { var d=v["error"] as! [String:Any]; d["data"]=data; v["error"]=d }; if let e, !e.logs.isEmpty {v["logs"]=e.logs}; return v }
actor Output { var closed=false; func write(_ value:[String:Any]) { guard !closed else{return}; print(encode(value)); fflush(stdout) }; func finish(_ id:String?) { guard !closed else{return}; closed=true; var v:[String:Any] = ["type":"closed"]; if let id {v["id"]=id}; print(encode(v)); fflush(stdout) } }

func run(lines: AsyncStream<String>) async {
  let output=Output(); var client: ConvexClient?; var live: LiveClient?; var subscriptions:[String:LiveClient.Subscription]=[:]
  for await line in lines { guard let data=line.data(using:.utf8), let command=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { await output.write(errorEvent(nil, nil, ConvexError(kind:.protocolError,message:"command is not an object",data:nil,logs:[]))); continue }; let id=command["id"] as? String; let op=command["op"] as? String
    do { if op == "hello" { guard command["protocolVersion"] as? Int == 1 else { throw ConvexError(kind:.protocolError,message:"unsupported adapter protocol version",data:nil,logs:[]) }; await output.write(["type":"ready","id":id ?? "hello","protocolVersion":1,"language":"swift","implementation":"native-swift-foundation","runtime":"Swift \(swiftVersion())"]); continue }
      if op == "close" { if let live { await live.close() }; client?.close(); await output.finish(id); return }
      guard let url=ProcessInfo.processInfo.environment["CONVEX_URL"], !url.isEmpty else { throw ConvexError(kind:.transport,message:"CONVEX_URL is required",data:nil,logs:[]) }; if client == nil { client=try ConvexClient(url) }
      if op == "setAuth" { try client!.setAuth(command["token"] as? String ?? ""); await output.write(["type":"ack","id":id ?? ""]) }
      else if ["query","mutation","action"].contains(op ?? "") { let args=command["args"] as? [String:Any] ?? [:]; let path=command["path"] as? String ?? ""; let r:ConvexResult; if op=="query" { r=try await client!.query(path,args) } else if op=="mutation" { r=try await client!.mutation(path,args) } else { r=try await client!.action(path,args) }; var event:[String:Any]=["type":"result","id":id ?? "","value":r.value]; if !r.logs.isEmpty {event["logs"]=r.logs}; await output.write(event) }
      else if op == "subscribe" { let sid=command["subscriptionId"] as? String ?? ""; guard !sid.isEmpty else { throw ConvexError(kind:.protocolError,message:"subscriptionId is required",data:nil,logs:[]) }; if let old=subscriptions.removeValue(forKey:sid) { await live?.unsubscribe(old) }; if live == nil { live=try LiveClient(url) }; let sub=try await live!.subscribe(command["path"] as? String ?? "", command["args"] as? [String:Any] ?? [:]); subscriptions[sid]=sub; await output.write(["type":"ack","id":id ?? ""]); Task { for await update in sub.stream { guard subscriptions[sid] === sub else { break }; if let error=update.error { await output.write(errorEvent(nil,sid,error)) } else { var event:[String:Any]=["type":"subscription","subscriptionId":sid,"value":update.value!]; if !update.logs.isEmpty {event["logs"]=update.logs}; await output.write(event) } } } }
      else if op == "unsubscribe" { let sid=command["subscriptionId"] as? String ?? ""; if let old=subscriptions.removeValue(forKey:sid) { await live?.unsubscribe(old) }; await output.write(["type":"ack","id":id ?? ""]) }
      else if op == "debugDisconnect" { guard let live else { throw ConvexError(kind:.transport,message:"Live WebSocket is not connected",data:nil,logs:[]) }; try await live.debugDisconnectForAdapter(); await output.write(["type":"ack","id":id ?? ""]) }
      else { throw ConvexError(kind:.protocolError,message:"unknown operation: \(op ?? "")",data:nil,logs:[]) }
    } catch { await output.write(errorEvent(id, nil, error)) }
  }
}
func swiftVersion() -> String { "6.1.2" }
func stdinLines() -> AsyncStream<String> { AsyncStream { continuation in Task.detached { while let line=readLine() { continuation.yield(line) }; continuation.finish() } } }
func tcpLines(_ address:String) -> AsyncStream<String> { // The harness sends one controller connection; use POSIX sockets rather than a delegated server runtime.
  AsyncStream { continuation in Task.detached { let pieces=address.split(separator:":",maxSplits:1).map(String.init); guard pieces.count==2, let port=UInt16(pieces[1]) else { continuation.finish(); return }; let fd=socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0); var yes:Int32=1; setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,socklen_t(MemoryLayout<Int32>.size)); var a=sockaddr_in(); a.sin_family=sa_family_t(AF_INET); a.sin_port=port.bigEndian; _="127.0.0.1".withCString { inet_pton(AF_INET,$0,&a.sin_addr) }; withUnsafePointer(to:&a) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }; listen(fd,1); let peer=accept(fd,nil,nil); guard peer >= 0 else { close(fd); continuation.finish(); return }; _ = dup2(peer, STDOUT_FILENO); var buffer=[UInt8](repeating:0,count:4096); var pending=""; while true { let n=read(peer,&buffer,buffer.count); if n <= 0 {break}; pending += String(decoding:buffer[0..<n],as:UTF8.self); while let i=pending.firstIndex(of:"\n") { continuation.yield(String(pending[..<i])); pending=String(pending[pending.index(after:i)...]) } }; close(peer); close(fd); continuation.finish() } }
}
let address=ProcessInfo.processInfo.environment["ADAPTER_LISTEN"]
await run(lines: address.map(tcpLines) ?? stdinLines())
