module c3_adapter;

import std::collections::object;
import std::core::string;
import std::encoding::json;
import std::io;
import std::os::env;
import c3_http;
import c3_response;

// Adapter output is deliberately written only here. C3 owns the command
// routing and Convex response semantics; platform.c only exchanges HTTPS
// bytes and never receives an operation name or Convex response type.
fn void emit(String event)
{
    io::printn(event);
}

// Adapter identifiers are schema-bounded ASCII test identifiers. The full
// client will replace this temporary formatter with JSON string escaping
// before it accepts arbitrary user-provided strings on this protocol surface.
fn String quote(String value) => string::tformat(`"%s"`, value);

fn void emit_error(String id, String name, String message, String data = "null")
{
    if (id.len)
    {
        emit(string::tformat(`{"id":%s,"type":"error","error":{"name":%s,"message":%s,"data":%s}}`,
            quote(id), quote(name), quote(message), data));
        return;
    }
    emit(string::tformat(`{"type":"error","error":{"name":%s,"message":%s,"data":%s}}`,
        quote(name), quote(message), data));
}

fn String object_json(Object* value) => string::tformat("%s", value);

fn void call_http(String id, String op, String path, Object* args, String deployment, String token)
{
    char[65536] response_buffer;
    usz response_length = 0;
    String args_json = object_json(args);
    String payload = op == "mutation"
        ? c3_http::mutation_envelope(path, args_json, id)
        : c3_http::query_envelope(path, args_json);
    String endpoint = op == "query" ? "/api/query" : op == "mutation" ? "/api/mutation" : "/api/action";
    CLong? response_status = c3_http::post(deployment, endpoint, payload, token,
        response_buffer[..], &response_length);
    if (catch ignored = response_status)
    {
        emit_error(id, "TransportError", "HTTPS request failed");
        return;
    }
    String response_json = (String)response_buffer[:response_length];
    c3_response::DecodedResponse? decoded = c3_response::decode(response_json);
    if (catch ignored = decoded)
    {
        emit_error(id, "ProtocolError", "invalid Convex HTTP response");
        return;
    }
    c3_response::DecodedResponse result = decoded;
    if (result.kind == SUCCESS)
    {
        // C3 represents an empty parsed array as an empty Object. In this
        // field the wire contract tells us that the empty value is logLines,
        // so preserve it as [] rather than serializing C3's internal {}.
        String logs_json = !result.logs || result.logs.is_empty() ? "[]" : object_json(result.logs);
        emit(string::tformat(`{"id":%s,"type":"result","value":%s,"logs":%s}`,
            quote(id), object_json(result.value), logs_json));
        return;
    }
    emit_error(id, "FunctionError", result.error_message,
        result.error_data ? object_json(result.error_data) : "null");
}

fn void main()
{
    String deployment = env::tget_var("CONVEX_URL") ?? "";
    String token = "";
    while (true)
    {
        String? maybe_line = io::treadline(limit: 1048576);
        if (catch ignored = maybe_line) return;
        String line = maybe_line;
        Object*? parsed = json::tparse(line, JSON);
        if (catch ignored = parsed)
        {
            emit_error("", "ProtocolError", "invalid adapter JSON");
            continue;
        }
        Object* command = parsed;
        if (!command.is_map() || !command.has_key("op") || !command.has_key("id"))
        {
            emit_error("", "ProtocolError", "adapter command requires id and op");
            continue;
        }
        Object* op = command.get("op")!!;
        Object* id = command.get("id")!!;
        if (!op.is_string() || !id.is_string())
        {
            emit_error("", "ProtocolError", "adapter id and op must be strings");
            continue;
        }
        if (op.s == "hello")
        {
            emit(string::tformat(`{"protocolVersion":1,"id":%s,"type":"ready","language":"c3","implementation":"native","runtime":"C3 0.8.2"}`,
                quote(id.s)));
            continue;
        }
        if (op.s == "setAuth" && command.has_key("token"))
        {
            Object* next_token = command.get("token")!!;
            if (!next_token.is_string()) { emit_error(id.s, "ProtocolError", "token must be a string"); continue; }
            token = next_token.s;
            emit(string::tformat(`{"id":%s,"type":"ack"}`, quote(id.s)));
            continue;
        }
        if (op.s == "close")
        {
            emit(string::tformat(`{"id":%s,"type":"closed"}`, quote(id.s)));
            return;
        }
        if ((op.s == "query" || op.s == "mutation" || op.s == "action")
            && command.has_key("path") && command.has_key("args"))
        {
            Object* path = command.get("path")!!;
            Object* args = command.get("args")!!;
            if (!path.is_string() || !args.is_map()) { emit_error(id.s, "ProtocolError", "path and args are invalid"); continue; }
            if (!deployment.len) { emit_error(id.s, "TransportError", "CONVEX_URL is required"); continue; }
            call_http(id.s, op.s, path.s, args, deployment, token);
            continue;
        }
        emit_error(id.s, "ProtocolError", "unsupported adapter operation");
    }
}
