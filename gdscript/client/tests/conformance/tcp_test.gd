extends SceneTree

# The adapter's TCP transport, end to end, as a separate process.
#
# The shared harness runs the client and the controller in different
# containers and connects them over TCP, so this test does the same thing in
# miniature: it starts the real conformance executable with ADAPTER_LISTEN
# set, speaks NDJSON to it over a socket, and checks that the process shuts
# down by itself after close.

const PORT := 39191
const CONNECT_MSEC := 20000
const READ_MSEC := 20000
const EXIT_MSEC := 10000
const POLL_DELAY_MSEC := 5


func _init() -> void:
	var harness := ConvexTestHarness.new("adapter tcp")
	# The adapter is not given a deployment, so this exercises the transport
	# and the lifecycle rather than any Convex call.
	OS.set_environment("CONVEX_URL", "")
	OS.set_environment("ADAPTER_LISTEN", "127.0.0.1:%d" % PORT)
	var pid := OS.create_process(OS.get_executable_path(), _adapter_arguments())
	# Clear it immediately so nothing else in this process inherits the value.
	OS.set_environment("ADAPTER_LISTEN", "")
	if not harness.check(pid > 0, "the adapter starts as its own process"):
		quit(harness.report())
		return

	var peer := _connect()
	if not harness.check(peer != null, "the controller connects to the adapter"):
		OS.kill(pid)
		quit(harness.report())
		return

	_send(peer, {"protocolVersion": 1, "id": "h", "op": "hello"})
	var ready := _read_event(peer)
	harness.equal(ready.get("type"), "ready", "the adapter answers hello over TCP")
	harness.equal(ready.get("language"), "gdscript", "the ready event names the language")

	_send(peer, {"id": "c", "op": "close"})
	var closed := _read_event(peer)
	harness.equal(closed.get("type"), "closed", "close is acknowledged over TCP")
	harness.equal(closed.get("id"), "c", "the closed event echoes the request id")

	peer.disconnect_from_host()
	harness.check(_wait_for_exit(pid), "the adapter exits by itself after close")
	if OS.is_process_running(pid):
		OS.kill(pid)
	quit(harness.report())


func _adapter_arguments() -> PackedStringArray:
	var arguments := PackedStringArray(["--headless"])
	arguments.append("--path")
	arguments.append(ProjectSettings.globalize_path("res://"))
	arguments.append("--script")
	arguments.append("res://client/tests/conformance/adapter.gd")
	return arguments


func _connect() -> StreamPeerTCP:
	var deadline := Time.get_ticks_msec() + CONNECT_MSEC
	while Time.get_ticks_msec() < deadline:
		var peer := StreamPeerTCP.new()
		if peer.connect_to_host("127.0.0.1", PORT) == OK:
			while Time.get_ticks_msec() < deadline:
				peer.poll()
				var status := peer.get_status()
				if status == StreamPeerTCP.STATUS_CONNECTED:
					peer.set_no_delay(true)
					return peer
				if status == StreamPeerTCP.STATUS_ERROR:
					break
				OS.delay_msec(POLL_DELAY_MSEC)
		OS.delay_msec(POLL_DELAY_MSEC)
	return null


func _send(peer: StreamPeerTCP, command: Dictionary) -> void:
	peer.put_data((JSON.stringify(command) + "\n").to_utf8_buffer())


func _read_event(peer: StreamPeerTCP) -> Dictionary:
	var buffer := PackedByteArray()
	var deadline := Time.get_ticks_msec() + READ_MSEC
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			var received: Array = peer.get_partial_data(available)
			if received[0] == OK:
				buffer.append_array(received[1])
		var separator := buffer.find(10)
		if separator >= 0:
			var line := buffer.slice(0, separator).get_string_from_utf8()
			var parsed := ConvexValues.parse_object(line, "adapter event")
			if ConvexResult.is_failure(parsed):
				return {}
			return parsed["value"]
		OS.delay_msec(POLL_DELAY_MSEC)
	return {}


func _wait_for_exit(pid: int) -> bool:
	var deadline := Time.get_ticks_msec() + EXIT_MSEC
	while Time.get_ticks_msec() < deadline:
		if not OS.is_process_running(pid):
			return true
		OS.delay_msec(POLL_DELAY_MSEC)
	return false
