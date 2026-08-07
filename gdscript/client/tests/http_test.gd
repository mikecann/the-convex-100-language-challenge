extends SceneTree

# Convex HTTP envelope behaviour, asserted against the bytes an origin server
# actually receives and sends.

const SUCCESS_COUNT := '{"status":"success","value":{"count":1.0},"logLines":["counted"]}'
const SUCCESS_TRUE := '{"status":"success","value":true}'


func _init() -> void:
	var harness := ConvexTestHarness.new("http")
	_test_url_parsing(harness)
	_test_argument_validation(harness)
	var fixture := ConvexHttpFixture.new()
	var started := fixture.start()
	if not harness.succeeded(started, "the HTTP fixture starts"):
		quit(harness.report())
		return
	_test_success(harness, fixture)
	_test_bearer_lifecycle(harness, fixture)
	_test_utf8_round_trip(harness, fixture)
	_test_function_error(harness, fixture)
	_test_broken_envelopes(harness, fixture)
	_test_response_limits(harness, fixture)
	_test_deadline(harness, fixture)
	fixture.stop()
	quit(harness.report())


func _test_url_parsing(harness: ConvexTestHarness) -> void:
	var https := ConvexHttp.parse_url("https://example.convex.cloud")
	harness.succeeded(https, "an https deployment URL parses")
	harness.check(https["value"]["port"] == 443, "https defaults to port 443")
	harness.check(https["value"]["tls"], "https selects TLS")
	harness.equal(https["value"]["path"], "", "a bare host has an empty base path")
	var http := ConvexHttp.parse_url("http://backend:3210/")
	harness.check(http["value"]["port"] == 3210, "an explicit port is used")
	harness.check(not http["value"]["tls"], "http does not select TLS")
	harness.equal(http["value"]["host"], "backend", "the host excludes the port")
	# Credentials would leak into logs and every retry, and Convex never needs
	# them, so they are refused rather than stripped.
	var credentials := ConvexHttp.parse_url("https://user:secret@example.convex.cloud")
	harness.failed(credentials, "ProtocolError", "user information is refused")
	harness.failed(ConvexHttp.parse_url("ftp://example.com"), "ProtocolError", "ftp is refused")
	var bad_port := ConvexHttp.parse_url("http://example.com:none")
	harness.failed(bad_port, "ProtocolError", "a non-numeric port is refused")
	var no_host := ConvexHttp.parse_url("http:///api")
	harness.failed(no_host, "ProtocolError", "a missing host is refused")


func _test_argument_validation(harness: ConvexTestHarness) -> void:
	var created := ConvexClient.create("http://127.0.0.1:1")
	var client: ConvexClient = created["value"]
	var no_path := client.call_function("query", "", {})
	harness.failed(no_path, "ProtocolError", "an empty function path is refused")
	var unknown := client.call_function("subscribe", "demo:state", {})
	harness.failed(unknown, "ProtocolError", "an unknown operation is refused")
	# An infinity would be serialized as a bare inf token, which no strict
	# JSON reader accepts, so it never reaches the wire.
	var unsafe := client.query("demo:echo", {"value": INF})
	harness.failed(unsafe, "ProtocolError", "non-JSON-safe arguments are refused")
	var injected := client.set_auth("token\r\nX-Injected: yes")
	harness.failed(injected, "ProtocolError", "a bearer header line break is refused")


