\ adapter-test.fth - the conformance adapter's wire shapes and its bounds.
\
\ The shared controller validates every emitted event strictly, so a field that
\ is absent must be omitted rather than serialized as null. Getting that wrong
\ shows up as an opaque schema failure during shared conformance, which is far
\ from the code that caused it; these checks keep it local.
\
\ The outbox test uses a real socket whose peer never reads, because a stopped
\ reader is the case where an unbounded queue would go unnoticed.

\ The Docker build flattens client/, client/tests/ and
\ client/tests/conformance/ into one staging directory, which is also the
\ layout the runtime images use, so the adapter is required by bare name.
require test-support.fth
require adapter.fth

json-new constant event-doc

: last-event ( -- addr u )
    outbox-oldest dup 0< if drop s" " exit then
    outbox-buf buf-span
    dup 0> if 1- then ;                 \ without the terminating newline

: take-event ( -- )
    last-event event-doc json-parse
    outbox-oldest dup 0< if drop exit then outbox-release ;

: event-root ( -- doc node )  event-doc dup doc-root ;

: event-field ( key-addr key-u -- doc node )
    { key-addr key-count }
    event-doc dup dup doc-root key-addr key-count json-get ;

: event-text ( key-addr key-u -- addr u )  event-field json-string@ ;
: event-raw ( key-addr key-u -- addr u )  event-field json-raw ;
: event-has? ( key-addr key-u -- flag )
    { key-addr key-count }
    event-doc dup doc-root key-addr key-count json-has? ;

: with-id ( addr u -- )
    adapter-id slot!
    true adapter-has-id ! ;

: without-id ( -- )  false adapter-has-id ! ;

\ ---------------------------------------------------------------------------

: test-ready ( -- )
    outbox-init
    s" h1" with-id
    emit-ready
    take-event
    s" type" event-text s" ready" s" the hello reply is a ready event" same
    s" id" event-text s" h1" s" the ready event echoes the command id" same
    s" language" event-text s" forth" s" the language is reported" same
    s" implementation" event-text s" native-forth-0.1.0"
    s" the implementation provenance is reported" same
    s" protocolVersion" event-field json-integer drop 1
    s" the protocol version is reported" same-n
    s" runtime" event-has? s" the runtime version is reported" ok ;

: test-result ( -- )
    outbox-init
    s" q1" with-id
    s| {"count":1}| s| ["a"]| emit-result
    take-event
    s" type" event-text s" result" s" a call reply is a result event" same
    s" value" event-raw s| {"count":1}|
    s" the value is the exact bytes Convex sent" same
    s" logs" event-raw s| ["a"]| s" log lines are carried through" same ;

: test-ack-and-closed ( -- )
    outbox-init
    s" a1" with-id
    emit-ack
    take-event
    s" type" event-text s" ack" s" an acknowledgement is an ack event" same
    outbox-init
    s" c1" with-id
    emit-closed
    take-event
    s" type" event-text s" closed" s" a close reply is a closed event" same
    s" id" event-text s" c1" s" the closed event echoes the command id" same ;

: test-error-shape ( -- )
    outbox-init
    s" e1" with-id
    cvx-error-reset
    s" FunctionError" cvx-error-name!
    s" boom" cvx-error-message!
    emit-error
    take-event
    s" type" event-text s" error" s" a failure is an error event" same
    s" error" event-field s" name" json-get event-doc swap json-string@
    s" FunctionError" s" the error name is carried" same
    s" error" event-field s" message" json-get event-doc swap json-string@
    s" boom" s" the error message is carried" same
    s" error" event-field s" data" json-has? 0=
    s" absent error data is omitted rather than null" ok
    outbox-init
    s" e2" with-id
    cvx-error-reset
    s" ProtocolError" cvx-error-name!
    s" bad" cvx-error-message!
    s| {"code":"X"}| cvx-error-data!
    emit-error
    take-event
    s" error" event-field s" data" json-get event-doc swap json-raw
    s| {"code":"X"}| s" present error data is carried" same ;

: test-absent-id ( -- )
    outbox-init
    without-id
    cvx-error-reset
    s" ProtocolError" cvx-error-name!
    s" unparsable line" cvx-error-message!
    emit-error
    take-event
    s" id" event-has? 0=
    s" an absent command id is omitted rather than null" ok ;

