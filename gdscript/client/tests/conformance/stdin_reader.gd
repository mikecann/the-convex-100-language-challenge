class_name ConvexStdinReader
extends RefCounted

# Line-oriented standard input for the adapter, on a helper thread.
#
# This exists because of a real Godot limitation, not a stylistic choice.
# Godot 4.4 offers OS.read_buffer_from_stdin(buffer_size) and
# OS.read_string_from_stdin(buffer_size), and the class reference states that
# when standard input is a pipe, both block until the requested number of
# bytes has been read or the pipe closes. There is no readiness query, no
# non-blocking mode, and no way to cancel a read in progress. Three
# consequences follow, and all three are deliberate here:
#
# 1. The read has to happen off the main loop, or a quiet controller would
#    stop the Live owner from polling its WebSocket.
# 2. On a pipe the request size has to be one byte. Asking for more would
#    block until that many bytes arrive, which a line-oriented protocol has no
#    reason to send, so the adapter would hang holding a complete command. On
#    a regular file the same call returns early at end of file, so the reader
#    uses a large chunk there instead.
# 3. A thread parked inside a read cannot be woken. After the controller's
#    close command the adapter waits briefly for end of file and then stops
#    without joining, which stop() reports rather than hides.
#
# The shared harness uses the TCP transport, where Godot's socket API is
# properly non-blocking. Standard input remains supported for a controller
# that prefers pipes, with the throughput cost described above.

const PIPE_CHUNK_BYTES := 1
const FILE_CHUNK_BYTES := 65536
const MAX_LINE_BYTES := 2 * 1024 * 1024
const MAX_QUEUED_BYTES := 2 * 1024 * 1024
const LINE_OVERHEAD_BYTES := 256
const STOP_DELAY_MSEC := 1

var _mutex := Mutex.new()
var _thread: Thread = null
var _lines: Array = []
var _buffer := PackedByteArray()
var _queued_bytes := 0
var _eof := false
var _overflowed := false
var _chunk_bytes := PIPE_CHUNK_BYTES


func start() -> void:
	if OS.get_stdin_type() == OS.STD_HANDLE_FILE:
		_chunk_bytes = FILE_CHUNK_BYTES
	_thread = Thread.new()
	_thread.start(_read_loop)


# Hand over every complete line received so far. The Convex client is only
# ever touched by the main loop, so the reader thread's whole job is to move
# bytes into this queue.
func take_lines() -> Array:
	_mutex.lock()
	var lines := _lines
	_lines = []
	_queued_bytes = 0
	_mutex.unlock()
	return lines


func is_finished() -> bool:
	_mutex.lock()
	var finished := _eof or _overflowed
	_mutex.unlock()
	return finished


func has_overflowed() -> bool:
	_mutex.lock()
	var overflowed := _overflowed
	_mutex.unlock()
	return overflowed


# Join the reader if it has already reached end of file. Returns false when the
# thread is still parked in a read that cannot be interrupted, which lets the
# caller report the situation instead of blocking the process shutdown.
func stop(deadline_msec: int) -> bool:
	if _thread == null:
		return true
	var deadline := Time.get_ticks_msec() + deadline_msec
	while _thread.is_alive() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(STOP_DELAY_MSEC)
	if _thread.is_alive():
		return false
	_thread.wait_to_finish()
	_thread = null
	return true


func _read_loop() -> void:
	while true:
		var chunk := OS.read_buffer_from_stdin(_chunk_bytes)
		if chunk.is_empty():
			_mutex.lock()
			_eof = true
			_mutex.unlock()
			return
		if not _consume(chunk):
			return


# Split on line breaks and refuse a line that would grow without bound. A
# controller that never sends a newline cannot make this buffer consume the
# adapter's whole memory budget.
func _consume(chunk: PackedByteArray) -> bool:
	for index in chunk.size():
		var byte := chunk[index]
		if byte == 10:
			var line := _buffer.get_string_from_utf8()
			if line.to_utf8_buffer() != _buffer:
				line = "{"
			var accounted := _buffer.size() + LINE_OVERHEAD_BYTES
			_buffer = PackedByteArray()
			_mutex.lock()
			if _queued_bytes + accounted > MAX_QUEUED_BYTES:
				_overflowed = true
				_mutex.unlock()
				return false
			_lines.push_back(line)
			_queued_bytes += accounted
			_mutex.unlock()
			continue
		if byte == 13:
			continue
		if _buffer.size() >= MAX_LINE_BYTES:
			_mutex.lock()
			_overflowed = true
			_mutex.unlock()
			return false
		_buffer.push_back(byte)
	return true
