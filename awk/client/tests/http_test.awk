# Language-local tests for the Convex HTTP envelope, response framing, bearer
# token transport, and error classification.
#
# The peer is client/tests/fixture.awk, started as a co-process. It is an
# independent implementation of the other half of the exchange, so these tests
# exercise the real socket path rather than a mocked response string.
#
#   gawk -f client/tests/http_test.awk -v FIXTURE=client/tests/fixture.awk

@include "convex.awk"

BEGIN {
    if (FIXTURE == "") {
        print "http_test: -v FIXTURE=<path> is required" > "/dev/stderr"
        exit 1
    }
    if (!start_fixture()) {
        exit 1
    }
    test_success()
    test_bearer_token()
    test_function_error()
    test_chunked()
    test_bad_bodies()
    test_client_validation()
    test_deadline()
    stop_fixture()
    exit report("http_test")
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

function start_fixture(    port) {
    COMMAND = "gawk -f " FIXTURE " -v ROLE=http"
    if ((COMMAND |& getline port) <= 0) {
        print "http_test: the fixture did not report a port" > "/dev/stderr"
        return 0
    }
    PORT = port + 0
    if (PORT < 1) {
        print "http_test: the fixture reported an unusable port" > "/dev/stderr"
        return 0
    }
    return convex_open("http://127.0.0.1:" PORT, "awk-test")
}

function stop_fixture() {
    print "quit" |& COMMAND
    fflush(COMMAND)
    close(COMMAND)
}

function field(value, key,    mark, node, child, text) {
    mark = cx_json_mark()
    node = cx_json_parse(value, 0)
    child = (node < 0) ? -1 : cx_json_find(node, key)
    text = (child < 0) ? "<missing>" : (cx_json_type(child) == "string" ?
        cx_json_text(child) : cx_json_encode(child))
    cx_json_release(mark)
    return text
}

function test_success(    response) {
    check(convex_query("demo:state", "{\"room\":\"r\"}", response) == 1,
        "a successful query returns 1")
    check(field(response["value"], "count") == "0", "the query value is decoded")
    check(response["logs"] == "[]", "empty log lines are preserved as an array")

    check(convex_mutation("demo:other", "{\"room\":\"r\"}", response) == 1,
        "a mutation uses the same envelope")
    check(response["value"] == "null", "a null value is preserved rather than dropped")

    check(convex_query("demo:echo", "{\"value\":1}", response) == 1, "logs are returned")
    check(response["logs"] ~ /demo:echo/, "function log lines stay separate from the value")
}

function test_bearer_token(    response) {
    convex_set_auth("secret-token-123")
    check(convex_query("demo:echo", "{\"value\":1}", response) == 1, "an authorised query runs")
    # The fixture echoes the header it received, so this asserts the exact bytes
    # the client put on the wire.
    check(field(response["value"], "authorization") == "Bearer secret-token-123",
        "the configured token is sent verbatim as a bearer token")

    convex_set_auth("replaced-token")
    convex_query("demo:echo", "{\"value\":1}", response)
    check(field(response["value"], "authorization") == "Bearer replaced-token",
        "a replaced token is sent instead of the old one")

    convex_set_auth("")
    convex_query("demo:echo", "{\"value\":1}", response)
    check(field(response["value"], "authorization") == "",
        "clearing the token removes the header entirely")
}

function test_function_error(    response) {
    check(convex_query("demo:fail", "{\"code\":\"AWK_EXPECTED\"}", response) == 0,
        "an application error reports failure")
    check(convex_error_name() == "FunctionError", "an application error is a FunctionError")
    check(convex_error_message() == "Intentional conformance failure",
        "the Convex error message is preserved")
    check(field(convex_error_data(), "code") == "AWK_EXPECTED",
        "structured error data is preserved")
}

function test_chunked(    response) {
    check(convex_query("demo:chunked", "{}", response) == 1,
        "a chunked response is accepted")
    check(field(response["value"], "count") == "7", "a chunked body is reassembled")
}

function test_bad_bodies(    response) {
    check(convex_query("demo:garbage", "{}", response) == 0, "a non-JSON body fails")
    check(convex_error_name() == "ProtocolError", "a non-JSON body is a protocol failure")

    check(convex_query("demo:badlogs", "{}", response) == 0,
        "malformed log lines fail rather than being forwarded")
    check(convex_error_name() == "ProtocolError", "malformed log lines are a protocol failure")

    check(convex_query("demo:http500", "{}", response) == 0,
        "a non-2xx success-shaped body is never accepted")
    check(convex_error_name() == "TransportError", "a non-2xx response is a transport failure")

    check(convex_query("demo:missingmessage", "{}", response) == 0,
        "an error envelope without errorMessage is rejected")
    check(convex_error_name() == "ProtocolError", "a malformed error envelope is a protocol failure")

    check(convex_query("demo:clte", "{}", response) == 0,
        "ambiguous Content-Length plus Transfer-Encoding is rejected")
    check(convex_error_name() == "ProtocolError", "ambiguous HTTP framing is a protocol failure")

    check(convex_query("demo:oversizedchunk", "{}", response) == 0,
        "an oversized chunk is rejected before its body is buffered")
    check(convex_error_name() == "ProtocolError", "an oversized chunk is a protocol failure")

    check(convex_query("demo:badchunk", "{}", response) == 0,
        "a chunk missing its CRLF terminator is rejected")
    check(convex_error_name() == "ProtocolError", "bad chunk framing is a protocol failure")

    check(convex_query("demo:state", "{}", response) == 1,
        "a valid call recovers after rejected HTTP responses")
}

function test_client_validation(    response) {
    check(convex_query("nocolon", "{}", response) == 0, "an invalid function path is refused")
    check(convex_error_name() == "ClientError", "an invalid path is a client error")
    check(convex_query("demo:state", "[1]", response) == 0, "non-object arguments are refused")
    check(convex_query("demo:state", "{oops}", response) == 0, "invalid argument JSON is refused")
    check(convex_set_auth("unsafe\r\ntoken") == 0, "header controls in auth are refused")
    check(convex_error_name() == "ClientError", "an unsafe auth token is a client error")
}

# A silent peer must be ended by the client's own deadline, not by the peer
# closing the connection.
function test_deadline(    response, started, elapsed) {
    convex_set_timeouts(1000, 700)
    started = convex_now_ms()
    check(convex_query("demo:silent", "{}", response) == 0, "a silent peer fails the call")
    elapsed = convex_now_ms() - started
    check(convex_error_name() == "TransportError", "a stalled read is a transport failure")
    check(elapsed >= 500 && elapsed < 2500,
        "the call ends on its own deadline (" int(elapsed) " ms)")
    convex_set_timeouts(5000, 15000)
}
