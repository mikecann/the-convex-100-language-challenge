//// The Convex client a Gleam program uses.
////
//// A client owns two things: the documented HTTP API, which is one POST per
//// call, and exactly one Live owner for the reactive `/api/sync` connection.
//// Creating the Live owner here rather than in `subscribe` is deliberate. A
//// client has one query set, so it must not be able to grow a second socket
//// by subscribing twice.

import convex_error.{type ConvexError}
import convex_http.{type Url}
import convex_json.{type Json, JsonObject, JsonString} as json
import convex_live.{type Live, type SubscriptionEvent}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Identifies this client to the deployment. Convex logs it, which makes a
/// hosted verification run traceable back to this language.
const client_header = "gleam-0.1.0"

/// Every HTTP call gets the same generous ceiling. Convex functions in this
/// demonstration return in milliseconds; the bound exists so a stalled network
/// surfaces as a `TransportError` rather than hanging an example forever.
const http_timeout = 30_000

pub opaque type Client {
  Client(origin: String, url: Url, token: Option(String), live: Live)
}

/// Which Convex entry point a call targets.
pub type CallKind {
  Query
  Mutation
  Action
}

/// A successful call: the decoded return value and any log lines the function
/// produced.
pub type CallResult {
  CallResult(value: Json, logs: List(String))
}

/// Connect a client to a deployment URL such as
/// `https://example.convex.cloud`. No socket is opened yet; the Live owner
/// connects the first time something is subscribed.
pub fn new(url: String) -> Result(Client, ConvexError) {
  start(url, None)
}

/// Test-only entry point that installs a relay pause point.
///
/// The deterministic Live tests use it to hold an event after the relay has
/// dequeued it. `new` never supplies a gate, so an ordinary client has no
/// pause point to trip over.
@internal
pub fn new_with_relay_gate(
  url: String,
  gate: convex_live.RelayGate,
) -> Result(Client, ConvexError) {
  start(url, Some(gate))
}

fn start(
  url: String,
  gate: Option(convex_live.RelayGate),
) -> Result(Client, ConvexError) {
  use parsed <- result.try(
    convex_http.parse_url(url)
    |> result.map_error(convex_error.protocol_error),
  )
  use live <- result.try(
    convex_live.start(parsed, True, gate)
    |> result.map_error(convex_error.transport_error),
  )
  Ok(Client(origin: url, url: parsed, token: None, live: live))
}

/// Attach a bearer token to later HTTP calls, or clear it with an empty
/// string. The client value is immutable, so this returns a new client that
/// shares the same Live owner.
pub fn set_auth(client: Client, token: String) -> Result(Client, ConvexError) {
  case
    valid_header_value(token),
    bit_array.byte_size(bit_array.from_string(token)) <= 65_536
  {
    False, _ ->
      Error(convex_error.protocol_error(
        "authentication token contains a line break",
      ))
    _, False ->
      Error(convex_error.protocol_error(
        "authentication token exceeds 65536 bytes",
      ))
    True, True ->
      case token {
        "" -> Ok(Client(..client, token: None))
        token -> Ok(Client(..client, token: Some(token)))
      }
  }
}

/// Call a Convex function over HTTP.
pub fn call(
  client: Client,
  kind: CallKind,
  path: String,
  args: Json,
) -> Result(CallResult, ConvexError) {
  use _ <- result.try(validate_path(path))
  let body =
    bit_array.from_string(
      json.to_string(
        JsonObject([
          #("path", JsonString(path)),
          #("args", args),
          #("format", JsonString("json")),
        ]),
      ),
    )
  case
    convex_http.request(
      client.url,
      "POST",
      "/api/" <> endpoint(kind),
      headers(client),
      body,
      http_timeout,
      True,
    )
  {
    Error(reason) -> Error(convex_error.transport_error(reason))
    Ok(response) -> decode_response(response.status, response.body)
  }
}

fn endpoint(kind: CallKind) -> String {
  case kind {
    Query -> "query"
    Mutation -> "mutation"
    Action -> "action"
  }
}

