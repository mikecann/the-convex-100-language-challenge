use "collections"
use "lib:crypto"

use @RAND_bytes[I32](buffer: Pointer[U8] tag, count: I32)

// Convex Live, owned by exactly one actor.
//
// `LiveOwner` is the sole owner of the WebSocket, the query set and its
// version, reconnect state, replay after a reconnect, and every delivery
// decision. Subscribers and the conformance adapter send it behaviours; none
// of them ever touch the socket. In Pony that is not a convention that has to
// be policed, it is the only thing the type system will allow, which is the
// main reason this client is worth writing in Pony at all.
//
// Delivery is deliberately demand driven and bounded. `LiveOwner` holds a
// bounded queue per subscription and has at most one update in flight to a
// relay at a time. A watcher asks for the next update by calling
// `LiveHandle.request_next()`. A watcher that stops asking therefore cannot
// grow an unbounded Pony mailbox: the queue fills, the oldest updates are
// dropped, and the newest state is what survives. That is the right trade for
// a reactive query, whose value is current state rather than a log of events.

primitive LiveLimits
  """
  Every bound the Live layer enforces, in one place.
  """

  fun max_queued_updates(): USize => 32
  fun max_queued_bytes(): USize => 2 * 1024 * 1024
  fun initial_backoff_ms(): U64 => 100
  fun max_backoff_ms(): U64 => 15_000
  fun handshake_deadline_ms(): U64 => 10_000
  fun frame_deadline_ms(): U64 => 15_000
  fun activity_deadline_ms(): U64 => 60_000
  fun close_deadline_ms(): U64 => 250

primitive SecureRandom
  """
  WebSocket masks, upgrade keys and session identifiers must not come from a
  clock-seeded simulation PRNG. `net_ssl` already links OpenSSL into the
  client, so use its operating-system-backed generator and fail the connection
  if entropy is unavailable.
  """

  fun bytes(count: USize): Array[U8] val ? =>
    if count > I32.max_value().usize() then error end
    var out: Array[U8] iso = Array[U8](count)
    var index: USize = 0
    while index < count do
      out.push(0)
      index = index + 1
    end
    if @RAND_bytes(out.cpointer(), count.i32()) != 1 then error end
    consume out

