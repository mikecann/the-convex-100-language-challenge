use "collections"
use "../../../../client"

use @write[ISize](fd: I32, buffer: Pointer[U8] tag, count: USize)
use @fcntl[I32](fd: I32, command: I32, argument: I32)

// The adapter's single writer.
//
// Two separate things are enforced here. Ordering: every line the adapter ever
// emits passes through this one actor, so a relay event and the acknowledgement
// that retires that relay have a total order and cannot cross. Memory: the
// process must stay well below the shared 128 MiB limit even with a controller
// that has stopped reading. Stdio fails on a full non-blocking pipe, and the
// TCP notifier retires a socket as soon as Pony reports retained writes.

primitive AdapterOutputLimits
  """
  Deliberately small. Live delivery is already one update in flight per
  subscription, so this queue only ever holds a handful of records, and the
  budget is a second, independent guarantee rather than the working size.
  """

  fun max_records(): USize => 16
  fun max_bytes(): USize => 8 * 1024 * 1024
  fun record_overhead(): USize => 1024
  fun max_line_bytes(): USize => 4 * 1024 * 1024

interface OutputWriter
  """
  Writes one already encoded line, terminator included. Returns false once the
  destination is permanently broken.
  """
  fun ref write(text: String): Bool

  fun ref dispose()
    """
    Closes the destination once nothing more will ever be written.

    For a socket this must happen after the final `write` has actually been
    handed to the connection actor, and from the same sender, so the two
    messages keep their order: a `dispose` sent from a different actor than
    the one that sent the final `write` could overtake it and the last event
    - typically `closed` - would never reach the controller.
    """

class iso StdoutWriter is OutputWriter
  """
  Bounded non-blocking writes to file descriptor one.

  Going through the standard output actor would let a stopped controller grow
  that actor's mailbox without limit. Descriptor one is switched to
  `O_NONBLOCK`, so a stopped reader fails the adapter instead of pinning this
  actor inside libc where a close command could never cancel it.
  """

  var _broken: Bool = false

  new iso create() =>
    // These are the Linux F_GETFL, F_SETFL and O_NONBLOCK values. The adapter
    // image is deliberately Linux-only and the Dockerfile verifies this path.
    let flags = @fcntl(I32(1), I32(3), I32(0))
    if (flags < 0) or (@fcntl(I32(1), I32(4), flags or I32(0x800)) < 0) then
      _broken = true
    end

  fun ref write(text: String): Bool =>
    if _broken then return false end
    let data = Bytes.of_string(text)
    var offset: USize = 0
    while offset < data.size() do
      let written = @write(I32(1), data.cpointer(offset), data.size() - offset)
      if written <= 0 then
        _broken = true
        return false
      end
      offset = offset + written.usize()
    end
    true

  fun ref dispose() =>
    // Descriptor one belongs to the process, not to this writer; there is
    // nothing to release beyond letting the process exit normally.
    None

class iso StreamWriter is OutputWriter
  """
  Writes to the controller's TCP connection. Backpressure arrives out of band
  as a throttle notification, which retires the controller socket.
  """

  let _stream: Stream

  new iso create(stream: Stream) =>
    _stream = stream

  fun ref write(text: String): Bool =>
    _stream.write(text)
    true

  fun ref dispose() =>
    _stream.dispose()

