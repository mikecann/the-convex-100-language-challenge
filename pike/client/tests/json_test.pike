#!/usr/bin/env pike
// Boundary tests for the JSON, URL, and CA-bundle helpers.
//
// These are the decisions every other layer depends on: that a decoded JSON
// null stays a null on the way back out, that an integral 1.0 is accepted while
// 1.5 is not, and that a deployment URL is parsed rather than guessed.
#include "../convex.pike"
#include "support.pike"

void test_value_round_trip()
{
  mixed decoded = json_parse_text("{\"a\":null,\"b\":true,\"c\":false,"
                                  "\"d\":[1,2.5],\"e\":{}}",
                                  "fixture");
  mapping value = require_object(decoded, "fixture");
  ok(json_is_null(value->a), "JSON null decodes to a distinguishable null");
  ok(json_is_true(value->b), "JSON true decodes to a true value");
  ok(json_is_false(value->c), "JSON false decodes to a false value");
  ok(!zero_type(value->a), "a decoded null is present, not absent");
  ok(zero_type(value->missing), "an absent key stays absent");

  // The adapter re-encodes whatever Convex sent. If null, true, or false did
  // not survive this trip, demo:state would answer 0 where the shared suite
  // requires null.
  mapping again = require_object(
    json_parse_bytes(json_bytes(value), "round trip"), "round trip");
  ok(json_is_null(again->a), "null survives an encode and decode round trip");
  ok(json_is_true(again->b), "true survives an encode and decode round trip");
  ok(json_is_false(again->c), "false survives an encode and decode round trip");
  check_equal(again->d, ({ 1, 2.5 }), "mixed number arrays survive intact");
  check_equal(again->e, ([]), "an empty object stays an object");
}

void test_utf8_round_trip()
{
  // Built from code points rather than literal bytes so the test does not
  // depend on how this source file itself is decoded.
  string text = sprintf("%c%c%c", 0x03BA, 0x1F7E8, 0x0645);
  string encoded = json_bytes(({ text }));
  array decoded = require_array(json_parse_bytes(encoded, "utf8"), "utf8");
  check_equal(decoded[0], text, "astral and multi-byte characters round trip");
  expect_error(lambda() { json_parse_bytes("[\"\xff\xfe\"]", "bad utf8"); },
               PROTOCOL_ERROR, "invalid UTF-8 is rejected, not repaired");
}

void test_whole_numbers()
{
  check_equal(require_whole_number(0, "count"), 0, "an integer zero is whole");
  check_equal(require_whole_number(1.0, "count"), 1,
              "Convex may spell one as 1.0");
  check_equal(require_whole_number(-3.0, "count"), -3,
              "negative integral floats are whole");
  expect_error(lambda() { require_whole_number(1.5, "count"); },
               PROTOCOL_ERROR, "a fractional count is rejected");
  expect_error(lambda() { require_whole_number("1", "count"); },
               PROTOCOL_ERROR, "a quoted count is rejected");
  expect_error(lambda() { require_whole_number(Val.null, "count"); },
               PROTOCOL_ERROR, "a null count is rejected");
  expect_error(lambda() { require_whole_number(1.0e30, "count"); },
               PROTOCOL_ERROR, "an out-of-range count is rejected");
}

void test_validators()
{
  expect_error(lambda() { require_object(({}), "args"); }, PROTOCOL_ERROR,
               "an array is not a JSON object");
  expect_error(lambda() { require_uint32(-1, "querySet"); }, PROTOCOL_ERROR,
               "a negative query set version is rejected");
  expect_error(lambda() { require_uint32(1.0, "querySet"); }, PROTOCOL_ERROR,
               "a float query set version is rejected");
  expect_error(lambda() { require_nonempty_string("", "errorMessage"); },
               PROTOCOL_ERROR, "an empty errorMessage is rejected");
  check_equal(require_log_lines(UNDEFINED), ({}),
              "absent logLines mean no logs");
  check_equal(require_log_lines(({ "one" })), ({ "one" }),
              "string logLines are accepted");
  expect_error(lambda() { require_log_lines(({ 1 })); }, PROTOCOL_ERROR,
               "non-string logLines are rejected");
}

void test_url_parsing()
{
  mapping target = parse_url("https://tidy-otter-1.convex.cloud");
  check_equal(target->host, "tidy-otter-1.convex.cloud", "host is extracted");
  check_equal(target->port, 443, "https defaults to port 443");
  check_equal(target->path, "/", "a missing path becomes a root path");
  ok(target->tls, "https implies TLS");

  mapping loopback = parse_url("http://backend:3210");
  check_equal(loopback->port, 3210, "an explicit port is honoured");
  check_equal(loopback->authority, "backend:3210",
              "the authority keeps its explicit port for the Host header");
  ok(!loopback->tls, "http implies no TLS");

  mapping six = parse_url("ws://[::1]:8080/api/sync");
  check_equal(six->host, "::1", "an IPv6 literal loses its brackets");
  check_equal(six->port, 8080, "an IPv6 port is parsed after the brackets");
  check_equal(six->path, "/api/sync", "the path is preserved");

  expect_error(lambda() { parse_url("ftp://example.com"); }, PROTOCOL_ERROR,
               "an unsupported scheme is rejected");
  expect_error(lambda() { parse_url("https://user:pass@example.com"); },
               PROTOCOL_ERROR, "embedded credentials are rejected");
  expect_error(lambda() { parse_url("https://example.com:0"); },
               PROTOCOL_ERROR, "port zero is rejected");
  expect_error(lambda() { parse_url("example.com"); }, PROTOCOL_ERROR,
               "a relative URL is rejected");
}

void test_pem_parsing()
{
  string bundle =
    "# a comment line the parser must ignore\n"
    "-----BEGIN CERTIFICATE-----\n" +
    MIME.encode_base64("first-certificate-bytes", 1) + "\n"
    "-----END CERTIFICATE-----\n"
    "trailing noise\n"
    "-----BEGIN CERTIFICATE-----\n" +
    MIME.encode_base64("second-certificate-bytes", 1) + "\n"
    "-----END CERTIFICATE-----\n";
  array(string) certificates = pem_certificates(bundle);
  check_equal(sizeof(certificates), 2, "both certificates are found");
  check_equal(certificates[0], "first-certificate-bytes",
              "the first certificate decodes to its DER bytes");
  check_equal(certificates[1], "second-certificate-bytes",
              "the second certificate decodes to its DER bytes");
  check_equal(pem_certificates("no certificates here"), ({}),
              "a bundle without certificates yields none");
}

void test_function_paths()
{
  check_equal(require_function_path("demo:state", "query"), "demo:state",
              "a file:export path is accepted");
  expect_error(lambda() { require_function_path("demo", "query"); },
               PROTOCOL_ERROR, "a path without an export is rejected");
  expect_error(lambda() { require_function_path("de mo:state", "query"); },
               PROTOCOL_ERROR, "a path with whitespace is rejected");
}

int main()
{
  test_value_round_trip();
  test_utf8_round_trip();
  test_whole_numbers();
  test_validators();
  test_url_parsing();
  test_pem_parsing();
  test_function_paths();
  return finish("json and url boundary");
}
