# Language-local tests for the Live owner: the pinned sync profile, the query
# set state machine, replay after reconnect, structured failure events, RFC6455
# fragmentation, and bounded shutdown.
#
# The peer is client/tests/fixture.awk in its sync role, driven command by
# command from this test, so every case below is deterministic rather than
# timing-dependent on a real deployment.
#
#   gawk -f client/tests/live_test.awk -v FIXTURE=client/tests/fixture.awk

@include "convex.awk"

BEGIN {
    if (FIXTURE == "") {
        print "live_test: -v FIXTURE=<path> is required" > "/dev/stderr"
        exit 1
    }
    if (!start_fixture()) {
        exit 1
    }
    test_initial_value()
    test_external_update_and_suppression()
    test_query_failure_and_recovery()
    test_control_frames()
    test_fragmented_message()
    test_unsubscribe_barrier()
    test_replacement()
    test_debug_disconnect()
    test_transport_error_recovery()
    test_protocol_error_recovery()
    test_connection_bookkeeping()
    test_bounded_close()
    stop_fixture()
    exit report("live_test")
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
    COMMAND = "gawk -f " FIXTURE " -v ROLE=sync"
    if ((COMMAND |& getline port) <= 0) {
        print "live_test: the fixture did not report a port" > "/dev/stderr"
        return 0
    }
    PORT = port + 0
    return PORT > 0 && convex_open("http://127.0.0.1:" PORT, "awk-test")
}

function stop_fixture() {
    command("quit")
    close(COMMAND)
}

function command(text) {
    print text |& COMMAND
    fflush(COMMAND)
}

# Pump the owner until an update is published or the budget runs out.
function poll_update(timeout_ms, update,    deadline) {
    deadline = convex_now_ms() + timeout_ms
    for (;;) {
        if (convex_next_update(update)) {
            return 1
        }
        if (cx_remaining(deadline) <= 0) {
            return 0
        }
        convex_live_pump(25)
    }
}

function pump_for(budget_ms,    deadline) {
    deadline = convex_now_ms() + budget_ms
    while (cx_remaining(deadline) > 0) {
        convex_live_pump(25)
    }
}

