class_name ConvexHttp
extends RefCounted

# Bounded HTTP/1.1 transport built on Godot's HTTPClient.
#
# HTTPRequest is the usual Godot entry point, but it is a Node: it needs a
# scene tree, it buffers the whole response for you, and it reports completion
# through a signal. HTTPClient is the lower-level API this client wants
# instead, because Convex conformance needs three things HTTPRequest does not
# offer directly: one absolute deadline covering DNS, TLS, the request write
# and every body chunk; a byte budget enforced while the body is still
# streaming; and the ability to run with no scene tree, so the same transport
# serves the example, the tests, and the conformance adapter.
#
# Godot supplies ordinary TLS and HTTP framing here. Everything Convex-shaped
# lives in convex.gd.

const MAX_RESPONSE_BYTES := 2 * 1024 * 1024
const READ_CHUNK_BYTES := 65536
const DEFAULT_TIMEOUT_MSEC := 30000
const POLL_DELAY_MSEC := 1

# A host loop may hand the transport something useful to do while it waits.
# The conformance adapter passes its Live pump here so a slow HTTP call cannot
# starve an open WebSocket, and the tests pass their in-process fixture server.
var _pump: Callable
var _tls_options: TLSOptions
var _timeout_msec: int


func _init(options: Dictionary = {}) -> void:
	_pump = options.get("pump", Callable())
	_tls_options = options.get("tls_options", null)
	_timeout_msec = options.get("timeout_msec", DEFAULT_TIMEOUT_MSEC)


# Split a deployment URL into the parts HTTPClient needs. Godot has no URL
# type, so the parsing is explicit here, and anything ambiguous is rejected
# rather than guessed at.
static func parse_url(url: String) -> Dictionary:
	if url.contains("\r") or url.contains("\n"):
		return ConvexResult.protocol_failure("Convex URL must not contain a line break")
	var scheme := ""
	var rest := ""
	if url.begins_with("https://"):
		scheme = "https"
		rest = url.substr(8)
	elif url.begins_with("http://"):
		scheme = "http"
		rest = url.substr(7)
	else:
		return ConvexResult.protocol_failure("Convex URL must use http:// or https://")

	var authority := rest
	var path := "/"
	var path_start := rest.find("/")
	if path_start >= 0:
		authority = rest.substr(0, path_start)
		path = rest.substr(path_start)
	if authority.is_empty():
		return ConvexResult.protocol_failure("Convex URL must include a host")
	# Credentials in the URL would leak into logs and into every retry, and
	# Convex never needs them, so they are refused instead of quietly stripped.
	if authority.contains("@"):
		return ConvexResult.protocol_failure("Convex URL must not include user information")

	var authority_parts := _split_authority(authority, scheme)
	if ConvexResult.is_failure(authority_parts):
		return authority_parts

	var parts: Dictionary = authority_parts["value"]
	parts["scheme"] = scheme
	parts["path"] = path.trim_suffix("/")
	parts["tls"] = scheme == "https"
	return ConvexResult.ok(parts)


static func _split_authority(authority: String, scheme: String) -> Dictionary:
	var default_port := 443 if scheme == "https" else 80
	if authority.begins_with("["):
		var close_bracket := authority.find("]")
		if close_bracket < 0:
			return ConvexResult.protocol_failure("Convex URL has an unterminated IPv6 host")
		var literal := authority.substr(1, close_bracket - 1)
		var tail := authority.substr(close_bracket + 1)
		if tail.is_empty():
			return _authority(literal, default_port)
		if not tail.begins_with(":"):
			return ConvexResult.protocol_failure("Convex URL has a malformed IPv6 authority")
		return _authority_with_port(literal, tail.substr(1))
	var separator := authority.rfind(":")
	if separator < 0:
		return _authority(authority, default_port)
	return _authority_with_port(authority.substr(0, separator), authority.substr(separator + 1))


static func _authority(host: String, port: int) -> Dictionary:
	if host.is_empty():
		return ConvexResult.protocol_failure("Convex URL must include a host")
	return ConvexResult.ok({"host": host, "port": port})


static func _authority_with_port(host: String, port_text: String) -> Dictionary:
	if not port_text.is_valid_int():
		return ConvexResult.protocol_failure("Convex URL has a non-numeric port")
	var port := port_text.to_int()
	if port < 1 or port > 65535:
		return ConvexResult.protocol_failure("Convex URL port is out of range")
	return _authority(host, port)


