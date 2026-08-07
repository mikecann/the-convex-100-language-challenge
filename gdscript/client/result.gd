class_name ConvexResult
extends RefCounted

# GDScript has no exceptions and no multiple return values, so every Convex
# operation in this client returns one small dictionary. A result carries
# either "value" or "error", never both, which keeps the failure path as
# visible as the success path at each call site.
#
# The four error names below are the only ones this client produces. They are
# the same names the conformance adapter serializes, so a structured Convex
# function failure can never be flattened into a successful value or into an
# anonymous transport string.

const FUNCTION_ERROR := "FunctionError"
const PROTOCOL_ERROR := "ProtocolError"
const TRANSPORT_ERROR := "TransportError"
const CLOSED_ERROR := "ClosedError"


static func ok(value: Variant) -> Dictionary:
	return {"value": value}


static func failure(
	name: String, message: String, data: Variant = null, include_null_data: bool = false
) -> Dictionary:
	var error := {"name": name, "message": message}
	# Convex application errors may carry structured data, including a
	# deliberate JSON null. Only attach the key when the function produced one
	# so an absent payload is never serialized as a present null.
	if data != null or include_null_data:
		error["data"] = data
	return {"error": error}


static func protocol_failure(message: String) -> Dictionary:
	return failure(PROTOCOL_ERROR, message)


static func transport_failure(message: String) -> Dictionary:
	return failure(TRANSPORT_ERROR, message)


static func closed_failure(message: String) -> Dictionary:
	return failure(CLOSED_ERROR, message)


static func is_failure(result: Dictionary) -> bool:
	return result.has("error")


# Convex reports function logs separately from the returned value. They travel
# beside the value or the error so a caller never has to choose between
# observing output and observing failure.
static func with_logs(result: Dictionary, logs: Array) -> Dictionary:
	if logs.is_empty():
		return result
	result["logs"] = logs
	return result


static func logs_of(result: Dictionary) -> Array:
	return result.get("logs", [])


static func error_name(result: Dictionary) -> String:
	if not is_failure(result):
		return ""
	return result["error"].get("name", "")


static func error_message(result: Dictionary) -> String:
	if not is_failure(result):
		return ""
	return result["error"].get("message", "")
