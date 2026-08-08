;; Dedicated regression for the Live reconnect/backoff behavior AGENTS.md's
;; "Live acceptance" section calls for, which -- before this file -- had
;; only ever been proven once, by smoke-live.r3's single forced reconnect.
;; This drives FIVE real reconnects via debugDisconnect against the real
;; hosted deployment, proving on every single one of them:
;;
;;   - the connection count actually increments (a genuine new socket, not
;;     a no-op)
;;   - exponential backoff is back at its base delay immediately after the
;;     reconnect succeeds (client/convex.r3's live-connect resets
;;     cx/live-backoff-ms right after a successful handshake, specifically
;;     so a healthy connection never inherits a stale, grown delay from an
;;     earlier unrelated run of failures)
;;   - the resent Add on that reconnect, whose value has not actually
;;     changed since the last delivery, is suppressed rather than
;;     redelivered (convex-wait-update times out instead of firing)
;;   - the subscription is still genuinely alive on the new connection: a
;;     real mutation immediately afterward still produces a real delivered
;;     update, proving the reconnect's Add replay actually re-established
;;     the subscription rather than merely reopening a socket
do %../convex.r3

failures: 0
check: func [condition [logic!] label [string!]] [
    unless condition [
        failures: failures + 1
        print ["FAIL --" label]
    ]
]

url: "https://usable-reindeer-44.convex.cloud"
check (convex-open url "rebol-live-reconnect-test-0.1.0") "convex-open"

room: rejoin ["rebol-live-reconnect-" (enbase random-bytes 8 16)]
args: make map! []
put args "room" room

;; Establishes the subscription and consumes its initial value so every
;; later convex-wait-update call is unambiguously about a NEW delivery.
;; convex-wait-update returns plain logic! false (not an object) on
;; timeout/unknown-tag, so every call site below checks `object?` before
;; ever touching /ok or /value -- a bare `/ok` path access on that false
;; sentinel errors instead of failing gracefully.
subscribed: convex-subscribe "counter" "demo:state" args
check subscribed "initial subscribe ok"
initial: convex-wait-update "counter" 15000
check (object? initial) "initial live value arrived"
expected-count: either object? initial [convex-field-integer initial/value "count"] [-999]
print ["starting count:" expected-count]

;; Blocks (bounded) until cx/live-socket is a real connection again,
;; pumping Live the same way the adapter's own main loop would between
;; controller commands. Returns true/false.
wait-for-reconnect: function [timeout-ms [integer!] /local deadline] [
    deadline: (now-ms) + timeout-ms
    until [
        live-pump remaining-ms deadline
        any [(cx/live-socket <> none) ((remaining-ms deadline) = 0)]
    ]
    cx/live-socket <> none
]

reconnect-round: 1
while [reconnect-round <= 5] [
    print ["--- reconnect round" reconnect-round "---"]
    before-count: cx/live-connection-count

    check (convex-debug-disconnect) rejoin ["round " reconnect-round ": debugDisconnect"]
    check (cx/live-socket = none) rejoin ["round " reconnect-round ": socket retired immediately"]

    reconnected: wait-for-reconnect 15000
    check reconnected rejoin ["round " reconnect-round ": reconnected within 15s"]
    check (cx/live-connection-count > before-count) rejoin ["round " reconnect-round ": connection count incremented"]
    check (cx/live-backoff-ms = cx/live-backoff-base-ms) rejoin ["round " reconnect-round ": backoff reset to base after a good handshake"]

    ;; The reconnect just resent this subscription's Add with its
    ;; already-known value; nothing about the underlying data changed,
    ;; so this must NOT redeliver -- convex-wait-update should time out,
    ;; returning plain logic! false rather than an update object.
    rehydration: convex-wait-update "counter" 3000
    check (not object? rehydration) rejoin ["round " reconnect-round ": unchanged rehydration suppressed (no spurious update)"]

    ;; Prove the subscription is genuinely alive on the new connection,
    ;; not just silently inert: a real mutation must still produce a
    ;; real delivered update.
    mutation-args: make map! []
    put mutation-args "room" room
    put mutation-args "language" "rebol"
    put mutation-args "runId" (enbase random-bytes 16 16)
    mutation-response: convex-mutation "demo:increment" mutation-args
    check mutation-response/ok rejoin ["round " reconnect-round ": mutation ok"]

    updated: convex-wait-update "counter" 15000
    check (object? updated) rejoin ["round " reconnect-round ": post-reconnect live update arrived"]
    if object? updated [
        expected-count: expected-count + 1
        updated-count: convex-field-integer updated/value "count"
        check (updated-count = expected-count) rejoin [
            "round " reconnect-round ": post-reconnect update is exactly " expected-count
        ]
    ]

    reconnect-round: reconnect-round + 1
]

check (cx/live-connection-count >= 6) "at least 6 connections total (1 initial + 5 reconnects)"

convex-unsubscribe "counter"
convex-close-live 2000

either failures = 0 [
    print "ALL LIVE RECONNECT CHECKS PASSED"
    quit/return 0
] [
    print [failures "LIVE RECONNECT CHECK(S) FAILED"]
    quit/return 1
]
