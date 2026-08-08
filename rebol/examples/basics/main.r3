Rebol [
    Title: "main.r3 -- the canonical Convex-from-REBOL example"
    Purpose: {
        A short tour of the native REBOL Convex client: an HTTP query, a
        Live subscription started before a mutation so the initial
        snapshot cannot be missed, an idempotent mutation, and the
        resulting Live update -- the same shared-counter 0 -> 1 journey
        every client in this repository proves.

        This program is deliberately thin: client/convex.r3 already owns
        every protocol detail (the hand-rolled JSON codec, the hardened
        TLS chain/hostname verification, HTTP framing, the RFC 6455
        WebSocket layer, and the /api/sync Live state machine). Everything
        below just calls its public convex-* functions and checks the
        values Convex actually returned; an unexpected value is a hard
        failure via QUIT/RETURN 1, never a printed warning.

        stdout carries only the six lines the website and video are meant
        to show; every diagnostic goes to stderr instead. REBOL's own
        ports collapse stdout and stdin into a single `console` scheme
        with no separate stderr port, so `secure [file allow]` below
        unlocks just enough of the language's own security sandbox to
        open the real OS file %/dev/stderr for that -- every other
        security category (network access included) keeps its
        restrictive default.
    }
]

;; client-dir is wherever THIS script lives; convex.r3 needs to be found
;; relative to it regardless of the caller's own working directory.
do %../../client/convex.r3

secure [file allow]

;; diagnose(message) -> writes one line to the real OS stderr, kept
;; entirely separate from the six lines of stdout the shared verifier
;; compares byte-for-byte against _shared/examples/basics.expected.txt.
diagnose: function [message [string!] /local err-port] [
    err-port: open/write %/dev/stderr
    write err-port rejoin [message "^/"]
    close err-port
]

;; fail(operation, message) -> reports a failed step on stderr and exits
;; non-zero. Never returns, so every call site below can rely on whatever
;; it was checking having held from this point on.
fail: function [operation [string!] message [string!]] [
    diagnose rejoin [operation ": " message]
    quit/return 1
]

;; check-result(operation, response) -> fails unless a convex-query/
;; mutation call actually succeeded; convex-call already classifies a
;; transport failure, an HTTP-level failure, and a Convex-level function
;; error into the same response/ok = false shape, so this one check
;; covers all three.
check-result: function [operation [string!] response] [
    unless response/ok [
        fail operation rejoin [convex-error-name ": " convex-error-message]
    ]
]

;; check-count(operation, value, expected) -> pulls "count" out of a
;; decoded Convex value (a query result, a mutation's returned state, or
;; a Live update) and fails unless it is exactly `expected`.
;; convex-field-integer already accepts Convex's integral-decimal
;; spellings such as 0.0, so this never has to special-case one itself;
;; a non-object value fails here too, rather than crashing on a type
;; REBOL's own function dispatch did not expect.
check-count: function [operation [string!] value expected [integer!] /local count] [
    unless map? value [fail operation "value is not a JSON object"]
    count: convex-field-integer value "count"
    unless count [fail operation "count is missing or not a whole number"]
    unless count = expected [
        fail operation rejoin ["count was " count ", expected " expected]
    ]
]

;; -- configuration: the deployment URL always comes from the
;; environment, never hardcoded, so this same image can run against any
;; approved Convex deployment.
convex-url: get-env "CONVEX_URL"
unless convex-url [
    diagnose "CONVEX_URL is required"
    quit/return 2
]

;; The shared conformance harness passes a fresh, unique room as this
;; program's own first argument, so the counter demonstrated below always
;; starts at 0; running the image by hand without one falls back to a
;; fixed room name instead.
room: either not empty? system/options/args [first system/options/args] ["rebol-basic-example"]

;; -- client creation. This example calls only a public demo function, so
;; it never sets an auth token; a client that needed one would pass it to
;; convex-set-auth instead of building a header by hand.
unless convex-open convex-url "rebol-0.1.0" [
    fail "open client" convex-error-message
]

query-args: make map! []
put query-args "room" room

;; -- the HTTP query: a plain request/response round trip through
;; client/convex.r3's own convex-query, this client's implementation of
;; Convex's documented "format":"json" /api/query endpoint.
current: convex-query "demo:state" query-args
check-result "current query" current
;; Decoding {"count": N} into a plain REBOL integer is this step's
;; "idiomatic value": everything above this line is Convex protocol
;; plumbing, and everything below just works with an ordinary number.
check-count "current query" current/value 0
print "current count: 0"

;; -- start Live before the mutation. Subscribing to the same query now
;; and reading its first value before changing anything is what makes the
;; later "updated" value unambiguous: if the mutation ran first, this
;; client could never tell a genuinely new value apart from one that was
;; already current when the subscription began.
unless convex-subscribe "counter" "demo:state" query-args [
    fail "subscribe" convex-error-message
]
initial: convex-wait-update "counter" 15000
unless initial/ok [fail "initial Live value" convex-error-message]
if initial/has-error [fail "initial Live value" initial/err-message]
check-count "initial Live value" initial/value 0
print "live initial count: 0"

;; -- the mutation, with its idempotency key. runId lets a retried
;; mutation (say, after a transient network failure between this client
;; and the deployment) return the already-applied result instead of
;; incrementing the counter a second time; a fresh random one here only
;; has to be unique to this one run, which random-bytes's process-seeded
;; random/secure already guarantees.
mutation-args: make map! []
put mutation-args "room" room
put mutation-args "language" "rebol"
put mutation-args "runId" enbase random-bytes 8 16
mutation: convex-mutation "demo:increment" mutation-args
check-result "mutation" mutation
unless (select mutation/value "applied") = true [
    fail "mutation" "was not applied"
]
print "mutation applied: true"
check-count "mutation" (select mutation/value "state") 1
print "mutation count: 1"

;; -- the resulting Live update, received without issuing a second HTTP
;; query: this is Convex's own reactivity working end to end, over the
;; RFC 6455 WebSocket + /api/sync state machine client/convex.r3
;; implements.
updated: convex-wait-update "counter" 15000
unless updated/ok [fail "updated Live value" convex-error-message]
if updated/has-error [fail "updated Live value" updated/err-message]
check-count "updated Live value" updated/value 1
print "live updated count: 1"

;; -- cleanup: stop the subscription and close the Live connection before
;; printing the final line, so a hang during teardown would itself be a
;; visible example failure rather than a silently skipped step.
convex-unsubscribe "counter"
convex-close-live 2000

;; Reached only once the HTTP query, the initial Live value, the
;; mutation, and the updated Live value all agree on the same 0 -> 1
;; journey.
print "verified count: 0 -> 1"
