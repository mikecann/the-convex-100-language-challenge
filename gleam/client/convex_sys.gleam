//// Typed access to the small OTP surface the client needs.
////
//// The Erlang side lives in `convex_ffi.erl` and contains no Convex logic. It
//// is kept deliberately narrow: sockets, TLS, the two crypto primitives the
//// WebSocket handshake requires, a monotonic clock, the standard streams, and
//// a way to retire a worker and know it is gone.

import gleam/erlang/process.{type Pid}

/// An open socket. Plain TCP and TLS sockets are different OTP types, so the
/// FFI keeps the transport tag alongside the handle and this stays opaque.
pub type Socket

/// Which transport to open. TLS is used for every hosted deployment; plain TCP
/// exists for the local self-hosted backend and the test fixture servers.
pub type Transport {
  Tcp
  Tls
}

/// One read attempt. A timeout is distinct from a close because the caller may
/// be part-way through a WebSocket frame and must decide whether to keep the
/// parser state or abandon the connection.
pub type RecvResult {
  Received(bytes: BitArray)
  RecvTimeout
  RecvClosed
  RecvFailed(reason: String)
}

/// One read attempt on standard input.
pub type ReadResult {
  ReadChunk(bytes: BitArray)
  ReadEnd
  ReadFailed(reason: String)
}

pub type LineSplit {
  LineFound(line: BitArray, rest: BitArray)
  NoLine
}

pub type JsonStringScan {
  StringQuote(chunk: BitArray, rest: BitArray)
  StringEscape(chunk: BitArray, rest: BitArray)
  StringControl(chunk: BitArray, byte: Int, rest: BitArray)
  StringEnd(chunk: BitArray)
}

@external(erlang, "convex_ffi", "connect")
pub fn connect(
  transport: Transport,
  host: String,
  port: Int,
  timeout: Int,
  verify_peer: Bool,
) -> Result(Socket, String)

@external(erlang, "convex_ffi", "socket_send")
pub fn send(socket: Socket, data: BitArray, timeout: Int) -> Result(Nil, String)

/// Read up to `length` bytes, or whatever has arrived when `length` is 0.
@external(erlang, "convex_ffi", "socket_recv")
pub fn recv(socket: Socket, length: Int, timeout: Int) -> RecvResult

@external(erlang, "convex_ffi", "socket_close")
pub fn close(socket: Socket) -> Nil

/// Listen on the requested numeric address. Port 0 asks the kernel to choose,
/// which keeps the fixture servers in the language-local tests from colliding.
@external(erlang, "convex_ffi", "listen")
pub fn listen(host: String, port: Int) -> Result(Socket, String)

@external(erlang, "convex_ffi", "listen_port")
pub fn listen_port(socket: Socket) -> Result(Int, String)

@external(erlang, "convex_ffi", "accept")
pub fn accept(socket: Socket, timeout: Int) -> Result(Socket, String)

@external(erlang, "convex_ffi", "sha1")
pub fn sha1(data: BitArray) -> BitArray

@external(erlang, "convex_ffi", "base64_encode")
pub fn base64_encode(data: BitArray) -> String

@external(erlang, "convex_ffi", "base64_decode")
pub fn base64_decode(text: String) -> Result(BitArray, Nil)

@external(erlang, "convex_ffi", "random_bytes")
pub fn random_bytes(count: Int) -> BitArray

/// XOR a byte string with a repeating key. Gleam owns the WebSocket masking
/// rules; this generic primitive avoids repeatedly copying an immutable binary
/// once for every byte of a large frame.
@external(erlang, "convex_ffi", "xor_repeating")
pub fn xor_repeating(data: BitArray, key: BitArray) -> BitArray

/// Join already-bounded byte chunks once. OTP can flatten an iolist without
/// repeatedly copying a growing accumulator.
@external(erlang, "convex_ffi", "concat_binaries")
pub fn concat_binaries(chunks: List(BitArray)) -> BitArray

@external(erlang, "convex_ffi", "split_newline")
pub fn split_newline(data: BitArray) -> LineSplit

/// Find a byte sequence without copying the prefix before it.
@external(erlang, "convex_ffi", "find_sequence")
pub fn find_sequence(data: BitArray, sequence: BitArray) -> Result(Int, Nil)

@external(erlang, "convex_ffi", "scan_json_string")
pub fn scan_json_string(data: BitArray) -> JsonStringScan

/// Milliseconds from an arbitrary origin that never moves backwards. Backoff
/// and deadlines are computed from this rather than from wall-clock time.
@external(erlang, "convex_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

@external(erlang, "convex_ffi", "stdin_read")
pub fn stdin_read(count: Int) -> ReadResult

@external(erlang, "convex_ffi", "stdout_write")
pub fn stdout_write(data: BitArray) -> Result(Nil, String)

/// Diagnostics go to standard error so that standard output stays a clean
/// protocol or transcript surface.
@external(erlang, "convex_ffi", "stderr_write")
pub fn stderr_write(text: String) -> Nil

@external(erlang, "convex_ffi", "otp_release")
pub fn otp_release() -> String

@external(erlang, "convex_ffi", "plain_arguments")
pub fn plain_arguments() -> List(String)

@external(erlang, "convex_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

/// Kill a worker and wait for its death certificate. This is a barrier: once
/// it returns, the worker cannot deliver anything else.
@external(erlang, "convex_ffi", "kill_and_wait")
pub fn kill_and_wait(pid: Pid, timeout: Int) -> Result(Nil, Nil)

/// Read an environment variable, falling back to a default.
pub fn env(name: String, default: String) -> String {
  case getenv(name) {
    Ok(value) -> value
    Error(_) -> default
  }
}
