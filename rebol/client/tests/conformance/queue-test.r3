;; Dedicated regression for the adapter's own bounded output queue
;; (client/tests/conformance/main.r3's ad-emit/ad-drop-oldest), which
;; AGENTS.md requires: a bounded queue tested under a stopped reader with
;; near-maximum messages, comfortably inside the shared 128 MiB adapter
;; limit. No network or transport is involved -- ADAPTER_NO_AUTORUN
;; suppresses main.r3's own connect-and-loop driver (see its own
;; ad-main comment) so this file gets every ad-* function and the `ad`
;; state object with no CONVEX_URL, no deployment, and no blocking read.
set-env "ADAPTER_NO_AUTORUN" "1"
do %main.r3

failures: 0
check: func [condition [logic!] label [string!]] [
    unless condition [
        failures: failures + 1
        print ["FAIL --" label]
    ]
]

;; A "stopped reader": ad-flush is simply never called below, so nothing
;; ever leaves ad/queue -- every check below is against the in-memory
;; queue and byte counter alone, exactly modelling a controller that
;; stopped reading its socket.

;; ---------------------------------------------------------------------
;; 1) Near-maximum droppable messages must never push the queue past its
;; own byte budget: the oldest droppable entry is evicted to make room,
;; not merely appended past the limit.
;; ---------------------------------------------------------------------
near-max: make string! ad-queue-max-bytes
loop (ad-queue-max-bytes / 2) [append near-max "xy"]
check ((ad-charge near-max) > (ad-queue-max-bytes / 2)) "fixture message is a real fraction of the byte budget"

pushed: 0
loop 40 [
    ad-emit near-max true
    pushed: pushed + 1
    check (ad/queue-bytes <= ad-queue-max-bytes) rejoin ["push " pushed ": queue-bytes within byte budget"]
    check ((length? ad/queue) <= ad-queue-max-count) rejoin ["push " pushed ": queue length within count budget"]
]
check (ad/queue-bytes <= ad-queue-max-bytes) "queue-bytes within the adapter's own 4 MiB budget after 40 near-max pushes"
check (ad/queue-bytes < (128 * 1024 * 1024)) "queue-bytes comfortably inside the shared 128 MiB adapter limit"

;; ---------------------------------------------------------------------
;; 2) Oldest-first eviction: push small, individually-tagged droppable
;; entries past the count budget and confirm only the NEWEST
;; ad-queue-max-count survive, in order.
;; ---------------------------------------------------------------------
tagged-entry: function [n [integer!] /local m] [
    m: make map! []
    put m "tag" n
    json-encode m
]

ad/queue: copy []
ad/queue-bytes: 0
tag: 1
loop (ad-queue-max-count + 5) [
    ad-emit (tagged-entry tag) true
    tag: tag + 1
]
check ((length? ad/queue) = ad-queue-max-count) "eviction keeps exactly max-count entries"
first-surviving: (to-integer (ad-queue-max-count + 5)) - (to-integer ad-queue-max-count) + 1
oldest-entry: first ad/queue
newest-entry: last ad/queue
check (oldest-entry/text = (tagged-entry first-surviving)) "the oldest SURVIVING entry is the right one (earlier ones were evicted)"
check (newest-entry/text = (tagged-entry (ad-queue-max-count + 5))) "the newest entry is the most recently pushed one"

;; ---------------------------------------------------------------------
;; 3) Undroppable responses (hello/result/error/ack/closed) are never
;; silently dropped to make room: if the budget cannot be freed without
;; evicting one, the adapter fails loudly (ad/done is set) rather than
;; growing without bound or discarding a response the controller is
;; waiting on.
;; ---------------------------------------------------------------------
ad/queue: copy []
ad/queue-bytes: 0
ad/done: false
loop (ad-queue-max-count) [ad-emit (ad-ack-event "x") false]
check (not ad/done) "queue not yet exhausted at exactly max-count undroppable entries"
ad-emit (ad-ack-event "overflow") false
check ad/done "adapter fails loudly instead of dropping an undroppable response"
check ((length? ad/queue) = ad-queue-max-count) "the undroppable overflow entry itself was not queued either"

either failures = 0 [
    print "ALL QUEUE CHECKS PASSED"
    quit/return 0
] [
    print [failures "QUEUE CHECK(S) FAILED"]
    quit/return 1
]
