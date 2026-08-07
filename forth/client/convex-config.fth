\ convex-config.fth - every bound the Forth Convex client enforces, in one
\ place so a reviewer can read the client's memory and time budget without
\ hunting through the transport code.
\
\ These are deliberately conservative. The shared conformance harness runs the
\ adapter under a 128 MiB container limit with a deliberately stopped reader,
\ so each queue is bounded by a byte budget as well as an item count, and the
\ byte budget is charged against the encoded size plus a fixed per-item
\ overhead rather than against the payload alone.

\ --- Protocol identity -----------------------------------------------------

\ Sent as Convex-Client on every HTTP request and WebSocket upgrade.
: cvx-client-version ( -- addr u )  s" forth-0.1.0" ;

\ The pinned sync profile this client implements. Recorded in manifest.yaml
\ and in the README so drift against a newer backend is visible as evidence
\ rather than as a silent behaviour change.
: cvx-sync-endpoint ( -- addr u )  s" /api/sync" ;

\ --- Size limits -----------------------------------------------------------

\ Largest byte range any single buffer may hold. One decoded Live message, one
\ HTTP response body and one outgoing frame are each charged against this.
2 1024 * 1024 * constant cvx-max-buffer

\ Largest JSON text the strict decoder will accept, and the structural limits
\ that stop a deeply nested or wide document from exhausting the return stack.
2 1024 * 1024 * constant cvx-max-json-bytes
128 constant cvx-max-json-depth
8192 constant cvx-max-json-nodes

\ A WebSocket frame declares its payload length before the payload arrives.
\ The declared length is checked against this ceiling before a single byte is
\ allocated, so an inflated length header cannot make the client reserve
\ memory on the peer's behalf.
2 1024 * 1024 * constant cvx-max-frame-bytes

\ A fragmented message is bounded twice: by total reassembled bytes and by
\ fragment count, because many tiny continuation frames are as expensive as
\ one large one.
2 1024 * 1024 * constant cvx-max-message-bytes
4096 constant cvx-max-fragments

\ HTTP response framing bounds. Headers are bounded separately from the body
\ because a peer that never sends the blank line is a different failure from a
\ peer that sends an oversized body.
32768 constant cvx-max-header-bytes
128 constant cvx-max-header-lines

18 constant cvx-max-digits          \ decimal digits accepted by str>u
255 constant cvx-max-zstring        \ host and port text handed to the native layer
32 constant cvx-max-random          \ bytes drawn from /dev/urandom at once

\ --- Live subscription budget ----------------------------------------------

64 constant cvx-max-subscriptions
8 1024 * 1024 * constant cvx-max-subscription-bytes

\ The client owns its Live delivery queue, so the queue is explicitly bounded.
\ Overflow drops the oldest delivery for that subscription and records the
\ drop; it never grows without limit and never blocks the socket owner.
16 constant cvx-max-deliveries
20 1024 * 1024 * constant cvx-max-delivery-bytes
512 constant cvx-delivery-overhead   \ charged per queued item on top of its bytes

\ The adapter's own output queue is bounded separately from the client's,
\ because a stopped controller reader stalls the adapter without stalling the
\ Convex WebSocket.
16 constant cvx-max-outbox
6 1024 * 1024 * constant cvx-max-outbox-bytes

\ --- Time limits, all milliseconds -----------------------------------------

\ Absolute deadlines. Every read and write loop compares against a deadline
\ captured before the first byte, so a peer that dribbles one byte at a time
\ cannot extend an operation indefinitely.
5000 constant cvx-connect-deadline
15000 constant cvx-http-deadline
2000 constant cvx-ws-connect-deadline
2000 constant cvx-close-deadline

\ Dribble deadline: the longest a read may go without any forward progress
\ while a message is already partly consumed.
5000 constant cvx-dribble-deadline
5000 constant cvx-write-deadline

\ Exponential transport backoff. The delay is reset after a successful
\ handshake or a valid server transition so a healthy connection does not
\ inherit the previous failure's maximum delay.
100 constant cvx-initial-backoff
15000 constant cvx-max-backoff

\ Upper bound on a single poll wait, so a stalled socket owner still wakes up
\ often enough to notice an expired deadline.
250 constant cvx-poll-slice
