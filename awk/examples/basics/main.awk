# Convex from Awk: the shared counter journey.
#
# The program reads a room's counter over Convex's documented HTTP API, starts
# a Live subscription, increments the counter once, and proves that the Live
# subscription reported the same change without polling.
#
# Run it with:  CONVEX_URL=https://<deployment>.convex.cloud convex-example <room>

@include "convex.awk"

BEGIN {
    # The example test includes this file to check its decoding rules directly.
    # Running the program normally is the default; nothing else changes.
    if (EXAMPLE_LIBRARY_ONLY != 1) {
        exit example_main()
    }
}

# Convex returns the room state as a JSON object. This narrows it to the
# non-negative integer the output contract needs, and refuses anything else.
function example_count(value, operation,    mark, root, node, literal, count) {
    mark = cx_json_mark()
    root = cx_json_parse(value, 0)
    if (root < 0 || cx_json_type(root) != "object") {
        cx_json_release(mark)
        return example_fail(operation " did not return a Convex object")
    }
    node = cx_json_find(root, "count")
    if (node < 0 || cx_json_type(node) != "number") {
        cx_json_release(mark)
        return example_fail(operation " returned no count")
    }
    literal = cx_json_text(node)
    cx_json_release(mark)
    # Convex JSON may encode an integral number as 0 or as 0.0. Both are
    # accepted; fractional, non-finite, and out-of-range values are not.
    if (!convex_integral(literal) || literal + 0 < 0) {
        return example_fail(operation " returned a non-integral or negative count")
    }
    count = literal + 0
    return count
}

# One failure channel. Diagnostics belong on stderr so that stdout stays the
# exact shared transcript.
function example_fail(message) {
    EXAMPLE_FAILED = 1
    print "Awk example failed: " message > "/dev/stderr"
    fflush("/dev/stderr")
    return -1
}

# Wait for the next value this subscription publishes, and surface a reactive
# query failure as a failure rather than as a missing value.
function example_next(operation, update) {
    if (!convex_wait_update("counter", 15000, update)) {
        return example_fail(operation ": " convex_error_message())
    }
    if (update["errorName"] != "") {
        return example_fail(operation ": " update["errorMessage"])
    }
    return example_count(update["value"], operation)
}

function example_main(    url, room, arguments, response, current, initial, updated, expected, mutation, mark, root, node, applied, state, state_count) {
    url = ENVIRON["CONVEX_URL"]
    if (url == "") {
        return example_fail("CONVEX_URL is required")
    }
    # The verifier passes a unique room as the first argument; the environment
    # variable and the literal default only make a hand run convenient.
    room = ARGV[1]
    if (room == "") {
        room = ENVIRON["EXAMPLE_ROOM"]
    }
    if (room == "") {
        room = "awk-example"
    }

    # Configure one native Awk client for the deployment the container names.
    if (!convex_open(url, "awk-0.1.0")) {
        return example_fail(convex_error_message())
    }
    arguments = "{\"room\":" convex_quote(room) "}"

    # Read the current value through Convex's documented HTTP query endpoint.
    if (!convex_query("demo:state", arguments, response)) {
        return example_shutdown(example_fail("query: " convex_error_message()))
    }
    current = example_count(response["value"], "current query")
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    printf "current count: %d\n", current

    # Start Live before mutating. Subscribing first is what makes the update
    # below an observation rather than a race.
    if (!convex_subscribe("counter", "demo:state", arguments)) {
        return example_shutdown(example_fail("subscribe: " convex_error_message()))
    }

    # The first Live value hydrates the same state the HTTP query returned.
    initial = example_next("initial Live value", response)
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    if (initial != current) {
        return example_shutdown(example_fail("the initial Live count disagreed with HTTP"))
    }
    printf "live initial count: %d\n", initial

    # runId is the mutation's idempotency key. Convex records it, so a repeated
    # run of the same key returns the previous result instead of incrementing
    # twice. A fresh random key means this run really applies its increment.
    mutation = "{\"room\":" convex_quote(room) ",\"language\":\"awk\",\"runId\":" \
        convex_quote(convex_random_hex(16)) "}"
    if (!convex_mutation("demo:increment", mutation, response)) {
        return example_shutdown(example_fail("mutation: " convex_error_message()))
    }

    mark = cx_json_mark()
    root = cx_json_parse(response["value"], 0)
    node = (root < 0) ? -1 : cx_json_find(root, "applied")
    applied = (node >= 0) ? cx_json_type(node) : ""
    node = (root < 0) ? -1 : cx_json_find(root, "state")
    state = (node >= 0) ? cx_json_encode(node) : ""
    cx_json_release(mark)
    if (applied != "true") {
        return example_shutdown(example_fail("the mutation was not applied"))
    }

    expected = current + 1
    state_count = example_count(state, "mutation")
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    if (state_count != expected) {
        return example_shutdown(example_fail("the mutation returned an unexpected count"))
    }
    print "mutation applied: true"
    printf "mutation count: %d\n", state_count

    # Receive the same change over Live, without polling HTTP again.
    updated = example_next("updated Live value", response)
    if (EXAMPLE_FAILED) {
        return example_shutdown(1)
    }
    if (updated != expected) {
        return example_shutdown(example_fail("the updated Live count disagreed with the mutation"))
    }
    printf "live updated count: %d\n", updated

    # Every operation agreed before this proof line is printed.
    printf "verified count: %d -> %d\n", current, updated
    return example_shutdown(0)
}

# Close the Live socket and drop every subscription within a bounded budget, so
# a stalled deployment cannot keep the example running.
function example_shutdown(status) {
    convex_close_live(2000)
    fflush("/dev/stdout")
    return status < 0 ? 1 : status
}
