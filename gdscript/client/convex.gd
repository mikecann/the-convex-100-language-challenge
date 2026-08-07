class_name ConvexClient
extends RefCounted

# A small native Convex client for Godot 4.
#
# It speaks Convex's documented JSON HTTP API for queries, mutations, and
# actions, and the pinned realtime sync profile for Live subscriptions. Godot
# provides ordinary TLS, HTTP, WebSocket framing, and JSON here; every
# Convex-specific decision - the request envelope, the strict response
# envelope, bearer-token handling, the query set, and reconnect behaviour -
# is implemented in GDScript.
#
# This is educational, unofficial, and not a production SDK.

const CLIENT_VERSION := "gdscript-0.1.0"
const MAX_REQUEST_BYTES := 1 * 1024 * 1024

var _target: Dictionary
var _bearer_token: String = ""
var _http: ConvexHttp
var _live: ConvexLive = null
var _live_options: Dictionary
var _base_url: String
var _closed: bool = false


# Constructing a client validates the deployment URL, which cannot fail from
# inside _init because GDScript constructors cannot return a value. create()
# is the supported entry point and returns the usual result dictionary.
static func create(deployment_url: String, options: Dictionary = {}) -> Dictionary:
	var initial_token: Variant = options.get("bearer_token", "")
	if typeof(initial_token) != TYPE_STRING:
		return ConvexResult.protocol_failure("bearer token must be a string")
	if initial_token.contains("\r") or initial_token.contains("\n"):
		return ConvexResult.protocol_failure("bearer token must not contain a line break")
	var parsed := ConvexHttp.parse_url(deployment_url)
	if ConvexResult.is_failure(parsed):
		return parsed
	return ConvexResult.ok(ConvexClient.new(deployment_url, parsed["value"], options))


func _init(deployment_url: String, target: Dictionary, options: Dictionary = {}) -> void:
	_base_url = deployment_url.trim_suffix("/")
	_target = target
	_bearer_token = options.get("bearer_token", "")
	_http = ConvexHttp.new(options)
	_live_options = options.duplicate()
	_live_options["client_version"] = CLIENT_VERSION


# Convex accepts a bearer token on every function call. Setting an empty
# string clears it, so the same call site can rotate and revoke credentials.
func set_auth(token: String) -> Dictionary:
	if _closed:
		return ConvexResult.closed_failure("Convex client is closed")
	if token.contains("\r") or token.contains("\n"):
		return ConvexResult.protocol_failure("bearer token must not contain a line break")
	_bearer_token = token
	return ConvexResult.ok(true)


func clear_auth() -> Dictionary:
	return set_auth("")


func query(path: String, args: Dictionary) -> Dictionary:
	return call_function("query", path, args)


func mutation(path: String, args: Dictionary) -> Dictionary:
	return call_function("mutation", path, args)


func action(path: String, args: Dictionary) -> Dictionary:
	return call_function("action", path, args)


# One documented Convex HTTP call. The operation name is also the endpoint
# name, so /api/query, /api/mutation, and /api/action share this path.
func call_function(operation: String, path: String, args: Dictionary) -> Dictionary:
	if _closed:
		return ConvexResult.closed_failure("Convex client is closed")
	if operation != "query" and operation != "mutation" and operation != "action":
		return ConvexResult.protocol_failure("unknown Convex operation %s" % operation)
	if path.is_empty():
		return ConvexResult.protocol_failure("Convex function path is required")
	if not ConvexValues.is_json_safe(args):
		return ConvexResult.protocol_failure("Convex arguments must be JSON-safe")

	# format: "json" selects Convex's documented public value format. This
	# client deliberately does not send the undocumented tagged format, so it
	# claims only the JSON-safe subset of Convex values.
	var envelope := {"path": path, "args": args, "format": "json"}
	var body := JSON.stringify(envelope)
	if body.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
		return ConvexResult.transport_failure("Convex request exceeds %d bytes" % MAX_REQUEST_BYTES)

	var target := _target.duplicate()
	target["path"] = "%s/api/%s" % [_target["path"], operation]
	var response := _http.post(target, _headers(), body)
	if ConvexResult.is_failure(response):
		return response
	return _decode_envelope(response["value"], operation)


