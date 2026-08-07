class_name ConvexHttpFixture
extends RefCounted

# A minimal in-process HTTP/1.1 origin server for the transport tests.
#
# It is deliberately not a general server. It captures the exact bytes the
# client sent, so header and body assertions are made against the wire rather
# than against the client's own idea of what it sent, and it can answer with
# the malformed, oversized, or silent responses a real deployment should never
# produce but a strict client still has to survive.
#
# Every write uses put_partial_data from poll(), so the fixture never blocks
# inside the same thread the client is polling on.

const HOST := "127.0.0.1"
const CHUNK_BYTES := 65536

var _server := TCPServer.new()
var _port: int = 0
var _connections: Array = []
var _responses: Array = []
var _requests: Array = []
var _stalled: bool = false


func start() -> Dictionary:
	var listening := _server.listen(0, HOST)
	if listening != OK:
		return ConvexResult.transport_failure("fixture cannot listen: %d" % listening)
	_port = _server.get_local_port()
	return ConvexResult.ok(_port)


func url() -> String:
	return "http://%s:%d" % [HOST, _port]


# Queue one response. Later requests are answered in the order queued, so a
# test can script a whole conversation before it starts.
func queue(status: int, body: String, options: Dictionary = {}) -> void:
	var response := {"status": status, "body": body}
	response["chunked"] = options.get("chunked", false)
	response["content_type"] = options.get("content_type", "application/json")
	response["declared_length"] = options.get("declared_length", -1)
	_responses.push_back(response)


# Accept connections but never answer them, so the client's absolute deadline
# is the only thing that can end the call.
func set_stalled(stalled: bool) -> void:
	_stalled = stalled


func requests() -> Array:
	return _requests


func poll() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		peer.set_no_delay(true)
		var connection := {"peer": peer, "answered": false}
		connection["input"] = PackedByteArray()
		connection["output"] = PackedByteArray()
		_connections.push_back(connection)
	for connection in _connections:
		_service(connection)


func stop() -> void:
	for connection in _connections:
		connection["peer"].disconnect_from_host()
	_connections.clear()
	_server.stop()


func _service(connection: Dictionary) -> void:
	var peer: StreamPeerTCP = connection["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var available := peer.get_available_bytes()
	if available > 0:
		var received: Array = peer.get_partial_data(available)
		if received[0] == OK:
			# Packed arrays are value types in GDScript, so the buffer is read
			# out, extended, and written back rather than mutated in place.
			var input: PackedByteArray = connection["input"]
			input.append_array(received[1])
			connection["input"] = input
	if not connection["answered"]:
		var request := _parse_request(connection["input"])
		if request["complete"]:
			connection["answered"] = true
			_requests.push_back(request)
			if not _stalled:
				connection["output"] = _next_response()
	_write(connection)


func _write(connection: Dictionary) -> void:
	var output: PackedByteArray = connection["output"]
	if output.is_empty():
		return
	var peer: StreamPeerTCP = connection["peer"]
	var written: Array = peer.put_partial_data(output)
	if written[0] != OK:
		# The client gave up on this response, which is exactly what the
		# oversized-body test expects to happen.
		connection["output"] = PackedByteArray()
		peer.disconnect_from_host()
		return
	connection["output"] = output.slice(written[1])


func _parse_request(input: PackedByteArray) -> Dictionary:
	var separator := _find_header_end(input)
	if separator < 0:
		return {"complete": false}
	var head := input.slice(0, separator).get_string_from_utf8()
	var lines := head.split("\r\n")
	var length := 0
	for index in range(1, lines.size()):
		var line: String = lines[index]
		if line.to_lower().begins_with("content-length:"):
			length = line.substr(line.find(":") + 1).strip_edges().to_int()
	var body_start := separator + 4
	if input.size() - body_start < length:
		return {"complete": false}
	var request := {"complete": true, "headers": lines}
	request["body"] = input.slice(body_start, body_start + length).get_string_from_utf8()
	return request


# Return the exact header line, if any, so a test can assert what went over
# the wire instead of trusting the client to describe itself.
static func header_of(request: Dictionary, name: String) -> String:
	var wanted := name.to_lower() + ":"
	for line in request["headers"]:
		if line.to_lower().begins_with(wanted):
			return line.substr(line.find(":") + 1).strip_edges()
	return ""


static func _find_header_end(input: PackedByteArray) -> int:
	for index in range(0, maxi(input.size() - 3, 0)):
		if input[index] != 13:
			continue
		if input[index + 1] == 10 and input[index + 2] == 13 and input[index + 3] == 10:
			return index
	return -1


func _next_response() -> PackedByteArray:
	if _responses.is_empty():
		return "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n".to_utf8_buffer()
	var response: Dictionary = _responses.pop_front()
	var body: PackedByteArray = str(response["body"]).to_utf8_buffer()
	var head := "HTTP/1.1 %d Fixture\r\n" % response["status"]
	head += "Content-Type: %s\r\n" % response["content_type"]
	head += "Connection: close\r\n"
	if response["chunked"]:
		head += "Transfer-Encoding: chunked\r\n\r\n"
		return _chunked(head, body)
	var declared: int = response["declared_length"]
	head += "Content-Length: %d\r\n\r\n" % (body.size() if declared < 0 else declared)
	var bytes := head.to_utf8_buffer()
	bytes.append_array(body)
	return bytes


static func _chunked(head: String, body: PackedByteArray) -> PackedByteArray:
	var bytes := head.to_utf8_buffer()
	var offset := 0
	while offset < body.size():
		var size := mini(CHUNK_BYTES, body.size() - offset)
		bytes.append_array(("%x\r\n" % size).to_utf8_buffer())
		bytes.append_array(body.slice(offset, offset + size))
		bytes.append_array("\r\n".to_utf8_buffer())
		offset += size
	bytes.append_array("0\r\n\r\n".to_utf8_buffer())
	return bytes
