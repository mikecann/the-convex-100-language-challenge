class_name ConvexAdapterMain
extends SceneTree

# The test-only conformance executable.
#
# It carries NDJSON adapter protocol v1 over either transport the shared
# contract allows. With ADAPTER_LISTEN set it listens on that address and
# accepts one controller connection, which is the mode the isolated Docker
# harness uses. With ADAPTER_LISTEN unset it uses standard input and standard
# output, where Godot's blocking stdin API forces the helper thread described
# in stdin_reader.gd.
#
# Standard output carries protocol events only. Every diagnostic goes to
# standard error.

const IDLE_DELAY_MSEC := 2
const FLUSH_TIMEOUT_MSEC := 1000
const ACCEPT_TIMEOUT_MSEC := 300000
const READER_STOP_MSEC := 500
const MAX_BUFFERED_INPUT_BYTES := 2 * 1024 * 1024
const READ_CHUNK_BYTES := 65536


func _init() -> void:
	quit(_run())


func _run() -> int:
	var listen := OS.get_environment("ADAPTER_LISTEN")
	if listen.is_empty():
		return _run_stdio()
	return _run_tcp(listen)


func _run_stdio() -> int:
	var output := ConvexAdapterOutput.new(ConvexStdoutStream.new())
	var session := ConvexAdapterSession.new(output)
	var reader := ConvexStdinReader.new()
	var exit_code := 0
	reader.start()
	while not session.is_closed():
		for line in reader.take_lines():
			session.handle_line(line)
		session.pump_live()
		if not _flush(output):
			exit_code = 1
			break
		if session.is_closed():
			break
		if reader.has_overflowed():
			printerr("convex-adapter: standard input line exceeded its byte limit")
			session.finish_from_eof()
			break
		if reader.is_finished():
			# End of input still has to drain whatever arrived with it before
			# the session is torn down.
			for line in reader.take_lines():
				session.handle_line(line)
			session.finish_from_eof()
			break
		OS.delay_msec(IDLE_DELAY_MSEC)
	_flush(output)
	if not reader.stop(READER_STOP_MSEC):
		# Godot cannot cancel a blocking read, so a controller that keeps the
		# pipe open after close leaves the helper thread parked. Say so rather
		# than pretending shutdown was clean.
		printerr("convex-adapter: standard input reader is still blocked; exiting anyway")
	return exit_code


func _run_tcp(address: String) -> int:
	var separator := address.rfind(":")
	if separator <= 0:
		printerr("convex-adapter: ADAPTER_LISTEN must be host:port")
		return 2
	var port_text := address.substr(separator + 1)
	if not port_text.is_valid_int():
		printerr("convex-adapter: ADAPTER_LISTEN port must be numeric")
		return 2
	var server := TCPServer.new()
	var listening := server.listen(port_text.to_int(), address.substr(0, separator))
	if listening != OK:
		printerr("convex-adapter: cannot listen on %s: %d" % [address, listening])
		return 2

	var peer := _accept(server)
	if peer == null:
		printerr("convex-adapter: no controller connected before the accept deadline")
		server.stop()
		return 2
	peer.set_no_delay(true)
	var output := ConvexAdapterOutput.new(ConvexTcpStream.new(peer))
	var session := ConvexAdapterSession.new(output)
	var status := _serve(peer, session, output)
	_flush(output)
	peer.disconnect_from_host()
	server.stop()
	return status


func _serve(peer: StreamPeerTCP, session: ConvexAdapterSession, output: ConvexAdapterOutput) -> int:
	var buffer := PackedByteArray()
	var exit_code := 0
	while not session.is_closed():
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			# The controller went away. That is an ordinary end of stream, so
			# the session is released without acknowledging anything.
			session.finish_from_eof()
			exit_code = 1
			break
		var available := mini(peer.get_available_bytes(), READ_CHUNK_BYTES)
		if available > 0:
			var received: Array = peer.get_partial_data(available)
			if received[0] != OK:
				printerr("convex-adapter: read failed: %d" % received[0])
				session.finish_from_eof()
				exit_code = 1
				break
			var chunk: PackedByteArray = received[1]
			if buffer.size() + chunk.size() > MAX_BUFFERED_INPUT_BYTES:
				printerr("convex-adapter: buffered command exceeded its byte limit")
				session.finish_from_eof()
				exit_code = 1
				break
			buffer.append_array(chunk)
		var split := _split_lines(buffer)
		buffer = split["rest"]
		# A controller that never sends a line break cannot make this buffer
		# grow without bound.
		if buffer.size() > MAX_BUFFERED_INPUT_BYTES:
			printerr("convex-adapter: buffered command exceeded its byte limit")
			session.finish_from_eof()
			exit_code = 1
			break
		for line in split["lines"]:
			session.handle_line(line)
		session.pump_live()
		if not _flush(output):
			exit_code = 1
			break
		if not session.is_closed():
			OS.delay_msec(IDLE_DELAY_MSEC)
	return exit_code


func _flush(output: ConvexAdapterOutput) -> bool:
	var flushed := output.flush(FLUSH_TIMEOUT_MSEC)
	if ConvexResult.is_failure(flushed):
		printerr("convex-adapter: %s" % ConvexResult.error_message(flushed))
		return false
	return true


static func _accept(server: TCPServer) -> StreamPeerTCP:
	var deadline := Time.get_ticks_msec() + ACCEPT_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if server.is_connection_available():
			return server.take_connection()
		OS.delay_msec(IDLE_DELAY_MSEC)
	return null


# Split whatever whole lines the buffer holds and return the unconsumed tail.
# PackedByteArray is a value type in GDScript, so the remainder is handed back
# rather than trimmed in place.
static func _split_lines(buffer: PackedByteArray) -> Dictionary:
	var lines := []
	var start := 0
	for index in buffer.size():
		if buffer[index] != 10:
			continue
		var line_bytes := buffer.slice(start, index)
		var line := line_bytes.get_string_from_utf8()
		if line.to_utf8_buffer() != line_bytes:
			line = "{"
		lines.append(line.trim_suffix("\r"))
		start = index + 1
	return {"lines": lines, "rest": buffer.slice(start)}