fn headers(client: Client) -> List(#(String, String)) {
  let base = [
    #("content-type", "application/json"),
    #("accept", "application/json"),
    #("convex-client", client_header),
  ]
  case client.token {
    None -> base
    Some(token) -> [#("authorization", "Bearer " <> token), ..base]
  }
}

/// Decode the Convex response envelope.
///
/// Convex always answers a well-formed call with `status`, so anything else is
/// protocol drift and is reported as such instead of being coerced into a
/// value.
@internal
pub fn decode_response(
  status: Int,
  body: BitArray,
) -> Result(CallResult, ConvexError) {
  case json.parse_bits(body) {
    Error(_) -> Error(invalid_response())
    Ok(envelope) ->
      case json.string_field(envelope, "status"), json.log_lines(envelope) {
        Ok("success"), Ok(logs) ->
          case status >= 200 && status < 300, json.field(envelope, "value") {
            True, Ok(value) -> Ok(CallResult(value: value, logs: logs))
            False, _ ->
              Error(convex_error.protocol_error(
                "non-success HTTP status carried a success envelope",
              ))
            _, Error(_) -> Error(invalid_response())
          }
        Ok("error"), Ok(logs) ->
          case json.string_field(envelope, "errorMessage") {
            Error(_) -> Error(invalid_response())
            Ok(message) ->
              Error(convex_error.function_error(
                message,
                // An absent `errorData` and an explicit null are different
                // Convex outcomes, and the adapter has to preserve both.
                case json.has_field(envelope, "errorData") {
                  True -> option.from_result(json.field(envelope, "errorData"))
                  False -> None
                },
                logs,
              ))
          }
        _, _ -> Error(invalid_response())
      }
  }
}

fn invalid_response() -> ConvexError {
  convex_error.protocol_error("invalid Convex HTTP response")
}

fn valid_header_value(value: String) -> Bool {
  !string.contains(value, "\r") && !string.contains(value, "\n")
}

fn validate_path(path: String) -> Result(Nil, ConvexError) {
  case
    string.split(path, ":"),
    valid_header_value(path),
    bit_array.byte_size(bit_array.from_string(path)) <= 4096
  {
    [module, function], True, True if module != "" && function != "" -> Ok(Nil)
    _, _, _ ->
      Error(convex_error.protocol_error(
        "Convex function path must be module:function within 4096 bytes",
      ))
  }
}

/// Subscribe to a query. Events arrive on `sink` until the subscription is
/// removed, including failures, so a subscriber sees a query error without
/// losing its place.
pub fn subscribe(
  client: Client,
  path: String,
  args: Json,
  sink: Subject(SubscriptionEvent),
) -> Result(String, ConvexError) {
  use _ <- result.try(validate_path(path))
  convex_live.subscribe(client.live, path, args, sink)
  |> result.replace_error(convex_error.transport_error(
    "Live owner did not accept the subscription",
  ))
}

/// Remove a subscription. Once this returns, nothing further can be delivered
/// for it.
pub fn unsubscribe(
  client: Client,
  subscription_id: String,
) -> Result(Nil, ConvexError) {
  convex_live.unsubscribe(client.live, subscription_id)
  |> result.replace_error(convex_error.transport_error(
    "Live owner did not acknowledge the unsubscribe",
  ))
}

/// Release the Live owner, its connection, and every relay.
pub fn close(client: Client) -> Result(Nil, ConvexError) {
  convex_live.close(client.live)
  |> result.replace_error(convex_error.transport_error(
    "Live owner did not acknowledge the close",
  ))
}

/// Adapter-only: force a reconnect. Not part of the educational API.
@internal
pub fn debug_disconnect(client: Client) -> Result(Nil, ConvexError) {
  convex_live.debug_disconnect(client.live)
  |> result.replace_error(convex_error.transport_error(
    "Live owner did not acknowledge the disconnect",
  ))
}

/// The deployment URL this client was built from, used by the adapter when it
/// rebuilds a client after the last subscription goes away.
pub fn origin(client: Client) -> String {
  client.origin
}

/// The bearer token currently attached, if any.
pub fn token(client: Client) -> Option(String) {
  client.token
}
