extends SceneTree

# The adapter's output queue: ordering, both bounds, the flush deadline, and
# the memory ceiling with a controller that has stopped reading.

const NEAR_MAXIMUM_BYTES := 2 * 1024 * 1024


# A controller that has stopped reading. Every write is accepted as zero bytes
# of progress, which is what a full socket buffer looks like.
class StalledStream:
	extends RefCounted

	var closed := false

	func send(_bytes: PackedByteArray, _text: String) -> int:
		return 0

	func close() -> void:
		closed = true


class RecordingStream:
	extends RefCounted

	var lines: Array = []

	func send(bytes: PackedByteArray, text: String) -> int:
		lines.push_back(text)
		return bytes.size()

	func close() -> void:
		pass


func _init() -> void:
	var harness := ConvexTestHarness.new("adapter output")
	_test_ordering(harness)
	_test_event_limit(harness)
	_test_byte_limit(harness)
	_test_flush_deadline(harness)
	_test_unserializable_event(harness)
	_test_memory_ceiling(harness)
	quit(harness.report())


func _test_ordering(harness: ConvexTestHarness) -> void:
	var stream := RecordingStream.new()
	var output := ConvexAdapterOutput.new(stream)
	output.enqueue({"id": "1", "type": "ack"})
	output.enqueue({"id": "2", "type": "ack"})
	harness.check(output.pending_events() == 2, "events queue before they are written")
	harness.succeeded(output.flush(1000), "a reading controller drains the queue")
	harness.check(output.pending_events() == 0, "the queue empties")
	harness.check(stream.lines.size() == 2, "one line per event")
	var first := ConvexValues.parse_object(stream.lines[0], "line")
	harness.equal(first["value"]["id"], "1", "events keep their order")
	harness.check(not stream.lines[0].contains("\n"), "an event is exactly one NDJSON line")


func _test_event_limit(harness: ConvexTestHarness) -> void:
	var stream := StalledStream.new()
	var output := ConvexAdapterOutput.new(stream)
	var refused := {}
	for index in ConvexAdapterOutput.MAX_PENDING_EVENTS + 1:
		refused = output.enqueue({"id": str(index), "type": "ack"})
	harness.failed(refused, "TransportError", "the event limit ends in a transport failure")
	harness.check(output.has_failed(), "the queue stays failed once it overflows")
	# Closing the stalled stream is what wakes a writer blocked on a stopped
	# reader, so the failure is reported instead of deadlocking.
	harness.check(stream.closed, "the stalled stream is closed on overflow")
	var data: Dictionary = refused["error"]["data"]
	harness.check(data["maxPendingEvents"] == ConvexAdapterOutput.MAX_PENDING_EVENTS, "limit named")


func _test_byte_limit(harness: ConvexTestHarness) -> void:
	var stream := StalledStream.new()
	var output := ConvexAdapterOutput.new(stream, {"max_bytes": 64 * 1024})
	var refused := {}
	for index in 8:
		refused = output.enqueue({"id": str(index), "type": "result", "value": "x".repeat(16384)})
	harness.failed(refused, "TransportError", "the byte limit ends in a transport failure")
	var message := ConvexResult.error_message(refused)
	harness.check(message.contains("byte limit"), "the failure names the byte budget")
	var data: Dictionary = refused["error"]["data"]
	harness.check(data["attemptedBytes"] > 16384, "the rejected size is reported")
	# An event limit alone would not have stopped this: eight events is well
	# inside the count bound.
	harness.check(output.pending_events() < ConvexAdapterOutput.MAX_PENDING_EVENTS, "count unused")


func _test_flush_deadline(harness: ConvexTestHarness) -> void:
	var output := ConvexAdapterOutput.new(StalledStream.new())
	output.enqueue({"id": "1", "type": "ack"})
	var started := Time.get_ticks_msec()
	var flushed := output.flush(200)
	var elapsed := Time.get_ticks_msec() - started
	harness.failed(flushed, "TransportError", "a stalled write ends at the deadline")
	harness.check(elapsed < 2000, "the flush deadline bounded the write (%d ms)" % elapsed)


# Godot's lax JSON parsing can produce an infinity, and JSON.stringify would
# then emit a bare token no strict reader accepts.
func _test_unserializable_event(harness: ConvexTestHarness) -> void:
	var stream := RecordingStream.new()
	var output := ConvexAdapterOutput.new(stream)
	var refused := output.enqueue({"id": "1", "type": "result", "value": INF})
	harness.failed(refused, "ProtocolError", "a non-JSON-safe event is refused")
	harness.check(not output.has_failed(), "one bad event does not fail the whole queue")
	harness.succeeded(output.enqueue({"id": "2", "type": "ack"}), "the queue still accepts events")


# The count bound is not a memory bound when a single Convex value can be
# close to the maximum Live frame. With a reader that has stopped, the queue
# stops well below the shared 128 MiB limit.
func _test_memory_ceiling(harness: ConvexTestHarness) -> void:
	var stream := StalledStream.new()
	var output := ConvexAdapterOutput.new(stream)
	var refused := {}
	var accepted := 0
	while not output.has_failed() and accepted < 64:
		var event := {"id": str(accepted), "type": "result"}
		event["value"] = "x".repeat(NEAR_MAXIMUM_BYTES)
		refused = output.enqueue(event)
		if not ConvexResult.is_failure(refused):
			accepted += 1
	harness.failed(refused, "TransportError", "near-maximum values stop at the byte budget")
	harness.check(accepted < 5, "only a few maximum-sized events fit (%d)" % accepted)
	var ceiling := ConvexAdapterOutput.MAX_PENDING_BYTES
	harness.check(output.pending_bytes() <= ceiling, "retained bytes never exceed the budget")
	# The whole adapter's retained ceiling is this queue plus one inbound Live
	# frame plus one HTTP response body, which is an order of magnitude below
	# the 128 MiB the shared harness allows.
	var total := ceiling + ConvexSubscription.MAX_QUEUED_BYTES
	total += ConvexLive.INBOUND_BUFFER_BYTES + ConvexHttp.MAX_RESPONSE_BYTES
	harness.check(total < 32 * 1024 * 1024, "the adapter's whole budget stays far below 128 MiB")
