import AdapterCore
import Foundation

let environment = ProcessInfo.processInfo.environment
do {
  let connection: LineConnection
  if let listen = environment["ADAPTER_LISTEN"], !listen.isEmpty {
    connection = try acceptConnection(at: ListenAddress(listen))
  } else {
    connection = LineConnection(input: 0, output: 1, ownsDescriptors: false)
  }
  await runAdapter(connection: connection, deploymentURL: environment["CONVEX_URL"])
} catch {
  FileHandle.standardError.write(Data("swift adapter startup failed: \(error)\n".utf8))
  exit(2)
}
