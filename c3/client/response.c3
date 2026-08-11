module c3_response;

import std::collections::object;
import std::encoding::json;

faultdef PROTOCOL_ERROR, FUNCTION_ERROR;

enum ResponseKind
{
    SUCCESS,
    FUNCTION_FAILURE
}

// The adapter keeps these raw JSON objects until it writes its own NDJSON
// event. That preserves Convex's nested errorData and logLines verbatim.
struct DecodedResponse
{
    ResponseKind kind;
    Object* value;
    Object* error_data;
    Object* logs;
    String error_message;
}

// Convex response interpretation stays in C3. `Object*` deliberately keeps
// nested objects, Unicode strings, and document IDs intact instead of
// round-tripping through a lossy scalar representation.
fn DecodedResponse? decode(String body)
{
    // `tparse` is only safe when the caller consumes the JSON tree in the
    // same temporary-allocation scope. This function returns fields from the
    // tree, so allocate them in the normal allocator instead of returning
    // dangling temporary objects after `decode` returns.
    Object* root = json::parse(mem, body, JSON)!;
    if (!root.is_map()) return PROTOCOL_ERROR~;
    Object* status = root.get("status") ?? PROTOCOL_ERROR~!;
    if (!status.is_string()) return PROTOCOL_ERROR~;
    Object* logs = root.has_key("logLines")
        ? root.get("logLines")!
        : null;
    // C3 0.8.2 leaves an empty JSON array as an empty Object until its first
    // element is pushed. logLines: [] is a valid Convex success envelope.
    if (logs && !logs.is_array() && !logs.is_empty()) return PROTOCOL_ERROR~;
    if (status.s == "success")
    {
        Object* value = root.get("value") ?? PROTOCOL_ERROR~!;
        return { .kind = SUCCESS, .value = value, .logs = logs };
    }
    if (status.s == "error")
    {
        Object* message = root.get("errorMessage") ?? PROTOCOL_ERROR~!;
        if (!message.is_string()) return PROTOCOL_ERROR~;
        Object* data = root.has_key("errorData")
            ? root.get("errorData")!
            : null;
        return { .kind = FUNCTION_FAILURE, .error_message = message.s,
                 .error_data = data, .logs = logs };
    }
    return PROTOCOL_ERROR~;
}
