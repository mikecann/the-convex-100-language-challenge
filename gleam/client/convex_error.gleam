//// The three failures a Convex caller has to tell apart.
////
//// Flattening these into one string would make an application error look like
//// a network blip, so the client keeps the distinction all the way out to the
//// caller and to the conformance adapter.

import convex_json.{type Json, JsonArray, JsonObject, JsonString}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type ConvexError {
  ConvexError(
    /// `FunctionError`, `ProtocolError`, or `TransportError`.
    name: String,
    message: String,
    /// The `errorData` a Convex function threw. Convex distinguishes an absent
    /// field from an explicit JSON null, so this is `Some(JsonNull)` for the
    /// latter and `None` for the former.
    data: Option(Json),
    logs: List(String),
  )
}

/// A Convex function raised an application error. The function ran; the
/// deployment and the transport are healthy.
pub fn function_error(
  message: String,
  data: Option(Json),
  logs: List(String),
) -> ConvexError {
  ConvexError(name: "FunctionError", message: message, data: data, logs: logs)
}

/// The peer said something this client cannot reconcile with the pinned sync
/// profile. Treated as drift rather than as an application failure.
pub fn protocol_error(message: String) -> ConvexError {
  ConvexError(name: "ProtocolError", message: message, data: None, logs: [])
}

/// The connection failed. The request may or may not have been applied, which
/// is why Convex mutations in the example carry an idempotency key.
pub fn transport_error(message: String) -> ConvexError {
  ConvexError(name: "TransportError", message: message, data: None, logs: [])
}

/// Render for the NDJSON adapter. Optional members are omitted rather than
/// serialised as null, because the shared schema validates event shapes
/// strictly.
pub fn to_json(error: ConvexError) -> Json {
  let base = [
    #("name", JsonString(error.name)),
    #("message", JsonString(error.message)),
  ]
  let with_data = case error.data {
    Some(data) -> list.append(base, [#("data", data)])
    None -> base
  }
  case error.logs {
    [] -> JsonObject(with_data)
    logs ->
      JsonObject(
        list.append(with_data, [
          #("logs", JsonArray(list.map(logs, JsonString))),
        ]),
      )
  }
}
