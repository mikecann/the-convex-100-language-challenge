use "pony_test"

// End to end HTTP behaviour of the public client, against a scripted peer.
//
// The three responses here are the three shapes the adapter has to serialise
// differently: a success with a value and log lines, a Convex function error
// carrying structured data, and a transport level failure that must never be
// flattened into either of the other two.

class _SinkBox
  """
  Holds the stream sink for a scripted connection. A nominal class beside
  `None` keeps the optional field simple to match on.
  """

  let sink: StreamSink

  new create(sink': StreamSink) =>
    sink = sink'

actor _HttpScenario
  let _h: TestHelper
  let _config: ConvexConfig
  var _client: (ConvexClient | None) = None
  var _sink: (_SinkBox | None) = None
  var _stage: USize = 0

  new create(h: TestHelper, config: ConvexConfig) =>
    _h = h
    _config = config

  be start() =>
    let client = ConvexClient(_config, this, this)
    _client = client
    client.query("state", "demo:state", JsonOf.obj1("room", "demo"), this)

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    // The request deadline is never fired: every stage here completes on its
    // own, so firing it would only mask a hang rather than prove one.
    None

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    // Nothing to unwind: this fixture never holds a real timer.
    None

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    _sink = _SinkBox(sink)
    sink.stream_opened(generation, this)

  be write(data: ByteSeq) =>
    let request = Bytes.to_string(TestLiveConfig.to_bytes(data))
    match _stage
    | 0 =>
      _h.assert_true(
        Bytes.starts_with(request, "POST /api/query HTTP/1.1\r\n"), request)
      _respond("HTTP/1.1 200 OK", "{\"status\":\"success\"," +
        "\"value\":{\"room\":\"demo\",\"count\":0.0}," +
        "\"logLines\":[\"demo:echo received a JSON-safe value\"]}")
    | 1 =>
      // Convex function failures use HTTP 560 and remain FunctionErrors.
      _respond("HTTP/1.1 560 Convex Error", "{\"status\":\"error\"," +
        "\"errorMessage\":\"Uncaught ConvexError\"," +
        "\"errorData\":{\"code\":\"PONY_EXPECTED\"},\"logLines\":[]}")
    | 2 =>
      // The same status may not smuggle a success-shaped envelope through the
      // HTTP boundary.
      _respond("HTTP/1.1 560 Convex Error",
        "{\"status\":\"success\",\"value\":null,\"logLines\":[]}")
    | 3 =>
      _respond("HTTP/1.1 200 OK",
        "{\"status\":\"success\",\"value\":null,\"logLines\":{}}")
    | 4 =>
      // A gateway that never speaks Convex. This must not become a value.
      _respond("HTTP/1.1 502 Bad Gateway", "<html>upstream is unavailable")
    end

  be dispose() =>
    None

  be convex_ok(step: String, result: ConvexResult) =>
    if step == "state" then
      let encoded = try JsonEncode(result.value)? else "?" end
      _h.assert_eq[String]("{\"room\":\"demo\",\"count\":0.0}", encoded)
      _h.assert_eq[USize](1, result.logs.size())
      _stage = 1
      _query("failure", "demo:fail")
    else
      _h.fail("unexpected success for " + step)
      _h.complete(false)
    end

  be convex_failed(step: String, error': ConvexError) =>
    if step == "failure" then
      _h.assert_eq[String]("FunctionError", error'.name())
      _h.assert_true(error'.has_data)
      let code =
        try
          match error'.data
          | let fields: JsonObject => fields.string_field("code")?
          else
            ""
          end
        else
          ""
        end
      _h.assert_eq[String]("PONY_EXPECTED", code)
      _stage = 2
      _query("bad-success", "demo:state")
    elseif step == "bad-success" then
      _h.assert_eq[String]("ProtocolError", error'.name())
      _h.assert_true(error'.message.contains("560"))
      _stage = 3
      _query("bad-logs", "demo:state")
    elseif step == "bad-logs" then
      _h.assert_eq[String]("ProtocolError", error'.name())
      _h.assert_true(error'.message.contains("logLines"))
      _stage = 4
      _query("gateway", "demo:state")
    elseif step == "gateway" then
      // A non-Convex body is a protocol failure, and it keeps the status in
      // its message so the cause is visible.
      _h.assert_eq[String]("ProtocolError", error'.name())
      _h.assert_true(error'.message.contains("502"))
      _h.assert_false(error'.has_data)
      _h.complete(true)
    else
      _h.fail(step + " failed unexpectedly: " + error'.describe())
      _h.complete(false)
    end

  fun ref _query(step: String, path: String) =>
    match _client
    | let client: ConvexClient =>
      client.query(step, path, JsonOf.obj1("room", "demo"), this)
    end

  fun ref _respond(status_line: String, body: String) =>
    let response: String val =
      status_line + "\r\nContent-Type: application/json\r\n" +
      "Content-Length: " + body.size().string() + "\r\n\r\n" + body
    match _sink
    | let held: _SinkBox => held.sink.stream_data(1, Bytes.of_string(response))
    end

class iso _TestClientHttp is UnitTest
  fun name(): String => "client/http-envelopes"

  fun apply(h: TestHelper) ? =>
    h.long_test(20_000_000_000)
    _HttpScenario(h, TestLiveConfig()?).start()

class iso _TestClientAuth is UnitTest
  fun name(): String => "client/auth-header"

  fun apply(h: TestHelper) ? =>
    h.long_test(20_000_000_000)
    _AuthScenario(h, TestLiveConfig()?).start()

actor _AuthScenario
  """
  The bearer token lifecycle: set, replaced, and cleared. Each state has to be
  visible on the wire, because that is the only thing the deployment sees.
  """

  let _h: TestHelper
  let _config: ConvexConfig
  var _client: (ConvexClient | None) = None
  var _sink: (_SinkBox | None) = None
  var _stage: USize = 0

  new create(h: TestHelper, config: ConvexConfig) =>
    _h = h
    _config = config

  be start() =>
    let client = ConvexClient(_config, this, this)
    _client = client
    client.set_auth("first-token", "auth-one", this)

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    None

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    // Nothing to unwind: this fixture never holds a real timer.
    None

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    _sink = _SinkBox(sink)
    sink.stream_opened(generation, this)

  be write(data: ByteSeq) =>
    let request = Bytes.to_string(TestLiveConfig.to_bytes(data))
    match _stage
    | 0 =>
      _h.assert_true(
        request.contains("Authorization: Bearer first-token\r\n"), request)
    | 1 =>
      _h.assert_true(
        request.contains("Authorization: Bearer second-token\r\n"), request)
      _h.assert_false(request.contains("first-token"))
    | 2 =>
      // Clearing the token removes the header rather than sending an empty one.
      _h.assert_false(request.contains("Authorization"), request)
    end
    _respond("{\"status\":\"success\",\"value\":null,\"logLines\":[]}")

  be dispose() =>
    None

  be convex_ok(step: String, result: ConvexResult) =>
    match _client
    | let client: ConvexClient =>
      if step == "auth-one" then
        client.query("call-one", "demo:state", JsonOf.obj1("room", "a"), this)
      elseif step == "call-one" then
        _stage = 1
        client.set_auth("second-token", "auth-two", this)
      elseif step == "auth-two" then
        client.query("call-two", "demo:state", JsonOf.obj1("room", "b"), this)
      elseif step == "call-two" then
        _stage = 2
        client.set_auth("", "auth-clear", this)
      elseif step == "auth-clear" then
        client.query("call-three", "demo:state", JsonOf.obj1("room", "c"), this)
      elseif step == "call-three" then
        _h.complete(true)
      end
    end

  be convex_failed(step: String, error': ConvexError) =>
    _h.fail(step + " failed: " + error'.describe())
    _h.complete(false)

  fun ref _respond(body: String) =>
    let response: String val =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
      "Content-Length: " + body.size().string() + "\r\n\r\n" + body
    match _sink
    | let held: _SinkBox => held.sink.stream_data(1, Bytes.of_string(response))
    end
