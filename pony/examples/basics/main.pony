use "../../client"
use "../../client/tls"
use "random"
use "time"

// Convex from Pony: read a shared counter, watch it, increment it once, and
// prove that the HTTP read, the mutation, and the live subscription all agree.
//
// Pony has no blocking calls, so the journey is written as a small state
// machine. Each Convex operation is given a caller-chosen step name, and the
// answer arrives later on `convex_ok` or `convex_failed` carrying that same
// name. Reading the steps in order below is reading the program in order.

actor Main
  new create(env: Env) =>
    // The verifier passes a room id no other run shares, so this example's
    // counter starts at zero. The default only exists for running the image
    // by hand.
    let room = try env.args(1)? else "pony-example" end

    // Configuration is the deployment URL and nothing else. Convex needs no
    // authentication for these public demo functions, so no token is set.
    let url = ExampleEnv.lookup(env.vars, "CONVEX_URL")
    if url.size() == 0 then
      env.err.print("CONVEX_URL is required")
      env.exitcode(2)
      return
    end

    try
      // Parsing the URL up front decides once whether this deployment needs
      // TLS and which host header every request carries.
      let config = ConvexConfig(ConvexEndpoint(url)?)
      // The clock is injected so deadlines are explicit, and the TLS opener
      // dials `https://` deployments and plain `http://` ones alike.
      let ticker = RealTicker
      let client = ConvexClient(config, TlsStreamOpener(env.root), ticker)
      CounterExample(env, client, ticker, room).start()
    else
      env.err.print("CONVEX_URL is not a usable Convex deployment URL")
      env.exitcode(2)
    end

primitive ExampleEnv
  """
  Pony hands a program its environment as a list of `NAME=value` strings rather
  than a map, so a small lookup is needed before anything else can start.
  """

  fun lookup(vars: Array[String] val, name: String): String =>
    let prefix: String val = name + "="
    for entry in vars.values() do
      if Bytes.starts_with(entry, prefix) then
        return HttpText.slice(entry, prefix.size(), entry.size())
      end
    end
    ""

primitive CounterValue
  """
  Decoding a Convex result into the value this example actually wants.

  Convex numbers are JSON numbers, and an integral count can legitimately
  arrive as `0`, `0.0`, or `0e0`. This client keeps a number's exact source
  text, so `integral` converts it without a float ever being involved: a
  fractional, quoted, or out-of-range count is a decoding failure rather than
  a number that has silently changed.
  """

  fun count(value: JsonValue): I64 ? =>
    match value
    | let fields: JsonObject =>
      match fields("count")?
      | let number: JsonNumber => number.integral()?
      else
        error
      end
    else
      error
    end

  fun applied(value: JsonValue): Bool ? =>
    match value
    | let fields: JsonObject =>
      match fields("applied")?
      | let flag: Bool => flag
      else
        error
      end
    else
      error
    end

  fun state(value: JsonValue): JsonValue ? =>
    match value
    | let fields: JsonObject => fields("state")?
    else
      error
    end

primitive ExampleLimits
  fun deadline_ms(): U64 => 60_000
  fun deadline_tick(): U64 => 1

