# Language-local tests for the client's JSON reader and writer, its numeric
# rules, and deployment URL parsing. No sockets are involved.

@include "convex.awk"

BEGIN {
    test_round_trips()
    test_numbers()
    test_strings()
    test_rejections()
    test_integral()
    test_logs()
    test_urls()
    exit report("json_test")
}

function check(condition, label) {
    CHECKS++
    if (!condition) {
        FAILURES++
        print "FAIL " label > "/dev/stderr"
    }
}

function report(name) {
    printf "%s: %d checks, %d failures\n", name, CHECKS, FAILURES
    fflush("/dev/stdout")
    return FAILURES > 0 ? 1 : 0
}

function round_trip(text,    mark, node, encoded) {
    mark = cx_json_mark()
    node = cx_json_parse(text, 0)
    encoded = node < 0 ? "<error:" CX_JSON_ERROR ">" : cx_json_encode(node)
    cx_json_release(mark)
    return encoded
}

function parse_fails(text,    mark, node, failed) {
    mark = cx_json_mark()
    node = cx_json_parse(text, 0)
    failed = (node < 0)
    cx_json_release(mark)
    return failed
}

function test_round_trips(    mark) {
    check(round_trip("{}") == "{}", "empty object round trip")
    check(round_trip("[]") == "[]", "empty array round trip")
    check(round_trip("{\"a\":[1,2,{\"b\":null}],\"c\":true}") == \
        "{\"a\":[1,2,{\"b\":null}],\"c\":true}", "nested round trip")
    check(round_trip("  {\"a\"\t:\n1 }") == "{\"a\":1}", "whitespace is ignored")
    check(round_trip("{\"room\":\"r\",\"count\":0,\"lastLanguage\":null}") == \
        "{\"room\":\"r\",\"count\":0,\"lastLanguage\":null}", "Convex state round trip")

    # Node accounting returns to its mark, so a long-running adapter does not
    # grow one node store forever.
    mark = cx_json_mark()
    round_trip("{\"a\":{\"b\":{\"c\":[1,2,3]}}}")
    check(cx_json_mark() == mark, "parsing releases every node back to its mark")
}

function test_numbers() {
    # Number literals are preserved verbatim rather than being rewritten
    # through an Awk double.
    check(round_trip("{\"n\":1e30}") == "{\"n\":1e30}", "large exponent is preserved")
    check(round_trip("{\"n\":0.30000000000000004}") == "{\"n\":0.30000000000000004}",
        "full precision is preserved")
    check(round_trip("{\"n\":42.5}") == "{\"n\":42.5}", "fraction is preserved")
    check(round_trip("{\"n\":-0}") == "{\"n\":-0}", "negative zero is preserved")
    check(round_trip("[0.0,1.0]") == "[0.0,1.0]", "integral decimal form is preserved")
}

function test_strings(    mark, node, value) {
    check(round_trip("[\"Hello, \344\270\226\347\225\214 \360\237\221\213\"]") == \
        "[\"Hello, \344\270\226\347\225\214 \360\237\221\213\"]", "UTF-8 passes through")
    check(round_trip("[\"\\u00e9\"]") == "[\"\303\251\"]",
        "a \\u escape becomes the same UTF-8 bytes")
    check(round_trip("[\"\\ud83d\\udc4b\"]") == "[\"\360\237\221\213\"]",
        "a surrogate pair becomes one code point")
    check(round_trip("[\"tab\\there\"]") == "[\"tab\\there\"]", "tab is re-escaped")
    check(round_trip("[\"\\u0001\"]") == "[\"\\u0001\"]", "control bytes are escaped")
    check(round_trip("[\"quote\\\"slash\\\\\"]") == "[\"quote\\\"slash\\\\\"]",
        "quote and backslash are escaped")
    check(round_trip("[\"solidus\\/\"]") == "[\"solidus/\"]",
        "an escaped solidus decodes to a plain one")

    mark = cx_json_mark()
    node = cx_json_parse("{\"a\":\"x\",\"b\":\"y\"}", 0)
    value = cx_json_find(node, "b")
    check(cx_json_text(value) == "y", "object lookup finds a member")
    check(cx_json_find(node, "missing") == -1, "object lookup reports a missing member")
    check(cx_json_count(node) == 2, "object member count")
    cx_json_release(mark)
}

