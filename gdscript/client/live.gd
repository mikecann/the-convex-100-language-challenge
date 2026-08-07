class_name ConvexLive
extends RefCounted

# The single owner of one Convex Live connection.
#
# Ownership rule: this object is the only thing in the client that touches a
# WebSocketPeer. Subscriptions, the canonical example, and the conformance
# adapter never read, write, close, or reconnect a socket themselves; they ask
# the owner, and the owner performs the work while advancing its own state
# machine in poll(). Godot supplies the RFC 6455 implementation underneath:
# WebSocketPeer performs the HTTP 101 handshake, masks outgoing frames,
# reassembles fragmented frames, validates UTF-8 payloads, and answers ping
# and close control frames. Everything Convex-shaped, and every deadline,
# lives here.
#
# GDScript is single-threaded here, but the conformance adapter does read its
# standard input on a helper thread, so the owner records the thread it was
# created on and refuses commands arriving from anywhere else rather than
# letting a second thread mutate the query set.
#
# Wire profile: convex-rs 0.10.4, unversioned /api/sync. See manifest.yaml.

const SYNC_PATH := "/api/sync"
const INITIAL_BACKOFF_MSEC := 100
const MAX_BACKOFF_MSEC := 15000
const CONNECT_DEADLINE_MSEC := 10000
const CLOSE_DEADLINE_MSEC := 2000
const MESSAGE_DEADLINE_MSEC := 60000
const POLL_DELAY_MSEC := 1
const INBOUND_BUFFER_BYTES := 2 * 1024 * 1024
const OUTBOUND_BUFFER_BYTES := 256 * 1024
const MAX_QUEUED_PACKETS := 64
const MAX_CLOSE_REASON_BYTES := 123

var _websocket_url: String
var _client_version: String
var _tls_options: TLSOptions
var _pump: Callable
var _owner_thread: int
# The two transport deadlines are configurable so their behaviour can be
# asserted in a bounded test instead of being trusted.
var _connect_deadline_msec: int
var _close_deadline_msec: int
var _message_deadline_msec: int

var _peer: WebSocketPeer = null
var _handshake_complete: bool = false
var _connect_deadline: int = 0
var _close_deadline: int = 0
var _message_deadline: int = 0
var _session_id: String = ""

var _subscriptions: Dictionary = {}
var _remote_results: Dictionary = {}
var _next_query_id: int = 0
var _query_set_version: int = 0
var _remote_version: Dictionary = {}

var _connection_count: int = 0
var _last_close_reason: String = "InitialConnect"
var _max_observed_timestamp: String = ""
var _next_backoff_msec: int = INITIAL_BACKOFF_MSEC
var _reconnect_at: int = 0
var _closed: bool = false


func _init(deployment_url: String, options: Dictionary = {}) -> void:
	var base := deployment_url.trim_suffix("/")
	if base.begins_with("https://"):
		_websocket_url = "wss://" + base.substr(8) + SYNC_PATH
	else:
		_websocket_url = "ws://" + base.substr(7) + SYNC_PATH
	_client_version = options.get("client_version", "gdscript")
	_tls_options = options.get("tls_options", null)
	_pump = options.get("pump", Callable())
	_connect_deadline_msec = options.get("connect_deadline_msec", CONNECT_DEADLINE_MSEC)
	_close_deadline_msec = options.get("close_deadline_msec", CLOSE_DEADLINE_MSEC)
	_message_deadline_msec = options.get("message_deadline_msec", MESSAGE_DEADLINE_MSEC)
	_owner_thread = OS.get_thread_caller_id()
	_session_id = _new_session_id()
	_remote_version = _zero_version()


func websocket_url() -> String:
	return _websocket_url


func connection_count() -> int:
	return _connection_count


func last_close_reason() -> String:
	return _last_close_reason


func max_observed_timestamp() -> String:
	return _max_observed_timestamp


func query_set_version() -> int:
	return _query_set_version


func backoff_msec() -> int:
	return _next_backoff_msec


func is_socket_open() -> bool:
	return _peer != null and _handshake_complete