actor CounterExample
  let _env: Env
  let _client: ConvexClient
  let _ticker: RealTicker
  let _room: String
  var _initial: I64 = 0
  var _expected: I64 = 0
  var _stage: USize = 0
  var _pending_live: I64 = 0
  var _has_pending: Bool = false
  var _finished: Bool = false

  new create(
    env: Env,
    client: ConvexClient,
    ticker: RealTicker,
    room: String)
  =>
    _env = env
    _client = client
    _ticker = ticker
    _room = room

  be start() =>
    // One deadline covers the whole journey. Without it a deployment that
    // never answers would leave the example waiting rather than failing.
    _ticker.schedule(
      ExampleLimits.deadline_ms(), this, ExampleLimits.deadline_tick())

    // Step one: read the room's current state over the HTTP API.
    _client.query(
      "initial-query", "demo:state", JsonOf.obj1("room", _room), this)

  be tick(tick_id: U64) =>
    _fail("timed out waiting for Convex")

  be convex_ok(step: String, result: ConvexResult) =>
    if step == "initial-query" then
      // Decode the JSON result into the one number this example cares about.
      _initial =
        try
          CounterValue.count(result.value)?
        else
          _fail("the initial query did not return an integral count")
          return
        end
      _env.out.print("current count: " + _initial.string())

      // Step two: start listening before the mutation. Subscribing first is
      // what makes the update that follows unambiguously caused by it.
      _stage = 1
      _client.subscribe(
        "counter",
        "demo:state",
        JsonOf.obj1("room", _room),
        this,
        "subscribe",
        this)
    elseif step == "mutation" then
      // Step four: the mutation's own answer, which reports whether this run
      // applied the write and what the room became.
      let applied =
        try
          CounterValue.applied(result.value)?
        else
          _fail("the mutation did not report whether it applied")
          return
        end
      if not applied then
        _fail("the mutation was not applied; the idempotency key was reused")
        return
      end
      _env.out.print("mutation applied: " + applied.string())

      let mutated =
        try
          CounterValue.count(CounterValue.state(result.value)?)?
        else
          _fail("the mutation did not return an integral count")
          return
        end
      if mutated != _expected then
        _fail("the mutation produced " + mutated.string() + ", expected " +
          _expected.string())
        return
      end
      _env.out.print("mutation count: " + mutated.string())

      // The live update may already have arrived while the mutation's HTTP
      // response was still in flight, so it is held until now to keep the
      // printed journey in the order the reader expects.
      _stage = 3
      if _has_pending and (_pending_live == _expected) then _verify() end
    end

  be convex_failed(step: String, error': ConvexError) =>
    _fail(step + " failed: " + error'.describe())

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    let count =
      try
        CounterValue.count(result.value)?
      else
        _fail("a live update did not carry an integral count")
        return
      end

    if _stage == 1 then
      // Step three: a subscription publishes the query's current value first.
      // It has to match the HTTP read, or the two views of the same room have
      // already disagreed.
      if count != _initial then
        _fail("the initial live value was " + count.string() + ", expected " +
          _initial.string())
        return
      end
      _env.out.print("live initial count: " + count.string())

      // Now the write. `runId` is the idempotency key: replaying the same one
      // for this room returns the existing result instead of counting twice,
      // which is what makes a retry safe.
      _expected = _initial + 1
      _stage = 2
      _client.mutation(
        "mutation",
        "demo:increment",
        JsonOf.obj3(
          "room", _room, "language", "Pony", "runId", ExampleRunId.next()),
        this)
    elseif (_stage == 2) or (_stage == 3) then
      if count == _expected then
        _pending_live = count
        _has_pending = true
        if _stage == 3 then _verify() end
      end
    end

    // Live delivery is demand driven, so the next update is only sent once it
    // has been asked for. That is what bounds the client's memory when a
    // watcher falls behind.
    handle.request_next()

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    _fail("the live subscription failed: " + error'.describe())

  fun ref _verify() =>
    if _finished then return end
    // Step five: the same increment, observed through Live rather than by
    // asking again over HTTP.
    _env.out.print("live updated count: " + _pending_live.string())
    // Reaching this line means the HTTP read, the mutation, and the live
    // subscription all agreed about the same change.
    _env.out.print("verified count: " + _initial.string() + " -> " +
      _pending_live.string())
    _finish(0)

  fun ref _fail(message: String) =>
    if _finished then return end
    // Diagnostics go to standard error. Standard output belongs to the six
    // lines the shared verifier compares.
    _env.err.print("convex example failed: " + message)
    _finish(1)

  fun ref _finish(code: I32) =>
    _finished = true
    _stage = 4
    _env.exitcode(code)
    // Cleanup: cancel the deadline and close the client, which unsubscribes,
    // shuts the Live socket down, and lets the program exit.
    _ticker.cancel(this, ExampleLimits.deadline_tick())
    _client.close("close", this)

primitive ExampleRunId
  """
  A fresh idempotency key for this run. Convex uses it to recognise a retry of
  the same logical increment, so it must not be shared between runs.
  """

  fun next(): String =>
    let random = Rand(Time.nanos(), Time.millis())
    var raw: Array[U8] iso = Array[U8](8)
    var index: USize = 0
    while index < 8 do
      raw.push(random.u8())
      index = index + 1
    end
    Hex.encode(consume raw)
