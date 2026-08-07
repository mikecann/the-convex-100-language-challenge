# Language-local tests for the conformance adapter.
#
# The first half includes the adapter as a library and checks the exact shape of
# every serialized event, because the shared controller validates each line
# against _shared/schemas/adapter.schema.json and rejects an absent field that
# was written as null. The second half runs the real adapter as a co-process
# against the HTTP fixture and drives a full session over its NDJSON stream.
#
#   gawk -f client/tests/adapter_test.awk -v ADAPTER_LIBRARY_ONLY=1 \
#        -v ADAPTER=client/tests/conformance/adapter.awk \
#        -v FIXTURE=client/tests/fixture.awk

@include "adapter.awk"

BEGIN {
    if (ADAPTER == "" || FIXTURE == "") {
        print "adapter_test: -v ADAPTER=<path> -v FIXTURE=<path> are required" > "/dev/stderr"
        exit 1
    }
    test_event_shapes()
    test_command_schema()
    test_output_bounds()
    test_delivery_queue_bounds()
    test_end_to_end()
    exit report("adapter_test")
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

function has_field(text, key) {
    return index(text, "\"" key "\":") > 0
}

function test_event_shapes(    event) {
    event = adapter_ready("h1")
    check(event ~ /"protocolVersion":1/, "ready reports the protocol version")
    check(event ~ /"type":"ready"/, "ready has the ready type")
    check(event ~ /"language":"awk"/, "ready reports the roster language id")
    check(event ~ /"implementation":"native-awk/, "ready reports its provenance string")
    check(event ~ /"runtime":"gawk /, "ready reports the runtime version")
    check(!has_field(event, "value") && !has_field(event, "error"),
        "ready carries no absent members")

    event = adapter_result("r1", "{\"count\":1}", "[\"log\"]")
    check(event == "{\"id\":\"r1\",\"type\":\"result\",\"value\":{\"count\":1},\"logs\":[\"log\"]}",
        "a result carries id, value, and logs only")

    event = adapter_result("r2", "null", "")
    check(event ~ /"value":null/, "an explicit null value is preserved")
    check(event ~ /"logs":\[\]/, "missing logs become an empty array")

    event = adapter_error("e1", "FunctionError", "boom", "{\"code\":\"X\"}")
    check(event == "{\"id\":\"e1\",\"type\":\"error\",\"error\":{\"name\":\"FunctionError\"," \
        "\"message\":\"boom\",\"data\":{\"code\":\"X\"}}}", "an error carries a structured error")
    check(!has_field(event, "value"), "an error never serializes an absent value")

    event = adapter_ack("a1")
    check(event == "{\"id\":\"a1\",\"type\":\"ack\"}", "an ack has only id and type")
    check(adapter_closed("c1") == "{\"id\":\"c1\",\"type\":\"closed\"}",
        "closed has only id and type")

    event = adapter_subscription_value("s1", "{\"count\":0}", "[]")
    check(event == "{\"type\":\"subscription\",\"subscriptionId\":\"s1\"," \
        "\"value\":{\"count\":0},\"logs\":[]}", "a subscription value has no request id")
    check(index(event, "\"id\":") == 0, "a subscription event never carries a request id")

    event = adapter_subscription_error("s1", "TransportError", "dropped", "null", "[]")
    check(event == "{\"type\":\"subscription\",\"subscriptionId\":\"s1\"," \
        "\"error\":{\"name\":\"TransportError\",\"message\":\"dropped\",\"data\":null}}",
        "a subscription error omits value and empty logs")

    # A message containing quotes and control bytes must still serialize as one
    # NDJSON line.
    event = adapter_error("e2", "ProtocolError", "he said \"stop\"\nnow", "null")
    check(index(event, "\n") == 0, "an event is always a single line")
    check(event ~ /\\"stop\\"/, "quotes inside a message are escaped")
}

function test_output_bounds(    index_, before) {
    adapter_setup_limits()
    for (index_ = 1; index_ <= 40; index_++) {
        adapter_emit(adapter_subscription_value("s", "{\"n\":" index_ "}", "[]"), 1)
    }
    check(adapter_output_count() <= ADAPTER_OUTPUT_COUNT,
        "a stopped reader cannot grow the event queue past its count bound")
    check(ADAPTER_DROPPED > 0, "dropped subscription events are counted")
    check(ADAPTER_OUT_BYTES <= ADAPTER_OUTPUT_BYTES, "the byte budget is respected")

    # Newest wins: the last event queued is still present.
    check(index(ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL], "{\"n\":40}") > 0,
        "the newest event survives")

    adapter_setup_limits()
    before = ADAPTER_STATUS
    for (index_ = 1; index_ <= 8 && ADAPTER_STATUS == 0; index_++) {
        adapter_emit(adapter_result("r" index_, "\"" sprintf("%01000000d", 1) "\"", "[]"), 0)
    }
    check(before == 0 && ADAPTER_STATUS == 1,
        "responses that cannot be dropped fail the adapter instead of growing")
    check(ADAPTER_OUT_BYTES <= ADAPTER_OUTPUT_BYTES,
        "even the failing response is rolled back before the byte budget is crossed")
    adapter_setup_limits()
}

function test_command_schema(    event, id128, id129, index_) {
    adapter_setup_limits()
    adapter_command("{\"protocolVersion\":1,\"id\":7,\"op\":\"hello\"}")
    event = ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL]
    check(event ~ /\"type\":\"error\"/ && index(event, "\"id\":") == 0,
        "a wrong-type id is rejected and never echoed")

    adapter_command("{\"protocolVersion\":1,\"id\":\"extra\",\"op\":\"hello\",\"x\":1}")
    event = ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL]
    check(event ~ /\"id\":\"extra\"/ && event ~ /ProtocolError/,
        "additional command properties are rejected with a valid id")

    adapter_command("{\"id\":\"args\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":[]}")
    event = ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL]
    check(event ~ /ProtocolError/, "call args must be an object")

    for (index_ = 1; index_ <= 128; index_++) {
        id128 = id128 "\360\237\237\250"
    }
    id129 = id128 "\360\237\237\250"
    adapter_command("{\"protocolVersion\":1,\"id\":" convex_quote(id128) ",\"op\":\"hello\"}")
    event = ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL]
    check(event ~ /\"type\":\"ready\"/, "a 128-code-point astral id is accepted")
    adapter_command("{\"protocolVersion\":1,\"id\":" convex_quote(id129) ",\"op\":\"hello\"}")
    event = ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL]
    check(event ~ /\"type\":\"error\"/ && index(event, "\"id\":") == 0,
        "a 129-code-point astral id is rejected and omitted")

    adapter_command("{\"protocolVersion\":1,\"id\":\"recovered\",\"op\":\"hello\"}")
    event = ADAPTER_OUT_TEXT[ADAPTER_OUT_TAIL]
    check(event ~ /\"id\":\"recovered\"/ && event ~ /\"type\":\"ready\"/,
        "the adapter recovers after invalid commands")
    adapter_setup_limits()
}