actor AdapterOutput
  let _writer: OutputWriter
  let _exit: AdapterExit
  let _active: Map[String, U64] = Map[String, U64]
  let _pending: Array[String] = Array[String]
  var _pending_bytes: USize = 0
  var _paused: Bool = false
  var _accepting: Bool = true
  var _broken: Bool = false
  var _dropped: USize = 0

  new create(writer: OutputWriter iso, exit': AdapterExit) =>
    _writer = consume writer
    _exit = exit'

  be activate_relay(subscription_id: String, generation: U64) =>
    _active(subscription_id) = generation

  be invalidate_relay(subscription_id: String, generation: U64) =>
    """
    Retires a relay. Because this arrives in the same queue as the events that
    relay produces and as the acknowledgement that follows, an event from the
    retired generation can never appear after the acknowledgement.
    """
    try
      if _active(subscription_id)? == generation then
        _active.remove(subscription_id)?
      end
    end

  be emit(line: String) =>
    _write(line)

  be emit_relay(
    subscription_id: String,
    generation: U64,
    line: String,
    relay: AdapterRelay)
  =>
    if _current(subscription_id) == generation then
      _write(line)
    end
    // The relay is told either way, so a dropped stale event still releases
    // the credit that keeps delivery moving.
    relay.output_drained()

  be pause() =>
    _paused = true

  be resume() =>
    _paused = false
    _drain()

  be stop() =>
    _accepting = false
    _drain()

  be finish() =>
    """
    The adapter is shutting down for good: nothing more will ever be
    written, so the destination can be closed now. Because this actor is
    the one that sent every prior `write`, the `dispose` below is sent from
    that same actor and therefore queues strictly after them - the last
    event a caller emitted just before calling this is guaranteed to reach
    the destination before it closes.
    """
    _accepting = false
    _drain()
    _writer.dispose()

  fun ref _current(subscription_id: String): U64 =>
    try _active(subscription_id)? else 0 end

  fun ref _write(line: String) =>
    if _broken or (not _accepting) then return end
    if line.size() > AdapterOutputLimits.max_line_bytes() then
      // A record this large is a fault in the client, not a legitimate value.
      _dropped = _dropped + 1
      return
    end
    if _paused or (_pending.size() > 0) then
      _enqueue(line)
      _drain()
      return
    end
    if not _writer.write(line + "\n") then _break() end

  fun ref _enqueue(line: String) =>
    let cost = line.size() + AdapterOutputLimits.record_overhead()
    if (_pending.size() >= AdapterOutputLimits.max_records()) or
      ((_pending_bytes + cost) > AdapterOutputLimits.max_bytes())
    then
      _dropped = _dropped + 1
      return
    end
    _pending.push(line)
    _pending_bytes = _pending_bytes + cost

  fun ref _drain() =>
    while (not _paused) and (not _broken) and (_pending.size() > 0) do
      try
        let line = _pending.shift()?
        _pending_bytes = _pending_bytes -
          (line.size() + AdapterOutputLimits.record_overhead())
        if not _writer.write(line + "\n") then _break() end
      else
        break
      end
    end

  fun ref _break() =>
    if _broken then return end
    _broken = true
    _accepting = false
    _pending.clear()
    _pending_bytes = 0
    _exit.adapter_finished(1)

actor AdapterRelay
  """
  One Live subscription's relay.

  It is the client's watcher and the output's producer, and it holds the
  generation that lets `AdapterOutput` discard anything from a subscription
  identifier that has since been replaced or removed. Exactly one event is in
  flight at a time: the next update is requested only after the output has
  dealt with the previous one.
  """

  let _output: AdapterOutput
  let _subscription_id: String
  let _generation: U64
  var _handle: (LiveHandle | None) = None

  new create(
    output: AdapterOutput,
    subscription_id: String,
    generation: U64)
  =>
    _output = output
    _subscription_id = subscription_id
    _generation = generation

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    _handle = handle
    try
      _output.emit_relay(
        _subscription_id,
        _generation,
        AdapterEvents.subscription_value(
          _subscription_id, result.value, result.logs)?,
        this)
    else
      _emit_failure(ConvexError.protocol(
        "a Live value could not be encoded for the adapter stream"))
    end

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    _handle = handle
    _emit_failure(error')

  be output_drained() =>
    match _handle
    | let handle: LiveHandle => handle.request_next()
    end

  fun ref _emit_failure(error': ConvexError) =>
    try
      _output.emit_relay(
        _subscription_id,
        _generation,
        AdapterEvents.subscription_failure(_subscription_id, error')?,
        this)
    end