func _test_success(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	fixture.queue(200, SUCCESS_COUNT)
	var client := _client(fixture, 5000)
	var result := client.query("demo:state", {"room": "alpha"})
	harness.succeeded(result, "a documented success envelope decodes")
	harness.equal(result["value"], {"count": 1.0}, "the returned value is preserved")
	# Convex keeps function logs separate from the return value, and so does
	# this client.
	harness.equal(ConvexResult.logs_of(result), ["counted"], "log lines travel beside the value")

	var request: Dictionary = fixture.requests()[0]
	harness.equal(request["headers"][0], "POST /api/query HTTP/1.1", "query posts to /api/query")
	var content_type := ConvexHttpFixture.header_of(request, "Content-Type")
	harness.equal(content_type, "application/json", "the request declares JSON")
	var sent := ConvexValues.parse_object(request["body"], "request")
	harness.equal(sent["value"]["path"], "demo:state", "the function path is sent")
	harness.equal(sent["value"]["args"], {"room": "alpha"}, "the arguments are sent verbatim")
	# format: "json" is the documented public value format. This client never
	# sends the undocumented tagged format.
	harness.equal(sent["value"]["format"], "json", "the documented JSON format is requested")


func _test_bearer_lifecycle(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	var client := _client(fixture, 5000)
	fixture.queue(200, SUCCESS_TRUE)
	client.query("demo:state", {"room": "alpha"})
	var anonymous: Dictionary = _last_request(fixture)
	harness.equal(
		ConvexHttpFixture.header_of(anonymous, "Authorization"), "", "no token, no header"
	)

	client.set_auth("opaque.token.value")
	fixture.queue(200, SUCCESS_TRUE)
	client.query("demo:state", {"room": "alpha"})
	var authorized: Dictionary = _last_request(fixture)
	var header := ConvexHttpFixture.header_of(authorized, "Authorization")
	# The configured token is transported exactly, with no reshaping: Convex
	# decides whether it is valid, not this client.
	harness.equal(header, "Bearer opaque.token.value", "the token is sent as a bearer credential")

	client.set_auth("replacement.token")
	fixture.queue(200, SUCCESS_TRUE)
	client.query("demo:state", {"room": "alpha"})
	var replaced := ConvexHttpFixture.header_of(_last_request(fixture), "Authorization")
	harness.equal(replaced, "Bearer replacement.token", "a replaced token is sent")

	client.clear_auth()
	fixture.queue(200, SUCCESS_TRUE)
	client.query("demo:state", {"room": "alpha"})
	var cleared := ConvexHttpFixture.header_of(_last_request(fixture), "Authorization")
	harness.equal(cleared, "", "clearing the token removes the header entirely")


func _test_utf8_round_trip(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	var value := "snø ☃ 🚀 éè"
	fixture.queue(200, JSON.stringify({"status": "success", "value": value}))
	var client := _client(fixture, 5000)
	var result := client.query("demo:echo", {"value": value})
	harness.equal(result["value"], value, "multibyte text survives the round trip")
	var sent := ConvexValues.parse_object(_last_request(fixture)["body"], "request")
	harness.equal(sent["value"]["args"]["value"], value, "multibyte text is sent unchanged")


func _test_function_error(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	var envelope := {"status": "error", "errorMessage": "room is empty"}
	envelope["errorData"] = {"code": "ROOM_EMPTY"}
	envelope["logLines"] = ["about to fail"]
	fixture.queue(200, JSON.stringify(envelope))
	var client := _client(fixture, 5000)
	var result := client.query("demo:fail", {"code": "ROOM_EMPTY"})
	harness.failed(result, "FunctionError", "a Convex application error stays a function error")
	harness.equal(result["error"]["data"], {"code": "ROOM_EMPTY"}, "structured error data survives")
	harness.equal(ConvexResult.logs_of(result), ["about to fail"], "logs survive a failure")

	# Convex may report an application failure with a non-2xx status. The
	# envelope decides, so this is still a function error rather than a
	# transport problem.
	fixture.queue(560, JSON.stringify(envelope))
	var non_2xx := client.query("demo:fail", {"code": "ROOM_EMPTY"})
	harness.failed(non_2xx, "FunctionError", "a 560 with an error envelope is a function error")


func _test_broken_envelopes(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	var client := _client(fixture, 5000)
	# The reverse of the case above is never tolerated: a failing status may
	# not report a successful call.
	fixture.queue(500, SUCCESS_TRUE)
	harness.failed(client.query("demo:state", {}), "ProtocolError", "a 500 cannot report success")

	fixture.queue(200, "<html>gateway</html>", {"content_type": "text/html"})
	var not_json := client.query("demo:state", {})
	harness.failed(not_json, "ProtocolError", "a non-JSON body is a protocol failure")

	fixture.queue(200, "[1, 2, 3]")
	harness.failed(client.query("demo:state", {}), "ProtocolError", "an array root is refused")

	fixture.queue(200, '{"status":"success"}')
	var no_value := client.query("demo:state", {})
	harness.failed(no_value, "ProtocolError", "a success envelope without a value is refused")

	# The envelope carries protocol metadata this client never reads as a
	# number - real deployments send a nanosecond serverTs on Live messages
	# that is nowhere near this exact - so only the value itself, the part a
	# caller actually decodes as a number, is held to is_json_safe.
	fixture.queue(200, '{"status":"success","value":1,"serverTs":1786132596447083569}')
	var metadata_only := client.query("demo:state", {})
	harness.succeeded(metadata_only, "an oversized field outside value does not fail the call")

	fixture.queue(200, '{"status":"success","value":9007199254740993}')
	var unsafe_value := client.query("demo:state", {})
	harness.failed(unsafe_value, "ProtocolError", "a value beyond exact integers is refused")

	fixture.queue(200, '{"status":"queued"}')
	var unknown := client.query("demo:state", {})
	harness.failed(unknown, "ProtocolError", "an unknown envelope status is refused")

	fixture.queue(200, '{"status":"success","value":1,"logLines":"one"}')
	var bad_logs := client.query("demo:state", {})
	harness.failed(bad_logs, "ProtocolError", "malformed logLines are refused")


func _test_response_limits(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	var client := _client(fixture, 10000)
	# A declared Content-Length above the budget is refused before a single
	# body byte is buffered.
	var declared := ConvexHttp.MAX_RESPONSE_BYTES + 1024
	fixture.queue(200, SUCCESS_TRUE, {"declared_length": declared})
	var oversize := client.query("demo:state", {})
	harness.failed(oversize, "TransportError", "an oversized declared length is refused")

	# A chunked response declares no length at all, so the budget has to be
	# enforced while the body streams.
	var filler := "x".repeat(ConvexHttp.MAX_RESPONSE_BYTES + 4096)
	fixture.queue(200, filler, {"chunked": true})
	var streamed := client.query("demo:state", {})
	harness.failed(streamed, "TransportError", "an oversized streamed body is refused")


func _test_deadline(harness: ConvexTestHarness, fixture: ConvexHttpFixture) -> void:
	fixture.set_stalled(true)
	var client := _client(fixture, 400)
	var started := Time.get_ticks_msec()
	var result := client.query("demo:state", {})
	var elapsed := Time.get_ticks_msec() - started
	fixture.set_stalled(false)
	harness.failed(result, "TransportError", "a silent server ends at the deadline")
	# The assertion is the deadline itself, not merely that the call returned.
	harness.check(elapsed < 3000, "the deadline bounded the call (%d ms)" % elapsed)


func _client(fixture: ConvexHttpFixture, timeout_msec: int) -> ConvexClient:
	var options := {"pump": fixture.poll, "timeout_msec": timeout_msec}
	var created := ConvexClient.create(fixture.url(), options)
	return created["value"]


func _last_request(fixture: ConvexHttpFixture) -> Dictionary:
	var requests := fixture.requests()
	return requests[requests.size() - 1]
