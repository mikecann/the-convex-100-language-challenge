class_name ConvexAdapterOutput
extends RefCounted

# The adapter's only writer.
#
# Every protocol event goes through this queue, and the queue is bounded twice
# over. A count limit alone is not a memory limit when one Convex value can
# approach the maximum Live frame size, so the byte budget below accounts for
# the encoded line, the line break, and a conservative per-entry allowance for
# the GDScript objects that hold it. The in-flight entry stays in the queue
# until it is fully written, so a controller that has stopped reading is
# counted rather than ignored.
#
# Worst case retained here is MAX_PENDING_BYTES. Live and HTTP have separate
# conservative budgets, so stopped-reader verification measures the real final
# process as well as checking these source-level ceilings.

const MAX_PENDING_EVENTS := 64
const MAX_PENDING_BYTES := 8 * 1024 * 1024
const ENTRY_OVERHEAD := 256
const FLUSH_DELAY_MSEC := 1

# Untyped because the two stream implementations are duck-typed rather than
# a shared base class: standard output and one accepted TCP connection.
var _stream
var _queue: Array = []
var _pending_bytes: int = 0
var _offset: int = 0
var _failure: Dictionary = {}
var _max_events: int
var _max_bytes: int


func _init(stream: RefCounted, options: Dictionary = {}) -> void:
	_stream = stream
	_max_events = options.get("max_events", MAX_PENDING_EVENTS)
	_max_bytes = options.get("max_bytes", MAX_PENDING_BYTES)


func pending_events() -> int:
	return _queue.size()


func pending_bytes() -> int:
	return _pending_bytes


func has_failed() -> bool:
	return not _failure.is_empty()


func failure() -> Dictionary:
	return _failure


# Encode and queue one event. Nothing here waits for capacity: the Live owner
# may be producing the very event that would let the controller drain, so a
# full queue becomes a bounded transport failure instead of a deadlock.
func enqueue(event: Dictionary) -> Dictionary:
	if has_failed():
		return _failure
	# Godot's JSON parser can produce an infinity from a lax numeric literal,
	# and JSON.stringify would then emit a bare token no strict reader
	# accepts. Refusing it here keeps every emitted line parseable.
	if not ConvexValues.is_json_safe(event):
		return ConvexResult.protocol_failure("adapter event is not JSON-safe")
	if _queue.size() >= _max_events:
		return _overflow("event limit", 0)
	var text := JSON.stringify(event)
	var bytes := (text + "\n").to_utf8_buffer()
	var accounted := bytes.size() + ENTRY_OVERHEAD
	if _pending_bytes + accounted > _max_bytes:
		return _overflow("byte limit", accounted)
	var entry := {"text": text, "bytes": bytes, "accounted": accounted}
	_queue.push_back(entry)
	_pending_bytes += accounted
	return ConvexResult.ok(true)


# Write everything queued, bounded by a deadline. A partially written line
# keeps its offset so the stream is never restarted in the middle of an event.
func flush(timeout_msec: int) -> Dictionary:
	if has_failed():
		return _failure
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not _queue.is_empty():
		var entry: Dictionary = _queue[0]
		var bytes: PackedByteArray = entry["bytes"]
		var chunk := bytes.slice(_offset) if _offset > 0 else bytes
		var sent: int = _stream.send(chunk, entry["text"])
		if sent < 0:
			return _fail("write adapter event failed")
		_offset += sent
		if _offset >= bytes.size():
			_queue.pop_front()
			_pending_bytes -= entry["accounted"]
			_offset = 0
			continue
		if Time.get_ticks_msec() >= deadline:
			return _fail("timed out writing adapter event")
		OS.delay_msec(FLUSH_DELAY_MSEC)
	return ConvexResult.ok(true)


func _fail(message: String) -> Dictionary:
	_failure = ConvexResult.transport_failure(message)
	return _failure


# Overflow is reported with the numbers that produced it, so a controller sees
# why the adapter gave up rather than a bare timeout. Closing the stream also
# wakes a writer that is blocked on a stopped reader.
func _overflow(limit: String, attempted: int) -> Dictionary:
	var data := {"maxPendingEvents": _max_events, "maxPendingBytes": _max_bytes}
	data["pendingEvents"] = _queue.size()
	data["pendingBytes"] = _pending_bytes
	data["attemptedBytes"] = attempted
	var message := "adapter output queue exceeded its %s" % limit
	_failure = ConvexResult.failure(ConvexResult.TRANSPORT_ERROR, message, data)
	_stream.close()
	return _failure
