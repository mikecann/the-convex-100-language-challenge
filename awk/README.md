# Awk

Awk is a small pattern-scanning and text-processing language [created at Bell
Labs in the 1970s](https://www.gnu.org/software/gawk/manual/html_node/History.html)
by Alfred Aho, Peter Weinberger, and Brian Kernighan. Its name comes from their
surnames. It is still a handy fit for record-oriented jobs such as logs,
reports, and shell pipelines, and it is [standardized by
POSIX](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/awk.html). This
client uses [GNU Awk](https://www.gnu.org/software/gawk/), the GNU implementation
that adds [loadable extensions](https://www.gnu.org/software/gawk/manual/html_node/Dynamic-Extensions.html)
to the core language.

This is an educational, unofficial Convex client, not a production SDK or a
package you should depend on. It demonstrates both HTTP functions and reactive
Live queries while keeping the Convex-specific behaviour in Awk.

## Getting Started

Start with [`examples/basics/main.awk`](examples/basics/main.awk). It reads a
counter, starts a Live query before mutating it, increments with a fresh
idempotency key, and observes the resulting `0 -> 1` update.

From the repository root, run the exact example in its Docker runtime image:

```sh
./run verify-example awk
```

Docker supplies the pinned GNU Awk runtime and compiled transport extension, so
nothing needs to be installed on your host.

## Interesting Parts

### JSON is written by putting strings side by side

Awk — Bell Labs, 1977 — has no string concatenation operator: writing two
expressions next to each other joins them, and the client builds every Convex
argument object exactly that way. A Convex call also has no input file to
scan, so the whole program lives in `BEGIN`, awk's before-any-input hook
moonlighting as `main`.

```awk
BEGIN {
    room = "readme-awk-query-room"
    # Adjacent strings concatenate; there is no operator to forget.
    arguments = "{\"room\":" convex_quote(room) "}"

    if (!convex_open(ENVIRON["CONVEX_URL"], "awk-readme")) exit 1
    # TypeScript: const state = useQuery(api.demo.state, { room })
    if (!convex_query("demo:state", arguments, response)) exit 1
}
```

### The result comes back in the array you hand over

An Awk function can return only a single number or string — but arrays pass by
reference. So every client call takes an array as its final argument and fills
it in place: `response["value"]` holds the result JSON, and a Live update
carries `update["errorName"]` beside its value. Parsed JSON follows the same
spirit: nodes are integer handles you walk, then release with a mark.

```awk
# convex_query filled `response` through its third parameter.
mark = cx_json_mark()
root = cx_json_parse(response["value"], 0)
node = cx_json_find(root, "count")
if (node >= 0 && cx_json_type(node) == "number") {
    print cx_json_text(node)    # TypeScript: state.count
}
cx_json_release(mark)
```

### Four spaces of whitespace are the variable declaration

Awk has no `local` keyword: touch a variable and it is global, unless it
happens to be a function parameter. The time-honored idiom is to pad the
parameter list — callers pass three arguments, and everything after the
conspicuous gap is a fresh local. This is the client's Live wait, verbatim;
the gap before `deadline` is its declaration.

```awk
function convex_wait_update(tag, timeout_ms, update,    deadline) {
    deadline = convex_now_ms() + timeout_ms
    for (;;) {
        while (convex_next_update(update)) {
            if (update["tag"] == tag) {
                return 1
            }
        }
        if (cx_remaining(deadline) <= 0) {
            return cx_fail("TransportError", "timed out waiting for a Live update")
        }
        convex_live_pump(cx_remaining(deadline) > 250 ? 250 : cx_remaining(deadline))
    }
}
```

These fifteen lines are also the reactive heart: one single-threaded process
owns the WebSocket, draining delivered updates and pumping the socket in turn.

### Subscribe first, and the socket proves the increment

Live is verified for this client, and the canonical example leans on it:
subscribe, read the initial value, mutate, then watch the same change arrive
over the WebSocket without polling. Everything React's `useQuery` hides behind
a hook becomes four explicit calls.

```awk
# Subscribe before mutating, so the update is an observation, not a race.
if (!convex_subscribe("counter", "demo:state", arguments)) exit 1
if (!convex_wait_update("counter", 15000, initial)) exit 1

mutation_args = "{\"room\":" convex_quote(room) \
    ",\"language\":\"awk\",\"runId\":" convex_quote(convex_random_hex(16)) "}"
if (!convex_mutation("demo:increment", mutation_args, mutation)) exit 1

# The same change arrives as a pushed update, not a second poll.
if (!convex_wait_update("counter", 15000, updated)) exit 1
convex_unsubscribe("counter")
convex_close_live(2000)
```

## Status

The shared black-box controller passed against local and hosted deployments,
earning HTTP and Live.

| Capability | Status | Evidence |
| --- | --- | --- |
| Docker build and local tests | Passing | `./run test awk` builds GNU Awk 5.3.2 and the extension, then runs seven language-local suites. |
| HTTP query, mutation, and action | Earned | Shared local and hosted conformance passed. |
| Live subscriptions | Earned | Shared local and hosted conformance passed. |
| Implementation provenance | Native | Convex behaviour is implemented in Awk; the C extension supplies transport and framing primitives. |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.awk -->
```awk
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
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

```sh
./run test awk             # builds gawk and the extension from source, runs every local suite
./run verify-example awk   # runs the exact example above against a unique room
./run verify awk           # adds shared black-box conformance against the local backend
./run verify-hosted awk    # repeats both against the hosted drift target
```

`./run test awk` proves that the pinned gawk source builds, that the extension
compiles and loads, that every Awk source parses, and that the local suites
pass. It proves nothing about a real deployment. `./run verify-example awk` runs
the canonical example itself against Convex and compares its stdout with the
shared transcript. `./run verify awk` adds the shared controller, which is the
only thing that can award HTTP or Live.

### Files

| File | Role |
| --- | --- |
| `client/convex.awk` | The client: JSON, the HTTP envelope, the Live owner and state machine, the bounded delivery queue. |
| `client/convexext.c` | The gawk extension: sockets, TLS, deadlines, digests, randomness, RFC6455 framing. |
| `client/Makefile` | Builds the runtime extension and a test build that adds a TLS server hook. |
| `client/tests/` | Language-local suites and the fixture peer they run against. |
| `client/tests/conformance/adapter.awk` | Test-only NDJSON adapter v1 for the shared controller. |
| `examples/basics/main.awk` | The canonical example, projected into this README verbatim. |

### Live

Awk runs a single thread, so the adapter loop owns the WebSocket and alternates
between pumping it and accepting commands. Every step has a monotonic deadline.
After a disconnect, the client reconnects and replays active subscriptions. It
also suppresses an unchanged rehydration value, so reconnecting does not look
like a new application update.

Subscription replacement and unsubscribe clear stale queued values before they
return. Partial WebSocket frames retain their parser state across short reads,
and 64-bit sync timestamps are compared in the extension because an Awk number
cannot represent their low bits exactly.

### Buffering

The client retains the newest eight deliveries within 4 MiB. Older subscription
events may be dropped, but command responses are not. Active subscriptions are
separately capped at 64 entries and 768 KiB so reconnect replay stays below the
WebSocket frame limit. These are client design choices, not Awk language limits.

### The adapter

`client/tests/conformance/adapter.awk` is test infrastructure, not public client
code. It calls the real client for each operation and includes a test-only
disconnect command used to prove reconnect behaviour.

### Tests

Seven suites run inside the Docker test image. They cover JSON, HTTP and TLS,
Live setup and recovery, WebSocket fragmentation, bounded queues, adapter event
shapes, and the canonical example's full counter journey against a deterministic
fixture.

## Known Issues

1. The client is pinned to GNU Awk 5.3.2. A source build of 5.4.1 miscompiled
   an array-subscript condition used by this implementation, so the newer
   toolchain is deliberately not claimed.
2. Awk has no built-in TLS sockets or WebSocket framing. The in-process
   `convexext.c` extension supplies those primitives, while the HTTP envelope,
   JSON handling, Live state machine, reconnect, and replay remain in Awk.
3. The client is single threaded. An HTTP call delays Live reads until that
   call completes or reaches its deadline.
4. WebSocket mutations and actions, Live authentication, optimistic updates,
   journals, and `TransitionChunk` assembly are not implemented.
5. Values cover Convex's JSON-safe subset only. Tagged values such as int64 and
   bytes are out of scope, U+0000 strings are refused, and bracketed IPv6
   deployment URLs are unsupported.
