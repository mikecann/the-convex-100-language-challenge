// The Convex sync protocol as this client pins it.
//
// `/api/sync` is not a documented, versioned public API. This file implements
// the `convex-rs 0.10.4` unversioned profile recorded in `manifest.yaml`, and
// nothing else: an unrecognised envelope is a protocol error that drops the
// connection rather than something to skip past and hope about.
//
// Timestamps deserve a note. They travel as base64 of a little endian 64 bit
// integer, so comparing the base64 text, or comparing the bytes left to right,
// orders them wrongly. `SyncTimestamp.compare` decodes and walks from the most
// significant byte, which is the last one.

primitive SyncTimestamp
  fun initial(): String => "AAAAAAAAAAA="

  fun valid(encoded: String): Bool =>
    try
      Base64Codec.decode(encoded)?.size() == 8
    else
      false
    end

  fun compare(left: String, right: String): I8 ? =>
    let left_bytes = Base64Codec.decode(left)?
    let right_bytes = Base64Codec.decode(right)?
    if (left_bytes.size() != 8) or (right_bytes.size() != 8) then error end
    var index: USize = 8
    while index > 0 do
      index = index - 1
      let a = left_bytes(index)?
      let b = right_bytes(index)?
      if a > b then return 1 end
      if a < b then return -1 end
    end
    0