func active_query_ids() -> Array:
	var ids := _subscriptions.keys()
	ids.sort()
	return ids


# Start one reactive query. The subscription object is returned immediately;
# the Add modification is written on the current connection when there is one,
# and replayed by the next connection when there is not.
func subscribe(path: String, args: Dictionary) -> Dictionary:
	var guard := _guard("subscribe")
	if ConvexResult.is_failure(guard):
		return guard
	if _closed:
		return ConvexResult.closed_failure("Convex Live is closed")
	if path.is_empty():
		return ConvexResult.protocol_failure("Convex function path is required")
	if not ConvexValues.is_json_safe(args):
		return ConvexResult.protocol_failure("Convex arguments must be JSON-safe")

	var query_id := _next_query_id
	_next_query_id += 1
	var subscription := ConvexSubscription.new(self, query_id)
	var state := {"path": path, "args": ConvexValues.copy(args)}
	state["subscription"] = subscription
	state["last_delivered"] = null
	state["has_delivered"] = false
	_subscriptions[query_id] = state

	if not is_socket_open():
		# poll() opens a connection as soon as the query set stops being empty,
		# so an idle client never holds a socket it does not need. A first
		# subscription starts immediately; one added while the transport is
		# already backing off waits for the scheduled retry instead of turning
		# every new query into another connection attempt.
		if _peer == null and _next_backoff_msec == INITIAL_BACKOFF_MSEC:
			_reconnect_at = mini(_reconnect_at, Time.get_ticks_msec())
		return ConvexResult.ok(subscription)
	var sent := _modify([_add_modification(query_id, state)])
	if ConvexResult.is_failure(sent):
		_subscriptions.erase(query_id)
		subscription.finish_from_owner()
		_recover_query_set_write(sent)
		return sent
	return ConvexResult.ok(subscription)


# Stop one reactive query. The relay is invalidated before this function can
# do anything that yields, so no update produced earlier can be observed after
# the acknowledgement, whether the socket write succeeds or fails.
func unsubscribe(query_id: int) -> Dictionary:
	var guard := _guard("unsubscribe")
	if ConvexResult.is_failure(guard):
		return guard
	# Closing the owner already invalidated every relay, so stopping a query
	# afterwards is a no-op rather than an error.
	if _closed:
		return ConvexResult.ok(true)
	if not _subscriptions.has(query_id):
		return ConvexResult.ok(true)
	var state: Dictionary = _subscriptions[query_id]
	_subscriptions.erase(query_id)
	_remote_results.erase(query_id)
	state["subscription"].finish_from_owner()
	if not is_socket_open():
		return ConvexResult.ok(true)
	var removal := {"type": "Remove", "queryId": query_id}
	var sent := _modify([removal])
	if ConvexResult.is_failure(sent):
		_recover_query_set_write(sent)
		return sent
	return ConvexResult.ok(true)


# Close the client. Every relay is invalidated first, then the socket is
# retired within a bounded deadline even if the peer never answers.
func close() -> Dictionary:
	var guard := _guard("close")
	if ConvexResult.is_failure(guard):
		return guard
	if _closed:
		return ConvexResult.ok(true)
	_closed = true
	var closing := _subscriptions
	_subscriptions = {}
	_remote_results = {}
	for state in closing.values():
		state["subscription"].finish_from_owner()
	_retire_peer(1000, "client closed", _close_deadline_msec)
	_last_close_reason = "ClientClosed"
	return ConvexResult.ok(true)


# Test-only fault injection used by the conformance adapter's debugDisconnect
# command. It drops the transport without closing the client, and returns only
# after the old connection is retired and the reconnect is scheduled, so the
# controller can never observe a value from the connection it just killed.
func debug_disconnect() -> Dictionary:
	var guard := _guard("debugDisconnect")
	if ConvexResult.is_failure(guard):
		return guard
	if _closed or _peer == null:
		return ConvexResult.transport_failure("Live WebSocket is not connected")
	_drop_peer()
	_after_disconnect("DebugDisconnect")
	return ConvexResult.ok(true)


