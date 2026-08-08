class_name ConvexAdapterEvents
extends RefCounted

# Exact NDJSON adapter protocol v1 event shapes.
#
# The shared controller validates every emitted line against
# _shared/schemas/adapter.schema.json, and an optional field that is present
# but null is not the same as an absent field. These constructors are the only
# place events are built, so "omitted when absent" is provable in one small
# unit test instead of being re-asserted at every call site.

const PROTOCOL_VERSION := 1
const LANGUAGE := "gdscript"
const IMPLEMENTATION := "native-gdscript-godot-httpclient-websocketpeer"


static func ready(id: String) -> Dictionary:
	var event := {"protocolVersion": PROTOCOL_VERSION, "id": id, "type": "ready"}
	event["language"] = LANGUAGE
	event["implementation"] = IMPLEMENTATION
	event["runtime"] = runtime_version()
	return event


static func runtime_version() -> String:
	return "Godot %s" % Engine.get_version_info().get("string", "unknown")


static func ack(id: String) -> Dictionary:
	return {"id": id, "type": "ack"}


static func closed(id: String) -> Dictionary:
	return {"id": id, "type": "closed"}


# A successful call. "value" is always present, including when the function
# returned JSON null, because the schema distinguishes a null result from an
# absent one. Logs travel only when the function actually produced some.
static func result(id: String, call_result: Dictionary) -> Dictionary:
	var event := {"id": id, "type": "result", "value": call_result["value"]}
	return _with_logs(event, ConvexResult.logs_of(call_result))


# A structured failure. The request id is omitted for a command that could not
# be parsed well enough to have one, rather than serialized as null.
static func error(id: String, failure: Dictionary) -> Dictionary:
	var event := {"type": "error", "error": _error_body(failure)}
	if not id.is_empty():
		event["id"] = id
	return _with_logs(event, ConvexResult.logs_of(failure))


# One subscription update. A reactive query failure keeps its structure here
# instead of being flattened into a value or promoted to a request error.
static func subscription(subscription_id: String, update: Dictionary) -> Dictionary:
	var event := {"type": "subscription", "subscriptionId": subscription_id}
	if ConvexResult.is_failure(update):
		event["error"] = _error_body(update)
	else:
		event["value"] = update["value"]
	return _with_logs(event, ConvexResult.logs_of(update))


static func _error_body(failure: Dictionary) -> Dictionary:
	var source: Dictionary = failure["error"]
	var body := {"name": source.get("name", "Error")}
	body["message"] = source.get("message", "unknown failure")
	if source.has("data"):
		body["data"] = source["data"]
	return body


static func _with_logs(event: Dictionary, logs: Array) -> Dictionary:
	if not logs.is_empty():
		event["logs"] = logs
	return event
