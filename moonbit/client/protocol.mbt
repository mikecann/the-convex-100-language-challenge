// The Convex sync protocol as this client speaks it.
//
// The sync protocol is not a published, versioned API, so `manifest.yaml` pins
// the exact upstream revision this encoding was read from. Everything here is
// deliberately strict: an unrecognised message or a version that does not chain
// onto the local one is treated as drift and reported as a `ProtocolError`
// rather than being skipped, because skipping a transition silently desyncs
// every subscription on the socket.

///|
/// The initial `ts` a client reports before it has seen any transition. Convex
/// expects a base64 encoded zero timestamp here.
const INITIAL_TIMESTAMP : String = "AAAAAAAAAAA="

///|
/// Length of the text Convex uses for a sync timestamp: eight bytes of unsigned
/// database time in base64, so eleven encoding characters and one pad.
const TIMESTAMP_TEXT_LENGTH : Int = 12

///|
/// True when `text` is exactly the encoding Convex uses for a sync timestamp.
///
/// The value is opaque to this client - it never orders, subtracts, or decodes
/// one - but its encoding is not. A timestamp taken from a `Transition` becomes
/// `maxObservedTimestamp` on the next `Connect`, so it is handed straight back
/// to the deployment. Accepting an arbitrary string would let a drifting or
/// hostile peer choose what this client says about itself on a later connection,
/// and would let a truncated `ts` pass for a real one and silently anchor the
/// version chain to a value that means nothing.
///
/// Because the value is never interpreted, this is a check on the encoding
/// alone: it proves the shape, not that the instant it names is plausible.
fn is_sync_timestamp(text : String) -> Bool {
  guard text.length() == TIMESTAMP_TEXT_LENGTH else { return false }
  // Eight bytes is not a multiple of three, so the standard alphabet always
  // leaves exactly one pad character.
  guard text.unsafe_char_at(TIMESTAMP_TEXT_LENGTH - 1) == '=' else {
    return false
  }
  for index = 0; index < TIMESTAMP_TEXT_LENGTH - 1; index = index + 1 {
    let character = text.unsafe_char_at(index)
    let encoding = (character >= 'A' && character <= 'Z') ||
      (character >= 'a' && character <= 'z') ||
      (character >= '0' && character <= '9') ||
      character == '+' ||
      character == '/'
    if !encoding {
      return false
    }
  }
  true
}

///|
/// One point in the server's version chain. `querySet` counts query-set edits,
/// `identity` counts auth changes, and `ts` is the database timestamp the
/// values were read at.
pub(all) struct StateVersion {
  query_set : Int64
  identity : Int64
  ts : String
}

///|
/// A single per-query change inside a `Transition`.
pub(all) enum Modification {
  QueryUpdated(Int64, Json, Array[String])
  QueryFailed(Int64, String, Json?, Array[String])
  QueryRemoved(Int64)
}

///|
/// A decoded server message. Only the messages this client acts on get their
/// own case; the rest are classified so the Live worker can decide between
/// ignoring them and treating them as drift.
pub(all) enum ServerMessage {
  Transition(StateVersion, StateVersion, Array[Modification])
  Ping
  /// A response to a WebSocket mutation or action. This client only issues
  /// queries over the socket, so these are accepted and ignored rather than
  /// treated as drift: a well behaved server may still send them after a
  /// reconnect races with an in-flight request.
  Ignored
  /// Anything else, including `AuthError` and `FatalError`. The payload is the
  /// message this client will report.
  Fatal(String)
}

///|
/// Build the `Connect` message that opens a Live session.
///
/// `connectionCount` and `lastCloseReason` tell the server how many times this
/// client has reconnected and why the previous socket went away, and
/// `maxObservedTimestamp` lets it avoid replaying values older than ones this
/// client has already seen. Getting these wrong does not fail loudly - it just
/// makes reconnects deliver stale data - so they are carried explicitly.
fn connect_message(
  session_id : String,
  connection_count : Int,
  last_close_reason : String,
  max_observed_timestamp : String?,
) -> Json {
  let fields : Array[(String, Json)] = [
    ("type", Json::string("Connect")),
    ("sessionId", Json::string(session_id)),
    ("connectionCount", Json::number(connection_count.to_double())),
    ("lastCloseReason", Json::string(last_close_reason)),
    ("clientTs", Json::number(0.0)),
  ]
  match max_observed_timestamp {
    Some(timestamp) =>
      fields.push(("maxObservedTimestamp", Json::string(timestamp)))
    None => ()
  }
  json_object(fields)
}

///|
/// Build a `ModifyQuerySet` message.
///
/// `baseVersion` must be the query-set version the server last acknowledged and
/// `newVersion` must be exactly one higher. The server rejects the whole socket
/// if that chain breaks, which is why only the Live worker is allowed to bump
/// the counter.
fn modify_query_set_message(
  base_version : Int,
  modifications : Array[Json],
) -> Json {
  json_object([
    ("type", Json::string("ModifyQuerySet")),
    ("baseVersion", Json::number(base_version.to_double())),
    ("newVersion", Json::number((base_version + 1).to_double())),
    ("modifications", Json::array(modifications)),
  ])
}