# Advance the connection. Everything that reads, writes, opens, or retires a
# socket happens inside this call or inside one of the command methods above.
func poll() -> void:
	if _closed:
		return
	if _peer == null:
		if _subscriptions.is_empty():
			return
		if Time.get_ticks_msec() >= _reconnect_at:
			_connect()
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if Time.get_ticks_msec() >= _connect_deadline:
				var late := "Live handshake exceeded its deadline"
				_fail_connection(ConvexResult.transport_failure(late))
		WebSocketPeer.STATE_OPEN:
			if not _handshake_complete:
				_on_handshake()
			if _peer != null and _handshake_complete:
				_receive()
				if _peer != null and Time.get_ticks_msec() >= _message_deadline:
					var stalled := "Live produced no complete message before its deadline"
					_fail_connection(ConvexResult.transport_failure(stalled))
		WebSocketPeer.STATE_CLOSING:
			# The peer started a closing handshake. Give it a bounded chance to
			# finish, then abandon the connection rather than polling forever.
			if _close_deadline == 0:
				_close_deadline = Time.get_ticks_msec() + _close_deadline_msec
			elif Time.get_ticks_msec() >= _close_deadline:
				_drop_peer()
				_after_disconnect("CloseTimeout")
		WebSocketPeer.STATE_CLOSED:
			var reason := _peer.get_close_reason()
			var code := _peer.get_close_code()
			_drop_peer()
			var detail := "Live connection closed (%d %s)" % [code, reason]
			_publish(ConvexResult.transport_failure(detail))
			_after_disconnect("PeerClosed")


func _connect() -> void:
	var peer := WebSocketPeer.new()
	# Bound what one connection can hold in memory before any Convex message
	# is even parsed. A frame larger than the inbound buffer fails the
	# connection instead of growing the process.
	peer.inbound_buffer_size = INBOUND_BUFFER_BYTES
	peer.outbound_buffer_size = OUTBOUND_BUFFER_BYTES
	peer.max_queued_packets = MAX_QUEUED_PACKETS
	peer.handshake_headers = PackedStringArray(["Convex-Client: " + _client_version])
	var started := peer.connect_to_url(_websocket_url, _tls_options)
	if started != OK:
		_publish(ConvexResult.transport_failure("open Live WebSocket failed: %d" % started))
		_after_disconnect("ConnectFailed")
		return
	_peer = peer
	_handshake_complete = false
	_connect_deadline = Time.get_ticks_msec() + _connect_deadline_msec
	_close_deadline = 0
	_message_deadline = 0
	# A new socket starts a new query set and a new server version. Nothing
	# from the previous connection is assumed to still hold.
	_query_set_version = 0
	_remote_version = _zero_version()
	_remote_results = {}


func _on_handshake() -> void:
	_handshake_complete = true
	_message_deadline = Time.get_ticks_msec() + _message_deadline_msec
	var connect_message := {"type": "Connect", "sessionId": _session_id}
	connect_message["connectionCount"] = _connection_count
	connect_message["lastCloseReason"] = _last_close_reason
	# maxObservedTimestamp lets the server resume from what this client has
	# already seen. It is omitted, not sent as null, before the first
	# Transition arrives.
	if not _max_observed_timestamp.is_empty():
		connect_message["maxObservedTimestamp"] = _max_observed_timestamp
	var sent := _send(connect_message)
	if ConvexResult.is_failure(sent):
		_fail_connection(sent)
		return
	# Every active query is re-added on the new connection, in a stable order,
	# so a reconnect restores exactly the set the caller still holds.
	var modifications := []
	for query_id in active_query_ids():
		modifications.append(_add_modification(query_id, _subscriptions[query_id]))
	if not modifications.is_empty():
		var replayed := _modify(modifications)
		if ConvexResult.is_failure(replayed):
			_fail_connection(replayed)
			return
	# A completed handshake proves the transport is healthy again, so the next
	# failure starts from the shortest delay rather than inheriting the last
	# maximum.
	_next_backoff_msec = INITIAL_BACKOFF_MSEC


