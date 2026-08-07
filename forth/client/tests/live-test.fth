\ live-test.fth - the failure modes a happy-path Live test never reaches.
\
\ Three groups. The frame codec is driven from raw bytes over a real loopback
\ socket, including a deliberately truncated frame, because "a timeout must
\ never restart at a false frame boundary" is only proved by stopping in the
\ middle of one and carrying on. The sync protocol is driven by feeding whole
\ server messages to the same word the socket owner uses. The queue and barrier
\ tests drive the manager directly, since a stopped reader and a retired
\ connection are states a cooperating server will not produce on demand.

require test-support.fth

s" http://127.0.0.1:1" convex-open constant live-client
live-client live-ensure constant live

4096 buf-new constant frame-buf
1024 buf-new constant response-buf
1024 buf-new constant modification-buf
65536 buf-new constant filler

\ ---------------------------------------------------------------------------
\ Building server frames
\ ---------------------------------------------------------------------------

\ Server frames are never masked, which is exactly what the client checks.
: server-frame ( payload-addr payload-u fin opcode buf -- )
    { addr count fin opcode buf }
    fin if $80 else 0 then opcode or buf buf-char
    count 126 u< if
        count buf buf-char
    else
        count 65536 u< if
            126 buf buf-char
            count 8 rshift 255 and buf buf-char
            count 255 and buf buf-char
        else
            127 buf buf-char
            8 0 ?do count 56 i 8 * - rshift 255 and buf buf-char loop
        then
    then
    addr count buf buf-append ;

: send-frame ( payload-addr payload-u fin opcode stream -- )
    { addr count fin opcode stream }
    frame-buf buf-reset
    addr count fin opcode frame-buf server-frame
    frame-buf buf-span stream preload ;

variable ws-under-test
variable peer-stream

: open-ws ( port-addr port-u -- )
    loopback-pair peer-stream ! ws-new ws-under-test ! ;

: close-ws ( -- )
    ws-under-test @ ws-free
    peer-stream @ stream-close ;

: pump ( ms -- result )  deadline+ >r ws-under-test @ r> ws-pump ;

: probe-pump ( -- )  probe-a @ pump probe-b ! ;