function test_rejections(    deep, depth_index) {
    check(parse_fails("{\"a\":1} trailing"), "trailing content is rejected")
    check(parse_fails("{\"a\":}"), "a missing value is rejected")
    check(parse_fails("{a:1}"), "an unquoted key is rejected")
    check(parse_fails("[1,]"), "a dangling comma is rejected")
    check(parse_fails("[01]"), "a leading zero is rejected")
    check(parse_fails("[1.]"), "a bare decimal point is rejected")
    check(parse_fails("[\"\\ud83d\"]"), "an unpaired high surrogate is rejected")
    check(parse_fails("[\"\\udc4b\"]"), "an unpaired low surrogate is rejected")
    check(parse_fails("[\"\\u0000\"]"), "an embedded NUL is rejected")
    check(parse_fails("[\"\\x41\"]"), "an unknown escape is rejected")
    check(parse_fails("[\"unterminated"), "an unterminated string is rejected")
    check(parse_fails("[\"raw\tcontrol\"]"), "an unescaped control byte is rejected")

    deep = ""
    for (depth_index = 0; depth_index < 200; depth_index++) {
        deep = deep "["
    }
    check(parse_fails(deep), "excessive nesting is rejected")

    check(cx_json_parse("{\"a\":1}", 3) < 0, "an oversized document is rejected")
}

function test_integral() {
    check(convex_integral("0") == 1, "0 is integral")
    check(convex_integral("0.0") == 1, "0.0 is integral")
    check(convex_integral("1.0") == 1, "1.0 is integral")
    check(convex_integral("-3") == 1, "-3 is integral")
    check(convex_integral("1e3") == 1, "1e3 is integral")
    check(convex_integral("0.5") == 0, "0.5 is not integral")
    check(convex_integral("1e400") == 0, "an overflowing value is rejected")
    check(convex_integral("9007199254740993") == 0, "an out-of-range value is rejected")
    check(convex_integral("nan") == 0, "nan is rejected")
    check(convex_integral("Infinity") == 0, "Infinity is rejected")
    check(convex_integral("\"1\"") == 0, "a quoted value is rejected")
}

function test_logs(    mark, node) {
    mark = cx_json_mark()
    node = cx_json_parse("[\"one\",\"two\"]", 0)
    check(cx_logs_text(node) == "[\"one\",\"two\"]", "string log lines are forwarded")
    cx_json_release(mark)

    mark = cx_json_mark()
    node = cx_json_parse("[7]", 0)
    check(cx_logs_text(node) == "", "non-string log lines are refused")
    cx_json_release(mark)

    check(cx_logs_text(-1) == "[]", "absent log lines become an empty array")
}

function test_urls(    parsed) {
    check(cx_parse_url("http://backend:3210", parsed) == 1, "plain URL parses")
    check(parsed["host"] == "backend" && parsed["port"] == 3210 && parsed["secure"] == 0,
        "plain URL fields")
    check(parsed["hostHeader"] == "backend:3210", "a non-default port is carried in Host")
    check(cx_parse_url("https://usable-reindeer-44.convex.cloud", parsed) == 1,
        "https URL parses")
    check(parsed["port"] == 443 && parsed["secure"] == 1, "https defaults to port 443")
    check(cx_parse_url("http://example.test/", parsed) == 1, "one trailing slash is accepted")
    check(parsed["host"] == "example.test" && parsed["port"] == 80, "http defaults to port 80")
    check(cx_parse_url("http://example.test/api", parsed) == 0, "a deployment path is rejected")
    check(cx_parse_url("http://user@example.test", parsed) == 0, "userinfo is rejected")
    check(cx_parse_url("http://example.test?x=1", parsed) == 0, "a query is rejected")
    check(cx_parse_url("http://example.test:abc", parsed) == 0, "a nonnumeric port is rejected")
    check(cx_parse_url("ftp://example.test", parsed) == 0, "an unknown scheme is rejected")
    check(cx_parse_url("https://[::1]:8080", parsed) == 0, "an IPv6 URL is rejected clearly")
    check(cx_parse_url("http://example.test:0", parsed) == 0, "port zero is rejected")
}
