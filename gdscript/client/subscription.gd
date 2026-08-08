class_name ConvexSubscription
extends RefCounted

# One reactive Convex query. The Live owner in live.gd is the only thing that
# writes to this object; everything here either reads the queue or asks the
# owner to do socket work on the caller's behalf.
#
# The queue is deliberately bounded. A reactive query only ever needs its most
# recent state, so when a slow consumer falls behind, the oldest update is
# dropped and counted rather than allowed to grow without limit. dropped()
# makes that visible instead of silent.

const MAX_QUEUED_UPDATES := 16
const MAX_QUEUED_BYTES := 16 * 1024 * 1024
const POLL_DELAY_MSEC := 1

# Deliberately untyped. The owner is a ConvexLive, but naming both classes in
# each other's annotations is a cyclic dependency Godot refuses to resolve
# while parsing, and a RefCounted annotation would make every call back into
# the owner a compile error instead.
var _owner
var _query_id: int
var _updates: Array = []
var _queued_bytes: int = 0
var _dropped: int = 0
var _finished: bool = false
var _closed: bool = false


func _init(owner: RefCounted, query_id: int) -> void:
	_owner = owner
	_query_id = query_id


func query_id() -> int:
	return _query_id


func dropped() -> int:
	return _dropped


func is_finished() -> bool:
	return _finished


func pending() -> int:
	return _updates.size()


# Take the next update if one is already queued, without doing any socket
# work. An empty dictionary means nothing was waiting; the conformance adapter
# uses this from its own poll loop.
func try_next_update() -> Dictionary:
	if _updates.is_empty():
		return {}
	return _take()


# Wait for the next update, driving the Live owner while waiting. The returned
# dictionary is an ordinary result: a delivered query value, a structured
# query failure, or a transport failure when the deadline passes first.
func next_update(timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not _updates.is_empty():
			return _take()
		if _finished:
			return ConvexResult.closed_failure("Live subscription is closed")
		_owner.poll()
		OS.delay_msec(POLL_DELAY_MSEC)
	if not _updates.is_empty():
		return _take()
	return ConvexResult.transport_failure("timed out waiting for a Live update")


# Stop this query. The owner invalidates the relay before it acknowledges, so
# no update produced before this call can still be observed afterwards.
func close() -> Dictionary:
	if _closed:
		return ConvexResult.ok(true)
	_closed = true
	return _owner.unsubscribe(_query_id)


# Called by the Live owner only. It is spelled without a leading underscore
# because it genuinely crosses an object boundary, and the name says who is
# allowed to use it.
func apply_update_from_owner(update: Dictionary, encoded_bytes: int) -> void:
	if _finished:
		return
	# The decoded Dictionary/Array graph costs more than the packet text. Four
	# times the wire size plus fixed entry overhead is a conservative charge.
	var accounted := maxi((encoded_bytes * 4) + 4096, 4096)
	while not _updates.is_empty() and _would_overflow(accounted):
		var oldest: Dictionary = _updates.pop_front()
		_queued_bytes -= oldest["bytes"]
		_dropped += 1
	var entry := {"update": update, "bytes": accounted}
	_updates.push_back(entry)
	_queued_bytes += accounted


# Called by the Live owner only, before it acknowledges an unsubscribe, a
# same-id replacement, or a client close. Dropping the queue here is what
# makes a stale update impossible to observe across the acknowledgement.
func finish_from_owner() -> void:
	if _finished:
		return
	_finished = true
	_updates.clear()
	_queued_bytes = 0


func _would_overflow(accounted: int) -> bool:
	if _updates.size() >= MAX_QUEUED_UPDATES:
		return true
	return _queued_bytes + accounted > MAX_QUEUED_BYTES


func _take() -> Dictionary:
	var entry: Dictionary = _updates.pop_front()
	_queued_bytes -= entry["bytes"]
	return entry["update"]
