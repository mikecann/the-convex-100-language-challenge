extends SceneTree

# Adapter protocol v1 behaviour: the handshake, the exact serialized shapes the
# shared schema validates, and the Live commands driven against a real
# WebSocket fixture rather than a mock.

const WAIT_MSEC := 8000
const PUMP_DELAY_MSEC := 1
const FLUSH_MSEC := 1000
const SETTLE_MSEC := 300
const RECONNECTS := 5


class RecordingStream:
	extends RefCounted

	var lines: Array = []

	func send(bytes: PackedByteArray, text: String) -> int:
		lines.push_back(text)
		return bytes.size()

	func close() -> void:
		pass


func _init() -> void:
	var harness := ConvexTestHarness.new("adapter")
	_test_handshake(harness)
	_test_event_shapes(harness)
	_test_live_commands(harness)
	OS.set_environment("CONVEX_URL", "")
	quit(harness.report())


func _test_handshake(harness: ConvexTestHarness) -> void:
	# No deployment is configured for this part, which is also how the missing
	# configuration path gets proved.
	OS.set_environment("CONVEX_URL", "")
	var context := _session(null)
	var session: ConvexAdapterSession = context["session"]

	session.handle_line(JSON.stringify({"protocolVersion": 1, "id": "h1", "op": "hello"}))
	var ready: Dictionary = _drain(context)[0]
	harness.equal(ready["type"], "ready", "hello is answered with ready")
	harness.check(ready["protocolVersion"] == 1, "ready reports the protocol version")
	harness.equal(ready["id"], "h1", "ready echoes the request id")
	harness.equal(ready["language"], "gdscript", "ready reports the roster language id")
	harness.check(str(ready["implementation"]).contains("native"), "ready reports provenance")
	harness.check(str(ready["runtime"]).begins_with("Godot"), "ready reports the runtime version")

	session.handle_line(JSON.stringify({"protocolVersion": 2, "id": "h2", "op": "hello"}))
	var refused: Dictionary = _drain(context)[0]
	harness.equal(refused["type"], "error", "an unsupported version is refused")
	harness.equal(refused["error"]["name"], "ProtocolError", "the refusal is a protocol error")

	session.handle_line("{not json")
	var broken: Dictionary = _drain(context)[0]
	harness.equal(broken["type"], "error", "an undecodable command is an error")
	# That command had no usable id, and an absent id is omitted rather than
	# serialized as null.
	harness.check(not broken.has("id"), "an error without a request id omits the id")

	session.handle_line(JSON.stringify({"id": "u1", "op": "teleport"}))
	var unsupported: Dictionary = _drain(context)[0]
	harness.equal(unsupported["error"]["name"], "ProtocolError", "an unknown operation is refused")
	harness.equal(unsupported["id"], "u1", "the refusal keeps the request id")

	# The command boundary follows the shared schema rather than coercing values
	# into strings or echoing an identifier the event schema would reject.
	for command in [
		{"id": 7, "op": "close"},
		{"id": "x".repeat(129), "op": "close"},
		{"id": "extra", "op": "close", "surprise": true},
		{"id": "sub", "op": "unsubscribe", "subscriptionId": 9},
	]:
		session.handle_line(JSON.stringify(command))
		var strict: Dictionary = _drain(context)[0]
		harness.equal(strict["type"], "error", "a schema-invalid command is refused")
	var unicode_id := "😀".repeat(128)
	session.handle_line(JSON.stringify({"id": unicode_id, "op": "hello", "protocolVersion": 1}))
	harness.equal(_drain(context)[0]["id"], unicode_id, "the id limit counts Unicode characters")

	var query := {"id": "q1", "op": "query", "path": "demo:state", "args": {}}
	session.handle_line(JSON.stringify(query))
	var unconfigured: Dictionary = _drain(context)[0]
	harness.equal(unconfigured["error"]["name"], "TransportError", "a missing URL is transport")

	session.handle_line(JSON.stringify({"id": "c1", "op": "close"}))
	var closed: Dictionary = _drain(context)[0]
	harness.equal(closed["type"], "closed", "close is acknowledged with closed")
	harness.equal(closed["id"], "c1", "closed echoes the request id")
	harness.check(session.is_closed(), "the session stops after close")


