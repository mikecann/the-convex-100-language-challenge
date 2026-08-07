class_name ConvexAdapterSession
extends RefCounted

# NDJSON adapter protocol v1, independent of which transport carries it.
#
# This is test infrastructure, not public client code: it exists so the shared
# controller can drive the real GDScript client. Every command below calls the
# same client the canonical example uses, and structured function, protocol,
# and transport failures are forwarded as typed events rather than collapsed
# into successful values.

const PROTOCOL_VERSION := 1
const MAX_ID_CHARACTERS := 128

var _output: ConvexAdapterOutput
var _client: ConvexClient = null
var _subscriptions: Dictionary = {}
var _next_generation: int = 0
var _closed: bool = false


func _init(output: ConvexAdapterOutput) -> void:
	_output = output


func is_closed() -> bool:
	return _closed


func output() -> ConvexAdapterOutput:
	return _output


# The relay a subscriptionId currently maps to. The conformance tests use it
# to hold an entry across an unsubscribe or a same-id replacement and prove
# the generation check refuses the stale one.
func subscription_entry(subscription_id: String) -> Variant:
	return _subscriptions.get(subscription_id)


func handle_line(line: String) -> void:
	if _closed:
		return
	var parsed := ConvexValues.parse_object(line, "adapter command")
	if ConvexResult.is_failure(parsed):
		_emit(ConvexAdapterEvents.error("", parsed))
		return
	var command: Dictionary = parsed["value"]
	var raw_id: Variant = command.get("id")
	var id := str(raw_id) if _valid_id(raw_id) else ""
	var validated := _validate_command(command)
	if ConvexResult.is_failure(validated):
		_emit(ConvexAdapterEvents.error(id, validated))
		return
	var operation: String = command["op"]
	match operation:
		"hello":
			_handle_hello(id, command)
		"query", "mutation", "action":
			_handle_call(id, operation, command)
		"setAuth":
			_handle_set_auth(id, command)
		"subscribe":
			_handle_subscribe(id, command)
		"unsubscribe":
			_handle_unsubscribe(id, command)
		"debugDisconnect":
			_handle_debug_disconnect(id)
		"close":
			_handle_close(id)
		_:
			var detail := "unknown adapter operation %s" % operation
			_emit(ConvexAdapterEvents.error(id, ConvexResult.protocol_failure(detail)))


# Advance Live work and publish whatever the subscriptions have produced. The
# HTTP transport also calls this while it waits, so an open WebSocket keeps
# being polled during a slow query instead of stalling behind it.
func pump_live() -> void:
	if _client == null or not _client.has_live():
		return
	_client.poll()
	for subscription_id in _subscriptions.keys():
		var entry: Variant = _subscriptions.get(subscription_id)
		if entry == null:
			continue
		_drain(subscription_id, entry)


# Publish one dequeued update, unless the relay it came from is no longer the
# one the controller holds. Generations, rather than object identity, make the
# check explicit: an unsubscribe or a same-id replacement installs a new
# generation before it acknowledges, so an update taken from the old relay can
# never cross either acknowledgement.
func publish_update(subscription_id: String, entry: Dictionary, update: Dictionary) -> bool:
	var current: Variant = _subscriptions.get(subscription_id)
	if current == null:
		return false
	if current["generation"] != entry["generation"]:
		return false
	_emit(ConvexAdapterEvents.subscription(subscription_id, update))
	return true


# End of input is the same shutdown as an explicit close, minus the event: the
# controller is gone, so there is nobody left to acknowledge to.
func finish_from_eof() -> void:
	if _closed:
		return
	_closed = true
	_release()


func _handle_hello(id: String, command: Dictionary) -> void:
	# Godot's JSON parser turns every number into a float, so the protocol
	# version arrives as 1.0 and has to be checked as a number rather than
	# compared to the integer 1.
	var version := ConvexValues.count_from_json(command.get("protocolVersion"), "protocolVersion")
	if ConvexResult.is_failure(version) or version["value"] != PROTOCOL_VERSION:
		var detail := "unsupported adapter protocol version"
		_emit(ConvexAdapterEvents.error(id, ConvexResult.protocol_failure(detail)))
		return
	_emit(ConvexAdapterEvents.ready(id))


