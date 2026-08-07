use "collections"
use "../../../../client"

// The NDJSON command loop.
//
// Validation is strict on purpose. A controller that sends a malformed or
// unknown command gets a structured error event, never a guess: an unknown
// field, a missing identifier, an oversized line, and a wrong protocol version
// are all refusals. The shared controller only ever sends well formed
// commands, so anything else means something is wrong and hiding it would make
// the conformance result meaningless.

primitive AdapterLimits
  fun max_line_bytes(): USize => 2 * 1024 * 1024
  fun max_id_characters(): USize => 128

interface tag AdapterExit
  """
  Told once the adapter has finished, so the program can release stdin or the
  controller socket and exit with a definite status.
  """
  be adapter_finished(code: I32)

class val AdapterCommand
  let id: String
  let op: String
  let path: String
  let args: JsonObject
  let subscription_id: String
  let token: String

  new val create(
    id': String,
    op': String,
    path': String,
    args': JsonObject,
    subscription_id': String,
    token': String)
  =>
    id = id'
    op = op'
    path = path'
    args = args'
    subscription_id = subscription_id'
    token = token'

primitive AdapterCommandParser
  """
  Parses one NDJSON line into a command, or into the reason it was refused.
  """

  fun parse(line: String): (AdapterCommand | (String, String)) =>
    """
    On failure, returns `(id, reason)` rather than a bare reason, so a
    command that names itself but fails later validation - an unknown
    operation, an unexpected field, a wrong protocol version - still gets
    its `id` echoed back on the error event instead of being silently
    dropped.
    """
    let fields =
      try
        JsonDecode.parse_object(line)?
      else
        return ("", "adapter command must be a JSON object")
      end

    let op = try fields.string_field("op")? else
      return ("", "adapter command op must be a string")
    end
    let id = try fields.string_field("id")? else "" end
    let id_characters = try Utf8.scalar_count(id)? else
      return ("", "adapter command id must be valid UTF-8")
    end
    if (id_characters == 0) or
      (id_characters > AdapterLimits.max_id_characters())
    then
      return (id, "adapter command id must be 1 to " +
        AdapterLimits.max_id_characters().string() + " characters")
    end

    for entry in fields.entries.values() do
      if not AdapterCommandParser._allowed(op, entry._1) then
        return (id, "adapter command has an unexpected field: " + entry._1)
      end
    end

    if op == "hello" then
      let version =
        try
          match fields("protocolVersion")?
          | let number: JsonNumber => number.integral()?
          else
            error
          end
        else
          return (id, "hello requires a numeric protocolVersion")
        end
      if version != AdapterEvents.protocol_version() then
        return (id, "unsupported adapter protocol version " + version.string())
      end
      return AdapterCommand(id, op, "", JsonOf.empty(), "", "")
    end

    if (op == "query") or (op == "mutation") or (op == "action") then
      let path = try fields.string_field("path")? else
        return (id, op + " requires a path string")
      end
      if path.size() < 3 then return (id, op + " path is too short") end
      let args = try fields.object_field("args")? else
        return (id, op + " requires an args object")
      end
      return AdapterCommand(id, op, path, args, "", "")
    end

    if (op == "subscribe") or (op == "unsubscribe") then
      let subscription_id = try fields.string_field("subscriptionId")? else
        return (id, op + " requires a subscriptionId string")
      end
      let subscription_characters =
        try Utf8.scalar_count(subscription_id)? else
          return (id, "subscriptionId must be valid UTF-8")
        end
      if (subscription_characters == 0) or
        (subscription_characters > AdapterLimits.max_id_characters())
      then
        return (id, "subscriptionId must be 1 to " +
          AdapterLimits.max_id_characters().string() + " characters")
      end
      var path = ""
      var args = JsonOf.empty()
      if op == "subscribe" then
        path = try fields.string_field("path")? else
          return (id, "subscribe requires a path string")
        end
        if path.size() < 3 then return (id, "subscribe path is too short") end
        args = try fields.object_field("args")? else
          return (id, "subscribe requires an args object")
        end
      end
      return AdapterCommand(id, op, path, args, subscription_id, "")
    end

    if op == "setAuth" then
      let token = try fields.string_field("token")? else
        return (id, "setAuth requires a token string")
      end
      return AdapterCommand(id, op, "", JsonOf.empty(), "", token)
    end

    if (op == "close") or (op == "debugDisconnect") then
      return AdapterCommand(id, op, "", JsonOf.empty(), "", "")
    end

    (id, "unknown operation " + op)

  fun _allowed(op: String, field: String): Bool =>
    if (field == "id") or (field == "op") then return true end
    if op == "hello" then return field == "protocolVersion" end
    if (op == "query") or (op == "mutation") or (op == "action") then
      return (field == "path") or (field == "args")
    end
    if (op == "subscribe") or (op == "unsubscribe") then
      return (field == "subscriptionId") or (field == "path") or
        (field == "args")
    end
    if op == "setAuth" then return field == "token" end
    false

class AdapterLineBuffer
  """
  Splits the incoming byte stream into NDJSON lines with a hard length bound.

  An over-long line is reported once and then skipped to the next terminator,
  so a controller that sends garbage cannot make the adapter buffer without
  limit and cannot silently desynchronise the stream either.
  """

  let _buffer: Array[U8] = Array[U8]
  var _skipping: Bool = false

  fun ref push(data: Array[U8] val): Array[(Bool, String)] val =>
    var out: Array[(Bool, String)] iso = Array[(Bool, String)](4)
    var index: USize = 0
    while index < data.size() do
      let byte = try data(index)? else 0 end
      index = index + 1
      if byte == '\n' then
        if _skipping then
          _skipping = false
          out.push((false, ""))
        else
          var line = Bytes.to_string(Bytes.freeze(_buffer, 0, _buffer.size()))
          if (line.size() > 0) and
            (try line(line.size() - 1)? == '\r' else false end)
          then
            line = HttpText.slice(line, 0, line.size() - 1)
          end
          if line.size() > 0 then out.push((true, line)) end
        end
        _buffer.clear()
      elseif not _skipping then
        _buffer.push(byte)
        if _buffer.size() > AdapterLimits.max_line_bytes() then
          _buffer.clear()
          _skipping = true
        end
      end
    end
    consume out

actor AdapterRunner
  """
  Owns the command loop, the client, and the relay bookkeeping.
  """

  let _output: AdapterOutput
  let _exit: AdapterExit
  let _config: (ConvexConfig | None)
  let _opener: StreamOpener
  let _ticker: Ticker
  let _runtime: String
  var _client: (ConvexClient | None) = None
  let _relays: Map[String, U64] = Map[String, U64]
  var _next_generation: U64 = 0
  var _stopped: Bool = false

  new create(
    output: AdapterOutput,
    exit': AdapterExit,
    config: (ConvexConfig | None),
    opener: StreamOpener,
    ticker: Ticker,
    runtime: String)
  =>
    _output = output
    _exit = exit'
    _config = config
    _opener = opener
    _ticker = ticker
    _runtime = runtime

  be line(text: String) =>
    if _stopped then return end
    match AdapterCommandParser.parse(text)
    | let command: AdapterCommand => _dispatch(command)
    | (let id: String, let reason: String) =>
      _emit_failure(id, ConvexError.protocol(reason))
    end

  be malformed_line() =>
    if _stopped then return end
    _emit_failure("", ConvexError.protocol(
      "adapter command line exceeded " +
        AdapterLimits.max_line_bytes().string() + " bytes"))

  be input_closed() =>
    """
    The controller went away without sending `close`. Finishing with a failing
    status keeps that visibly different from a clean shutdown.
    """
    if _stopped then return end
    _stopped = true
    _output.stop()
    _exit.adapter_finished(1)

  be close_quietly(id: String) =>
    """
    A `close` the transport has already acknowledged directly on the
    connection, synchronously, ahead of this message: everything below is
    the same cleanup the ordinary `close` path does, minus emitting
    `closed` a second time. The transport only takes this path when it
    knows no client exists yet, but the check against `_client` here is
    kept anyway - it is the one thing that determines whether a real
    connection to a deployment still needs to be closed.
    """
    if _stopped then return end
    _stopped = true
    for subscription_id in _relay_ids().values() do
      _retire(subscription_id)
    end
    match _client
    | let existing: ConvexClient => existing.close("c|" + id, this)
    | None =>
      _output.finish()
      _exit.adapter_finished(0)
    end

  be convex_ok(step: String, result: ConvexResult) =>
    (let kind, let id) = _split_step(step)
    if kind == "r" then
      try
        _output.emit(AdapterEvents.result(id, result.value, result.logs)?)
      else
        _emit_failure(id, ConvexError.protocol(
          "the Convex result could not be encoded for the adapter stream"))
      end
    elseif kind == "a" then
      try _output.emit(AdapterEvents.ack(id)?) end
    elseif kind == "c" then
      _stopped = true
      try _output.emit(AdapterEvents.closed(id)?) end
      _output.finish()
      _exit.adapter_finished(0)
    end

  be convex_failed(step: String, error': ConvexError) =>
    (let kind, let id) = _split_step(step)
    if kind == "c" then
      // A failure while closing is still a shutdown; the controller expects a
      // terminal event either way.
      _stopped = true
      try _output.emit(AdapterEvents.closed(id)?) end
      _output.finish()
      _exit.adapter_finished(0)
      return
    end
    _emit_failure(id, error')

  fun ref _dispatch(command: AdapterCommand) =>
    if command.op == "hello" then
      try
        _output.emit(AdapterEvents.ready(
          command.id, "pony", "native-pony-0.1.0", _runtime)?)
      end
      return
    end

    if command.op == "close" then
      // Closing never requires a deployment: a controller that never sent
      // anything but `hello` and `close` still gets a clean shutdown rather
      // than a `CONVEX_URL is required` refusal for a connection it never
      // asked this adapter to open.
      for subscription_id in _relay_ids().values() do
        _retire(subscription_id)
      end
      match _client
      | let existing: ConvexClient => existing.close("c|" + command.id, this)
      | None =>
        _stopped = true
        try _output.emit(AdapterEvents.closed(command.id)?) end
        _output.finish()
        _exit.adapter_finished(0)
      end
      return
    end

    let client =
      match _ensure_client()
      | let existing: ConvexClient => existing
      | let reason: String =>
        _emit_failure(command.id, ConvexError.protocol(reason))
        return
      end

    if command.op == "query" then
      client.query("r|" + command.id, command.path, command.args, this)
    elseif command.op == "mutation" then
      client.mutation("r|" + command.id, command.path, command.args, this)
    elseif command.op == "action" then
      client.action("r|" + command.id, command.path, command.args, this)
    elseif command.op == "setAuth" then
      client.set_auth(command.token, "a|" + command.id, this)
    elseif command.op == "subscribe" then
      // Replacing an identifier retires the previous relay first, so nothing
      // from it can appear after this subscribe is acknowledged.
      _retire(command.subscription_id)
      _next_generation = _next_generation + 1
      let generation = _next_generation
      let relay = AdapterRelay(_output, command.subscription_id, generation)
      _relays(command.subscription_id) = generation
      _output.activate_relay(command.subscription_id, generation)
      client.subscribe(
        command.subscription_id,
        command.path,
        command.args,
        relay,
        "a|" + command.id,
        this)
    elseif command.op == "unsubscribe" then
      _retire(command.subscription_id)
      client.unsubscribe(command.subscription_id, "a|" + command.id, this)
    elseif command.op == "debugDisconnect" then
      client.debug_disconnect("a|" + command.id, this)
    end

  fun ref _relay_ids(): Array[String] =>
    let ids = Array[String](_relays.size())
    for subscription_id in _relays.keys() do
      ids.push(subscription_id)
    end
    ids

  fun ref _retire(subscription_id: String) =>
    try
      let generation = _relays(subscription_id)?
      _output.invalidate_relay(subscription_id, generation)
      _relays.remove(subscription_id)?
    end

  fun ref _ensure_client(): (ConvexClient | String) =>
    match _client
    | let existing: ConvexClient => existing
    | None =>
      match _config
      | let config: ConvexConfig =>
        let created = ConvexClient(config, _opener, _ticker)
        _client = created
        created
      | None =>
        "CONVEX_URL is required"
      end
    end

  fun ref _emit_failure(id: String, error': ConvexError) =>
    try _output.emit(AdapterEvents.failure(id, error')?) end

  fun ref _split_step(step: String): (String, String) =>
    try
      let separator = HttpText.index_of(step, '|')?
      (HttpText.slice(step, 0, separator),
        HttpText.slice(step, separator + 1, step.size()))
    else
      ("", step)
    end