# Start a reactive query over the Live WebSocket. The Live owner is created
# lazily so an HTTP-only program never opens a socket.
func subscribe(path: String, args: Dictionary) -> Dictionary:
	if _closed:
		return ConvexResult.closed_failure("Convex client is closed")
	return live().subscribe(path, args)


# Advance Live work. A program that only makes HTTP calls never needs this;
# one holding subscriptions calls it from its own loop, and next_update()
# calls it while waiting.
func poll() -> void:
	if _live != null:
		_live.poll()


func live() -> ConvexLive:
	if _live == null:
		_live = ConvexLive.new(_base_url, _live_options)
	return _live


func has_live() -> bool:
	return _live != null


# Test-only fault injection, reached from the conformance adapter's
# debugDisconnect command. It is not part of the educational client API and
# the canonical example never calls it.
func debug_disconnect_for_adapter() -> Dictionary:
	if _live == null:
		return ConvexResult.transport_failure("Live WebSocket is not connected")
	return _live.debug_disconnect()


func close() -> Dictionary:
	if _closed:
		return ConvexResult.ok(true)
	_closed = true
	if _live != null:
		return _live.close()
	return ConvexResult.ok(true)


func _headers() -> PackedStringArray:
	var headers := PackedStringArray()
	headers.append("Content-Type: application/json")
	headers.append("Accept: application/json")
	headers.append("Convex-Client: " + CLIENT_VERSION)
	# The configured token is sent verbatim. Convex, not this client, decides
	# whether it is valid, so nothing here reshapes or validates the string.
	if not _bearer_token.is_empty():
		headers.append("Authorization: Bearer " + _bearer_token)
	return headers


# Decode a Convex HTTP response strictly.
#
# The body is parsed before the status code is consulted, because Convex
# reports application failures with a structured envelope that may arrive with
# a non-2xx status. The reverse is not tolerated: a non-2xx response claiming
# success is a protocol failure, not a value.
func _decode_envelope(response: Dictionary, operation: String) -> Dictionary:
	var code: int = response["status"]
	var parsed := ConvexValues.parse_object(response["body"], "Convex %s response" % operation)
	if ConvexResult.is_failure(parsed):
		var detail := "HTTP %d returned a non-Convex body: %s" % [code, parsed["error"]["message"]]
		return ConvexResult.protocol_failure(detail)
	var envelope: Dictionary = parsed["value"]

	var logs := ConvexValues.log_lines(envelope.get("logLines"), "logLines")
	if ConvexResult.is_failure(logs):
		return logs
	var status := str(envelope.get("status", ""))

	if status == "success":
		if not envelope.has("value"):
			return ConvexResult.protocol_failure("Convex success response omitted value")
		if code < 200 or code > 299:
			return ConvexResult.protocol_failure("HTTP %d reported a successful Convex call" % code)
		var result := ConvexResult.ok(envelope["value"])
		return ConvexResult.with_logs(result, logs["value"])

	if status == "error":
		# errorMessage and errorData are the function's own failure, not a
		# transport problem, so they keep their structure and their logs.
		var message: Variant = envelope.get("errorMessage")
		if typeof(message) != TYPE_STRING:
			return ConvexResult.protocol_failure("Convex error response omitted errorMessage")
		var data: Variant = envelope.get("errorData")
		var failure := ConvexResult.failure(
			ConvexResult.FUNCTION_ERROR, message, data, envelope.has("errorData")
		)
		return ConvexResult.with_logs(failure, logs["value"])

	return ConvexResult.protocol_failure("HTTP %d response has unknown status %s" % [code, status])
