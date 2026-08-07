use "pony_test"

// Live acceptance tests.
//
// Every one of these runs entirely in process. The fixture actor is the socket,
// the connection opener, the clock, and the watcher all at once, so a whole
// scenario is one totally ordered sequence of messages into a single actor.
// Nothing sleeps and nothing races: a reconnect happens because the fixture
// fires the reconnect tick, and a deadline expires because the fixture fires
// the deadline tick.

primitive TestSync
  """
  Server side sync envelopes, written by hand so a test never proves only that
  the client agrees with itself.
  """

  fun timestamp(value: U64): String =>
    // The protocol's timestamps are little endian, so the low byte is first.
    var raw: Array[U8] iso = Array[U8](8)
    var index: U64 = 0
    while index < 8 do
      raw.push(((value >> (index * 8)) and 0xff).u8())
      index = index + 1
    end
    Base64Codec.encode(consume raw)

  fun version(query_set: U32, ts: U64): String =>
    "{\"querySet\":" + query_set.string() + ",\"identity\":0,\"ts\":\"" +
      TestSync.timestamp(ts) + "\"}"

  fun updated(query_id: U32, value: String): String =>
    "{\"type\":\"QueryUpdated\",\"queryId\":" + query_id.string() +
      ",\"value\":" + value + ",\"logLines\":[]}"

  fun failed(query_id: U32, code: String): String =>
    "{\"type\":\"QueryFailed\",\"queryId\":" + query_id.string() +
      ",\"errorMessage\":\"Uncaught ConvexError\",\"errorData\":{\"code\":\"" +
      code + "\"},\"logLines\":[]}"

  fun transition(
    start_query_set: U32,
    start_ts: U64,
    end_query_set: U32,
    end_ts: U64,
    modifications: String)
    : String
  =>
    "{\"type\":\"Transition\",\"startVersion\":" +
      TestSync.version(start_query_set, start_ts) + ",\"endVersion\":" +
      TestSync.version(end_query_set, end_ts) + ",\"modifications\":[" +
      modifications + "]}"

  fun state(count: I64): String =>
    // Convex sends integral counts in decimal form, which is exactly the shape
    // the client and the example have to decode.
    "{\"room\":\"demo\",\"count\":" + count.string() + ".0," +
      "\"lastLanguage\":null,\"latestRunId\":null,\"updatedAt\":null}"

class _PeerLink
  """
  The server half of the connection.

  It answers the upgrade with a `Sec-WebSocket-Accept` derived from the key the
  client actually sent, and it unmasks client frames, so the client's own
  handshake and masking are exercised rather than bypassed. A fresh link is
  made for every owner connection generation. This is deterministic protocol
  coverage, while the shared verifier remains responsible for real TCP/WSS
  reconnect evidence.
  """

  let _buffer: Array[U8] = Array[U8]
  var _position: USize = 0
  var _upgraded: Bool = false

  fun ref feed(data: Array[U8] val): (Array[U8] val, Array[String] val) =>
    Bytes.append_all(_buffer, data)
    var reply: Array[U8] val = recover val Array[U8](256) end
    var messages: Array[String] iso = Array[String](4)

    if not _upgraded then
      match _find_header_end()
      | let header_end: USize =>
        let head = Bytes.to_string(
          Bytes.freeze(_buffer, _position, header_end))
        reply = recover val
          let out = Array[U8](256)
          Bytes.append_string(
            out,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
            "Connection: Upgrade\r\nSec-WebSocket-Accept: " +
            WsHandshake.accept_for(_key(head)) + "\r\n\r\n")
          out
        end
        _upgraded = true
        _position = header_end + 4
      end
    end

    while _upgraded do
      let available = _buffer.size() - _position
      if available < 2 then break end
      let byte0 = try _buffer(_position)? else U8(0) end
      let byte1 = try _buffer(_position + 1)? else U8(0) end
      let masked = (byte1 and 0x80) != 0
      var header: USize = 2
      var length: USize = (byte1 and 0x7f).usize()
      if length == 126 then
        if available < 4 then break end
        length = ((try _buffer(_position + 2)?.usize() else 0 end) << 8) or
          (try _buffer(_position + 3)?.usize() else 0 end)
        header = 4
      elseif length == 127 then
        if available < 10 then break end
        length = 0
        var index: USize = 2
        while index < 10 do
          let byte = try _buffer(_position + index)?.usize() else 0 end
          length = (length << 8) or byte
          index = index + 1
        end
        header = 10
      end
      let mask_size: USize = if masked then 4 else 0 end
      if available < ((header + mask_size) + length) then break end

      let payload_start = (_position + header) + mask_size
      var payload: String iso = String(length)
      var offset: USize = 0
      while offset < length do
        let raw = try _buffer(payload_start + offset)? else U8(0) end
        if masked then
          let key =
            try _buffer((_position + header) + (offset % 4))? else U8(0) end
          payload.push(raw xor key)
        else
          payload.push(raw)
        end
        offset = offset + 1
      end
      _position = payload_start + length
      if (byte0 and 0x0f) == WsOpcode.text() then
        messages.push(consume payload)
      end
    end
    (consume reply, consume messages)

  fun ref _find_header_end(): (USize | None) =>
    var index = _position
    while (index + 4) <= _buffer.size() do
      try
        if (_buffer(index)? == '\r') and (_buffer(index + 1)? == '\n') and
          (_buffer(index + 2)? == '\r') and (_buffer(index + 3)? == '\n')
        then
          return index
        end
      end
      index = index + 1
    end
    None

  fun ref _key(head: String): String =>
    for line in HttpText.split_lines(head).values() do
      try
        let colon = HttpText.index_of(line, ':')?
        if Bytes.lower(HttpText.slice(line, 0, colon)) == "sec-websocket-key"
        then
          return HttpText.trim(HttpText.slice(line, colon + 1, line.size()))
        end
      end
    end
    ""