: test-subscription-events ( -- )
    outbox-init
    without-id
    s" s1" s| {"count":2}| s| []| emit-subscription-value
    take-event
    s" type" event-text s" subscription"
    s" a Live update is a subscription event" same
    s" subscriptionId" event-text s" s1"
    s" the controller's subscription id is echoed" same
    s" value" event-raw s| {"count":2}| s" the Live value is exact" same
    s" id" event-has? 0= s" a subscription event carries no command id" ok
    outbox-init
    cvx-error-reset
    s" FunctionError" cvx-error-name!
    s" query failed" cvx-error-message!
    s" s1" emit-subscription-error
    take-event
    s" subscriptionId" event-text s" s1"
    s" a subscription failure keeps its id" same
    s" error" event-has? s" a subscription failure carries an error" ok
    s" value" event-has? 0=
    s" a subscription failure carries no value" ok ;

\ ---------------------------------------------------------------------------
\ Bounds under a stopped reader
\ ---------------------------------------------------------------------------

65536 buf-new constant big-filler
1024 buf-new constant big-value

\ A single unwritable attempt is not proof the peer is stalled: the kernel
\ keeps draining the send buffer into the peer's own receive buffer via ACKs
\ that need no application read, so a moment later there is room again. The
\ flood below must find the socket still jammed on every push, not just the
\ first, so this waits out a run of consecutive failures before giving up.
: fill-socket ( stream -- )
    0 0 { stream written stall }
    big-filler buf-reset
    65536 0 ?do 0 big-filler buf-char loop
    begin stall 20 u< while
        big-filler buf-span stream stream-write-some to written
        written 0= if
            stall 1+ to stall
            5 io-sleep
        else
            0 to stall
        then
    repeat ;

: big-payload ( -- addr u )
    big-value buf-reset
    [char] " big-value buf-char
    900 0 ?do [char] x big-value buf-char loop
    [char] " big-value buf-char
    big-value buf-span ;

: test-outbox-bounds ( -- )
    0 0 { client peer }
    s" 45030" loopback-pair to peer to client
    client adapter-out !
    client fill-socket
    outbox-init
    without-id
    \ One command reply, which may never be dropped, then a flood of Live
    \ updates, which may.
    s| {"ok":true}| s| []| emit-result
    64 0 ?do
        s" s1" big-payload s| []| emit-subscription-value
    loop
    outbox-count @ cvx-max-outbox u> 0=
    s" a stopped reader cannot grow the outbox past its count bound" ok
    outbox-bytes @ cvx-max-outbox-bytes u> 0=
    s" the outbox stays inside its byte budget" ok
    outbox-drops @ 0> s" overflow is recorded rather than hidden" ok
    \ The command reply is the oldest event and is never droppable, so it is
    \ still queued after the flood.
    outbox-drop-ok outbox-oldest cells + @ 0=
    s" a command reply is never dropped for a Live update" ok
    client stream-close
    peer stream-close ;

\ ---------------------------------------------------------------------------
\ NDJSON line framing
\ ---------------------------------------------------------------------------

: test-line-framing ( -- )
    s\" {\"a\":1}\n{\"b\":2}\r\n" memory-stream adapter-in !
    adapter-take-line s" a complete line is available" ok
    adapter-line buf-span s| {"a":1}| s" the first line is exact" same
    adapter-take-line s" a second line is available" ok
    adapter-line buf-span s| {"b":2}|
    s" a carriage return is stripped from the second line" same
    adapter-take-line 0= s" a partial trailing line is not delivered yet" ok ;

: test-registry ( -- )
    registry-init
    s" s1" 3 0 registry-set
    s" s1" registry-find 0 s" a registered identifier is found" same-n
    s" s2" registry-find -1 s" an unknown identifier is not found" same-n
    3 registry-slot-for-sub 0 s" a subscription maps back to its slot" same-n
    0 registry-clear
    s" s1" registry-find -1 s" a cleared identifier is forgotten" same-n ;

test-ready
test-result
test-ack-and-closed
test-error-shape
test-absent-id
test-subscription-events
test-outbox-bounds
test-line-framing
test-registry

s" adapter-test" tests-done
0 convex-exit
