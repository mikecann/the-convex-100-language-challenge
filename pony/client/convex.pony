// The public Convex client.
//
// `ConvexClient` is a thin, well-behaved front door. It owns configuration and
// the decision of when a Live owner exists; it does not own sockets. Each HTTP
// call is a short lived `_HttpCall` actor that opens a connection, writes one
// request, reads one bounded response, and completes exactly once. Live work
// belongs entirely to `LiveOwner`.
//
// Every operation takes a caller-chosen `step` label and a callback, and the
// label comes back with the result. One actor can therefore drive a whole
// sequence of Convex calls, which is exactly what the canonical example does,
// without a separate callback object for each step.

actor ConvexClient
  var _config: ConvexConfig
  let _opener: StreamOpener
  let _ticker: Ticker
  var _live: (LiveOwner | None) = None
  var _closed: Bool = false

  new create(config: ConvexConfig, opener: StreamOpener, ticker: Ticker) =>
    _config = config
    _opener = opener
    _ticker = ticker

  be set_auth(token: String, step: String, callback: ConvexCallback) =>
    """
    Sets or clears the bearer token used by later HTTP calls. An empty token
    clears it.

    Live authentication is deliberately not implemented: the sync protocol
    carries identity in its own `Authenticate` message with its own version
    counter, and claiming it works without proving it would be dishonest.
    """
    if _closed then
      callback.convex_failed(
        step, ConvexError.protocol("the Convex client is closed"))
      return
    end
    if not HttpRequest.safe_header_value(token) then
      callback.convex_failed(
        step, ConvexError.protocol("the bearer token is not a legal header"))
      return
    end
    _config = _config.with_auth(token)
    callback.convex_ok(step, ConvexResult(None))

  be query(
    step: String,
    path: String,
    args: JsonObject,
    callback: ConvexCallback)
  =>
    _call("query", step, path, args, callback)

  be mutation(
    step: String,
    path: String,
    args: JsonObject,
    callback: ConvexCallback)
  =>
    _call("mutation", step, path, args, callback)

  be action(
    step: String,
    path: String,
    args: JsonObject,
    callback: ConvexCallback)
  =>
    _call("action", step, path, args, callback)

  be subscribe(
    subscription_id: String,
    path: String,
    args: JsonObject,
    watcher: LiveWatcher,
    step: String,
    callback: ConvexCallback)
  =>
    if _closed then
      callback.convex_failed(
        step, ConvexError.protocol("the Convex client is closed"))
      return
    end
    _live_owner().subscribe(
      subscription_id, path, args, watcher, step, callback)

  be unsubscribe(
    subscription_id: String,
    step: String,
    callback: ConvexCallback)
  =>
    match _live
    | let owner: LiveOwner => owner.unsubscribe(subscription_id, step, callback)
    | None => callback.convex_ok(step, ConvexResult(None))
    end

  be debug_disconnect(step: String, callback: ConvexCallback) =>
    """
    Adapter-only hook, compiled out unless the build defines `convex_adapter`.
    It is not part of the client API this demonstration teaches.
    """
    match _live
    | let owner: LiveOwner => owner.debug_disconnect(step, callback)
    | None =>
      callback.convex_failed(
        step, ConvexError.transport("the Live socket is not connected"))
    end

  be close(step: String, callback: ConvexCallback) =>
    if _closed then
      callback.convex_ok(step, ConvexResult(None))
      return
    end
    _closed = true
    match _live
    | let owner: LiveOwner => owner.close(step, callback)
    | None => callback.convex_ok(step, ConvexResult(None))
    end

  fun ref _live_owner(): LiveOwner =>
    match _live
    | let owner: LiveOwner => owner
    | None =>
      let owner = LiveOwner(_config, _opener, _ticker)
      _live = owner
      owner
    end

  fun ref _call(
    operation: String,
    step: String,
    path: String,
    args: JsonObject,
    callback: ConvexCallback)
  =>
    if _closed then
      callback.convex_failed(
        step, ConvexError.protocol("the Convex client is closed"))
      return
    end
    if path.size() < 3 then
      callback.convex_failed(
        step, ConvexError.protocol("a Convex function path is required"))
      return
    end
    let call = _HttpCall(_config, operation, step, path, args, callback)
    // Started as a separate behaviour so the actor is fully constructed before
    // it hands its own reference to the opener and the ticker.
    call.start(_opener, _ticker)

primitive HttpCallLimits
  fun request_deadline_ms(): U64 => 30_000

