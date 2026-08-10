module c3_response;

import std::collections::object;
import std::encoding::json;

faultdef PROTOCOL_ERROR, FUNCTION_ERROR;

// Convex response interpretation stays in C3. `Object*` deliberately keeps
// nested objects, Unicode strings, and document IDs intact instead of
// round-tripping through a lossy scalar representation.
fn Object*? decode_result(String body)
{
    Object* root = json::tparse(body, JSON)!;
    if (!root.is_map()) return PROTOCOL_ERROR~;
    if (root.has_key("errorMessage")) return FUNCTION_ERROR~;
    Object* value = root.get("value") ?? PROTOCOL_ERROR~!;
    return value;
}

fn Object*? decode_logs(String body)
{
    Object* root = json::tparse(body, JSON)!;
    if (!root.is_map()) return PROTOCOL_ERROR~;
    return root.get("logLines") ?? PROTOCOL_ERROR~!;
}
