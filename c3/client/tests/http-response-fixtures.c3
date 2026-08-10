module c3_http_response_fixtures;

import std::io;
import c3_http;
import c3_response;

fn void require(bool condition, String message)
{
    if (condition) return;
    io::eprintfn("FAIL %s", message)!!;
    unreachable();
}

fn void main()
{
    // These are the exact response envelopes that the HTTP transport hands
    // back to C3. They cover query, mutation, and action because all three
    // differ only in the C3-selected endpoint path, not response semantics.
    c3_response::DecodedResponse success = c3_response::decode(`{"status":"success","value":{"count":1.0},"logLines":["hello"]}`)!!;
    require(success.kind == SUCCESS, "success envelope classification");
    require(success.value.is_map(), "success value remains an object");
    require(success.logs.is_array(), "success logLines remain an array");

    c3_response::DecodedResponse function_failure = c3_response::decode(`{"status":"error","errorMessage":"room is empty","errorData":{"code":"ROOM_EMPTY"},"logLines":["failure log"]}`)!!;
    require(function_failure.kind == FUNCTION_FAILURE, "function error classification");
    require(function_failure.error_data.is_map(), "errorData is preserved");
    require(function_failure.logs.is_array(), "error logLines are preserved");

    bool protocol_rejected = false;
    c3_response::DecodedResponse? missing_value = c3_response::decode(`{"status":"success"}`);
    if (catch ignored = missing_value) protocol_rejected = true;
    require(protocol_rejected, "success without value is protocol error");

    String query = c3_http::query_envelope("demo:state", `{"room":"r"}`);
    String mutation = c3_http::mutation_envelope("demo:increment", `{"room":"r"}`, "run-1");
    require(query.contains(`"format":"json"`), "query envelope");
    require(mutation.contains(`"idempotencyKey":"run-1"`), "mutation idempotency key");
    io::eprintfn("http-response-fixtures: PASS")!!;
}