class _TickerBox
  let ticker: Ticker

  new create(ticker': Ticker) =>
    ticker = ticker'

actor _HttpCall
  """
  One Convex function call over one connection.

  The response envelope is validated strictly. A success must carry a value, an
  error must carry a message, and anything else is a protocol failure that
  keeps the HTTP status in its message rather than being flattened into a
  successful result.
  """

  let _config: ConvexConfig
  let _operation: String
  let _step: String
  let _callback: ConvexCallback
  let _parser: HttpResponseParser = HttpResponseParser
  var _stream: (_StreamBox | None) = None
  var _ticker: (_TickerBox | None) = None
  let _request: Array[U8] val
  let _encoding_failure: (ConvexError | None)
  var _done: Bool = false

  new create(
    config: ConvexConfig,
    operation: String,
    step: String,
    path: String,
    args: JsonObject,
    callback: ConvexCallback)
  =>
    _config = config
    _operation = operation
    _step = step
    _callback = callback

    var encoded: Array[U8] val = recover val Array[U8] end
    var failure: (ConvexError | None) = None
    try
      let body = JsonEncode(JsonOf.obj3(
        "path", path, "args", args, "format", "json"))?
      encoded = HttpRequest.post_json(
        config.endpoint,
        config.endpoint.function_path(operation),
        body,
        config.client_version,
        config.auth_token)?
    else
      failure = ConvexError.protocol(
        "could not encode the Convex " + operation + " request")
    end
    _request = encoded
    _encoding_failure = failure

  be start(opener: StreamOpener, ticker: Ticker) =>
    match _encoding_failure
    | let problem: ConvexError =>
      _fail(problem)
    | None =>
      // One deadline covers connect, write, and read together, so a peer that
      // stalls at any stage costs the same bounded wait.
      _ticker = _TickerBox(ticker)
      ticker.schedule(HttpCallLimits.request_deadline_ms(), this, 1)
      opener.open_stream(1, _config.endpoint, this)
    end

  be stream_opened(generation: U64, stream: Stream) =>
    if _done then
      stream.dispose()
      return
    end
    _stream = _StreamBox(stream)
    stream.write(_request)

  be stream_data(generation: U64, data: Array[U8] val) =>
    if _done then return end
    try
      _parser.push(data)?
    else
      _fail(ConvexError.transport(
        "the Convex " + _operation + " response was malformed or too large"))
      return
    end
    if _parser.ready() then
      try
        _complete(_parser.response()?)
      else
        _fail(ConvexError.transport("could not read the Convex response"))
      end
    end

  be stream_closed(generation: U64, reason: String) =>
    if _done then return end
    // A close is legitimate when the body was delimited by it, so try to
    // finish the response before treating the close as a failure.
    try
      _complete(_parser.finish()?)
    else
      _fail(ConvexError.transport(
        "the Convex " + _operation + " connection closed: " + reason))
    end

  be stream_throttled(generation: U64, throttled: Bool) =>
    None

  be tick(tick_id: U64) =>
    if _done then return end
    _fail(ConvexError.transport(
      "the Convex " + _operation + " request timed out"))

  fun ref _complete(response: HttpResponse) =>
    if _done then return end
    match _decode(response)
    | let result: ConvexResult => _finish_ok(result)
    | let failure: ConvexError => _fail(failure)
    end

  fun ref _decode(response: HttpResponse): (ConvexResult | ConvexError) =>
    let envelope =
      try
        JsonDecode.parse_object(response.body)?
      else
        return ConvexError.protocol(
          "HTTP " + response.status.string() +
            " did not return a Convex JSON object")
      end
    let logs =
      if envelope.contains("logLines") then
        try envelope.string_list("logLines")? else
          return ConvexError.protocol(
            "the Convex response logLines field was not an array of strings")
        end
      else
        NoLogs()
      end
    let status = try envelope.string_field("status")? else "" end

    if status == "success" then
      if (response.status < 200) or (response.status >= 300) then
        return ConvexError.protocol(
          "HTTP " + response.status.string() +
            " returned a success-shaped Convex response")
      end
      // A success without a value is not a success. Convex always sends one,
      // including an explicit JSON null.
      if not envelope.contains("value") then
        return ConvexError.protocol("the Convex success response had no value")
      end
      try
        return ConvexResult(envelope("value")?, logs)
      else
        return ConvexError.protocol("the Convex success value was unreadable")
      end
    end

    if status == "error" then
      let message =
        try
          envelope.string_field("errorMessage")?
        else
          return ConvexError.protocol(
            "the Convex error response had no errorMessage string")
        end
      let has_data = envelope.contains("errorData")
      let data = try envelope("errorData")? else None end
      return ConvexError.function(message, data, has_data, logs)
    end

    ConvexError.protocol(
      "HTTP " + response.status.string() + " returned an unknown status")

  fun ref _finish_ok(result: ConvexResult) =>
    if _done then return end
    _done = true
    _shutdown()
    _callback.convex_ok(_step, result)

  fun ref _fail(failure: ConvexError) =>
    if _done then return end
    _done = true
    _shutdown()
    _callback.convex_failed(_step, failure)

  fun ref _shutdown() =>
    match _stream
    | let held: _StreamBox => held.stream.dispose()
    end
    _stream = None
    // The deadline has done its job. Leaving it pending would keep a finished
    // program alive until it fired.
    match _ticker
    | let held: _TickerBox => held.ticker.cancel(this, 1)
    end
    _ticker = None
