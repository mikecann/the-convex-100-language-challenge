class_name ConvexLiveFixture
extends RefCounted

# A Convex sync server, in process, for the Live tests.
#
# Godot's WebSocketPeer can act as a server through accept_stream, so the
# tests exercise the real RFC 6455 implementation over a real socket rather
# than a mocked transport: real handshakes, real frames, real close codes.
# The fixture speaks the pinned convex-rs 0.10.4 profile and can also produce
# the malformed traffic a strict client has to reject.

const HOST := "127.0.0.1"
const INBOUND_BUFFER_BYTES := 2 * 1024 * 1024

var _server := TCPServer.new()
var _port: int = 0
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _accepting: bool = true
var _upgrading: bool = true
var _connects: Array = []
var _messages: Array = []
var _query_set: Dictionary = {}
var _query_set_version: int = 0
var _version: Dictionary = {}
var _timestamp: int = 0
var _auto_values: Dictionary = {}
var _connection_total: int = 0


func start() -> Dictionary:
	var listening := _server.listen(0, HOST)
	if listening != OK:
		return ConvexResult.transport_failure("fixture cannot listen: %d" % listening)
	_port = _server.get_local_port()
	_version = _zero_version()
	return ConvexResult.ok(_port)


# The client turns this into ws://.../api/sync itself.
func url() -> String:
	return "http://%s:%d" % [HOST, _port]


# Stop accepting new connections, so a reconnect attempt finds nothing and the
# client's transport backoff is what the test observes.
func set_accepting(accepting: bool) -> void:
	_accepting = accepting


# Accept the TCP connection but never complete the WebSocket handshake, which
# is what a stalled or half-open peer looks like from the client's side.
func set_upgrading(upgrading: bool) -> void:
	_upgrading = upgrading


# Answer every Add for this path with the given value, the way a real
# deployment hydrates a new or replayed query.
func set_auto_value(udf_path: String, value: Variant) -> void:
	_auto_values[udf_path] = value


func connection_total() -> int:
	return _connection_total


func connects() -> Array:
	return _connects


func last_connect() -> Dictionary:
	if _connects.is_empty():
		return {}
	return _connects[_connects.size() - 1]


func messages() -> Array:
	return _messages


func query_ids() -> Array:
	var ids := _query_set.keys()
	ids.sort()
	return ids


func query_of(query_id: int) -> Dictionary:
	return _query_set.get(query_id, {})


# The version the client currently holds, so a test can hand-build a
# Transition that chains correctly and vary only the part under test.
func version() -> Dictionary:
	return _version.duplicate()


func is_open() -> bool:
	if _peer == null:
		return false
	return _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func poll() -> void:
	if _accepting and _server.is_connection_available():
		_accept()
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_peer = null
		return
	while _peer != null and _peer.get_available_packet_count() > 0:
		var text := _peer.get_packet().get_string_from_utf8()
		var parsed := ConvexValues.parse_object(text, "client message")
		if ConvexResult.is_failure(parsed):
			continue
		_receive(parsed["value"])


# Drop the connection the way a broken network does: no close frame, no
# warning, just a socket that stops existing.
func drop() -> void:
	if _peer == null:
		return
	_peer.close(-1)
	_peer = null


func stop() -> void:
	drop()
	_server.stop()


func send_query_updated(query_id: int, value: Variant, logs: Array = []) -> void:
	send_transition([_updated(query_id, value, logs)])


func send_query_failed(query_id: int, message: String, data: Variant = null) -> void:
	var modification := {"type": "QueryFailed", "queryId": query_id}
	modification["errorMessage"] = message
	modification["logLines"] = []
	if data != null:
		modification["errorData"] = data
	send_transition([modification])


# Send one Transition that chains from the version the client currently holds
# to a new one with a strictly increasing timestamp.
func send_transition(modifications: Array) -> void:
	if _peer == null:
		return
	_timestamp += 1
	var end_version := {"querySet": _query_set_version, "identity": 0}
	end_version["ts"] = encode_timestamp(_timestamp)
	var message := {"type": "Transition", "startVersion": _version}
	message["endVersion"] = end_version
	message["modifications"] = modifications
	_peer.send_text(JSON.stringify(message))
	_version = end_version


# Send anything at all, including traffic no Convex deployment would produce,
# without advancing the fixture's own version.
func send_raw(message: Dictionary) -> void:
	if _peer == null:
		return
	_peer.send_text(JSON.stringify(message))


# Convex sync is a text protocol. A binary frame is protocol drift, and the
# client has to say so rather than guessing at the payload.
func send_binary(payload: PackedByteArray) -> void:
	if _peer == null:
		return
	_peer.send(payload, WebSocketPeer.WRITE_MODE_BINARY)


static func encode_timestamp(value: int) -> String:
	var bytes := PackedByteArray()
	bytes.resize(8)
	var remaining := value
	for index in 8:
		bytes[index] = remaining & 0xFF
		remaining >>= 8
	return Marshalls.raw_to_base64(bytes)


func _accept() -> void:
	var stream := _server.take_connection()
	stream.set_no_delay(true)
	_stream = stream
	if not _upgrading:
		return
	var peer := WebSocketPeer.new()
	peer.inbound_buffer_size = INBOUND_BUFFER_BYTES
	# Large enough to send one Convex value that crosses many TCP segments,
	# which is what the reassembly test needs.
	peer.outbound_buffer_size = INBOUND_BUFFER_BYTES
	if peer.accept_stream(stream) != OK:
		return
	_peer = peer
	_connection_total += 1
	# Each connection starts a fresh query set and version, exactly as the
	# client assumes when it replays its active queries.
	_query_set = {}
	_query_set_version = 0
	_version = _zero_version()


func _receive(message: Dictionary) -> void:
	_messages.push_back(message)
	var kind := str(message.get("type", ""))
	if kind == "Connect":
		_connects.push_back(message)
		return
	if kind != "ModifyQuerySet":
		return
	_query_set_version = int(message.get("newVersion", 0))
	var hydrate := []
	for modification in message.get("modifications", []):
		var query_id := int(modification.get("queryId", 0))
		var modification_kind := str(modification.get("type", ""))
		if modification_kind == "Add":
			var entry := {"udfPath": str(modification.get("udfPath", ""))}
			entry["args"] = modification.get("args", [])
			_query_set[query_id] = entry
			if _auto_values.has(entry["udfPath"]):
				hydrate.push_back(_updated(query_id, _auto_values[entry["udfPath"]], []))
		elif modification_kind == "Remove":
			_query_set.erase(query_id)
	# One Transition carries the whole batch, which is what a replayed query
	# set looks like after a reconnect.
	if not hydrate.is_empty():
		send_transition(hydrate)


static func _updated(query_id: int, value: Variant, logs: Array) -> Dictionary:
	var modification := {"type": "QueryUpdated", "queryId": query_id}
	modification["value"] = value
	modification["logLines"] = logs
	return modification


static func _zero_version() -> Dictionary:
	var version := {"querySet": 0, "identity": 0}
	version["ts"] = ConvexValues.INITIAL_TIMESTAMP
	return version