func _receive() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		_message_deadline = Time.get_ticks_msec() + _message_deadline_msec
		if not _peer.was_string_packet():
			_fail_connection(ConvexResult.protocol_failure("Live sent a non-text message"))
			return
		var text := packet.get_string_from_utf8()
		if text.to_utf8_buffer() != packet:
			_fail_connection(ConvexResult.protocol_failure("Live message was not valid UTF-8"))
			return
		var parsed := ConvexValues.parse_object(text, "Live message")
		if ConvexResult.is_failure(parsed):
			_fail_connection(parsed)
			return
		_handle_message(parsed["value"], packet.size())


func _handle_message(message: Dictionary, encoded_bytes: int) -> void:
	var kind := str(message.get("type", ""))
	if kind == "Transition":
		var applied := _apply_transition(message, encoded_bytes)
		if ConvexResult.is_failure(applied):
			_fail_connection(applied)
			return
		# Only a valid transition proves the server is talking this profile,
		# so that is where the transport backoff resets.
		_next_backoff_msec = INITIAL_BACKOFF_MSEC
		return
	if kind == "Ping" or kind == "MutationResponse" or kind == "ActionResponse":
		return
	if kind == "FatalError" or kind == "AuthError":
		var detail := "%s: %s" % [kind, str(message.get("error", ""))]
		_fail_connection(ConvexResult.protocol_failure(detail))
		return
	_fail_connection(ConvexResult.protocol_failure("unknown Live message %s" % kind))


# Apply one Transition atomically. The complete next snapshot is built before
# any owner state changes, so a modification rejected halfway through cannot
# advance the version, alter cached results, or move the observed timestamp.
func _apply_transition(message: Dictionary, encoded_bytes: int) -> Dictionary:
	var start_version := _version_from(message.get("startVersion"), "startVersion")
	if ConvexResult.is_failure(start_version):
		return start_version
	var end_version := _version_from(message.get("endVersion"), "endVersion")
	if ConvexResult.is_failure(end_version):
		return end_version
	if not ConvexValues.equal_values(start_version["value"], _remote_version):
		return ConvexResult.protocol_failure("Transition start version does not match")
	var modifications: Variant = message.get("modifications")
	if typeof(modifications) != TYPE_ARRAY:
		return ConvexResult.protocol_failure("Transition modifications must be an array")
	var end_value: Dictionary = end_version["value"]
	var start_value: Dictionary = start_version["value"]
	var same_ts := ConvexValues.same_timestamp(end_value["ts"], start_value["ts"])
	if not same_ts and not ConvexValues.is_later_timestamp(end_value["ts"], start_value["ts"]):
		return ConvexResult.protocol_failure("Transition end timestamp moved backwards")

	var changed := {}
	var next_results := _remote_results.duplicate()
	var seen := {}
	for modification in modifications:
		if typeof(modification) != TYPE_DICTIONARY:
			return ConvexResult.protocol_failure("Transition modification must be an object")
		var checked_id := ConvexValues.count_from_json(modification.get("queryId"), "queryId")
		if ConvexResult.is_failure(checked_id):
			return checked_id
		if seen.has(checked_id["value"]):
			return ConvexResult.protocol_failure("Transition repeated a queryId")
		seen[checked_id["value"]] = true
		var applied := _transition_entry(modification, changed, next_results)
		if ConvexResult.is_failure(applied):
			return applied

	_remote_results = next_results
	_remote_version = end_version["value"]
	var timestamp := str(_remote_version["ts"])
	if ConvexValues.is_later_timestamp(timestamp, _max_observed_timestamp):
		_max_observed_timestamp = timestamp
	_deliver_changed(changed, encoded_bytes)
	return ConvexResult.ok(true)