class val LiveHandle
  """
  Passed to a watcher with every update.

  `request_next` is the demand half of delivery. Until it is called, the owner
  holds the next update in its bounded queue instead of pushing it.
  """

  let id: String
  let _relay: SubscriptionRelay

  new val create(id': String, relay: SubscriptionRelay) =>
    id = id'
    _relay = relay

  fun request_next() =>
    _relay.deliver_next()

actor SubscriptionRelay
  """
  The one-update-at-a-time channel between the owner and a watcher.

  It exists so that invalidation has a single place to happen. Once the owner
  invalidates a relay, nothing further is sent to the watcher through it.
  Something already handed to an arbitrary watcher actor may still be in that
  actor's mailbox. The conformance adapter therefore has a second generation
  barrier at its single final output actor, where events and acknowledgements
  become externally observable in one total order.
  """

  let _owner: LiveOwner
  let _query_id: U32
  let _name: String
  let _watcher: LiveWatcher
  var _valid: Bool = true

  new create(
    owner: LiveOwner,
    query_id: U32,
    name: String,
    watcher: LiveWatcher)
  =>
    _owner = owner
    _query_id = query_id
    _name = name
    _watcher = watcher

  be deliver_result(result: ConvexResult) =>
    if _valid then
      _watcher.live_value(LiveHandle(_name, this), result)
    end

  be deliver_failure(failure: ConvexError) =>
    if _valid then
      _watcher.live_failed(LiveHandle(_name, this), failure)
    end

  be deliver_next() =>
    if _valid then
      _owner.relay_credit(_query_id)
    end

  be invalidate() =>
    _valid = false

class _StreamBox
  """
  Holds the current socket.

  Pony matches on a union at runtime, and a nominal class beside `None` is the
  form that is unambiguous to match. Wrapping the structural `Stream` in a
  class keeps that check simple rather than relying on interface matching.
  """

  let stream: Stream

  new create(stream': Stream) =>
    stream = stream'

class _CallbackBox
  let callback: ConvexCallback

  new create(callback': ConvexCallback) =>
    callback = callback'

class val _LiveUpdate
  """
  A queued delivery, with the encoded size it costs against the byte budget.
  """

  let result: (ConvexResult | None)
  let failure: (ConvexError | None)
  let encoded: String
  let cost: USize

  new val value(result': ConvexResult, encoded': String) =>
    result = result'
    failure = None
    encoded = encoded'
    // A decoded JSON tree costs materially more than its wire text. Charging
    // eight times the canonical encoding plus fixed actor/framing overhead is
    // deliberately conservative, so a value made from many tiny nodes cannot
    // defeat the byte budget while its encoded text still looks small.
    cost = (encoded'.size() * 8) + 4096

  new val problem(failure': ConvexError) =>
    result = None
    failure = failure'
    encoded = ""
    cost = (failure'.message.size() * 4) + 1024

class _LiveState
  let query_id: U32
  let name: String
  let path: String
  let args: JsonObject
  let relay: SubscriptionRelay
  let queue: Array[_LiveUpdate] = Array[_LiveUpdate]
  var queued_bytes: USize = 0
  var credit: Bool = true
  var dropped: USize = 0
  var last_encoded: String = ""
  var last_success: Bool = false
  var has_last: Bool = false
  var awaiting_rehydration: Bool = false

  new create(
    query_id': U32,
    name': String,
    path': String,
    args': JsonObject,
    relay': SubscriptionRelay)
  =>
    query_id = query_id'
    name = name'
    path = path'
    args = args'
    relay = relay'

actor LiveOwner
  let _config: ConvexConfig
  let _opener: StreamOpener
  let _ticker: Ticker

  let _states: Map[U32, _LiveState] = Map[U32, _LiveState]
  let _names: Map[String, U32] = Map[String, U32]
  var _next_query_id: U32 = 0

  var _stream: (_StreamBox | None) = None
  var _generation: U64 = 0
  var _handshake: (WsHandshakeReader | None) = None
  var _frames: WsFrameParser = WsFrameParser
  var _connected: Bool = false

  var _query_set_version: U32 = 0
  var _remote_version: SyncStateVersion = SyncStateVersion.zero()
  var _max_observed_timestamp: String = ""
  var _connection_count: U32 = 0
  var _last_close_reason: String = "InitialConnect"
  var _session: String = ""
  var _backoff_ms: U64 = LiveLimits.initial_backoff_ms()

  var _next_tick: U64 = 0
  var _reconnect_tick: U64 = 0
  var _frame_tick: U64 = 0
  var _activity_tick: U64 = 0
  var _close_tick: U64 = 0

  var _closing: Bool = false
  var _closed: Bool = false
  var _close_step: String = ""
  var _close_callback: (_CallbackBox | None) = None

  new create(config: ConvexConfig, opener: StreamOpener, ticker: Ticker) =>
    _config = config
    _opener = opener
    _ticker = ticker

  be subscribe(
    name: String,
    path: String,
    args: JsonObject,
    watcher: LiveWatcher,
    step: String,
    callback: ConvexCallback)
  =>
    if _closing or _closed then
      callback.convex_failed(
        step, ConvexError.protocol("the Convex client is closed"))
      return
    end
    if (name.size() == 0) or (path.size() < 3) then
      callback.convex_failed(
        step,
        ConvexError.protocol(
          "a subscription id and function path are required"))
      return
    end

    // Replacing a live subscription identifier must retire the old relay
    // before the new subscription is acknowledged, so nothing from the old
    // query can appear after the acknowledgement.
    _drop_by_name(name)

    let query_id = _next_query_id
    _next_query_id = _next_query_id + 1
    let relay = SubscriptionRelay(this, query_id, name, watcher)
    let state = _LiveState(query_id, name, path, args, relay)
    _states(query_id) = state
    _names(name) = query_id

    if _connected then
      try
        let modification = SyncProtocol.add_modification(query_id, path, args)
        _send_query_set_change(modification)?
      else
        _fail_connection("could not send the Add modification", true, true)
      end
    else
      _schedule_reconnect(0)
    end
    callback.convex_ok(step, ConvexResult(None))

  be unsubscribe(name: String, step: String, callback: ConvexCallback) =>
    // Unsubscribing something already gone is not an error; the caller's
    // intent is satisfied either way.
    if _names.contains(name) and _connected then
      try
        let query_id = _names(name)?
        _send_query_set_change(SyncProtocol.remove_modification(query_id))?
      else
        _fail_connection("could not send the Remove modification", true, true)
      end
    end
    _drop_by_name(name)
    if _states.size() == 0 then
      // Nothing left to reconnect for.
      _disarm(_reconnect_tick)
      _reconnect_tick = 0
    end
    // Unsubscribe never waits for the peer, so it is bounded even against a
    // server that is idle, flooding, or stalled mid-frame.
    callback.convex_ok(step, ConvexResult(None))

  be relay_credit(query_id: U32) =>
    try
      let state = _states(query_id)?
      state.credit = true
      _pump(state)
    end

  be debug_disconnect(step: String, callback: ConvexCallback) =>
    """
    Adapter-only. Retires the current connection so the shared controller can
    prove a real reconnect. It is compiled out of an ordinary client build.
    """
    ifdef "convex_adapter" then
      if not _connected then
        callback.convex_failed(
          step, ConvexError.transport("the Live socket is not connected"))
        return
      end
      // The old connection is retired and the reconnect is scheduled before
      // the acknowledgement, so the controller's next step cannot race a
      // straggling event from the connection that was just dropped.
      _fail_connection("DebugDisconnect", true, false)
      callback.convex_ok(step, ConvexResult(None))
    else
      callback.convex_failed(
        step,
        ConvexError.protocol(
          "debugDisconnect is only compiled into adapter builds"))
    end

  be close(step: String, callback: ConvexCallback) =>
    if _closed then
      callback.convex_ok(step, ConvexResult(None))
      return
    end
    _closing = true
    _close_step = step
    _close_callback = _CallbackBox(callback)
    for state in _states.values() do
      state.relay.invalidate()
    end
    if _connected then
      // Send a courteous close frame, then bound the wait. A peer that never
      // answers costs one deadline, not an unbounded shutdown.
      try
        let frame = WsFrame.close(1000, _mask()?)?
        match _stream
        | let held: _StreamBox => held.stream.write(frame)
        end
      end
      _close_tick = _arm(LiveLimits.close_deadline_ms())
    else
      _finish_close()
    end

  be stream_opened(generation: U64, stream: Stream) =>
    if (generation != _generation) or _closed then
      stream.dispose()
      return
    end
    _stream = _StreamBox(stream)
    try
      let key = _websocket_key()?
      _handshake = WsHandshakeReader(WsHandshake.accept_for(key))
      stream.write(WsHandshake.request(
        _config.endpoint,
        _config.endpoint.sync_path(),
        _config.client_version,
        key)?)
      _frame_tick = _arm(LiveLimits.handshake_deadline_ms())
      _activity_tick = _arm(LiveLimits.activity_deadline_ms())
    else
      _fail_connection("could not send the WebSocket handshake", true, true)
    end

  be stream_data(generation: U64, data: Array[U8] val) =>
    if (generation != _generation) or _closed then return end
    // Any byte from the peer is evidence of liveness.
    _disarm(_activity_tick)
    _activity_tick = _arm(LiveLimits.activity_deadline_ms())
    match _handshake
    | let reader: WsHandshakeReader =>
      try
        reader.push(data)?
      else
        _fail_connection(
          "the Convex WebSocket handshake was rejected", true, true)
        return
      end
      if not reader.complete() then return end
      _handshake = None
      _connected = true
      // A completed handshake is a healthy connection, so a long backoff
      // inherited from earlier failures must not survive it.
      _backoff_ms = LiveLimits.initial_backoff_ms()
      _disarm(_frame_tick)
      _frame_tick = 0
      let remainder = reader.take_remainder()
      if not _open_query_set() then return end
      if remainder.size() > 0 then
        _consume_frames(remainder)
      end
    else
      _consume_frames(data)
    end

  be stream_closed(generation: U64, reason: String) =>
    if generation != _generation then return end
    if _closing then
      _finish_close()
      return
    end
    if _closed then return end
    _fail_connection(reason, true, true)

  be stream_throttled(generation: U64, throttled: Bool) =>
    // The Live socket only ever carries small control messages, so write
    // backpressure is recorded rather than acted on.
    None

  be tick(tick_id: U64) =>
    if tick_id == 0 then return end
    if (tick_id == _close_tick) and _closing then
      _close_tick = 0
      _finish_close()
      return
    end
    if _closed or _closing then return end
    if tick_id == _reconnect_tick then
      _reconnect_tick = 0
      if (not _connected) and (_stream is None) and (_states.size() > 0) then
        _connect()
      end
      return
    end
    if tick_id == _frame_tick then
      _frame_tick = 0
      // The parser holds bytes of an unfinished frame, or a handshake never
      // completed. Resuming would mean guessing at a frame boundary, so the
      // connection is abandoned instead.
      _fail_connection(
        "timed out part way through a WebSocket frame", true, true)
      return
    end
    if tick_id == _activity_tick then
      _activity_tick = 0
      _fail_connection(
        "the Convex deployment stopped responding", true, true)
    end

  fun ref _connect() =>
    _generation = _generation + 1
    _connected = false
    _handshake = None
    _frames = WsFrameParser
    _query_set_version = 0
    _remote_version = SyncStateVersion.zero()
    // Every subscription that has already delivered a value expects to be
    // rehydrated on the new connection, and an unchanged rehydration is
    // suppressed rather than delivered twice.
    for state in _states.values() do
      state.awaiting_rehydration = state.has_last
    end
    _opener.open_stream(_generation, _config.endpoint, this)

  fun ref _open_query_set(): Bool =>
    try
      let connect_message = SyncProtocol.connect_message(
        _session_id()?,
        _connection_count,
        _last_close_reason,
        _max_observed_timestamp)?
      _write_text(connect_message)?

      let ordered = _ordered_query_ids()
      if ordered.size() > 0 then
        var modifications: Array[JsonValue] iso =
          Array[JsonValue](ordered.size())
        for query_id in ordered.values() do
          let state = _states(query_id)?
          modifications.push(
            SyncProtocol.add_modification(query_id, state.path, state.args))
        end
        _write_text(
          SyncProtocol.modify_query_set(0, 1, consume modifications)?)?
        _query_set_version = 1
      end
      true
    else
      _fail_connection("could not resend the Convex query set", true, true)
      false
    end

  fun ref _send_query_set_change(modification: JsonObject) ? =>
    if _query_set_version == U32.max_value() then error end
    let modifications = recover val
      let out = Array[JsonValue](1)
      out.push(modification)
      out
    end
    _write_text(SyncProtocol.modify_query_set(
      _query_set_version, _query_set_version + 1, modifications)?)?
    _query_set_version = _query_set_version + 1

  fun ref _write_text(text: String) ? =>
    match _stream
    | let held: _StreamBox => held.stream.write(WsFrame.text(text, _mask()?)?)
    | None => error
    end

  fun ref _consume_frames(data: Array[U8] val) =>
    try
      _frames.push(data)?
    else
      _publish_protocol_error("the Convex WebSocket frame exceeded its budget")
      _fail_connection(
        "the Convex WebSocket frame exceeded its budget", true, false)
      return
    end
    while true do
      let message =
        try
          _frames.next()?
        else
          _publish_protocol_error("malformed WebSocket frame")
          _fail_connection("malformed WebSocket frame", true, false)
          return
        end
      match message
      | let frame: WsMessage =>
        if not _handle_frame(frame) then return end
      | None => break
      end
    end
    // Arm the partial-frame deadline only while a frame is genuinely
    // incomplete, so an idle but healthy connection is not torn down.
    if _frames.partial() then
      if _frame_tick == 0 then
        _frame_tick = _arm(LiveLimits.frame_deadline_ms())
      end
    else
      _disarm(_frame_tick)
      _frame_tick = 0
    end

  fun ref _handle_frame(frame: WsMessage): Bool =>
    if frame.opcode == WsOpcode.close() then
      _fail_connection(
        "the Convex deployment sent a WebSocket close", true, true)
      return false
    end
    if frame.opcode == WsOpcode.ping() then
      try
        let pong = WsFrame.pong(frame.payload, _mask()?)?
        match _stream
        | let held: _StreamBox => held.stream.write(pong)
        end
      end
      return true
    end
    if frame.opcode == WsOpcode.pong() then
      return true
    end
    if frame.opcode != WsOpcode.text() then
      _publish_protocol_error("the sync protocol carries text frames only")
      _fail_connection("unexpected binary WebSocket frame", true, false)
      return false
    end

    let decoded =
      try
        SyncProtocol.decode(frame.text())?
      else
        _publish_protocol_error("unrecognised Convex sync message")
        _fail_connection("unrecognised Convex sync message", true, false)
        return false
      end

    match decoded
    | let transition: SyncTransition =>
      if not _apply_transition(transition) then return false end
      _backoff_ms = LiveLimits.initial_backoff_ms()
    | let server_error: SyncServerError =>
      _publish_protocol_error(server_error.kind + ": " + server_error.message)
      _fail_connection(server_error.kind, true, false)
      return false
    else
      // Ping and unrelated responses are liveness, nothing more.
      _backoff_ms = LiveLimits.initial_backoff_ms()
    end
    true

  fun ref _apply_transition(transition: SyncTransition): Bool =>
    if not transition.start_version.same(_remote_version) then
      let detail: String val =
        "Transition start " + transition.start_version.describe() +
        " does not follow local " + _remote_version.describe()
      _publish_protocol_error(detail)
      _fail_connection("out of order Convex Transition", true, false)
      return false
    end

    // Validate everything that can fail before changing any subscription
    // state. A malformed final modification must not partially publish or
    // clear rehydration flags from the earlier modifications in its batch.
    try
      if SyncTimestamp.compare(
        transition.end_version.ts, transition.start_version.ts)? < 0
      then
        error
      end
      if _max_observed_timestamp.size() > 0 then
        SyncTimestamp.compare(
          transition.end_version.ts, _max_observed_timestamp)?
      end
      let seen = Map[U32, Bool]
      for modification in transition.modifications.values() do
        if seen.contains(modification.query_id) then error end
        seen(modification.query_id) = true
        if modification.kind is SyncQueryUpdated then
          JsonEncode(modification.value)?
        end
      end
    else
      _publish_protocol_error("invalid Convex Transition batch")
      _fail_connection("invalid Convex Transition batch", true, false)
      return false
    end

    let changed = Array[U32](transition.modifications.size())
    let updates = Map[U32, _LiveUpdate]
    for modification in transition.modifications.values() do
      let query_id = modification.query_id
      match modification.kind
      | SyncQueryUpdated =>
        let encoded =
          try
            JsonEncode(modification.value)?
          else
            _publish_protocol_error("could not re-encode a Convex value")
            _fail_connection("unencodable Convex value", true, false)
            return false
          end
        var suppressed = false
        try
          let state = _states(query_id)?
          if state.awaiting_rehydration then
            state.awaiting_rehydration = false
            // The reconnect produced the value the watcher already has.
            // Delivering it again would make a reconnect observable as a
            // duplicate update, so it is suppressed.
            suppressed = state.has_last and state.last_success and
              (state.last_encoded == encoded)
          end
        end
        if not suppressed then
          updates(query_id) = _LiveUpdate.value(
            ConvexResult(modification.value, modification.logs), encoded)
          changed.push(query_id)
        end
      | SyncQueryFailed =>
        try
          let state = _states(query_id)?
          state.awaiting_rehydration = false
        end
        updates(query_id) = _LiveUpdate.problem(ConvexError.function(
          modification.error_message,
          modification.error_data,
          modification.has_error_data,
          modification.logs))
        changed.push(query_id)
      | SyncQueryRemoved =>
        try
          let state = _states(query_id)?
          state.has_last = false
          state.awaiting_rehydration = false
        end
      end
    end

    // Commit the whole transition before any watcher is told about part of it.
    _remote_version = transition.end_version
    if _max_observed_timestamp.size() == 0 then
      _max_observed_timestamp = transition.end_version.ts
    else
      try
        if SyncTimestamp.compare(
          transition.end_version.ts, _max_observed_timestamp)? > 0
        then
          _max_observed_timestamp = transition.end_version.ts
        end
      else
        _publish_protocol_error("invalid Convex Transition timestamp")
        _fail_connection("invalid Convex Transition timestamp", true, false)
        return false
      end
    end

    _sort(changed)
    for query_id in changed.values() do
      try
        _enqueue(_states(query_id)?, updates(query_id)?)
      end
    end
    true

  fun ref _enqueue(state: _LiveState, update: _LiveUpdate) =>
    state.queue.push(update)
    state.queued_bytes = state.queued_bytes + update.cost
    // Drop the oldest values first. A reactive query publishes current state,
    // so the newest value is the one worth keeping when a watcher falls
    // behind. The drop is counted rather than silent.
    while (state.queue.size() > LiveLimits.max_queued_updates()) or
      ((state.queued_bytes > LiveLimits.max_queued_bytes()) and
        (state.queue.size() > 1))
    do
      try
        let dropped = state.queue.shift()?
        state.queued_bytes = state.queued_bytes - dropped.cost
        state.dropped = state.dropped + 1
      else
        break
      end
    end
    _pump(state)

  fun ref _pump(state: _LiveState) =>
    if not state.credit then return end
    if state.queue.size() == 0 then return end
    try
      let update = state.queue.shift()?
      state.queued_bytes = state.queued_bytes - update.cost
      state.credit = false
      match update.result
      | let result: ConvexResult =>
        state.has_last = true
        state.last_success = true
        state.last_encoded = update.encoded
        state.relay.deliver_result(result)
      else
        match update.failure
        | let failure: ConvexError =>
          state.has_last = true
          state.last_success = false
          state.last_encoded = ""
          state.relay.deliver_failure(failure)
        end
      end
    end

  fun ref _publish_protocol_error(message: String) =>
    """
    A protocol or transport fault is reported on every live subscription, but
    it never removes them: the reconnect that follows must be able to deliver
    a later valid value on the same subscription.
    """
    let failure = ConvexError.protocol(message)
    for state in _states.values() do
      state.has_last = false
      state.awaiting_rehydration = false
      _enqueue(state, _LiveUpdate.problem(failure))
    end

  fun ref _publish_transport_error(message: String) =>
    let failure = ConvexError.transport(message)
    for state in _states.values() do
      state.has_last = false
      state.awaiting_rehydration = false
      _enqueue(state, _LiveUpdate.problem(failure))
    end

  fun ref _fail_connection(
    reason: String,
    reconnect: Bool,
    publish_transport: Bool)
  =>
    if publish_transport then _publish_transport_error(reason) end
    match _stream
    | let held: _StreamBox => held.stream.dispose()
    end
    if _connected or (_stream isnt None) then
      _connection_count = _connection_count + 1
    end
    _stream = None
    _connected = false
    _handshake = None
    _frames = WsFrameParser
    _last_close_reason = reason
    _query_set_version = 0
    _remote_version = SyncStateVersion.zero()
    _disarm(_frame_tick)
    _frame_tick = 0
    _disarm(_activity_tick)
    _activity_tick = 0
    if _closing then
      _finish_close()
      return
    end
    if reconnect and (_states.size() > 0) and (not _closed) then
      _schedule_reconnect(_backoff_ms)
      _backoff_ms = _backoff_ms * 2
      if _backoff_ms > LiveLimits.max_backoff_ms() then
        _backoff_ms = LiveLimits.max_backoff_ms()
      end
    end

  fun ref _finish_close() =>
    if _closed then return end
    _closed = true
    _closing = false
    match _stream
    | let held: _StreamBox => held.stream.dispose()
    end
    _stream = None
    _connected = false
    _disarm(_reconnect_tick)
    _reconnect_tick = 0
    _disarm(_frame_tick)
    _frame_tick = 0
    _disarm(_activity_tick)
    _activity_tick = 0
    _disarm(_close_tick)
    _close_tick = 0
    for state in _states.values() do
      state.relay.invalidate()
    end
    _states.clear()
    _names.clear()
    match _close_callback
    | let held: _CallbackBox =>
      held.callback.convex_ok(_close_step, ConvexResult(None))
    end
    _close_callback = None

  fun ref _drop_by_name(name: String) =>
    try
      let query_id = _names(name)?
      let state = _states(query_id)?
      state.relay.invalidate()
      _states.remove(query_id)?
      _names.remove(name)?
    end

  fun ref _schedule_reconnect(delay_ms: U64) =>
    _reconnect_tick = _arm(delay_ms)

  fun ref _arm(delay_ms: U64): U64 =>
    _next_tick = _next_tick + 1
    _ticker.schedule(delay_ms, this, _next_tick)
    _next_tick

  fun ref _disarm(tick_id: U64) =>
    // Cancelling a deadline that is no longer relevant keeps a finished
    // program from waiting on a timer nobody is listening to.
    if tick_id != 0 then _ticker.cancel(this, tick_id) end

  fun ref _ordered_query_ids(): Array[U32] =>
    let ids = Array[U32](_states.size())
    for query_id in _states.keys() do
      ids.push(query_id)
    end
    _sort(ids)
    ids

  fun ref _sort(ids: Array[U32]) =>
    // Insertion sort. Query sets here are small, and a stable, obvious order
    // matters more than asymptotics: replay and delivery must both be
    // deterministic for the reconnect tests to mean anything.
    var index: USize = 1
    while index < ids.size() do
      try
        let value = ids(index)?
        var position = index
        while (position > 0) and (ids(position - 1)? > value) do
          ids(position)? = ids(position - 1)?
          position = position - 1
        end
        ids(position)? = value
      end
      index = index + 1
    end

  fun ref _mask(): Array[U8] val ? =>
    // RFC 6455 requires every client frame to carry a fresh masking key.
    SecureRandom.bytes(4)?

  fun ref _websocket_key(): String ? =>
    Base64Codec.encode(SecureRandom.bytes(16)?)

  fun ref _session_id(): String ? =>
    if _session.size() > 0 then return _session end
    let random = SecureRandom.bytes(16)?
    var raw: Array[U8] iso = Array[U8](16)
    var index: USize = 0
    while index < random.size() do
      var byte = random(index)?
      if index == 6 then byte = (byte and 0x0f) or 0x40 end
      if index == 8 then byte = (byte and 0x3f) or 0x80 end
      raw.push(byte)
      index = index + 1
    end
    let bytes: Array[U8] val = consume raw
    let hex = Hex.encode(bytes)
    // Convex expects a UUID shaped session identifier.
    _session = HttpText.slice(hex, 0, 8) + "-" +
      HttpText.slice(hex, 8, 12) + "-" + HttpText.slice(hex, 12, 16) + "-" +
      HttpText.slice(hex, 16, 20) + "-" + HttpText.slice(hex, 20, 32)
    _session