function count_of(value,    mark, node, child, text) {
    mark = cx_json_mark()
    node = cx_json_parse(value, 0)
    child = (node < 0) ? -1 : cx_json_find(node, "count")
    text = (child < 0) ? "" : cx_json_text(child)
    cx_json_release(mark)
    return text
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

function test_initial_value(    update) {
    check(convex_subscribe("a", "demo:state", "{\"room\":\"r\"}") == 1,
        "subscribing opens the Live connection and sends Add")
    check(CX_LIVE_SOCKET >= 0, "the owner holds one WebSocket")
    check(CX_LIVE_QUERY_SET_VERSION == 1, "the query set version advanced to 1")

    command("update 0 0")
    check(poll_update(5000, update) == 1, "the initial value arrives")
    check(update["tag"] == "a" && count_of(update["value"]) == "0",
        "the initial value is the query result")
    check(update["errorName"] == "", "a value update carries no error")
}

function test_external_update_and_suppression(    update) {
    command("update 0 1")
    check(poll_update(5000, update) == 1, "an external change arrives without polling")
    check(count_of(update["value"]) == "1", "the external change carries the new value")

    # A rehydration that repeats the current value must not be republished,
    # which is what keeps the reconnect sequence unambiguous.
    command("update 0 1")
    check(poll_update(750, update) == 0, "an unchanged repeat is suppressed")
}

function test_query_failure_and_recovery(    update) {
    command("fail 0 ROOM_EMPTY")
    check(poll_update(5000, update) == 1, "a reactive failure is delivered")
    check(update["errorName"] == "FunctionError", "a failed query is a function error")
    check(field(update["errorData"], "code") == "ROOM_EMPTY",
        "structured error data survives the sync protocol")

    command("update 0 1")
    check(poll_update(5000, update) == 1, "the same subscription recovers after repair")
    check(count_of(update["value"]) == "1", "the repaired value is delivered")
}

function test_control_frames(    update) {
    command("ping")
    pump_for(300)
    check(CX_LIVE_SOCKET >= 0, "a ping does not disturb the connection")
    command("update 0 2")
    check(poll_update(5000, update) == 1, "the connection still delivers after a ping")
    check(count_of(update["value"]) == "2", "the value after the ping is correct")
}

# A message split across frames must survive read timeouts. After the first
# fragment the parser holds bytes and publishes nothing; only the final frame
# completes the message.
function test_fragmented_message(    update, pending) {
    command("fragment 0 9")
    pump_for(400)
    pending = convex_ws_pending(CX_LIVE_SOCKET)
    check(pending > 0, "the parser retains a partly delivered message across timeouts")
    check(poll_update(300, update) == 0, "no value is published from a partial message")

    command("fragment2")
    pump_for(400)
    check(poll_update(300, update) == 0, "an interleaved control frame does not complete it")

    command("fragment3")
    check(poll_update(5000, update) == 1, "the reassembled message is delivered")
    check(count_of(update["value"]) == "9", "the reassembled value is correct")
    check(field(update["value"], "note") == "fragmented \303\251",
        "fragmented UTF-8 is reassembled byte for byte")
}

# Unsubscribing has to invalidate the old relay before it returns, so a value
# that was already queued can never be delivered afterwards.
function test_unsubscribe_barrier(    update, query_id) {
    check(convex_subscribe("b", "demo:state", "{\"room\":\"second\"}") == 1,
        "a second subscription is added on the same connection")
    query_id = CX_SUB_BY_TAG["b"]
    while (poll_update(200, update)) {
        # Start from an empty queue so the assertions below are exact.
    }
    command("update " query_id " 5")
    pump_for(700)
    check(cx_queue_count() == 1, "the second subscription queued exactly one delivery")

    convex_unsubscribe("b")
    check(!("b" in CX_SUB_BY_TAG), "the subscription is forgotten")
    check(cx_queue_count() == 0,
        "the queued value is invalidated before the unsubscribe returns")
    check(poll_update(400, update) == 0, "no queued value crosses the unsubscribe barrier")

    command("update " query_id " 6")
    check(poll_update(750, update) == 0, "a removed query publishes nothing later")
}

function test_replacement(    update, first, second) {
    first = CX_SUB_BY_TAG["a"]
    command("update " first " 10")
    pump_for(700)
    check(cx_queue_count() == 1, "the old relay has one queued value before replacement")
    check(convex_subscribe("a", "demo:state", "{\"room\":\"replaced\"}") == 1,
        "the same tag can be resubscribed")
    second = CX_SUB_BY_TAG["a"]
    check(second != first, "replacement allocates a new query identifier")
    check(!(first in CX_SUB_PATH), "the replaced query is removed from the active set")
    check(cx_queue_count() == 0,
        "replacement invalidates the old queued relay before returning")

    command("update " first " 99")
    check(poll_update(750, update) == 0, "the replaced query cannot publish")
    command("update " second " 3")
    check(poll_update(5000, update) == 1, "the replacement subscription delivers")
    check(count_of(update["value"]) == "3", "the replacement value is correct")
}

# debugDisconnect is the adapter-only fault injection. It must retire the old
# transport before acknowledging, then reconnect and replay the query set.
function test_debug_disconnect(    update, query_id, attempt, current) {
    query_id = CX_SUB_BY_TAG["a"]
    current = 3
    for (attempt = 1; attempt <= 5; attempt++) {
        check(convex_debug_disconnect() == 1,
            "debugDisconnect " attempt " reports success")
        check(CX_LIVE_SOCKET == -1,
            "debugDisconnect " attempt " retires the old transport before acknowledgement")
        check(cx_queue_count() == 0,
            "debugDisconnect " attempt " drops the old connection queue")
        check(CX_LIVE_LAST_CLOSE == "DebugDisconnect",
            "debugDisconnect " attempt " records the close reason")

        pump_for(1500)
        check(CX_LIVE_SOCKET >= 0,
            "debugDisconnect " attempt " reconnects on its own")
        check(CX_LIVE_BACKOFF_MS == CX_LIVE_INITIAL_BACKOFF_MS,
            "debugDisconnect " attempt " resets backoff after handshake")

        # Every new TCP connection replays Add. Its hydration repeats the
        # current value and must not cross the relay as a fresh publication.
        command("update " query_id " " current)
        check(poll_update(750, update) == 0,
            "debugDisconnect " attempt " suppresses unchanged rehydration")
        current++
        command("update " query_id " " current)
        check(poll_update(5000, update) == 1,
            "debugDisconnect " attempt " delivers a later external change")
        check(count_of(update["value"]) == current,
            "debugDisconnect " attempt " delivers the correct value")
    }
}

function test_transport_error_recovery(    update, query_id) {
    query_id = CX_SUB_BY_TAG["a"]
    command("update " query_id " 77")
    pump_for(500)
    check(cx_queue_count() == 1, "one old-generation value is queued before a drop")
    command("drop")
    pump_for(500)
    check(poll_update(5000, update) == 1, "an unexpected drop publishes an event")
    check(update["errorName"] == "TransportError", "a dropped socket is a transport error")
    check(count_of(update["value"]) != "77",
        "a queued value from the retired transport does not cross recovery")

    pump_for(1500)
    command("update " query_id " 5")
    check(poll_update(5000, update) == 1, "the subscription is not stranded by a drop")
    check(count_of(update["value"]) == "5", "a later valid value still arrives")
}

function test_protocol_error_recovery(    update, query_id) {
    query_id = CX_SUB_BY_TAG["a"]
    command("junk")
    check(poll_update(5000, update) == 1, "an unsupported server message publishes an event")
    check(update["errorName"] == "ProtocolError", "an unsupported message is a protocol error")

    pump_for(1500)
    command("update " query_id " 6")
    check(poll_update(5000, update) == 1, "the subscription recovers after a protocol error")
    check(count_of(update["value"]) == "6", "a later valid value still arrives")
}

function test_connection_bookkeeping(    line, parts, connections, adds, removes) {
    command("report")
    if ((COMMAND |& getline line) > 0) {
        split(line, parts, / /)
        sub(/^connect=/, "", parts[1])
        sub(/^modify=/, "", parts[2])
        sub(/^add=/, "", parts[3])
        sub(/^remove=/, "", parts[4])
        connections = parts[1] + 0
        adds = parts[3] + 0
        removes = parts[4] + 0
        check(connections >= 8, "every reconnect sent a fresh Connect message")
        check(adds >= 8, "every connection replayed the active Add operations")
        check(removes >= 1, "unsubscribing sent a Remove operation")
    } else {
        check(0, "the fixture reported its connection counters")
    }
    if ((COMMAND |& getline line) > 0) {
        check(line ~ /"connectionCount":[1-9]/, "connectionCount grows across reconnects")
        check(line ~ /"lastCloseReason":"/, "lastCloseReason is carried")
        check(line ~ /"maxObservedTimestamp":"/,
            "maxObservedTimestamp is carried once a transition has been seen")
        check(line ~ /"sessionId":"[0-9a-f]{8}-/, "the session identifier is a UUID")
    } else {
        check(0, "the fixture reported the Connect message")
    }
}

# Shutdown must be bounded even though the peer is still connected and idle.
function test_bounded_close(    started, elapsed) {
    started = convex_now_ms()
    check(convex_close_live(200) == 1, "closing Live reports success")
    elapsed = convex_now_ms() - started
    check(elapsed < 1500, "close returns within its budget (" int(elapsed) " ms)")
    check(CX_LIVE_SOCKET == -1, "the socket is released")
    check(CX_LIVE_SUBSCRIPTION_COUNT == 0, "every subscription is dropped")
    check(cx_queue_count() == 0, "the delivery queue is emptied")
}