///|
/// An `Add` modification. Convex takes the query arguments as a single element
/// array, which is the shape the sync protocol uses for positional UDF args.
fn add_modification(query_id : Int, path : String, args : Json) -> Json {
  json_object([
    ("type", Json::string("Add")),
    ("queryId", Json::number(query_id.to_double())),
    ("udfPath", Json::string(path)),
    ("args", Json::array([args])),
  ])
}

///|
fn remove_modification(query_id : Int) -> Json {
  json_object([
    ("type", Json::string("Remove")),
    ("queryId", Json::number(query_id.to_double())),
  ])
}

///|
fn parse_state_version(
  message : Json,
  key : String,
) -> StateVersion raise ConvexError {
  let version = required_field(message, key, "Transition")
  guard version is Object(_) else {
    raise protocol_error("Transition " + key + " was not an object")
  }
  let query_set = expect_counter(
    required_field(version, "querySet", "Transition " + key),
    "Transition " + key + " querySet",
  )
  let identity = expect_counter(
    required_field(version, "identity", "Transition " + key),
    "Transition " + key + " identity",
  )
  let ts = expect_string(
    required_field(version, "ts", "Transition " + key),
    "Transition " + key + " ts",
  )
  guard is_sync_timestamp(ts) else {
    raise protocol_error(
      "Transition " + key + " ts was not a Convex sync timestamp",
    )
  }
  { query_set, identity, ts }
}

///|
/// Validate and decode one `Transition` modification.
///
/// Every field is checked here, before the caller applies any of them, so that
/// a transition containing one malformed entry cannot leave half of its changes
/// applied to the subscription state.
fn parse_modification(entry : Json) -> Modification raise ConvexError {
  guard entry is Object(_) else {
    raise protocol_error("Transition modification was not an object")
  }
  let kind = expect_string(
    required_field(entry, "type", "Transition modification"),
    "Transition modification type",
  )
  let query_id = expect_counter(
    required_field(entry, "queryId", "Transition modification"),
    "Transition modification queryId",
  )
  let logs = log_lines(json_field(entry, "logLines"))
  match kind {
    "QueryUpdated" => {
      guard json_has_field(entry, "value") else {
        raise protocol_error("QueryUpdated omitted its value member")
      }
      QueryUpdated(
        query_id,
        required_field(entry, "value", "QueryUpdated"),
        logs,
      )
    }
    "QueryFailed" => {
      let message = expect_string(
        required_field(entry, "errorMessage", "QueryFailed"),
        "QueryFailed errorMessage",
      )
      let data = json_field(entry, "errorData")
      QueryFailed(query_id, message, data, logs)
    }
    "QueryRemoved" => QueryRemoved(query_id)
    other =>
      raise protocol_error("unknown Transition modification type " + other)
  }
}

///|
/// Decode one server message.
///
/// `MutationResponse` and `ActionResponse` are accepted and ignored. Every
/// other unknown type becomes `Fatal`, carrying the server's own `error` text
/// when it supplied one, so the Live worker can surface a useful reason instead
/// of a bare "unexpected message".
fn parse_server_message(message : Json) -> ServerMessage raise ConvexError {
  guard message is Object(_) else {
    raise protocol_error("Live server message was not a JSON object")
  }
  let kind = match json_field(message, "type") {
    Some(String(kind)) => kind
    _ => raise protocol_error("Live server message omitted a string type")
  }
  match kind {
    "Transition" => {
      let start = parse_state_version(message, "startVersion")
      let end = parse_state_version(message, "endVersion")
      let entries = expect_array(
        required_field(message, "modifications", "Transition"),
        "Transition modifications",
      )
      let modifications : Array[Modification] = []
      for entry in entries {
        modifications.push(parse_modification(entry))
      }
      Transition(start, end, modifications)
    }
    "Ping" => Ping
    "MutationResponse" => Ignored
    "ActionResponse" => Ignored
    other => {
      let detail = match json_field(message, "error") {
        Some(String(text)) => ": " + text
        Some(value) => ": " + value.stringify()
        None => ""
      }
      Fatal("Live server sent " + other + detail)
    }
  }
}

///|
/// Format 16 random bytes as an RFC 4122 version 4 UUID.
///
/// Convex uses the session id to correlate reconnects from the same client.
/// It is not a security boundary, but reusing one across processes would make
/// two clients look like one reconnecting client, so it is generated per
/// `LiveManager` from the platform entropy source.
fn format_session_id(raw : Bytes) -> String {
  let mut out = ""
  for index = 0; index < 16; index = index + 1 {
    if index == 4 || index == 6 || index == 8 || index == 10 {
      out = out + "-"
    }
    let mut byte = raw[index].to_int()
    // Stamp the version (4) and variant (10xx) bits the standard requires.
    if index == 6 {
      byte = (byte & 0x0f) | 0x40
    }
    if index == 8 {
      byte = (byte & 0x3f) | 0x80
    }
    out = out + hex_digit((byte >> 4) & 0x0f) + hex_digit(byte & 0x0f)
  }
  out
}

///|
/// One lowercase hexadecimal digit for a nibble in `0..=15`.
fn hex_digit(nibble : Int) -> String {
  "0123456789abcdef".substring(start=nibble, end=nibble + 1)
}
