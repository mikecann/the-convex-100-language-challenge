#!/usr/bin/env pike
// Tests for the HTTP/1.1 reader, the Convex envelope classifier, and the
// client's request shape.
//
// The reader is fed one byte at a time wherever framing matters, because the
// network is free to split a response anywhere and a parser that only works on
// whole responses would pass a happy-path test and fail in production.
#include "../convex.pike"
#include "support.pike"

HttpResponse parse_response(string bytes, void|int byte_at_a_time)
{
  HttpResponseParser parser = HttpResponseParser("test");
  if (byte_at_a_time)
    foreach (bytes / "", string byte)
      parser->feed(byte);
  else
    parser->feed(bytes);
  if (!parser->complete)
    parser->end_of_stream();
  return parser->response();
}

void test_content_length_response()
{
  string wire = "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                "Content-Length: 13\r\n"
                "\r\n"
                "{\"status\":1}\n";
  HttpResponse response = parse_response(wire, 1);
  check_equal(response->status, 200, "the status line is parsed");
  check_equal(response->reason, "OK", "the reason phrase is parsed");
  check_equal(response->headers["content-type"], "application/json",
              "header names are folded to lower case");
  check_equal(response->body, "{\"status\":1}\n",
              "a content-length body is delivered exactly");
}

void test_chunked_response()
{
  string wire = "HTTP/1.1 200 OK\r\n"
                "Transfer-Encoding: chunked\r\n"
                "\r\n"
                "5\r\nhello\r\n"
                "7;ext=1\r\n, world\r\n"
                "0\r\n"
                "X-Trailer: ignored\r\n"
                "\r\n";
  HttpResponse response = parse_response(wire, 1);
  check_equal(response->body, "hello, world",
              "chunks, extensions, and trailers are handled");
}

void test_connection_close_framing()
{
  string wire = "HTTP/1.1 200 OK\r\n\r\n{\"status\":\"success\",\"value\":1}";
  HttpResponse response = parse_response(wire);
  check_equal(response->body, "{\"status\":\"success\",\"value\":1}",
              "a body framed only by connection close is accepted");
}

void test_reader_limits()
{
  expect_error(
    lambda() {
      HttpResponseParser parser = HttpResponseParser("test");
      parser->feed("HTTP/1.1 200 OK\r\nX-Big: " + ("a" * 40000));
    },
    PROTOCOL_ERROR, "an oversized header block is rejected");

  expect_error(
    lambda() {
      parse_response("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n");
    },
    PROTOCOL_ERROR, "a declared body larger than the budget is rejected");

  expect_error(
    lambda() {
      parse_response("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort");
    },
    TRANSPORT_ERROR, "a truncated body is a transport failure, not a value");

  expect_error(lambda() { parse_response("HTTP/9 200 OK\r\n\r\n"); },
               PROTOCOL_ERROR, "a non-HTTP/1.x response is rejected");

  expect_error(
    lambda() {
      parse_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n");
    },
    PROTOCOL_ERROR, "an unsupported transfer encoding is rejected");

  expect_error(
    lambda() {
      parse_response("HTTP/1.1 200 OK\r\nX-Folded: one\r\n  two\r\n\r\n");
    },
    PROTOCOL_ERROR, "obsolete header folding is rejected");
}

void test_envelope_success()
{
  CallResult result = decode_envelope(
    json_response(200, "{\"status\":\"success\",\"value\":{\"count\":0},"
                       "\"logLines\":[\"demo:echo said hello\"]}"),
    "query");
  check_equal(result->value, ([ "count": 0 ]), "the success value is returned");
  check_equal(result->logs, ({ "demo:echo said hello" }),
              "log lines travel with the value");

  CallResult nulled = decode_envelope(
    json_response(200, "{\"status\":\"success\",\"value\":null}"), "query");
  ok(json_is_null(nulled->value),
     "an explicit null value is a value, not an omission");
}