# The schema treats an absent field and a null field as different things, so
# these assertions are made against the serialized event.
func _test_event_shapes(harness: ConvexTestHarness) -> void:
	var plain := ConvexAdapterEvents.result("r1", ConvexResult.ok({"count": 1.0}))
	harness.check(not plain.has("logs"), "a result without logs omits the key")
	var with_logs := ConvexResult.with_logs(ConvexResult.ok(true), ["one"])
	var logged := ConvexAdapterEvents.result("r2", with_logs)
	harness.equal(logged["logs"], ["one"], "a result with logs carries them")

	# A Convex function may legitimately return null, so the value key stays
	# present even when the value itself is null.
	var null_result := ConvexAdapterEvents.result("r3", ConvexResult.ok(null))
	harness.check(null_result.has("value"), "a null return value is still a present value")
	harness.check(JSON.stringify(null_result).contains('"value":null'), "null is serialized")

	var bare := ConvexResult.failure(ConvexResult.FUNCTION_ERROR, "boom")
	var bare_event := ConvexAdapterEvents.error("e1", bare)
	harness.check(not bare_event["error"].has("data"), "an error without data omits the key")
	harness.equal(bare_event["error"]["name"], "FunctionError", "the error name is carried")

	var structured := ConvexResult.failure(ConvexResult.FUNCTION_ERROR, "boom", {"code": "X"})
	var structured_event := ConvexAdapterEvents.error("e2", structured)
	harness.equal(structured_event["error"]["data"], {"code": "X"}, "structured data is carried")
	var null_data := ConvexResult.failure(ConvexResult.FUNCTION_ERROR, "boom", null, true)
	var null_event := ConvexAdapterEvents.error("e3", null_data)
	harness.check(null_event["error"].has("data"), "explicit null error data stays present")

	var anonymous := ConvexAdapterEvents.error("", ConvexResult.protocol_failure("bad"))
	harness.check(not anonymous.has("id"), "an error with no request id omits the id")

	var update := ConvexAdapterEvents.subscription("sub-1", ConvexResult.ok({"count": 2.0}))
	harness.equal(update["subscriptionId"], "sub-1", "a subscription event names its relay")
	harness.check(not update.has("id"), "a subscription event carries no request id")
	var failed := ConvexResult.failure(ConvexResult.FUNCTION_ERROR, "room is empty")
	var failed_event := ConvexAdapterEvents.subscription("sub-1", failed)
	harness.check(not failed_event.has("value"), "a failed subscription event carries no value")
	harness.equal(failed_event["error"]["message"], "room is empty", "the failure is structured")