function test_delivery_queue_bounds(    index_, dropped, update) {
    cx_queue_clear()
    CX_SUB_TAG[0] = "a"
    for (index_ = 1; index_ <= 40; index_++) {
        cx_live_publish_value(0, "{\"n\":" index_ "}", "[]")
    }
    check(cx_queue_count() <= CX_LIVE_QUEUE_COUNT,
        "the Live delivery queue keeps its newest-N bound")
    check(convex_dropped_updates() > 0, "dropped deliveries are counted")
    check(CX_QUEUE_BYTES <= CX_LIVE_QUEUE_BYTES, "the delivery byte budget is respected")

    dropped = convex_dropped_updates()
    check(cx_queue_push("a", sprintf("%05000000d", 1), "[]", "", "", "") == 0,
        "one delivery larger than the whole budget is refused")
    check(convex_dropped_updates() == dropped + 1, "the refused delivery is counted")

    check(convex_next_update(update) == 1, "the queue still hands out its newest deliveries")
    check(update["tag"] == "a", "a delivery carries its subscription tag")
    cx_queue_clear()
    delete CX_SUB_TAG[0]
    delete CX_SUB_SIGNATURE[0]
}

# Drive the real adapter over its NDJSON stream, with the HTTP fixture standing
# in for the deployment.
function test_end_to_end(    port, line, status) {
    FIXTURE_COMMAND = "gawk -f " FIXTURE " -v ROLE=http"
    if ((FIXTURE_COMMAND |& getline port) <= 0) {
        check(0, "the fixture reported a port")
        return
    }
    ADAPTER_COMMAND = "CONVEX_URL=http://127.0.0.1:" (port + 0) " gawk -f " ADAPTER
    line = exchange("{\"protocolVersion\":1,\"id\":\"h\",\"op\":\"hello\"}")
    check(line ~ /"type":"ready"/ && line ~ /"language":"awk"/,
        "the adapter answers hello with a ready event")

    line = exchange("{\"id\":\"q1\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{\"room\":\"r\"}}")
    check(line ~ /"id":"q1"/ && line ~ /"type":"result"/ && line ~ /"count":0/,
        "a query returns a result event")

    line = exchange("{\"id\":\"q2\",\"op\":\"query\",\"path\":\"demo:fail\",\"args\":{\"code\":\"AWK_EXPECTED\"}}")
    check(line ~ /"type":"error"/ && line ~ /"code":"AWK_EXPECTED"/,
        "an application error becomes an error event with its data")

    line = exchange("{\"id\":\"a1\",\"op\":\"setAuth\",\"token\":\"t\"}")
    check(line == "{\"id\":\"a1\",\"type\":\"ack\"}", "setAuth is acknowledged")

    line = exchange("{\"id\":\"u1\",\"op\":\"nonsense\"}")
    check(line ~ /"type":"error"/ && line ~ /unknown operation/,
        "an unknown operation is refused without stopping the session")

    line = exchange("not json at all")
    check(line ~ /"type":"error"/ && index(line, "\"id\":") == 0,
        "a malformed line produces an error event with no request id")

    line = exchange("{\"id\":\"c1\",\"op\":\"close\"}")
    check(line == "{\"id\":\"c1\",\"type\":\"closed\"}", "close is acknowledged")
    status = close(ADAPTER_COMMAND)
    check(status == 0, "the adapter exits cleanly after close (status " status ")")

    print "quit" |& FIXTURE_COMMAND
    fflush(FIXTURE_COMMAND)
    close(FIXTURE_COMMAND)
}

function exchange(request,    line) {
    print request |& ADAPTER_COMMAND
    fflush(ADAPTER_COMMAND)
    if ((ADAPTER_COMMAND |& getline line) <= 0) {
        return "<no response>"
    }
    return line
}