func _transition_entry(
	modification: Variant, changed: Dictionary, next_results: Dictionary
) -> Dictionary:
	if typeof(modification) != TYPE_DICTIONARY:
		return ConvexResult.protocol_failure("Transition modification must be an object")
	var query_id := ConvexValues.count_from_json(modification.get("queryId"), "queryId")
	if ConvexResult.is_failure(query_id):
		return query_id
	var id: int = query_id["value"]
	var kind := str(modification.get("type", ""))
	match kind:
		"QueryUpdated":
			if not modification.has("value"):
				return ConvexResult.protocol_failure("QueryUpdated omitted value")
			var updated_logs := ConvexValues.log_lines(modification.get("logLines"), "logLines")
			if ConvexResult.is_failure(updated_logs):
				return updated_logs
			var update := ConvexResult.ok(ConvexValues.copy(modification["value"]))
			changed[id] = ConvexResult.with_logs(update, updated_logs["value"])
			next_results[id] = changed[id]
		"QueryFailed":
			var reason: Variant = modification.get("errorMessage")
			if typeof(reason) != TYPE_STRING:
				return ConvexResult.protocol_failure("QueryFailed omitted errorMessage")
			var failed_logs := ConvexValues.log_lines(modification.get("logLines"), "logLines")
			if ConvexResult.is_failure(failed_logs):
				return failed_logs
			var data: Variant = modification.get("errorData")
			var failure := ConvexResult.failure(
				ConvexResult.FUNCTION_ERROR, reason, data, modification.has("errorData")
			)
			changed[id] = ConvexResult.with_logs(failure, failed_logs["value"])
			next_results[id] = changed[id]
		"QueryRemoved":
			if modification.has("logLines"):
				return ConvexResult.protocol_failure("QueryRemoved must not include logLines")
			next_results.erase(id)
		_:
			return ConvexResult.protocol_failure("unknown Transition modification %s" % kind)
	return ConvexResult.ok(true)


# Publish one snapshot's changes. A rehydrated value identical to the one the
# caller already holds is suppressed, which is what makes a reconnect
# invisible to a query whose state did not actually change.
func _deliver_changed(changed: Dictionary, encoded_bytes: int) -> void:
	for id in changed:
		if not _subscriptions.has(id):
			continue
		var state: Dictionary = _subscriptions[id]
		var update: Dictionary = changed[id]
		if not ConvexResult.is_failure(update):
			var same: bool = state["has_delivered"]
			if same and ConvexValues.equal_values(state["last_delivered"], update["value"]):
				continue
			state["last_delivered"] = ConvexValues.copy(update["value"])
			state["has_delivered"] = true
		else:
			# A failed query has no delivered value any more, so the next
			# successful value is always published even if it repeats the one
			# from before the failure.
			state["last_delivered"] = null
			state["has_delivered"] = false
		state["subscription"].apply_update_from_owner(update, encoded_bytes)


func _publish(error_result: Dictionary) -> void:
	for state in _subscriptions.values():
		state["subscription"].apply_update_from_owner(error_result, 0)


# A structured failure on an otherwise usable client: report it to every
# subscription, retire the connection, and schedule a reconnect. Subscriptions
# stay in the query set, so a later valid value still reaches the caller.
func _fail_connection(error_result: Dictionary) -> void:
	_publish(error_result)
	_drop_peer()
	_after_disconnect(ConvexResult.error_name(error_result))


# A failed query-set write is ambiguous: the server may have applied all, part
# or none of the frame. Retire that connection rather than trusting a local
# version that may no longer match, then replay the still-active set.
func _recover_query_set_write(error_result: Dictionary) -> void:
	_drop_peer()
	_after_disconnect("QuerySetWriteFailed")
	_publish(error_result)


func _after_disconnect(reason: String) -> void:
	_last_close_reason = reason
	_query_set_version = 0
	_remote_version = _zero_version()
	_remote_results = {}
	if _subscriptions.is_empty():
		return
	_reconnect_at = Time.get_ticks_msec() + _next_backoff_msec
	_next_backoff_msec = mini(_next_backoff_msec * 2, MAX_BACKOFF_MSEC)


