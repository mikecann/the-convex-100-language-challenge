// Stopped-reader memory proof for the real adapter binary.
//
// An event-count bound is not a memory bound: one Convex value can be close to
// the maximum protocol message size, so a queue of sixteen "events" can still
// be tens of megabytes. This program proves the real
// `/usr/local/bin/convex-adapter` stays far below the shared 128 MiB container
// limit while a controller stops reading and near-maximum values keep arriving.
//
// It is a peer, not a harness. It plays two roles and nothing else:
//
//   * a fake Convex deployment whose every function call returns a value just
//     under the client's HTTP response limit, and
//   * a controller that issues a burst of calls and then stops reading, so the
//     adapter's writer has nowhere to put its output.
//
// The Dockerfile launches the adapter, runs this peer against it, and samples
// `/proc/<pid>/status` for the peak resident set. Measuring from the shell
// keeps the measurement independent of the process being measured.
//
// This is test-only infrastructure and is never installed into a runtime image.

///|
/// Size of the value each fake function call returns. Chosen to sit just under
/// the client's two megabyte HTTP response limit so every reply is a
/// near-maximum message rather than a token one.
const NEAR_MAX_VALUE_BYTES : Int = 2000000

///|
/// How many calls the controller issues before it stops reading.
const BURST_COMMANDS : Int = 64

///|
/// Serve the fake Convex deployment.
async fn serve_backend(port : Int, payload : String) -> Unit {
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:" + port.to_string()),
    reuse_addr=true,
  )
  server.run_forever(
    (_request, _body, connection) => {
      connection.skip_request_body()
      connection.send_response(200, "OK")
      connection.write_string(payload)
      connection.end_response()
    },
    allow_failure=true,
  )
}

///|
/// Issue a burst of calls, stop reading for `hold_ms`, then drain and close.
async fn drive_adapter(address : String, hold_ms : Int) -> Unit {
  let adapter = @socket.Tcp::connect(@socket.Addr::parse(address))
  defer adapter.close()
  adapter.write(
    @utf8.encode("{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"),
  )
  // Read the ready event so the burst below starts from a known state.
  adapter.read_until("\n") |> ignore
  let burst = @buffer.Buffer(size_hint=BURST_COMMANDS * 96)
  for index = 0; index < BURST_COMMANDS; index = index + 1 {
    burst.write_bytes(
      @utf8.encode(
        "{\"id\":\"call-" +
        index.to_string() +
        "\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{\"room\":\"stress\"}}\n",
      )[:],
    )
  }
  adapter.write(burst.to_bytes())
  // Stop reading. Every reply is a near-maximum value, so the adapter's writer
  // fills its budget and then blocks instead of growing. The Dockerfile samples
  // the adapter's resident set during this window.
  @async.sleep(hold_ms)
  // Drain whatever the adapter managed to queue, then close cleanly so the
  // Dockerfile can also assert a zero exit status.
  @async.with_timeout_opt(20000, () => {
    for index = 0; index < BURST_COMMANDS; index = index + 1 {
      adapter.read_until("\n") |> ignore
    }
  })
  |> ignore
  adapter.write(@utf8.encode("{\"id\":\"close\",\"op\":\"close\"}\n"))
  @async.with_timeout_opt(10000, () => {
    for ;; {
      guard adapter.read_until("\n") is Some(line) else { break }
      if line.contains("\"closed\"") {
        break
      }
    }
  })
  |> ignore
}

///|
async fn main {
  let arguments = @env.args()
  guard arguments.length() >= 4 else {
    @stdio.stderr.write(
      "usage: convex-stress-peer <backend-port> <adapter-address> <hold-ms>\n",
    ) catch {
      _ => ()
    }
    panic()
  }
  let backend_port = @string.parse_int(arguments[1])
  let adapter_address = arguments[2]
  let hold_ms = @string.parse_int(arguments[3])
  let payload = "{\"status\":\"success\",\"value\":\"" +
    "x".repeat(NEAR_MAX_VALUE_BYTES) +
    "\",\"logLines\":[]}"
  @async.with_task_group(group => {
    group.spawn_bg(
      () => serve_backend(backend_port, payload),
      no_wait=true,
      allow_failure=true,
    )
    drive_adapter(adapter_address, hold_ms)
  })
}
