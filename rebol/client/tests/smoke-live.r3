do %../convex.r3

failures: 0
check: func [condition [logic!] label [string!]] [
    unless condition [
        failures: failures + 1
        print ["FAIL --" label]
    ]
]

url: "https://usable-reindeer-44.convex.cloud"
check (convex-open url "rebol-smoke-live-0.1.0") "convex-open"

room: rejoin ["rebol-live-smoke-" (enbase random-bytes 8 16)]
args: make map! []
put args "room" room

response: convex-query "demo:state" args
unless response/ok [print ["query error:" convex-error-name convex-error-message]]
check response/ok "initial HTTP query ok"
current: either response/ok [convex-field-integer response/value "count"] [-999]
print ["current:" current]

subscribed: convex-subscribe "counter" "demo:state" args
unless subscribed [print ["subscribe error:" convex-error-name convex-error-message]]
check subscribed "subscribe ok"

initial: convex-wait-update "counter" 15000
unless initial/ok [print ["wait-update error:" convex-error-name convex-error-message]]
check initial/ok "wait-update (initial) ok"
either initial/ok [
    check (not initial/has-error) "initial has no error"
    initial-count: convex-field-integer initial/value "count"
    print ["initial live count:" initial-count]
    check (initial-count = current) "initial live value matches HTTP"
] [
    failures: failures + 1
]

;; Prove a real reconnect: force the socket down, then subscribe state
;; must still recover the SAME logical subscription without re-issuing
;; convex-subscribe.
check (convex-debug-disconnect) "debugDisconnect"
check (cx/live-socket = none) "socket is retired immediately after debugDisconnect"

mutation-args: make map! []
put mutation-args "room" room
put mutation-args "language" "rebol"
put mutation-args "runId" (enbase random-bytes 16 16)
mutation-response: convex-mutation "demo:increment" mutation-args
unless mutation-response/ok [print ["mutation error:" convex-error-name convex-error-message]]
check mutation-response/ok "mutation ok"
if mutation-response/ok [
    applied: select mutation-response/value "applied"
    check (applied = true) "mutation applied true"
]

updated: convex-wait-update "counter" 15000
unless updated/ok [print ["wait-update (updated) error:" convex-error-name convex-error-message]]
check updated/ok "wait-update (after reconnect + mutation) ok"
either updated/ok [
    check (not updated/has-error) "updated has no error"
    updated-count: convex-field-integer updated/value "count"
    print ["updated live count (after forced reconnect):" updated-count]
    check (updated-count = (current + 1)) "updated live value is exactly current+1"
] [
    failures: failures + 1
]
check (cx/live-socket <> none) "reconnected automatically"
check (cx/live-connection-count >= 2) "connection count reflects the reconnect"

convex-close-live 2000

either failures = 0 [
    print "ALL LIVE SMOKE CHECKS PASSED"
    quit/return 0
] [
    print [failures "LIVE SMOKE CHECK(S) FAILED"]
    quit/return 1
]
