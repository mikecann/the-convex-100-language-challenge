\ Convex from Forth: read a shared counter over HTTP, watch it over Live, and
\ prove a mutation arrives on both. Against a fresh room the journey is 0 -> 1.

require convex.fth

\ json-get returns only the child index, so this keeps the document beside it
\ and lets the example walk into a nested field without losing its place.
: example-field ( doc node key-addr key-u -- doc node )
    { doc node key-addr key-count }
    doc  doc node key-addr key-count json-get ;

\ Convex's demo functions return a record. This narrows one to the single field
\ the example promises and insists on a whole number: Convex may encode an
\ integral count as 0 or as 0.0, and convex-integer accepts both while still
\ rejecting a fractional, quoted or out-of-range value.
: example-count ( doc node -- count )
    s" count" example-field convex-integer ;

\ The verifier passes a unique room as the first argument of
\ /usr/local/bin/convex-example, which forwards it in EXAMPLE_ROOM. Running the
\ image by hand without one still works.
: example-room ( -- addr u )
    s" EXAMPLE_ROOM" getenv dup 0= if 2drop s" forth-example" then ;

\ runId is the mutation's idempotency key: Convex replays the earlier result
\ rather than counting twice when the same key arrives again. It must therefore
\ be fresh for every run and must not come from a predictable source.
64 buf-new constant run-id

: fresh-run-id ( -- addr u )
    run-id buf-reset
    16 run-id random-hex
    run-id buf-span ;

\ Every Live wait is bounded. A missing update is a failed demonstration, not
\ something to keep waiting for.
10000 constant example-live-timeout

: example-give-up ( addr u -- )
    note-line
    1 convex-exit ;

\ Take the next Live delivery and hand back the parsed value. A delivery is the
\ exact bytes Convex sent, so it goes through the same strict reader as an HTTP
\ response instead of a looser Live-only path.
: example-live-value ( client sub what-addr what-u -- doc node )
    0 { client sub what-addr what-count kind }
    client sub example-live-timeout convex-live-wait to kind
    kind convex-live-none = if
        what-addr what-count note
        s"  did not arrive before the deadline" example-give-up
    then
    kind convex-live-error = if
        what-addr what-count note s" : " note
        client convex-live-error-message@ example-give-up
    then
    client convex-live-value@ client client-doc json-parse
    client convex-live-release
    client client-doc dup doc-root ;

variable example-client
variable example-subscription

: example-run ( -- )
    0 0 0 0 0 0 0 { client subscription current initial expected applied count }
    \ Configure one client for the deployment this container was given.
    s" CONVEX_URL" getenv dup 0= if
        2drop s" CONVEX_URL is required" example-give-up
    then
    convex-open to client
    client example-client !

    \ Ask Convex for the current state through its documented HTTP endpoint.
    client s" demo:state"
    client convex-args
        s" room" example-room convex-arg-string
    client convex-args-done
    convex-query
    client convex-value example-count to current
    s" current count: " type current u-type cr

    \ Subscribe before mutating, so no reactive update can fall into the gap.
    client s" demo:state"
    client convex-args
        s" room" example-room convex-arg-string
    client convex-args-done
    convex-subscribe to subscription
    subscription example-subscription !

    \ The first Live value hydrates the same state the HTTP query just read.
    client subscription s" the initial Live value" example-live-value
    example-count to initial
    initial current <> if
        s" the initial Live count disagreed with HTTP" example-give-up
    then
    s" live initial count: " type initial u-type cr

    \ Apply the mutation, keyed so that a retry stays safe.
    client s" demo:increment"
    client convex-args
        s" room" example-room convex-arg-string
        s" language" s" forth" convex-arg-string
        s" runId" fresh-run-id convex-arg-string
    client convex-args-done
    convex-mutation
    current 1+ to expected
    client convex-value s" applied" example-field to applied drop
    client client-doc applied json-true? 0= if
        s" the mutation was not applied" example-give-up
    then
    client convex-value s" state" example-field example-count to count
    count expected <> if
        s" the mutation returned an unexpected count" example-give-up
    then
    s" mutation applied: true" type cr
    s" mutation count: " type count u-type cr

    \ Receive the same change reactively, with no second HTTP request.
    client subscription s" the updated Live value" example-live-value
    example-count to count
    count expected <> if
        s" the updated Live count disagreed with the mutation" example-give-up
    then
    s" live updated count: " type count u-type cr

    \ Only now, with all three operations agreeing, print the proof line.
    s" verified count: " type current u-type s"  -> " type count u-type cr ;

\ Cleanup is bounded: unsubscribe and close use the client's own deadlines
\ rather than waiting on a peer that may never answer.
: example-cleanup ( -- )
    example-client @ 0= if exit then
    example-subscription @ 0< 0= if
        example-client @ example-subscription @ convex-unsubscribe
    then
    example-client @ convex-close ;

-1 example-subscription !

' example-run catch ?dup if
    cvx-adopt-fault
    s" the Forth example failed" note-line
    report-error
    example-cleanup
    1 convex-exit
then
example-cleanup
0 convex-exit