func _handle_call(id: String, operation: String, command: Dictionary) -> void:
	var client := _ensure_client()
	if ConvexResult.is_failure(client):
		_emit(ConvexAdapterEvents.error(id, client))
		return
	var arguments := _arguments_of(command)
	if ConvexResult.is_failure(arguments):
		_emit(ConvexAdapterEvents.error(id, arguments))
		return
	var path := str(command.get("path", ""))
	var result := _client.call_function(operation, path, arguments["value"])
	if ConvexResult.is_failure(result):
		_emit(ConvexAdapterEvents.error(id, result))
		return
	_emit(ConvexAdapterEvents.result(id, result))


func _handle_set_auth(id: String, command: Dictionary) -> void:
	var client := _ensure_client()
	if ConvexResult.is_failure(client):
		_emit(ConvexAdapterEvents.error(id, client))
		return
	var token: Variant = command.get("token")
	if typeof(token) != TYPE_STRING:
		var detail := "setAuth requires a string token"
		_emit(ConvexAdapterEvents.error(id, ConvexResult.protocol_failure(detail)))
		return
	# An empty token clears the header, which is how the controller proves the
	# cleared case of the bearer-token lifecycle.
	var applied := _client.set_auth(token)
	if ConvexResult.is_failure(applied):
		_emit(ConvexAdapterEvents.error(id, applied))
		return
	_emit(ConvexAdapterEvents.ack(id))


func _handle_subscribe(id: String, command: Dictionary) -> void:
	var client := _ensure_client()
	if ConvexResult.is_failure(client):
		_emit(ConvexAdapterEvents.error(id, client))
		return
	var subscription_id := str(command.get("subscriptionId", ""))
	if subscription_id.is_empty():
		var detail := "subscriptionId is required"
		_emit(ConvexAdapterEvents.error(id, ConvexResult.protocol_failure(detail)))
		return
	var arguments := _arguments_of(command)
	if ConvexResult.is_failure(arguments):
		_emit(ConvexAdapterEvents.error(id, arguments))
		return
	# A repeated subscriptionId replaces the old relay. Invalidating it here,
	# before the new subscription exists, is what stops an update from the
	# replaced query reaching the controller under the new identity.
	_invalidate(subscription_id)
	var path := str(command.get("path", ""))
	var subscribed := _client.subscribe(path, arguments["value"])
	if ConvexResult.is_failure(subscribed):
		_emit(ConvexAdapterEvents.error(id, subscribed))
		return
	_next_generation += 1
	var entry := {"subscription": subscribed["value"], "generation": _next_generation}
	_subscriptions[subscription_id] = entry
	_emit(ConvexAdapterEvents.ack(id))


func _handle_unsubscribe(id: String, command: Dictionary) -> void:
	var subscription_id := str(command.get("subscriptionId", ""))
	var entry: Variant = _subscriptions.get(subscription_id)
	# The relay leaves the table before the client is asked to stop the query,
	# so nothing dequeued earlier can still be published after the ack.
	_subscriptions.erase(subscription_id)
	if entry == null:
		_emit(ConvexAdapterEvents.ack(id))
		return
	var stopped: Dictionary = entry["subscription"].close()
	if ConvexResult.is_failure(stopped):
		_emit(ConvexAdapterEvents.error(id, stopped))
		return
	_emit(ConvexAdapterEvents.ack(id))


# Adapter-only fault injection. It drops the Live transport without closing
# the client, and the client only returns once the old connection is retired
# and the reconnect is scheduled, so this acknowledgement is proof that no
# value can still arrive from the killed connection.
func _handle_debug_disconnect(id: String) -> void:
	if _client == null:
		var detail := "Live WebSocket is not connected"
		_emit(ConvexAdapterEvents.error(id, ConvexResult.transport_failure(detail)))
		return
	var dropped := _client.debug_disconnect_for_adapter()
	if ConvexResult.is_failure(dropped):
		_emit(ConvexAdapterEvents.error(id, dropped))
		return
	_emit(ConvexAdapterEvents.ack(id))


func _handle_close(id: String) -> void:
	_closed = true
	_release()
	_emit(ConvexAdapterEvents.closed(id))


# Invalidate every relay first, then close the client. Doing it in this order
# means no subscription can publish while the client is being torn down.
func _release() -> void:
	var closing := _subscriptions
	_subscriptions = {}
	for entry in closing.values():
		entry["subscription"].close()
	if _client != null:
		_client.close()
	# Dropping the reference also breaks the cycle created by handing the
	# transport this session's pump, so nothing is left alive at exit.
	_client = null