# Abandon the current connection immediately. Godot closes without a closing
# handshake when the code is negative, which is what a dropped socket looks
# like. Any frame this peer had half-parsed dies with the peer, so a resumed
# read can never restart at a false frame boundary.
func _drop_peer() -> void:
	if _peer == null:
		return
	_peer.close(-1)
	_peer = null
	_handshake_complete = false
	_close_deadline = 0
	_message_deadline = 0
	_connection_count += 1


# Retire the current connection politely, bounded by a deadline. An idle or
# stalled peer that never answers the close frame costs at most deadline_msec.
func _retire_peer(code: int, reason: String, deadline_msec: int) -> void:
	if _peer == null:
		return
	_peer.close(code, _close_reason(reason))
	var deadline := Time.get_ticks_msec() + deadline_msec
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			break
		if _pump.is_valid():
			_pump.call()
		OS.delay_msec(POLL_DELAY_MSEC)
	_peer = null
	_handshake_complete = false
	_close_deadline = 0
	_message_deadline = 0
	_connection_count += 1


func _modify(modifications: Array) -> Dictionary:
	var next_version := _query_set_version + 1
	var message := {"type": "ModifyQuerySet", "baseVersion": _query_set_version}
	message["newVersion"] = next_version
	message["modifications"] = modifications
	var sent := _send(message)
	if ConvexResult.is_failure(sent):
		return sent
	_query_set_version = next_version
	return ConvexResult.ok(true)


func _send(message: Dictionary) -> Dictionary:
	if _peer == null:
		return ConvexResult.transport_failure("Live WebSocket is not connected")
	if not ConvexValues.is_json_safe(message):
		return ConvexResult.protocol_failure("Live message is not JSON-safe")
	var written := _peer.send_text(JSON.stringify(message))
	if written != OK:
		return ConvexResult.transport_failure("write Live message failed: %d" % written)
	return ConvexResult.ok(true)


func _add_modification(query_id: int, state: Dictionary) -> Dictionary:
	var modification := {"type": "Add", "queryId": query_id}
	modification["udfPath"] = state["path"]
	modification["args"] = [state["args"]]
	return modification


func _version_from(value: Variant, field: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return ConvexResult.protocol_failure("%s must be an object" % field)
	var query_set := ConvexValues.count_from_json(value.get("querySet"), "%s.querySet" % field)
	if ConvexResult.is_failure(query_set):
		return query_set
	var identity := ConvexValues.count_from_json(value.get("identity"), "%s.identity" % field)
	if ConvexResult.is_failure(identity):
		return identity
	if not ConvexValues.is_timestamp(value.get("ts")):
		return ConvexResult.protocol_failure("%s.ts must be a base64 timestamp" % field)
	var version := {"querySet": query_set["value"], "identity": identity["value"]}
	version["ts"] = value["ts"]
	return ConvexResult.ok(version)


func _zero_version() -> Dictionary:
	var version := {"querySet": 0, "identity": 0}
	version["ts"] = ConvexValues.INITIAL_TIMESTAMP
	return version


# Refuse a command that arrived from a thread other than the one that created
# the owner. The adapter's standard-input reader is the only other thread in
# this project, and it is not allowed to touch the query set.
func _guard(command: String) -> Dictionary:
	if OS.get_thread_caller_id() != _owner_thread:
		return ConvexResult.protocol_failure("%s must run on the Live owner thread" % command)
	return ConvexResult.ok(true)


# RFC 6455 leaves 123 bytes for a close reason. Keep a bounded ASCII
# diagnostic on the wire so a long or malformed reason cannot stop the socket
# from being retired.
static func _close_reason(reason: String) -> String:
	var ascii := ""
	for index in reason.length():
		var code := reason.unicode_at(index)
		ascii += reason[index] if code >= 32 and code <= 126 else "?"
		if ascii.length() >= MAX_CLOSE_REASON_BYTES:
			break
	return ascii


# A random version 4 UUID. Convex identifies a client session by this value,
# and reusing one across processes would make two clients share server state.
static func _new_session_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var hex := bytes.hex_encode()
	var head := "%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4)]
	return "%s-%s-%s" % [head, hex.substr(16, 4), hex.substr(20, 12)]
