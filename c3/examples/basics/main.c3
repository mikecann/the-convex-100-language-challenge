module c3_example;

import std::os::env;
import std::io;
import c3_http;
import c3_response;
import c3_values;

// The verifier supplies a unique room as argv[1]. Every call below is made by
// C3 through the same small HTTPS transport used by the adapter.
fn void main(String[] args)
{
    if (args.len < 2) { io::eprintn("usage: convex-example ROOM"); return; }
    String deployment = env::tget_var("CONVEX_URL") ?? "";
    if (!deployment.len) { io::eprintn("CONVEX_URL is required"); return; }
    String room = args[1];
    char[65536] response;
    usz response_length;
    String state_args = string::tformat(`{"room":"%s"}`, room);
    String query = c3_http::query_envelope("counter:get", state_args);
    c3_http::post(deployment, "/api/query", query, "", response[..], &response_length)!!;
    c3_response::DecodedResponse first = c3_response::decode((String)response[:response_length])!!;
    int before = c3_values::parse_counter(string::tformat("%s", first.value))!!;
    if (before != 0) { io::eprintn("expected initial counter 0"); return; }
    String mutation = c3_http::mutation_envelope("counter:increment", state_args, room);
    c3_http::post(deployment, "/api/mutation", mutation, "", response[..], &response_length)!!;
    c3_http::post(deployment, "/api/query", query, "", response[..], &response_length)!!;
    c3_response::DecodedResponse second = c3_response::decode((String)response[:response_length])!!;
    int after = c3_values::parse_counter(string::tformat("%s", second.value))!!;
    if (after != 1) { io::eprintn("expected counter 1"); return; }
    io::printn("HTTP query: 0");
    io::printn("Mutation applied");
    io::printn("HTTP query: 1");
    io::printn("Verification passed");
}