: pump-raises ( ms name-addr name-u -- )
    2>r probe-a ! ['] probe-pump 2r> raises ;

\ ---------------------------------------------------------------------------
\ Frame codec
\ ---------------------------------------------------------------------------

: test-simple-message ( -- )
    s" 45010" open-ws
    s" hello" true ws-opcode-text peer-stream @ send-frame
    1000 pump ws-got-message s" a whole text frame is delivered" same-n
    ws-under-test @ ws-message@ s" hello" s" the payload is exact" same
    close-ws ;

: test-fragmentation ( -- )
    s" 45011" open-ws
    s" he" false ws-opcode-text peer-stream @ send-frame
    s" llo" true ws-opcode-continuation peer-stream @ send-frame
    1000 pump ws-got-message s" a fragmented message is reassembled" same-n
    ws-under-test @ ws-message@ s" hello" s" fragments join in order" same
    \ A ping between fragments is legal and must not corrupt the reassembly.
    s" ab" false ws-opcode-text peer-stream @ send-frame
    s" p" true ws-opcode-ping peer-stream @ send-frame
    s" cd" true ws-opcode-continuation peer-stream @ send-frame
    1000 pump ws-got-message s" an interleaved ping is handled" same-n
    ws-under-test @ ws-message@ s" abcd" s" reassembly survives a ping" same
    close-ws ;

: test-control-frames ( -- )
    0 { got }
    s" 45012" open-ws
    s" pong-me" true ws-opcode-ping peer-stream @ send-frame
    s" tail" true ws-opcode-text peer-stream @ send-frame
    1000 pump ws-got-message s" a ping is answered and reading continues" same-n
    peer-stream @ 1000 deadline+ stream-read-once to got
    got 0> s" the client replied on the wire" ok
    peer-stream @ stream-in buf-data c@ $8A
    s" the reply is a final pong frame" same-n
    peer-stream @ stream-in buf-data 1+ c@ $80 and 0<>
    s" the client masks its frames" ok
    close-ws ;

: test-close-frame ( -- )
    s" 45013" open-ws
    s\" \x03\xE8" true ws-opcode-close peer-stream @ send-frame
    1000 pump ws-got-close s" a close frame ends the connection" same-n
    close-ws ;

: test-rejected-frames ( -- )
    s" 45014" open-ws
    \ Reserved bits set: 0xF1 is FIN plus RSV1..3 with a text opcode.
    frame-buf buf-reset
    $F1 frame-buf buf-char  1 frame-buf buf-char  [char] x frame-buf buf-char
    frame-buf buf-span peer-stream @ preload
    1000 s" reserved bits are rejected" pump-raises
    close-ws
    s" 45015" open-ws
    \ A masked server frame: mask bit set in the second byte.
    frame-buf buf-reset
    $81 frame-buf buf-char  $81 frame-buf buf-char
    0 frame-buf buf-char 0 frame-buf buf-char
    0 frame-buf buf-char 0 frame-buf buf-char
    [char] x frame-buf buf-char
    frame-buf buf-span peer-stream @ preload
    1000 s" a masked server frame is rejected" pump-raises
    close-ws
    s" 45016" open-ws
    \ A fragmented control frame is never legal.
    frame-buf buf-reset
    $09 frame-buf buf-char  1 frame-buf buf-char  [char] x frame-buf buf-char
    frame-buf buf-span peer-stream @ preload
    1000 s" a fragmented control frame is rejected" pump-raises
    close-ws ;

\ The length is declared before the payload arrives. Only the header is sent
\ here, so a client that trusted the declared length would already have
\ reserved three megabytes on the peer's word.
: test-declared-length ( -- )
    s" 45017" open-ws
    frame-buf buf-reset
    $81 frame-buf buf-char  127 frame-buf buf-char
    0 frame-buf buf-char 0 frame-buf buf-char
    0 frame-buf buf-char 0 frame-buf buf-char
    0 frame-buf buf-char  $30 frame-buf buf-char
    0 frame-buf buf-char 0 frame-buf buf-char
    frame-buf buf-span peer-stream @ preload
    1000 s" an oversized declared length is rejected before the payload"
    pump-raises
    close-ws ;

\ Stop in the middle of a frame, let the deadline expire, and continue. The
\ parser must resume at the same offset rather than treating the next byte as
\ a new frame header.
: test-mid-frame-resume ( -- )
    0 { buffered }
    s" 45018" open-ws
    frame-buf buf-reset
    $81 frame-buf buf-char  10 frame-buf buf-char
    s" abcd" frame-buf buf-append
    frame-buf buf-span peer-stream @ preload
    200 pump ws-idle s" a partial frame yields no message" same-n
    ws-under-test @ ws-stream stream-buffered to buffered
    buffered 6 s" the partial frame is still buffered" same-n
    s" efghij" peer-stream @ preload
    1000 pump ws-got-message s" the frame completes after the pause" same-n
    ws-under-test @ ws-message@ s" abcdefghij"
    s" the resumed payload is intact" same
    close-ws ;

\ ---------------------------------------------------------------------------
\ Handshake response validation
\ ---------------------------------------------------------------------------

variable handshake-stream

: probe-handshake ( -- )
    handshake-stream @ 1000 deadline+ ws-read-response ;

: handshake ( addr u -- )
    memory-stream handshake-stream !
    ws-accept-buf buf-reset
    s" s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" ws-accept-buf buf-append ;

: handshake-raises ( addr u name-addr name-u -- )
    2>r handshake ['] probe-handshake 2r> raises ;

: handshake-ok ( addr u name-addr name-u -- )
    2>r handshake ['] probe-handshake 2r> succeeds ;

: good-accept ( -- addr u )
    s" Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" ;

: response-reset ( -- )  response-buf buf-reset ;

: response+ ( addr u -- )
    response-buf buf-append
    s\" \r\n" response-buf buf-append ;

: response-done ( -- addr u )
    s\" \r\n" response-buf buf-append
    response-buf buf-span ;

: test-handshake ( -- )
    response-reset
    s" HTTP/1.1 101 Switching Protocols" response+
    s" Upgrade: websocket" response+
    s" Connection: Upgrade" response+
    good-accept response+
    response-done
    s" a correct upgrade response is accepted" handshake-ok

    response-reset
    s" HTTP/1.1 200 OK" response+
    s" Upgrade: websocket" response+
    s" Connection: Upgrade" response+
    good-accept response+
    response-done
    s" a non-101 response is rejected" handshake-raises

    response-reset
    s" HTTP/1.1 101 Switching Protocols" response+
    s" Upgrade: websocket" response+
    s" Connection: Upgrade" response+
    s" Sec-WebSocket-Accept: wrongwrongwrongwrongwrongwr=" response+
    response-done
    s" a wrong accept value is rejected" handshake-raises

    response-reset
    s" HTTP/1.1 101 Switching Protocols" response+
    s" Connection: Upgrade" response+
    good-accept response+
    response-done
    s" a missing upgrade header is rejected" handshake-raises

    response-reset
    s" HTTP/1.1 101 Switching Protocols" response+
    s" Upgrade: websocket" response+
    s" Connection: Upgrade" response+
    s" Sec-WebSocket-Extensions: permessage-deflate" response+
    good-accept response+
    response-done
    s" a negotiated extension is rejected" handshake-raises ;

\ ---------------------------------------------------------------------------
\ The sync protocol
\ ---------------------------------------------------------------------------

: install-subscription ( slot query-id path-addr path-u args-addr args-u -- )
    { slot query-id path-addr path-count args-addr args-count }
    live slot lv-sub sub>path + @ buf-reset
    path-addr path-count live slot lv-sub sub>path + @ buf-append
    live slot lv-sub sub>args + @ buf-reset
    args-addr args-count live slot lv-sub sub>args + @ buf-append
    query-id live slot lv-sub sub>query-id + !
    false live slot lv-sub sub>have-last + !
    true live slot lv-sub sub>active + ! ;

: probe-message ( -- )  live probe@ live-handle-message ;

: message-raises ( addr u name-addr name-u -- )
    2>r >probe ['] probe-message 2r> raises ;

: feed ( addr u -- )  >probe probe-message ;

: transition ( base new modification-addr modification-u -- )
    { base new addr count }
    frame-buf dup buf-reset jw-start
    jw{
        s" type" s" Transition" jw-pair-string
        s" startVersion" jw-key
        jw{
            s" querySet" base jw-pair-uint
            s" identity" 0 jw-pair-uint
            s" ts" s" AAAAAAAAAAA=" jw-pair-string
        jw}
        s" endVersion" jw-key
        jw{
            s" querySet" new jw-pair-uint
            s" identity" 0 jw-pair-uint
            s" ts" s" AAAAAAAAAAA=" jw-pair-string
        jw}
        s" modifications" jw-key
        jw[
            addr count jw-raw
        jw]
    jw}
    frame-buf buf-span feed ;

: query-updated ( count -- addr u )
    { count }
    modification-buf dup buf-reset jw-start
    jw{
        s" type" s" QueryUpdated" jw-pair-string
        s" queryId" 0 jw-pair-uint
        s" value" jw-key jw{ s" count" count jw-pair-uint jw}
        s" logLines" jw-key jw[ jw]
    jw}
    modification-buf buf-span ;

: query-failed ( -- addr u )
    modification-buf dup buf-reset jw-start
    jw{
        s" type" s" QueryFailed" jw-pair-string
        s" queryId" 0 jw-pair-uint
        s" errorMessage" s" broken" jw-pair-string
        s" errorData" jw-key jw{ s" code" s" E" jw-pair-string jw}
        s" logLines" jw-key jw[ jw]
    jw}
    modification-buf buf-span ;

: taken-value ( -- addr u )  live live-taken-value ;

: take ( -- kind )  live 0 live-take-for ;

: test-initial-and-external ( -- )
    0 0 s" demo:state" s| {"room":"r"}| install-subscription
    0 1 0 query-updated transition
    take live-value s" the initial value is delivered" same-n
    taken-value s| {"count":0}| s" the value is the exact server bytes" same
    live live-release-taken
    1 2 1 query-updated transition
    take live-value s" an external update is delivered" same-n
    taken-value s| {"count":1}| s" the updated value is exact" same
    live live-release-taken ;

: test-rehydration-suppressed ( -- )
    2 3 1 query-updated transition
    take live-none s" an unchanged rehydration is suppressed" same-n ;

: test-failure-and-recovery ( -- )
    3 4 query-failed transition
    take live-error s" QueryFailed becomes an error delivery" same-n
    live live-taken-name s" FunctionError" s" the error is a FunctionError" same
    live live-taken-message s" broken" s" the error message is preserved" same
    live live-taken-data s| {"code":"E"}| s" the error data is preserved" same
    live live-release-taken
    \ Recovery to the same value must still be published, because the error
    \ cleared the suppression memory.
    4 5 1 query-updated transition
    take live-value s" the same value after a failure is a recovery" same-n
    live live-release-taken ;

: test-message-validation ( -- )
    s| {"type":"Ping"}| >probe
    ['] probe-message s" a ping is accepted" succeeds
    s| {"type":"Nonsense"}| s" an unknown server message is rejected"
    message-raises
    frame-buf dup buf-reset jw-start
    jw{
        s" type" s" Transition" jw-pair-string
        s" startVersion" jw-key
        jw{ s" querySet" 99 jw-pair-uint s" identity" 0 jw-pair-uint
            s" ts" s" AAAAAAAAAAA=" jw-pair-string jw}
        s" endVersion" jw-key
        jw{ s" querySet" 100 jw-pair-uint s" identity" 0 jw-pair-uint
            s" ts" s" AAAAAAAAAAA=" jw-pair-string jw}
        s" modifications" jw-key jw[ jw]
    jw}
    frame-buf buf-span
    s" a start version mismatch is rejected" message-raises ;

: test-timestamp-monotonic ( -- )
    \ Move the connection forward to a later timestamp, then try to go back.
    \ This runs after the other transitions, so the version numbers continue
    \ from where they left off.
    frame-buf dup buf-reset jw-start
    jw{
        s" type" s" Transition" jw-pair-string
        s" startVersion" jw-key
        jw{ s" querySet" 6 jw-pair-uint s" identity" 0 jw-pair-uint
            s" ts" s" AAAAAAAAAAA=" jw-pair-string jw}
        s" endVersion" jw-key
        jw{ s" querySet" 7 jw-pair-uint s" identity" 0 jw-pair-uint
            s" ts" s" AQAAAAAAAAA=" jw-pair-string jw}
        s" modifications" jw-key jw[ jw]
    jw}
    frame-buf buf-span feed
    live lv>remote-ts + @ 1 s" the observed timestamp advanced" same-n
    live lv-max-ts 1 s" the maximum observed timestamp is carried" same-n
    frame-buf dup buf-reset jw-start
    jw{
        s" type" s" Transition" jw-pair-string
        s" startVersion" jw-key
        jw{ s" querySet" 7 jw-pair-uint s" identity" 0 jw-pair-uint
            s" ts" s" AQAAAAAAAAA=" jw-pair-string jw}
        s" endVersion" jw-key
        jw{ s" querySet" 8 jw-pair-uint s" identity" 0 jw-pair-uint
            s" ts" s" AAAAAAAAAAA=" jw-pair-string jw}
        s" modifications" jw-key jw[ jw]
    jw}
    frame-buf buf-span s" a backwards timestamp is rejected" message-raises ;

: test-backoff-reset ( -- )
    cvx-max-backoff live lv>backoff + !
    5 6 2 query-updated transition
    live lv>backoff + @ cvx-initial-backoff
    s" a valid transition resets the transport backoff" same-n
    take drop live live-release-taken ;

\ ---------------------------------------------------------------------------
\ The bounded delivery queue and the barriers
\ ---------------------------------------------------------------------------

: publish-many ( count -- )
    { count }
    count 0 ?do
        frame-buf buf-reset
        s| {"count":| frame-buf buf-append
        i frame-buf u>buf
        s" }" frame-buf buf-append
        live 0 frame-buf buf-span live-publish-value
    loop ;

: test-queue-bounds ( -- )
    0 { drops }
    live live-purge-all
    live lv-drops to drops
    cvx-max-deliveries 4 + publish-many
    live lv>queue-count + @ cvx-max-deliveries u> 0=
    s" a stopped reader cannot grow the queue past its count bound" ok
    live lv>queue-bytes + @ cvx-max-delivery-bytes u> 0=
    s" the queue stays inside its byte budget" ok
    live lv-drops drops u> s" overflow is recorded rather than hidden" ok
    live live-purge-all ;

: test-unsubscribe-barrier ( -- )
    0 { epoch }
    live live-purge-all
    false live 0 lv-sub sub>have-last + !
    live 0 s| {"count":9}| live-publish-value
    live lv>queue-count + @ 1 s" a value is queued" same-n
    live 0 lv-sub sub>epoch + @ to epoch
    live-client 0 convex-unsubscribe
    live 0 lv-sub sub>epoch + @ epoch u>
    s" unsubscribe advances the subscription epoch" ok
    live lv>queue-count + @ 0
    s" unsubscribe purges the queued value before acknowledging" same-n
    take live-none s" nothing survives the unsubscribe barrier" same-n ;

\ catch needs a word with no arguments, so the fault injector gets a wrapper.
: probe-debug-disconnect ( -- )  live-client live-debug-disconnect drop ;

: test-debug-disconnect ( -- )
    0 { generation }
    live lv-generation to generation
    \ With no socket the fault injector must refuse rather than pretend it
    \ retired one, because the controller treats the acknowledgement as proof.
    ['] probe-debug-disconnect throws?
    s" debugDisconnect without a connection is refused" ok
    live lv-generation generation
    s" a refused disconnect does not move the generation" same-n ;

\ ---------------------------------------------------------------------------
\ Close is bounded even when the peer never reads
\ ---------------------------------------------------------------------------

\ A single unwritable attempt is not proof the peer is stalled: the kernel
\ keeps draining the send buffer into the peer's own receive buffer via ACKs
\ that need no application read, so a moment later there is room again. Only
\ a run of consecutive failures, spaced out enough for that draining to
\ finish, means both kernel buffers are genuinely exhausted.
: fill-send-buffer ( stream -- )
    0 0 { stream written stall }
    filler buf-reset
    65536 0 ?do 0 filler buf-char loop
    begin stall 20 u< while
        filler buf-span stream stream-write-some to written
        written 0= if
            stall 1+ to stall
            5 io-sleep
        else
            0 to stall
        then
    repeat ;

: probe-close-frame ( -- )
    ws-under-test @ cvx-close-deadline deadline+ ws-send-close ;

: test-bounded-close ( -- )
    0 0 { started elapsed }
    s" 45019" open-ws
    ws-under-test @ ws-stream fill-send-buffer
    now to started
    ['] probe-close-frame throws?
    s" closing a stalled peer fails instead of hanging" ok
    now started - to elapsed
    elapsed cvx-close-deadline 4 * u< s" the close stayed inside its bound" ok
    close-ws ;

test-simple-message
test-fragmentation
test-control-frames
test-close-frame
test-rejected-frames
test-declared-length
test-mid-frame-resume
test-handshake
test-initial-and-external
test-rehydration-suppressed
test-failure-and-recovery
test-message-validation
test-backoff-reset
test-timestamp-monotonic
test-queue-bounds
test-unsubscribe-barrier
test-debug-disconnect
test-bounded-close

s" live-test" tests-done
0 convex-exit