func _test_live_commands(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	OS.set_environment("CONVEX_URL", fixture.url())

	var context := _session(fixture)
	var session: ConvexAdapterSession = context["session"]
	session.handle_line(JSON.stringify({"protocolVersion": 1, "id": "h", "op": "hello"}))
	_drain(context)

	session.handle_line(_subscribe_command("s1", "sub-1"))
	harness.equal(_drain(context)[0]["type"], "ack", "subscribe is acknowledged")

	var published := _collect(context, WAIT_MSEC)
	if not harness.check(published.size() > 0, "the initial Live value is published"):
		fixture.stop()
		return
	var initial: Dictionary = published[0]
	harness.equal(initial["type"], "subscription", "Live updates are subscription events")
	harness.equal(initial["subscriptionId"], "sub-1", "the event names the controller's relay")
	harness.equal(initial["value"], {"count": 0.0}, "the value is the query's value")

	# Hold the relay the controller currently has, then replace it under the
	# same id. The replacement installs a new generation before it
	# acknowledges, so an update taken from the old relay is refused.
	var replaced_entry: Dictionary = session.subscription_entry("sub-1")
	session.handle_line(_subscribe_command("s2", "sub-1"))
	harness.equal(_drain(context)[0]["type"], "ack", "a same-id subscribe is acknowledged")
	var stale := ConvexResult.ok({"count": 99.0})
	var crossed: bool = session.publish_update("sub-1", replaced_entry, stale)
	harness.check(not crossed, "an update from the replaced relay cannot cross the ack")
	harness.check(_drain(context).is_empty(), "nothing is emitted for a replaced relay")

	# The same guarantee has to hold across an unsubscribe.
	var removed_entry: Dictionary = session.subscription_entry("sub-1")
	var unsubscribe := {"id": "u1", "op": "unsubscribe", "subscriptionId": "sub-1"}
	session.handle_line(JSON.stringify(unsubscribe))
	harness.equal(_drain(context)[0]["type"], "ack", "unsubscribe is acknowledged")
	var late: bool = session.publish_update("sub-1", removed_entry, stale)
	harness.check(not late, "an update dequeued before an unsubscribe is refused")

	_test_debug_disconnect(harness, context)

	session.handle_line(JSON.stringify({"id": "c", "op": "close"}))
	var closed: Dictionary = _drain(context)[0]
	harness.equal(closed["type"], "closed", "close is acknowledged after the relays are released")
	fixture.stop()


# Five reconnects driven the way the shared controller drives them: an
# acknowledged disconnect, a suppressed rehydration, then the next change.
func _test_debug_disconnect(harness: ConvexTestHarness, context: Dictionary) -> void:
	var fixture: ConvexLiveFixture = context["fixture"]
	var session: ConvexAdapterSession = context["session"]
	session.handle_line(_subscribe_command("s3", "sub-2"))
	_drain(context)
	var hydrated := _collect(context, WAIT_MSEC)
	if not harness.check(hydrated.size() > 0, "the replacement subscription hydrates"):
		return
	var current: Dictionary = hydrated[hydrated.size() - 1]["value"]

	for round_index in RECONNECTS:
		# The server would rehydrate the reconnected query with the value the
		# controller already holds.
		fixture.set_auto_value("demo:state", current)
		var connections := fixture.connection_total()
		var disconnect := {"id": "d%d" % round_index, "op": "debugDisconnect"}
		session.handle_line(JSON.stringify(disconnect))
		harness.equal(_drain(context)[0]["type"], "ack", "debugDisconnect is acknowledged")

		var replayed := func(): return _is_replayed(fixture, connections)
		var quiet := _pump_until(context, replayed, WAIT_MSEC)
		var label := "reconnect %d restores the query set" % (round_index + 1)
		harness.check(fixture.connection_total() > connections, label)
		harness.check(quiet.is_empty(), "an unchanged rehydration publishes nothing")

		current = {"count": float(round_index + 1)}
		fixture.send_query_updated(fixture.query_ids()[0], current)
		var events := _collect(context, WAIT_MSEC)
		if not harness.check(events.size() > 0, "the next change is published"):
			return
		harness.equal(events[0]["value"], current, "the reconnected subscription still delivers")


func _session(fixture: ConvexLiveFixture) -> Dictionary:
	var stream := RecordingStream.new()
	var output := ConvexAdapterOutput.new(stream)
	var context := {"stream": stream, "output": output}
	context["session"] = ConvexAdapterSession.new(output)
	context["fixture"] = fixture
	return context


static func _subscribe_command(request_id: String, subscription_id: String) -> String:
	var command := {"id": request_id, "op": "subscribe"}
	command["subscriptionId"] = subscription_id
	command["path"] = "demo:state"
	command["args"] = {"room": "alpha"}
	return JSON.stringify(command)


static func _is_replayed(fixture: ConvexLiveFixture, previous_connections: int) -> bool:
	if fixture.connection_total() <= previous_connections:
		return false
	return fixture.query_ids().size() == 1


# Flush whatever the session produced and decode it, so every assertion is
# made against the bytes a controller would actually read.
func _drain(context: Dictionary) -> Array:
	var output: ConvexAdapterOutput = context["output"]
	var stream: RecordingStream = context["stream"]
	output.flush(FLUSH_MSEC)
	var events := []
	for line in stream.lines:
		var parsed := ConvexValues.parse_object(line, "adapter event")
		if not ConvexResult.is_failure(parsed):
			events.push_back(parsed["value"])
	stream.lines = []
	return events


func _collect(context: Dictionary, msec: int) -> Array:
	var fixture: ConvexLiveFixture = context["fixture"]
	var session: ConvexAdapterSession = context["session"]
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		fixture.poll()
		session.pump_live()
		var events := _drain(context)
		if not events.is_empty():
			return events
		OS.delay_msec(PUMP_DELAY_MSEC)
	return []


# Pump until a condition holds, plus a short settling window, and return
# everything published meanwhile. The reconnect assertions need it to be
# empty, so a late rehydration cannot race past them.
func _pump_until(context: Dictionary, test: Callable, msec: int) -> Array:
	var fixture: ConvexLiveFixture = context["fixture"]
	var session: ConvexAdapterSession = context["session"]
	var deadline := Time.get_ticks_msec() + msec
	var events := []
	while Time.get_ticks_msec() < deadline:
		fixture.poll()
		session.pump_live()
		events.append_array(_drain(context))
		if test.call():
			deadline = mini(deadline, Time.get_ticks_msec() + SETTLE_MSEC)
		OS.delay_msec(PUMP_DELAY_MSEC)
	return events
