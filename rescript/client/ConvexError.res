// One error type for the whole client. The conformance controller needs to
// tell an application failure apart from a wire failure apart from a transport
// failure, so the kind is part of the value instead of being flattened into a
// message string.

type kind =
  | FunctionError // the Convex function threw, including a structured ConvexError
  | ProtocolError // the server spoke sync in a way this pinned profile cannot follow
  | TransportError // the socket or request failed before a Convex answer existed
  | ClosedError // the caller used a closed client
  | UsageError // the caller passed something this client refuses to send

type t = {
  kind: kind,
  message: string,
  data: option<Js.Json.t>,
  logs: array<string>,
}

exception ConvexFailure(t)

let name = error =>
  switch error.kind {
  | FunctionError => "FunctionError"
  | ProtocolError => "ProtocolError"
  | TransportError => "TransportError"
  | ClosedError => "ClosedError"
  | UsageError => "UsageError"
  }

let make = (kind, message) => {kind, message, data: None, logs: []}

let functionFailure = (message, data, logs) => {
  kind: FunctionError,
  message,
  data,
  logs,
}

let protocol = message => make(ProtocolError, message)
let transport = message => make(TransportError, message)
let closed = () => make(ClosedError, "client is closed")
let usage = message => make(UsageError, message)

let raiseError = error => raise(ConvexFailure(error))

// Anything can reach a `catch` in JavaScript. Convex failures keep their
// structure; a foreign exception becomes a transport failure rather than being
// silently reported as a successful value.
let fromException = (error: exn) =>
  switch error {
  | ConvexFailure(convexError) => convexError
  | Js.Exn.Error(jsError) =>
    switch Js.Exn.message(jsError) {
    | Some(message) => transport(message)
    | None => transport("unknown JavaScript error")
    }
  | _ => transport("unknown error")
  }