class val SyncStateVersion
  let query_set: U32
  let identity: U32
  let ts: String

  new val create(query_set': U32, identity': U32, ts': String) =>
    query_set = query_set'
    identity = identity'
    ts = ts'

  new val zero() =>
    query_set = 0
    identity = 0
    ts = SyncTimestamp.initial()

  fun same(other: SyncStateVersion): Bool =>
    (query_set == other.query_set) and (identity == other.identity) and
      (ts == other.ts)

  fun describe(): String =>
    "querySet=" + query_set.string() + " identity=" + identity.string() +
      " ts=" + ts

primitive SyncQueryUpdated
primitive SyncQueryFailed
primitive SyncQueryRemoved

type SyncModificationKind is
  (SyncQueryUpdated | SyncQueryFailed | SyncQueryRemoved)

class val SyncModification
  let kind: SyncModificationKind
  let query_id: U32
  let value: JsonValue
  let has_value: Bool
  let error_message: String
  let error_data: JsonValue
  let has_error_data: Bool
  let logs: Array[String] val

  new val create(
    kind': SyncModificationKind,
    query_id': U32,
    value': JsonValue,
    has_value': Bool,
    error_message': String,
    error_data': JsonValue,
    has_error_data': Bool,
    logs': Array[String] val)
  =>
    kind = kind'
    query_id = query_id'
    value = value'
    has_value = has_value'
    error_message = error_message'
    error_data = error_data'
    has_error_data = has_error_data'
    logs = logs'

class val SyncTransition
  let start_version: SyncStateVersion
  let end_version: SyncStateVersion
  let modifications: Array[SyncModification] val

  new val create(
    start_version': SyncStateVersion,
    end_version': SyncStateVersion,
    modifications': Array[SyncModification] val)
  =>
    start_version = start_version'
    end_version = end_version'
    modifications = modifications'

class val SyncServerError
  """
  `FatalError` or `AuthError`. Both end the connection.
  """

  let kind: String
  let message: String

  new val create(kind': String, message': String) =>
    kind = kind'
    message = message'

primitive SyncPing
primitive SyncUnrelated
  """
  `MutationResponse` and `ActionResponse`. This client sends mutations and
  actions over HTTP, so these can only be replies to something it never sent.
  They are counted as server liveness and otherwise ignored.
  """

type SyncServerMessage is
  (SyncPing | SyncTransition | SyncServerError | SyncUnrelated)

primitive SyncProtocol
  """
  Encoding and decoding of the sync envelopes this client exchanges.
  """

  fun connect_message(
    session_id: String,
    connection_count: U32,
    last_close_reason: String,
    max_observed_timestamp: String)
    : String ?
  =>
    let fields = recover val
      let out = Array[(String, JsonValue)](6)
      out.push(("type", "Connect"))
      out.push(("sessionId", session_id))
      out.push(("connectionCount", JsonNumber.from_i64(connection_count.i64())))
      out.push(("lastCloseReason", last_close_reason))
      if max_observed_timestamp.size() > 0 then
        // Absent on the very first connection. Sending an empty string instead
        // would be a different message, not the same one with a blank field.
        out.push(("maxObservedTimestamp", max_observed_timestamp))
      end
      out.push(("clientTs", JsonNumber.from_i64(0)))
      out
    end
    JsonEncode(JsonObject(fields))?

  fun add_modification(
    query_id: U32,
    path: String,
    args: JsonObject)
    : JsonObject
  =>
    JsonObject(recover val
      let out = Array[(String, JsonValue)](4)
      out.push(("type", "Add"))
      out.push(("queryId", JsonNumber.from_i64(query_id.i64())))
      out.push(("udfPath", path))
      // The protocol carries a positional argument list whose single element
      // is the named argument object.
      out.push(("args", JsonOf.array1(args)))
      out
    end)

  fun remove_modification(query_id: U32): JsonObject =>
    JsonOf.obj2(
      "type", "Remove", "queryId", JsonNumber.from_i64(query_id.i64()))

  fun modify_query_set(
    base_version: U32,
    new_version: U32,
    modifications: Array[JsonValue] val)
    : String ?
  =>
    JsonEncode(JsonObject(recover val
      let out = Array[(String, JsonValue)](4)
      out.push(("type", "ModifyQuerySet"))
      out.push(("baseVersion", JsonNumber.from_i64(base_version.i64())))
      out.push(("newVersion", JsonNumber.from_i64(new_version.i64())))
      out.push(("modifications", JsonArray(modifications)))
      out
    end))?

  fun decode(text: String): SyncServerMessage ? =>
    let envelope = JsonDecode.parse_object(text)?
    let kind = envelope.string_field("type")?
    if kind == "Transition" then
      SyncProtocol._decode_transition(envelope)?
    elseif kind == "Ping" then
      SyncPing
    elseif (kind == "MutationResponse") or (kind == "ActionResponse") then
      SyncUnrelated
    elseif (kind == "FatalError") or (kind == "AuthError") then
      SyncServerError(kind, SyncProtocol._error_text(envelope))
    else
      // `TransitionChunk` lands here. Assembling chunked transitions is
      // deferred, and pretending to understand one would corrupt the query
      // set version, so it fails the connection instead.
      error
    end

  fun _error_text(envelope: JsonObject): String =>
    try envelope.string_field("error")? else "unspecified server error" end

  fun _decode_transition(envelope: JsonObject): SyncTransition ? =>
    let start_version = SyncProtocol._decode_version(
      envelope.object_field("startVersion")?)?
    let end_version = SyncProtocol._decode_version(
      envelope.object_field("endVersion")?)?
    let raw = envelope.array_field("modifications")?
    var out: Array[SyncModification] iso = Array[SyncModification](raw.size())
    var index: USize = 0
    while index < raw.size() do
      let entry =
        match raw(index)?
        | let fields: JsonObject => fields
        else
          error
        end
      out.push(SyncProtocol._decode_modification(entry)?)
      index = index + 1
    end
    SyncTransition(start_version, end_version, consume out)

  fun _decode_version(fields: JsonObject): SyncStateVersion ? =>
    let ts = fields.string_field("ts")?
    if not SyncTimestamp.valid(ts) then error end
    SyncStateVersion(
      fields.u32_field("querySet")?, fields.u32_field("identity")?, ts)

  fun _decode_modification(fields: JsonObject): SyncModification ? =>
    let query_id = fields.u32_field("queryId")?
    let logs = fields.string_list("logLines")?
    let kind = fields.string_field("type")?
    if kind == "QueryUpdated" then
      // A successful update always carries a value, even when that value is
      // JSON null, so an absent field is a protocol error rather than null.
      if not fields.contains("value") then error end
      SyncModification(
        SyncQueryUpdated,
        query_id,
        fields("value")?,
        true,
        "",
        None,
        false,
        logs)
    elseif kind == "QueryFailed" then
      let has_error_data = fields.contains("errorData")
      let error_data = if has_error_data then fields("errorData")? else None end
      let message =
        try fields.string_field("errorMessage")? else "query failed" end
      SyncModification(
        SyncQueryFailed,
        query_id,
        None,
        false,
        message,
        error_data,
        has_error_data,
        logs)
    elseif kind == "QueryRemoved" then
      SyncModification(
        SyncQueryRemoved, query_id, None, false, "", None, false, logs)
    else
      error
    end
