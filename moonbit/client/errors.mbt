// Structured failure taxonomy for the educational MoonBit Convex client.
//
// Convex separates three very different kinds of failure and a client that
// flattens them into one string makes the difference invisible to callers:
//
//   * FunctionError  - the deployment ran the function and it threw. The
//                      `data` payload is the application's own `ConvexError`
//                      value and callers are expected to branch on it.
//   * ProtocolError  - the peer spoke something this client cannot honour:
//                      an unexpected HTTP status, a malformed envelope, a
//                      Live message that does not match the pinned sync
//                      profile. Retrying the same request will not help.
//   * TransportError - the bytes never made it: DNS, TCP, TLS, timeout, or a
//                      closed WebSocket. A Live subscription recovers from
//                      this by reconnecting.
//
// The adapter and the example both depend on that separation, so it is part of
// the public surface rather than an internal detail.

///|
/// Which of the three Convex failure families a `ConvexError` belongs to.
pub(all) enum ErrorKind {
  FunctionError
  ProtocolError
  TransportError
  ClientClosed
}

///|
/// The wire name for a failure family. The conformance adapter reports this
/// verbatim so the shared controller can assert on it.
pub fn ErrorKind::to_string(self : ErrorKind) -> String {
  match self {
    FunctionError => "FunctionError"
    ProtocolError => "ProtocolError"
    TransportError => "TransportError"
    ClientClosed => "ClientClosed"
  }
}

///|
/// Everything a caller needs to explain a failure: which family it belongs to,
/// a human readable message, the application's structured `errorData` when
/// Convex supplied one, and any log lines the deployment produced before it
/// failed.
pub(all) struct ErrorInfo {
  kind : ErrorKind
  message : String
  data : Json?
  logs : Array[String]
}

///|
/// The single error type raised by every public client operation.
pub(all) suberror ConvexError {
  ConvexError(ErrorInfo)
}

///|
/// Unwrap the structured payload. Callers that only want to print a failure can
/// use `to_string` instead.
pub fn ConvexError::info(self : ConvexError) -> ErrorInfo {
  match self {
    ConvexError(info) => info
  }
}

///|
pub fn ConvexError::to_string(self : ConvexError) -> String {
  let info = self.info()
  info.kind.to_string() + ": " + info.message
}

///|
/// Build a `FunctionError`. `data` carries Convex's `errorData` unchanged so a
/// caller can pattern match on the application's own error shape.
fn function_error(
  message : String,
  data? : Json,
  logs? : Array[String] = [],
) -> ConvexError {
  ConvexError({ kind: FunctionError, message, data, logs })
}

///|
fn protocol_error(message : String) -> ConvexError {
  ConvexError({ kind: ProtocolError, message, data: None, logs: [] })
}

///|
fn transport_error(message : String) -> ConvexError {
  ConvexError({ kind: TransportError, message, data: None, logs: [] })
}

///|
fn closed_error(message : String) -> ConvexError {
  ConvexError({ kind: ClientClosed, message, data: None, logs: [] })
}

///|
/// Convert an arbitrary error raised by the transport libraries into the
/// client's taxonomy. Everything that escapes `@socket`, `@tls`, `@http` or
/// `@websocket` is a transport failure from Convex's point of view; a
/// `ConvexError` that we raised ourselves is passed through untouched so the
/// original family survives a `catch`.
fn as_convex_error(error : Error, context : String) -> ConvexError {
  match error {
    ConvexError(info) => ConvexError(info)
    other => transport_error(context + ": " + "\{other}")
  }
}