# POST one JSON document and return {"status": int, "body": String}. The
# target dictionary is a parse_url result whose "path" is the full request
# path, so this function never has to know what a Convex endpoint looks like.
func post(target: Dictionary, headers: PackedStringArray, body: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + _timeout_msec
	var client := HTTPClient.new()
	client.read_chunk_size = READ_CHUNK_BYTES
	client.blocking_mode_enabled = false

	var tls: TLSOptions = null
	if target["tls"]:
		# ConvexClient always supplies tls_options built from this client's
		# bundled trust store (see certs.gd) unless a caller overrides it, so
		# TLSOptions.client() here is reached only when this transport is
		# used directly, outside ConvexClient, with no chain of its own -
		# Godot's own default, which does not work in this runtime (see
		# certs.gd for why).
		tls = _tls_options if _tls_options != null else TLSOptions.client()
	var started := client.connect_to_host(target["host"], target["port"], tls)
	if started != OK:
		client.close()
		return ConvexResult.transport_failure("connect to Convex failed: %d" % started)

	var connected := _await_connected(client, deadline)
	if ConvexResult.is_failure(connected):
		client.close()
		return connected

	var requested := client.request(HTTPClient.METHOD_POST, target["path"], headers, body)
	if requested != OK:
		client.close()
		return ConvexResult.transport_failure("write Convex request failed: %d" % requested)

	var response := _await_response(client, deadline)
	client.close()
	return response


func _await_connected(client: HTTPClient, deadline: int) -> Dictionary:
	var status := client.get_status()
	while status != HTTPClient.STATUS_CONNECTED:
		var polled := client.poll()
		if polled != OK:
			return ConvexResult.transport_failure("poll Convex connection failed: %d" % polled)
		status = client.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			break
		if status != HTTPClient.STATUS_RESOLVING and status != HTTPClient.STATUS_CONNECTING:
			return ConvexResult.transport_failure(_status_message(status, "connect"))
		var waited := _wait(deadline, "connect to Convex")
		if ConvexResult.is_failure(waited):
			return waited
	return ConvexResult.ok(true)


func _await_response(client: HTTPClient, deadline: int) -> Dictionary:
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		var polled := client.poll()
		if polled != OK:
			return ConvexResult.transport_failure("poll Convex request failed: %d" % polled)
		if client.get_status() != HTTPClient.STATUS_REQUESTING:
			break
		var waited := _wait(deadline, "send the Convex request")
		if ConvexResult.is_failure(waited):
			return waited

	if not client.has_response():
		return ConvexResult.transport_failure(_status_message(client.get_status(), "request"))
	var code := client.get_response_code()
	# A declared Content-Length above the budget is refused before a single
	# body byte is buffered.
	var declared := client.get_response_body_length()
	if declared > MAX_RESPONSE_BYTES:
		return ConvexResult.transport_failure("Convex response declares %d bytes" % declared)

	var body := _read_body(client, deadline)
	if ConvexResult.is_failure(body):
		return body
	var bytes: PackedByteArray = body["value"]
	if _is_transport_error(client.get_status()):
		return ConvexResult.transport_failure(_status_message(client.get_status(), "response"))
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return ConvexResult.protocol_failure("Convex response was not valid UTF-8")
	return ConvexResult.ok({"status": code, "body": text})


func _read_body(client: HTTPClient, deadline: int) -> Dictionary:
	var bytes := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		var polled := client.poll()
		if polled != OK:
			return ConvexResult.transport_failure("poll Convex response failed: %d" % polled)
		var chunk := client.read_response_body_chunk()
		if chunk.is_empty():
			var waited := _wait(deadline, "read the Convex response")
			if ConvexResult.is_failure(waited):
				return waited
			continue
		# The budget is enforced while the body streams, so a chunked response
		# that never declares a length cannot grow past it either.
		if bytes.size() + chunk.size() > MAX_RESPONSE_BYTES:
			var limit := MAX_RESPONSE_BYTES
			return ConvexResult.transport_failure("Convex response exceeds %d bytes" % limit)
		bytes.append_array(chunk)
	return ConvexResult.ok(bytes)


# One bounded idle step. Every waiting loop in this file goes through here, so
# the deadline is checked in exactly one place and the host loop keeps running.
func _wait(deadline: int, action: String) -> Dictionary:
	if Time.get_ticks_msec() >= deadline:
		return ConvexResult.transport_failure("timed out trying to %s" % action)
	if _pump.is_valid():
		_pump.call()
	OS.delay_msec(POLL_DELAY_MSEC)
	return ConvexResult.ok(true)


static func _is_transport_error(status: int) -> bool:
	if status == HTTPClient.STATUS_CONNECTION_ERROR:
		return true
	return status == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR


static func _status_message(status: int, phase: String) -> String:
	match status:
		HTTPClient.STATUS_CANT_RESOLVE:
			return "cannot resolve the Convex host"
		HTTPClient.STATUS_CANT_CONNECT:
			return "cannot connect to the Convex host"
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "Convex TLS handshake failed"
		HTTPClient.STATUS_CONNECTION_ERROR:
			return "Convex connection failed during %s" % phase
		HTTPClient.STATUS_DISCONNECTED:
			return "Convex closed the connection during %s" % phase
		_:
			return "unexpected Convex connection state %d during %s" % [status, phase]