func _drain(subscription_id: String, entry: Dictionary) -> void:
	while true:
		var update: Dictionary = entry["subscription"].try_next_update()
		if update.is_empty():
			return
		if not publish_update(subscription_id, entry, update):
			return


func _invalidate(subscription_id: String) -> void:
	var entry: Variant = _subscriptions.get(subscription_id)
	if entry == null:
		return
	_subscriptions.erase(subscription_id)
	entry["subscription"].close()


func _ensure_client() -> Dictionary:
	if _client != null:
		return ConvexResult.ok(_client)
	var deployment_url := OS.get_environment("CONVEX_URL")
	if deployment_url.is_empty():
		return ConvexResult.transport_failure("CONVEX_URL is required")
	var created := ConvexClient.create(deployment_url, {"pump": pump_live})
	if ConvexResult.is_failure(created):
		return created
	_client = created["value"]
	var token := OS.get_environment("CONVEX_AUTH_TOKEN")
	if not token.is_empty():
		_client.set_auth(token)
	return ConvexResult.ok(_client)


static func _arguments_of(command: Dictionary) -> Dictionary:
	var arguments: Variant = command.get("args", {})
	if typeof(arguments) != TYPE_DICTIONARY:
		return ConvexResult.protocol_failure("args must be a JSON object")
	return ConvexResult.ok(arguments)


static func _validate_command(command: Dictionary) -> Dictionary:
	var id: Variant = command.get("id")
	if typeof(id) != TYPE_STRING or id.is_empty() or id.length() > MAX_ID_CHARACTERS:
		return ConvexResult.protocol_failure("id must be 1 to 128 characters")
	var operation: Variant = command.get("op")
	if typeof(operation) != TYPE_STRING:
		return ConvexResult.protocol_failure("op must be a string")
	var allowed := ["id", "op"]
	match operation:
		"hello":
			allowed.append("protocolVersion")
		"query", "mutation", "action":
			allowed.append_array(["path", "args"])
			if typeof(command.get("path")) != TYPE_STRING:
				return ConvexResult.protocol_failure("path must be a string")
			var path: String = command["path"]
			if path.length() < 3:
				return ConvexResult.protocol_failure("path must be at least 3 characters")
			if typeof(command.get("args")) != TYPE_DICTIONARY:
				return ConvexResult.protocol_failure("args must be a JSON object")
		"setAuth":
			allowed.append("token")
			if typeof(command.get("token")) != TYPE_STRING:
				return ConvexResult.protocol_failure("token must be a string")
		"subscribe":
			allowed.append_array(["subscriptionId", "path", "args"])
			var subscription_id: Variant = command.get("subscriptionId")
			if not _valid_id(subscription_id):
				return ConvexResult.protocol_failure("subscriptionId must be 1 to 128 characters")
			if typeof(command.get("path")) != TYPE_STRING:
				return ConvexResult.protocol_failure("path must be a string")
			if typeof(command.get("args")) != TYPE_DICTIONARY:
				return ConvexResult.protocol_failure("args must be a JSON object")
		"unsubscribe":
			allowed.append("subscriptionId")
			if not _valid_id(command.get("subscriptionId")):
				return ConvexResult.protocol_failure("subscriptionId must be 1 to 128 characters")
		"debugDisconnect", "close":
			pass
		_:
			return ConvexResult.protocol_failure("unknown adapter operation %s" % operation)
	for key in command:
		if not allowed.has(key):
			return ConvexResult.protocol_failure("unexpected command field %s" % key)
	return ConvexResult.ok(true)


static func _valid_id(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	return not value.is_empty() and value.length() <= MAX_ID_CHARACTERS


func _emit(event: Dictionary) -> void:
	var queued := _output.enqueue(event)
	if not ConvexResult.is_failure(queued):
		return
	if _output.has_failed():
		# The queue is bounded and it has given up. There is nowhere left to
		# report to, so the session stops rather than producing more events.
		_closed = true
		return
	# The event itself could not be serialized. Report that as a structured
	# protocol error instead of silently dropping the response.
	_output.enqueue(ConvexAdapterEvents.error(str(event.get("id", "")), queued))
