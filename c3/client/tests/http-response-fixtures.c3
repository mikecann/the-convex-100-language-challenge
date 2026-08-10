module c3_http_response_fixtures;

import std::io;
import c3_http;
import c3_response;
import c3_values;

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

    int counter = c3_values::parse_counter("1.0")!!;
    require(counter == 1, "integral decimal counter accepted");
    int? fractional = c3_values::parse_counter("1.5");
    bool fractional_rejected = false;
    if (catch ignored = fractional) fractional_rejected = true;
    require(fractional_rejected, "fractional counter rejected");

    char[4096] transport_buffer;
    usz response_length = 0;
    CLong query_status = c3_http::post("https://fixture.invalid", "/api/query",
        query, "token", transport_buffer[..], &response_length)!!;
    require(query_status == 200, "query uses C3-selected HTTPS endpoint");
    String transport_response = (String)transport_buffer[:response_length];
    c3_response::DecodedResponse queried = c3_response::decode(transport_response)!!;
    require(queried.kind == c3_response::ResponseKind.SUCCESS, "query fixture success");

    // The fixture verifies that the C3 auth value reaches the ordinary
    // transport boundary as a Bearer credential, without teaching C about
    // Convex operation semantics.
    CLong? rejected_auth_status = c3_http::post("https://fixture.invalid", "/api/query",
        query, "wrong-token", transport_buffer[..], &response_length);
    bool rejected_auth = false;
    if (catch ignored = rejected_auth_status) rejected_auth = true;
    require(rejected_auth, "invalid bearer credential is a transport failure");

    CLong mutation_status = c3_http::post("https://fixture.invalid", "/api/mutation",
        mutation, "token", transport_buffer[..], &response_length)!!;
    require(mutation_status == 200, "mutation carries idempotency key");

    CLong action_status = c3_http::post("https://fixture.invalid", "/api/action",
        query, "", transport_buffer[..], &response_length)!!;
    require(action_status == 200, "action endpoint transport success");
    transport_response = (String)transport_buffer[:response_length];
    c3_response::DecodedResponse action = c3_response::decode(transport_response)!!;
    require(action.kind == c3_response::ResponseKind.FUNCTION_FAILURE, "action function failure classification");
    require(action.error_data.is_map(), "action errorData preserved");

    CLong? transport_status = c3_http::post("https://fixture.invalid", "/api/transport",
        query, "", transport_buffer[..], &response_length);
    bool transport_rejected = false;
    if (catch ignored = transport_status) transport_rejected = true;
    require(transport_rejected, "non-2xx response is transport failure");
    io::eprintfn("http-response-fixtures: PASS")!!;
}