void test_envelope_failures()
{
  expect_error(
    lambda() {
      decode_envelope(
        json_response(503, "{\"status\":\"success\",\"value\":0}"), "query");
    },
    PROTOCOL_ERROR, "a non-2xx response may not carry a success envelope");

  expect_error(
    lambda() {
      decode_envelope(json_response(200, "{\"status\":\"success\"}"), "query");
    },
    PROTOCOL_ERROR, "a success envelope without a value is drift");

  expect_error(lambda() { decode_envelope(json_response(200, "[]"), "query"); },
               PROTOCOL_ERROR, "a non-object envelope is rejected");

  expect_error(
    lambda() { decode_envelope(json_response(401, "Unauthorized"), "query"); },
    PROTOCOL_ERROR, "a non-JSON error body is reported, never swallowed");

  expect_error(
    lambda() {
      decode_envelope(
        json_response(200, "{\"status\":\"pending\",\"value\":0}"), "query");
    },
    PROTOCOL_ERROR, "an unknown envelope status is rejected");

  // A rejected Convex function keeps its structured payload: the shared suite
  // reads error.data.code, so flattening this into a string would fail it.
  mixed failed = catch {
    decode_envelope(
      json_response(200, "{\"status\":\"error\",\"errorMessage\":\"boom\","
                         "\"errorData\":{\"code\":\"ROOM_EMPTY\"},"
                         "\"logLines\":[\"tried\"]}"),
      "query");
  };
  ConvexError failure = as_convex_error(failed);
  check_equal(failure->kind, FUNCTION_ERROR,
              "a Convex rejection is a FunctionError");
  check_equal(failure->message, "boom", "the error message is preserved");
  ok(failure->carries_data, "structured error data is marked present");
  check_equal(failure->data, ([ "code": "ROOM_EMPTY" ]),
              "structured error data is preserved");
  check_equal(failure->logs, ({ "tried" }), "failure log lines are preserved");

  // An error envelope with no errorData must not invent one.
  mixed bare = catch {
    decode_envelope(
      json_response(200, "{\"status\":\"error\",\"errorMessage\":\"boom\"}"),
      "query");
  };
  ok(!as_convex_error(bare)->carries_data,
     "absent error data stays absent rather than becoming null");
}

void test_request_building()
{
  mapping target = parse_url("http://backend:3210");
  string request = build_request(target, "POST", "/api/query",
                                 ([ "content-type": "application/json" ]),
                                 "{\"path\":\"demo:state\"}");
  ok(has_prefix(request, "POST /api/query HTTP/1.1\r\n"),
     "the request line names the method and path");
  ok(search(request, "\r\nhost: backend:3210\r\n") > 0,
     "the Host header carries the explicit port");
  ok(search(request, "\r\ncontent-length: 21\r\n") > 0,
     "the content length matches the body");
  ok(has_suffix(request, "\r\n\r\n{\"path\":\"demo:state\"}"),
     "the body follows the blank line");

  expect_error(
    lambda() {
      build_request(target, "POST", "/api/query",
                    ([ "authorization": "Bearer x\r\nX-Injected: 1" ]), "");
    },
    PROTOCOL_ERROR, "a header value may not smuggle a second request line");
}

void test_client_calls()
{
  FakeHttpTransport transport = FakeHttpTransport(({
    json_response(200, "{\"status\":\"success\",\"value\":{\"count\":0}}"),
    json_response(200, "{\"status\":\"success\",\"value\":{\"count\":1}}"),
    json_response(401, "{\"status\":\"error\",\"errorMessage\":\"bad token\"}"),
    json_response(200, "{\"status\":\"success\",\"value\":{\"count\":2}}"),
  }));
  Client client = Client("https://example.convex.cloud/",
                         ([ "transport": transport ]));

  CallResult first = client->query("demo:state", ([ "room": "r" ]));
  check_equal(first->value, ([ "count": 0 ]), "a query returns its value");
  mapping request = transport->requests[0];
  check_equal(request->path, "/api/query", "queries post to /api/query");
  check_equal(request->headers["convex-client"], CLIENT_VERSION,
              "the client version is announced");
  ok(zero_type(request->headers->authorization),
     "no Authorization header is sent without a token");
  check_equal(
    require_object(json_parse_bytes(request->body, "body"), "body"),
    ([ "path": "demo:state", "args": ([ "room": "r" ]), "format": "json" ]),
    "the request envelope names the path, args, and JSON format");

  client->mutation("demo:increment", ([ "room": "r" ]));
  check_equal(transport->requests[1]->path, "/api/mutation",
              "mutations post to /api/mutation");

  // Bearer token lifecycle: set, then cleared. The shared suite proves the same
  // sequence against a real deployment.
  client->set_auth("invalid-token");
  expect_error(lambda() { client->query("demo:state", ([])); },
               FUNCTION_ERROR, "an invalid token surfaces as a Convex error");
  check_equal(transport->requests[2]->headers->authorization,
              "Bearer invalid-token", "the bearer token is sent");
  client->set_auth("");
  client->query("demo:state", ([]));
  ok(zero_type(transport->requests[3]->headers->authorization),
     "clearing the token removes the Authorization header");

  expect_error(lambda() { client->query("demo", ([])); }, PROTOCOL_ERROR,
               "a malformed function path never reaches the network");

  client->close();
  expect_error(lambda() { client->query("demo:state", ([])); }, CLOSED_ERROR,
               "a closed client refuses further calls");
}

int main()
{
  test_content_length_response();
  test_chunked_response();
  test_connection_close_framing();
  test_reader_limits();
  test_envelope_success();
  test_envelope_failures();
  test_request_building();
  test_client_calls();
  return finish("http and envelope");
}