primitive TestLiveConfig
  fun apply(): ConvexConfig ? =>
    ConvexConfig(ConvexEndpoint("http://127.0.0.1:3210")?, "pony-test")

  fun args(): JsonObject =>
    JsonOf.obj1("room", "demo")

  fun to_bytes(data: ByteSeq): Array[U8] val =>
    match data
    | let text: String => Bytes.of_string(text)
    | let raw: Array[U8] val => raw
    end

actor _LiveLifecycle
  """
  One connection, start to finish: `Add`, an initial value, an external update,
  a query failure carrying structured data, recovery on the same subscription,
  and an unsubscribe that both sends `Remove` and retires the relay.
  """

  let _h: TestHelper
  let _config: ConvexConfig
  var _link: _PeerLink = _PeerLink
  var _owner: (LiveOwner | None) = None
  var _generation: U64 = 0
  var _query_set: U32 = 0
  var _ts: U64 = 0
  let _values: Array[String] = Array[String]
  let _failures: Array[String] = Array[String]
  var _saw_remove: Bool = false

  new create(h: TestHelper, config: ConvexConfig) =>
    _h = h
    _config = config

  be start() =>
    let owner = LiveOwner(_config, this, this)
    _owner = owner
    owner.subscribe(
      "s1", "demo:state", TestLiveConfig.args(), this, "sub", this)

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    // Only the immediate connect tick is fired. Deadlines are exercised by
    // `_LiveDeadlines`, and leaving them unfired here proves this scenario
    // never depends on one expiring.
    if delay_ms == 0 then receiver.tick(tick_id) end

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    // Nothing to unwind: this fixture never holds a real timer.
    None

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    _generation = generation
    _link = _PeerLink
    _query_set = 0
    _ts = 0
    sink.stream_opened(generation, this)

  be write(data: ByteSeq) =>
    (let reply, let messages) = _link.feed(TestLiveConfig.to_bytes(data))
    if reply.size() > 0 then _to_owner(reply) end
    for message in messages.values() do
      _on_client_message(message)
    end

  be dispose() =>
    None

  be convex_ok(step: String, result: ConvexResult) =>
    if step == "unsub" then
      // The `Remove` is written before the acknowledgement, so by the time the
      // fixture sees the acknowledgement it has already seen the write.
      _h.assert_true(_saw_remove, "unsubscribe must send a Remove")
      _h.assert_eq[USize](3, _values.size())
      _h.assert_eq[USize](1, _failures.size())
      _h.complete(true)
    end

  be convex_failed(step: String, error': ConvexError) =>
    _h.fail(step + " failed: " + error'.describe())
    _h.complete(false)

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    let encoded = try JsonEncode(result.value)? else "?" end
    _values.push(encoded)
    handle.request_next()
    if _values.size() == 1 then
      _h.assert_true(encoded.contains("\"count\":0.0"), encoded)
      // An external mutation observed through the same subscription.
      _transition(TestSync.updated(0, TestSync.state(1)))
    elseif _values.size() == 2 then
      _h.assert_true(encoded.contains("\"count\":1.0"), encoded)
      // Now fail the query and then repair it, on one connection.
      _transition(TestSync.failed(0, "ROOM_EMPTY"))
    elseif _values.size() == 3 then
      _h.assert_true(encoded.contains("\"count\":2.0"), encoded)
      match _owner
      | let owner: LiveOwner => owner.unsubscribe("s1", "unsub", this)
      end
    end

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    _failures.push(error'.describe())
    handle.request_next()
    // A query failure is a function error with the application's own payload,
    // not a transport failure and not a successful value.
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
    _h.assert_eq[String]("ROOM_EMPTY", code)
    // The same subscription must be able to deliver a later valid value.
    _transition(TestSync.updated(0, TestSync.state(2)))

  fun ref _on_client_message(message: String) =>
    if message.contains("\"type\":\"Connect\"") then
      _h.assert_true(message.contains("\"lastCloseReason\":\"InitialConnect\""))
    elseif message.contains("\"type\":\"Add\"") then
      _h.assert_true(message.contains("\"udfPath\":\"demo:state\""))
      _h.assert_true(message.contains("\"baseVersion\":0,\"newVersion\":1"))
      _transition(TestSync.updated(0, TestSync.state(0)))
    elseif message.contains("\"type\":\"Remove\"") then
      _saw_remove = true
    end

  fun ref _transition(modifications: String) =>
    let start_query_set = _query_set
    let start_ts = _ts
    _query_set = 1
    _ts = _ts + 1
    _to_owner(TestFrames.text(TestSync.transition(
      start_query_set, start_ts, 1, _ts, modifications)))

  fun ref _to_owner(bytes: Array[U8] val) =>
    match _owner
    | let owner: LiveOwner => owner.stream_data(_generation, bytes)
    end

actor _LiveReconnect
  """
  Five deterministic owner-level reconnect generations.

  Each round proves the same three things: the new connection resends the
  active `Add`, a rehydrated value that has not changed is suppressed, and the
  update following the external mutation is delivered. The sequence a watcher
  observes per round is therefore exactly `0`, then `1`.
  """

  let _h: TestHelper
  let _config: ConvexConfig
  var _link: _PeerLink = _PeerLink
  var _owner: (LiveOwner | None) = None
  var _generation: U64 = 0
  var _query_set: U32 = 0
  var _ts: U64 = 0
  var _round: USize = 0
  var _adds: USize = 0
  var _connections: USize = 0
  var _rehydrating: Bool = false
  let _values: Array[String] = Array[String]
  let _delays: Array[U64] = Array[U64]

  new create(h: TestHelper, config: ConvexConfig) =>
    _h = h
    _config = config

  be start() =>
    let owner = LiveOwner(_config, this, this)
    _owner = owner
    owner.subscribe(
      "s1", "demo:state", TestLiveConfig.args(), this, "sub", this)

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    if delay_ms <= LiveLimits.initial_backoff_ms() then
      // Every reconnect delay is recorded so the backoff can be asserted.
      _delays.push(delay_ms)
      receiver.tick(tick_id)
    elseif delay_ms == LiveLimits.close_deadline_ms() then
      // This peer never answers the close frame, so the bounded close
      // deadline is what finishes the shutdown.
      receiver.tick(tick_id)
    end

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    // Nothing to unwind: this fixture never holds a real timer.
    None

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    _generation = generation
    _connections = _connections + 1
    _link = _PeerLink
    _query_set = 0
    _ts = 0
    sink.stream_opened(generation, this)

  be write(data: ByteSeq) =>
    (let reply, let messages) = _link.feed(TestLiveConfig.to_bytes(data))
    if reply.size() > 0 then _to_owner(reply) end
    for message in messages.values() do
      if message.contains("\"type\":\"Add\"") then
        _adds = _adds + 1
        _transition(TestSync.updated(0, TestSync.state(0)))
        if _rehydrating then
          // The first transition above is the rehydration of a value the
          // watcher already holds, so it must not be delivered. This one is
          // the external mutation, and it must be.
          _rehydrating = false
          _transition(TestSync.updated(0, TestSync.state(1)))
        end
      end
    end

  be dispose() =>
    None

  be convex_ok(step: String, result: ConvexResult) =>
    if step == "disconnect" then
      // Acknowledged only after the old connection is retired and the
      // reconnect is scheduled.
      _rehydrating = true
    elseif step == "done" then
      _h.assert_eq[USize](6, _connections)
      _h.assert_eq[USize](6, _adds, "every connection must resend the Add")
      _h.assert_eq[USize](10, _values.size())
      // A healthy connection resets the backoff, so no reconnect was ever
      // scheduled at more than the initial delay.
      for delay in _delays.values() do
        _h.assert_true(delay <= LiveLimits.initial_backoff_ms())
      end
      _h.complete(true)
    end

  be convex_failed(step: String, error': ConvexError) =>
    _h.fail(step + " failed: " + error'.describe())
    _h.complete(false)

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    let encoded = try JsonEncode(result.value)? else "?" end
    _values.push(encoded)
    handle.request_next()
    match _owner
    | let owner: LiveOwner =>
      if encoded.contains("\"count\":0.0") then
        owner.debug_disconnect("disconnect", this)
      else
        _h.assert_true(encoded.contains("\"count\":1.0"), encoded)
        _round = _round + 1
        if _round >= 5 then
          owner.close("done", this)
        else
          // The next round starts from a room that reads zero again.
          _transition(TestSync.updated(0, TestSync.state(0)))
        end
      end
    end

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    _h.fail("no Live failure was expected: " + error'.describe())
    _h.complete(false)

  fun ref _transition(modifications: String) =>
    let start_query_set = _query_set
    let start_ts = _ts
    _query_set = 1
    _ts = _ts + 1
    _to_owner(TestFrames.text(TestSync.transition(
      start_query_set, start_ts, 1, _ts, modifications)))

  fun ref _to_owner(bytes: Array[U8] val) =>
    match _owner
    | let owner: LiveOwner => owner.stream_data(_generation, bytes)
    end

actor _LiveBackpressure
  """
  A watcher that stops asking for updates.

  The owner has exactly one update in flight and a bounded queue behind it, so
  a stalled watcher cannot grow an unbounded Pony mailbox. Two hundred updates
  arrive while the watcher holds its credit; the queue keeps the newest
  `max_queued_updates` and drops the rest, which is the right answer for a
  reactive query whose value is current state rather than a log.
  """

  let _h: TestHelper
  let _config: ConvexConfig
  var _link: _PeerLink = _PeerLink
  var _owner: (LiveOwner | None) = None
  var _generation: U64 = 0
  var _query_set: U32 = 0
  var _ts: U64 = 0
  var _delivered: USize = 0
  var _flooded: Bool = false

  new create(h: TestHelper, config: ConvexConfig) =>
    _h = h
    _config = config

  be start() =>
    let owner = LiveOwner(_config, this, this)
    _owner = owner
    owner.subscribe(
      "s1", "demo:state", TestLiveConfig.args(), this, "sub", this)

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    if delay_ms == 0 then receiver.tick(tick_id) end

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    // Nothing to unwind: this fixture never holds a real timer.
    None

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    _generation = generation
    _link = _PeerLink
    _query_set = 0
    _ts = 0
    sink.stream_opened(generation, this)

  be write(data: ByteSeq) =>
    (let reply, let messages) = _link.feed(TestLiveConfig.to_bytes(data))
    if reply.size() > 0 then _to_owner(reply) end
    for message in messages.values() do
      if message.contains("\"type\":\"Add\"") then
        _transition(TestSync.updated(0, TestSync.state(0)))
      end
    end

  be dispose() =>
    None

  be convex_ok(step: String, result: ConvexResult) =>
    None

  be convex_failed(step: String, error': ConvexError) =>
    _h.fail(step + " failed: " + error'.describe())
    _h.complete(false)

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    _delivered = _delivered + 1
    let encoded = try JsonEncode(result.value)? else "?" end
    if not _flooded then
      _flooded = true
      _h.assert_true(encoded.contains("\"count\":0.0"), encoded)
      // Deliberately no `request_next` yet. Everything below is queued.
      var count: I64 = 1
      while count <= 200 do
        _transition(TestSync.updated(0, TestSync.state(count)))
        count = count + 1
      end
      // Returning the credit through the owner keeps this deterministic:
      // messages from this actor to the owner are delivered in order, so the
      // credit is processed after all two hundred updates.
      match _owner
      | let owner: LiveOwner => owner.relay_credit(0)
      end
    else
      // The queue kept the newest thirty two updates, so the next value the
      // watcher sees is the front of that window rather than the second
      // update that was sent.
      let expected = (200 - LiveLimits.max_queued_updates().i64()) + 1
      _h.assert_eq[USize](2, _delivered)
      _h.assert_true(
        encoded.contains("\"count\":" + expected.string() + ".0"), encoded)
      _h.complete(true)
    end

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    _h.fail("no Live failure was expected: " + error'.describe())
    _h.complete(false)

  fun ref _transition(modifications: String) =>
    let start_query_set = _query_set
    let start_ts = _ts
    _query_set = 1
    _ts = _ts + 1
    _to_owner(TestFrames.text(TestSync.transition(
      start_query_set, start_ts, 1, _ts, modifications)))

  fun ref _to_owner(bytes: Array[U8] val) =>
    match _owner
    | let owner: LiveOwner => owner.stream_data(_generation, bytes)
    end

actor _LiveDeadlines
  """
  Two bounded waits, both asserted through the clock rather than a sleep.

  Half a frame arrives and then nothing, so the partial-frame deadline must
  abandon the connection rather than resynchronise at a byte that is not a
  frame boundary. Then `close` is called against a peer that answers nothing:
  it must complete on the close deadline instead of hanging.
  """

  let _h: TestHelper
  let _config: ConvexConfig
  var _link: _PeerLink = _PeerLink
  var _owner: (LiveOwner | None) = None
  var _generation: U64 = 0
  var _connections: USize = 0
  var _frame_deadlines: USize = 0
  var _close_deadlines: USize = 0
  var _abandoned: Bool = false

  new create(h: TestHelper, config: ConvexConfig) =>
    _h = h
    _config = config

  be start() =>
    let owner = LiveOwner(_config, this, this)
    _owner = owner
    owner.subscribe(
      "s1", "demo:state", TestLiveConfig.args(), this, "sub", this)

  be schedule(delay_ms: U64, receiver: TickReceiver, tick_id: U64) =>
    if (delay_ms == 0) or (delay_ms == LiveLimits.initial_backoff_ms()) then
      receiver.tick(tick_id)
    elseif delay_ms == LiveLimits.frame_deadline_ms() then
      // Firing the deadline the moment the owner arms it keeps the scenario
      // ordered without any waiting.
      _frame_deadlines = _frame_deadlines + 1
      _abandoned = true
      receiver.tick(tick_id)
    elseif delay_ms == LiveLimits.close_deadline_ms() then
      _close_deadlines = _close_deadlines + 1
      receiver.tick(tick_id)
    end

  be cancel(receiver: TickReceiver, tick_id: U64) =>
    // Nothing to unwind: this fixture never holds a real timer.
    None

  be open_stream(
    generation: U64,
    endpoint: ConvexEndpoint,
    sink: StreamSink)
  =>
    _generation = generation
    _connections = _connections + 1
    _link = _PeerLink
    sink.stream_opened(generation, this)

  be write(data: ByteSeq) =>
    (let reply, let messages) = _link.feed(TestLiveConfig.to_bytes(data))
    if reply.size() > 0 then _to_owner(reply) end
    for message in messages.values() do
      if message.contains("\"type\":\"Add\"") then
        if not _abandoned then
          // The first three bytes of a frame, and then silence.
          let whole = TestFrames.text(TestSync.transition(0, 0, 1, 1,
            TestSync.updated(0, TestSync.state(0))))
          _to_owner(Bytes.freeze(whole, 0, 3))
        else
          // A healthy connection whose peer will never answer the close.
          match _owner
          | let owner: LiveOwner => owner.close("close", this)
          end
        end
      end
    end

  be dispose() =>
    None

  be convex_ok(step: String, result: ConvexResult) =>
    if step == "close" then
      _h.assert_eq[USize](1, _frame_deadlines)
      _h.assert_eq[USize](1, _close_deadlines)
      // The abandoned connection was replaced rather than resumed.
      _h.assert_eq[USize](2, _connections)
      _h.complete(true)
    end

  be convex_failed(step: String, error': ConvexError) =>
    _h.fail(step + " failed: " + error'.describe())
    _h.complete(false)

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    _h.fail("a partial frame must never produce a value")
    _h.complete(false)

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    // A transport level abandonment is not reported as a query failure here.
    None

  fun ref _to_owner(bytes: Array[U8] val) =>
    match _owner
    | let owner: LiveOwner => owner.stream_data(_generation, bytes)
    end

class iso _TestLiveLifecycle is UnitTest
  fun name(): String => "live/lifecycle"

  fun apply(h: TestHelper) ? =>
    h.long_test(20_000_000_000)
    _LiveLifecycle(h, TestLiveConfig()?).start()

class iso _TestLiveReconnect is UnitTest
  fun name(): String => "live/reconnect-five-times"

  fun apply(h: TestHelper) ? =>
    h.long_test(20_000_000_000)
    _LiveReconnect(h, TestLiveConfig()?).start()

class iso _TestLiveBackpressure is UnitTest
  fun name(): String => "live/bounded-slow-watcher"

  fun apply(h: TestHelper) ? =>
    h.long_test(20_000_000_000)
    _LiveBackpressure(h, TestLiveConfig()?).start()

class iso _TestLiveDeadlines is UnitTest
  fun name(): String => "live/bounded-deadlines"

  fun apply(h: TestHelper) ? =>
    h.long_test(20_000_000_000)
    _LiveDeadlines(h, TestLiveConfig()?).start()
