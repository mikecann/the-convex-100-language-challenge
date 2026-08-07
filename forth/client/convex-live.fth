\ convex-live.fth - Convex Live over the pinned sync profile, in Forth.
\
\ Ownership
\ ---------
\ Exactly one worker may touch the WebSocket, change the query-set version or
\ decide to reconnect. This client is deliberately single threaded, so that
\ worker is the set of owner words in this file, driven by live-pump. The
\ public API never writes to the socket: it records what it wants, calls
\ live-pump until the owner has done the work, and then reads the result. The
\ conformance adapter drives the same pump from its own event loop. There is
\ therefore no second writer to race with, and no lock is needed to prove it.
\
\ Barriers
\ --------
\ Every delivery carries three stamps: which subscription it belongs to, that
\ subscription's epoch, and the manager generation at the moment it was queued.
\ Unsubscribing or replacing a subscription bumps its epoch and purges its
\ queued deliveries before the acknowledgement is published, and a consumer
\ re-checks the epoch after dequeue, so a value belonging to a removed or
\ replaced subscription can never cross either acknowledgement. Retiring a
\ connection bumps the manager generation, and debugDisconnect additionally
\ purges the queue, so nothing produced by the retired socket survives its
\ acknowledgement either. The generation is published for the conformance
\ adapter to use as its own second check.
\
\ Rehydration
\ -----------
\ After a reconnect the server resends the current value of every active
\ query. Publishing that unchanged value would turn one logical update into
\ two, so each subscription remembers the exact bytes it last published and
\ suppresses an identical rehydration. An error publication clears that
\ memory, which is what lets a QueryFailed be followed by the same value again
\ and still be seen as a recovery.

require convex-config.fth
require convex-error.fth
require convex-buffer.fth
require convex-json.fth
require convex-io.fth
require convex-ws.fth
require convex-http.fth

\ ---------------------------------------------------------------------------
\ Sync-profile timestamps
\
\ A version timestamp is a uint64 in little-endian byte order, base64 encoded
\ into exactly twelve characters with one padding character. Decoding is
\ canonical: the value is re-encoded and compared, so a non-canonical encoding
\ is rejected instead of being silently accepted.
\ ---------------------------------------------------------------------------

: base64-value ( c -- n )       \ -1 for a character outside the alphabet
    dup [char] A [char] Z 1+ within if [char] A - exit then
    dup [char] a [char] z 1+ within if [char] a - 26 + exit then
    dup [char] 0 [char] 9 1+ within if [char] 0 - 52 + exit then
    dup [char] + = if drop 62 exit then
    [char] / = if 63 else -1 then ;

create ts-bytes 8 allot

: timestamp-encode ( value buf -- )
    0 { value buf chunk }
    value 0< if
        s" Live timestamp is outside the supported range" cvx-raise-protocol
    then
    8 0 ?do
        value 255 and ts-bytes i + c!
        value 8 rshift to value
    loop
    ts-bytes 8 buf base64-encode ;

64 buf-new constant ts-scratch

: timestamp-decode ( addr u -- value )
    0 0 { addr count value digit }
    count 12 <> if
        s" Live timestamp is not a canonical base64 uint64" cvx-raise-protocol
    then
    addr 11 + c@ [char] = <> if
        s" Live timestamp is not a canonical base64 uint64" cvx-raise-protocol
    then
    ts-bytes 8 erase
    11 0 ?do
        addr i + c@ base64-value to digit
        digit 0< if
            s" Live timestamp contains invalid base64" cvx-raise-protocol
        then
    loop
    \ Rebuild the eight bytes from the eleven base64 characters.
    addr c@ base64-value 2 lshift
    addr 1+ c@ base64-value 4 rshift or ts-bytes c!
    addr 1+ c@ base64-value 15 and 4 lshift
    addr 2 + c@ base64-value 2 rshift or ts-bytes 1+ c!
    addr 2 + c@ base64-value 3 and 6 lshift
    addr 3 + c@ base64-value or ts-bytes 2 + c!
    addr 4 + c@ base64-value 2 lshift
    addr 5 + c@ base64-value 4 rshift or ts-bytes 3 + c!
    addr 5 + c@ base64-value 15 and 4 lshift
    addr 6 + c@ base64-value 2 rshift or ts-bytes 4 + c!
    addr 6 + c@ base64-value 3 and 6 lshift
    addr 7 + c@ base64-value or ts-bytes 5 + c!
    addr 8 + c@ base64-value 2 lshift
    addr 9 + c@ base64-value 4 rshift or ts-bytes 6 + c!
    addr 9 + c@ base64-value 15 and 4 lshift
    addr 10 + c@ base64-value 2 rshift or ts-bytes 7 + c!
    0 to value
    8 0 ?do
        value 8 lshift  ts-bytes 7 i - + c@ or to value
    loop
    value 0< if
        s" Live timestamp is outside the supported range" cvx-raise-protocol
    then
    ts-scratch buf-reset
    value ts-scratch timestamp-encode
    ts-scratch buf-span addr count str= 0= if
        s" Live timestamp is not canonical" cvx-raise-protocol
    then
    value ;

4294967295 constant max-uint32

: live-uint32 ( doc node -- value )
    0 0 { doc node value ok }
    doc node json-integer to ok to value
    ok 0= value 0< or value max-uint32 u> or if
        s" Live version field is not a uint32" cvx-raise-protocol
    then
    value ;

\ ---------------------------------------------------------------------------
\ Subscriptions
\ ---------------------------------------------------------------------------

0 cells constant sub>active
1 cells constant sub>query-id
2 cells constant sub>path
3 cells constant sub>args
4 cells constant sub>charge
5 cells constant sub>have-last
6 cells constant sub>last
7 cells constant sub>epoch
8 cells constant sub-size

\ ---------------------------------------------------------------------------
\ Deliveries
\
\ A fixed table rather than a growing queue, so the client's Live buffering is
\ bounded by construction. Each slot is charged its encoded bytes plus a fixed
\ per-item overhead, because sixteen near-maximum values would otherwise sit
\ well above the byte budget the count alone suggests.
\ ---------------------------------------------------------------------------

0 cells constant dl>used
1 cells constant dl>seq
2 cells constant dl>sub
3 cells constant dl>epoch
4 cells constant dl>generation
5 cells constant dl>kind        \ 1 value, 2 error
6 cells constant dl>value
7 cells constant dl>name
8 cells constant dl>message
9 cells constant dl>data
10 cells constant dl>logs
11 cells constant dl>bytes
12 cells constant dl-size

1 constant delivery-value
2 constant delivery-error

\ ---------------------------------------------------------------------------
\ The manager
\ ---------------------------------------------------------------------------

0 cells constant lv>client
1 cells constant lv>ws              \ 0 when there is no live connection
2 cells constant lv>subs
3 cells constant lv>sub-bytes
4 cells constant lv>next-query-id
5 cells constant lv>query-set-version
6 cells constant lv>remote-query-set
7 cells constant lv>remote-identity
8 cells constant lv>remote-ts
9 cells constant lv>generation
10 cells constant lv>connection-count
11 cells constant lv>close-reason
12 cells constant lv>max-ts
13 cells constant lv>backoff
14 cells constant lv>next-connect
15 cells constant lv>queue
16 cells constant lv>seq
17 cells constant lv>queue-count
18 cells constant lv>queue-bytes
19 cells constant lv>closed
20 cells constant lv>session
21 cells constant lv>doc
22 cells constant lv>out
23 cells constant lv>drops
24 cells constant lv>pending        \ per-subscription pending transition state
25 cells constant lv-size

: lv-subs ( live -- addr )  lv>subs + @ ;
: lv-sub ( live index -- addr )  sub-size *  swap lv-subs + ;
: lv-queue ( live -- addr )  lv>queue + @ ;
: lv-delivery ( live index -- addr )  dl-size *  swap lv-queue + ;
: lv-pending ( live -- addr )  lv>pending + @ ;
: lv-ws ( live -- ws )  lv>ws + @ ;
: lv-doc ( live -- doc )  lv>doc + @ ;
: lv-out ( live -- buf )  lv>out + @ ;
: lv-generation ( live -- n )  lv>generation + @ ;
: lv-connection-count ( live -- n )  lv>connection-count + @ ;
: lv-close-reason ( live -- addr u )  lv>close-reason + @ buf-span ;
: lv-max-ts ( live -- n )  lv>max-ts + @ ;
: lv-drops ( live -- n )  lv>drops + @ ;

: live-new ( client -- live )
    lv-size allocate throw { client live }
    client live lv>client + !
    0 live lv>ws + !
    cvx-max-subscriptions sub-size * allocate throw live lv>subs + !
    cvx-max-subscriptions 0 ?do
        false live i lv-sub sub>active + !
        0 live i lv-sub sub>query-id + !
        64 buf-new live i lv-sub sub>path + !
        64 buf-new live i lv-sub sub>args + !
        0 live i lv-sub sub>charge + !
        false live i lv-sub sub>have-last + !
        256 buf-new live i lv-sub sub>last + !
        0 live i lv-sub sub>epoch + !
    loop
    0 live lv>sub-bytes + !
    0 live lv>next-query-id + !
    0 live lv>query-set-version + !
    0 live lv>remote-query-set + !
    0 live lv>remote-identity + !
    0 live lv>remote-ts + !
    0 live lv>generation + !
    0 live lv>connection-count + !
    64 buf-new live lv>close-reason + !
    s" InitialConnect" live lv>close-reason + @ buf-append
    0 live lv>max-ts + !
    cvx-initial-backoff live lv>backoff + !
    0 live lv>next-connect + !
    cvx-max-deliveries dl-size * allocate throw live lv>queue + !
    cvx-max-deliveries 0 ?do
        false live i lv-delivery dl>used + !
        0 live i lv-delivery dl>seq + !
        -1 live i lv-delivery dl>sub + !
        0 live i lv-delivery dl>epoch + !
        0 live i lv-delivery dl>generation + !
        0 live i lv-delivery dl>kind + !
        256 buf-new live i lv-delivery dl>value + !
        64 buf-new live i lv-delivery dl>name + !
        256 buf-new live i lv-delivery dl>message + !
        64 buf-new live i lv-delivery dl>data + !
        64 buf-new live i lv-delivery dl>logs + !
        0 live i lv-delivery dl>bytes + !
    loop
    0 live lv>seq + !
    0 live lv>queue-count + !
    0 live lv>queue-bytes + !
    false live lv>closed + !
    64 buf-new live lv>session + !
    16 live lv>session + @ random-hex
    json-new live lv>doc + !
    4096 buf-new live lv>out + !
    0 live lv>drops + !
    cvx-max-subscriptions 2 * cells allocate throw live lv>pending + !
    live ;

\ ---------------------------------------------------------------------------
\ The bounded delivery queue
\ ---------------------------------------------------------------------------

: delivery-charge ( live index -- u )
    lv-delivery { entry }
    entry dl>value + @ buf-len
    entry dl>name + @ buf-len +
    entry dl>message + @ buf-len +
    entry dl>data + @ buf-len +
    entry dl>logs + @ buf-len +
    cvx-delivery-overhead + ;

: delivery-release ( live index -- )
    { live index }
    live index lv-delivery dl>used + @ 0= if exit then
    false live index lv-delivery dl>used + !
    live index lv-delivery dl>bytes + @ negate live lv>queue-bytes + +!
    -1 live lv>queue-count + +!
    \ Give large buffers back rather than keeping a high-water mark alive for
    \ the rest of the run.
    live index lv-delivery dl>value + @ buf-shrink
    live index lv-delivery dl>message + @ buf-shrink
    live index lv-delivery dl>data + @ buf-shrink
    live index lv-delivery dl>logs + @ buf-shrink ;

: delivery-oldest ( live -- index )      \ -1 when the queue is empty
    0 0 { live best best-seq }
    -1 to best  0 to best-seq
    cvx-max-deliveries 0 ?do
        live i lv-delivery dl>used + @ if
            best 0< live i lv-delivery dl>seq + @ best-seq u< or if
                i to best
                live i lv-delivery dl>seq + @ to best-seq
            then
        then
    loop
    best ;

: delivery-oldest-for ( live sub -- index )
    0 0 { live sub best best-seq }
    -1 to best  0 to best-seq
    cvx-max-deliveries 0 ?do
        live i lv-delivery dl>used + @
        live i lv-delivery dl>sub + @ sub = and if
            best 0< live i lv-delivery dl>seq + @ best-seq u< or if
                i to best
                live i lv-delivery dl>seq + @ to best-seq
            then
        then
    loop
    best ;

: delivery-free-slot ( live -- index )   \ -1 when every slot is in use
    { live }
    -1
    cvx-max-deliveries 0 ?do
        live i lv-delivery dl>used + @ 0= if drop i leave then
    loop ;

\ Make room for one more delivery. Overflow drops the oldest queued item and
\ records the drop, so a stopped reader costs bounded memory and is visible in
\ the client's own accounting rather than silently.
: delivery-make-room ( live charge -- )
    0 { live charge oldest }
    begin
        live lv>queue-count + @ cvx-max-deliveries u<
        live lv>queue-bytes + @ charge + cvx-max-delivery-bytes u> 0= and 0=
        live lv>queue-count + @ 0> and
    while
        live delivery-oldest to oldest
        oldest 0< if exit then
        live oldest delivery-release
        1 live lv>drops + +!
    repeat ;

: delivery-commit ( live index charge -- )
    { live index charge }
    true live index lv-delivery dl>used + !
    charge live index lv-delivery dl>bytes + !
    live lv>seq + @ 1+ dup live lv>seq + !
    live index lv-delivery dl>seq + !
    charge live lv>queue-bytes + +!
    1 live lv>queue-count + +! ;

\ ---------------------------------------------------------------------------
\ Publishing
\ ---------------------------------------------------------------------------

: live-stamp ( live index sub -- )
    { live index sub }
    sub live index lv-delivery dl>sub + !
    live sub lv-sub sub>epoch + @ live index lv-delivery dl>epoch + !
    live lv-generation live index lv-delivery dl>generation + ! ;

: live-publish-value ( live sub addr u -- )
    0 0 { live sub addr count index charge }
    \ Suppress an unchanged rehydration so one logical update stays one event.
    live sub lv-sub sub>have-last + @ if
        live sub lv-sub sub>last + @ buf-span addr count str= if exit then
    then
    live sub lv-sub sub>last + @ buf-reset
    addr count live sub lv-sub sub>last + @ buf-append
    true live sub lv-sub sub>have-last + !
    count cvx-delivery-overhead + to charge
    live charge delivery-make-room
    live delivery-free-slot to index
    index 0< if exit then
    delivery-value live index lv-delivery dl>kind + !
    live index lv-delivery dl>value + @ buf-reset
    addr count live index lv-delivery dl>value + @ buf-append
    live index lv-delivery dl>name + @ buf-reset
    live index lv-delivery dl>message + @ buf-reset
    live index lv-delivery dl>data + @ buf-reset
    live index lv-delivery dl>logs + @ buf-reset
    live index sub live-stamp
    live index charge delivery-commit ;

: live-publish-error ( live sub name-addr name-u message-addr message-u -- index )
    0 0 { live sub name-addr name-count message-addr message-count index charge }
    \ An error clears the suppression memory so the same value delivered after
    \ recovery is still published.
    false live sub lv-sub sub>have-last + !
    name-count message-count + cvx-delivery-overhead + to charge
    live charge delivery-make-room
    live delivery-free-slot to index
    index 0< if -1 exit then
    delivery-error live index lv-delivery dl>kind + !
    live index lv-delivery dl>value + @ buf-reset
    live index lv-delivery dl>name + @ buf-reset
    name-addr name-count live index lv-delivery dl>name + @ buf-append
    live index lv-delivery dl>message + @ buf-reset
    message-addr message-count live index lv-delivery dl>message + @ buf-append
    live index lv-delivery dl>data + @ buf-reset
    live index lv-delivery dl>logs + @ buf-reset
    live index sub live-stamp
    live index charge delivery-commit
    index ;

: live-attach-error-detail ( live index data-addr data-u logs-addr logs-u -- )
    { live index data-addr data-count logs-addr logs-count }
    data-addr data-count live index lv-delivery dl>data + @ buf-append
    logs-addr logs-count live index lv-delivery dl>logs + @ buf-append ;

: live-publish-to-all ( live name-addr name-u message-addr message-u -- )
    { live name-addr name-count message-addr message-count }
    cvx-max-subscriptions 0 ?do
        live i lv-sub sub>active + @ if
            live i name-addr name-count message-addr message-count
            live-publish-error drop
        then
    loop ;

: live-purge-subscription ( live sub -- )
    { live sub }
    cvx-max-deliveries 0 ?do
        live i lv-delivery dl>used + @
        live i lv-delivery dl>sub + @ sub = and if
            live i delivery-release
        then
    loop ;

\ Dropping an unconsumed value must also forget that it was published.
\ Otherwise the rehydration that follows a reconnect would be suppressed as
\ unchanged and the caller would never see the value at all.
: live-purge-all ( live -- )
    0 { live sub }
    cvx-max-deliveries 0 ?do
        live i lv-delivery dl>used + @ if
            live i lv-delivery dl>sub + @ to sub
            sub 0< 0= live i lv-delivery dl>kind + @ delivery-value = and if
                false live sub lv-sub sub>have-last + !
            then
        then
        live i delivery-release
    loop
    0 live lv>queue-count + !
    0 live lv>queue-bytes + ! ;

\ ---------------------------------------------------------------------------
\ Outgoing sync messages
\ ---------------------------------------------------------------------------

: live-send ( live absolute -- )
    { live absolute }
    live lv-ws 0= if s" Live WebSocket is not connected" cvx-raise-transport then
    live lv-out buf-span live lv-ws absolute ws-send-text ;

: live-write-modification ( live sub add? -- )
    { live sub add? }
    jw{
        add? if
            s" type" s" Add" jw-pair-string
            s" queryId" live sub lv-sub sub>query-id + @ jw-pair-uint
            s" udfPath" live sub lv-sub sub>path + @ buf-span jw-pair-string
            s" args" jw-key
            jw[
                live sub lv-sub sub>args + @ buf-span jw-raw
            jw]
        else
            s" type" s" Remove" jw-pair-string
            s" queryId" live sub lv-sub sub>query-id + @ jw-pair-uint
        then
    jw} ;

: live-send-connect ( live absolute -- )
    { live absolute }
    live lv-out dup buf-reset jw-start
    jw{
        s" type" s" Connect" jw-pair-string
        s" sessionId" live lv>session + @ buf-span jw-pair-string
        s" connectionCount" live lv-connection-count jw-pair-uint
        s" lastCloseReason" live lv-close-reason jw-pair-string
        s" clientTs" 0 jw-pair-uint
        live lv-max-ts 0> if
            s" maxObservedTimestamp" jw-key
            ts-scratch buf-reset
            live lv-max-ts ts-scratch timestamp-encode
            ts-scratch buf-span jw-value-string
        then
    jw}
    live absolute live-send ;

\ Resend every active Add on a fresh connection. Proving that this happens on
\ each of five reconnects is what makes reconnect evidence meaningful.
: live-send-full-query-set ( live absolute -- )
    0 { live absolute any }
    false to any
    cvx-max-subscriptions 0 ?do
        live i lv-sub sub>active + @ if true to any then
    loop
    any 0= if 0 live lv>query-set-version + ! exit then
    live lv-out dup buf-reset jw-start
    jw{
        s" type" s" ModifyQuerySet" jw-pair-string
        s" baseVersion" 0 jw-pair-uint
        s" newVersion" 1 jw-pair-uint
        s" modifications" jw-key
        jw[
            cvx-max-subscriptions 0 ?do
                live i lv-sub sub>active + @ if
                    live i true live-write-modification
                then
            loop
        jw]
    jw}
    live absolute live-send
    1 live lv>query-set-version + ! ;

: live-send-modification ( live sub add? absolute -- )
    0 { live sub add? absolute version }
    live lv>query-set-version + @ to version
    version max-uint32 = if
        s" Live query-set version is exhausted" cvx-raise-protocol
    then
    live lv-out dup buf-reset jw-start
    jw{
        s" type" s" ModifyQuerySet" jw-pair-string
        s" baseVersion" version jw-pair-uint
        s" newVersion" version 1+ jw-pair-uint
        s" modifications" jw-key
        jw[
            live sub add? live-write-modification
        jw]
    jw}
    live absolute live-send
    version 1+ live lv>query-set-version + ! ;

\ ---------------------------------------------------------------------------
\ Retiring a connection
\ ---------------------------------------------------------------------------

\ Retirement is the barrier. The generation moves first, so anything the old
\ connection queued is already stale by the time a caller can observe the
\ failure, and no later acknowledgement can be crossed by an old event.
: live-retire ( live reason-addr reason-u -- )
    { live reason-addr reason-count }
    1 live lv>generation + +!
    live lv-ws 0<> if
        live lv-ws ws-free
        0 live lv>ws + !
    then
    live lv>close-reason + @ buf-reset
    reason-addr reason-count live lv>close-reason + @ buf-append
    0 live lv>query-set-version + !
    0 live lv>remote-query-set + !
    0 live lv>remote-identity + !
    0 live lv>remote-ts + ! ;

: live-schedule-reconnect ( live -- )
    0 { live backoff }
    live lv>backoff + @ to backoff
    now backoff + live lv>next-connect + !
    backoff 2* cvx-max-backoff min live lv>backoff + ! ;

\ ---------------------------------------------------------------------------
\ Incoming sync messages
\ ---------------------------------------------------------------------------

0 constant pending-none
1 constant pending-value
2 constant pending-error

: pending-kind ( live sub -- addr )  2 * cells  swap lv-pending + ;
: pending-node ( live sub -- addr )  2 * 1+ cells  swap lv-pending + ;

: live-clear-pending ( live -- )
    { live }
    cvx-max-subscriptions 0 ?do
        pending-none live i pending-kind !
        -1 live i pending-node !
    loop ;

: live-find-query ( live query-id -- sub )      \ -1 when unknown
    { live query-id }
    -1
    cvx-max-subscriptions 0 ?do
        live i lv-sub sub>active + @
        live i lv-sub sub>query-id + @ query-id = and if drop i leave then
    loop ;

: live-version-field ( live doc node key-addr key-u -- value )
    0 { live doc node key-addr key-count child }
    doc node key-addr key-count json-get to child
    child 0< if
        s" Live state version is missing a field" cvx-raise-protocol
    then
    doc child live-uint32 ;

: live-version-ts ( doc node -- value )
    0 { doc node child }
    doc node s" ts" json-get to child
    doc child json-string? 0= if
        s" Live state version timestamp must be a string" cvx-raise-protocol
    then
    doc child json-string@ timestamp-decode ;

: live-check-start-version ( live doc node -- )
    { live doc node }
    doc node json-object? 0= if
        s" Live state version must be an object" cvx-raise-protocol
    then
    live doc node s" querySet" live-version-field
    live lv>remote-query-set + @ <>
    live doc node s" identity" live-version-field
    live lv>remote-identity + @ <> or
    doc node live-version-ts live lv>remote-ts + @ <> or if
        s" Live transition start version did not match local state"
        cvx-raise-protocol
    then ;

: live-record-modification ( live doc node -- )
    0 0 0 0 0 0 { live doc node kind-node kind-addr kind-count query-id sub value }
    doc node json-object? 0= if
        s" Live modification must be an object" cvx-raise-protocol
    then
    doc node s" type" json-get to kind-node
    doc kind-node json-string? 0= if
        s" Live modification type must be a string" cvx-raise-protocol
    then
    doc kind-node json-string@ to kind-count to kind-addr
    doc node s" queryId" json-get to value
    doc value live-uint32 to query-id
    live query-id live-find-query to sub
    kind-addr kind-count s" QueryUpdated" str= if
        doc node s" value" json-has? 0= if
            s" QueryUpdated is missing value" cvx-raise-protocol
        then
        doc node s" logLines" json-get dup 0< 0= if
            doc swap json-log-lines? 0= if
                s" Live logLines must be an array of strings" cvx-raise-protocol
            then
        else drop then
        sub 0< if exit then
        pending-value live sub pending-kind !
        doc node s" value" json-get live sub pending-node !
        exit
    then
    kind-addr kind-count s" QueryFailed" str= if
        doc node s" errorMessage" json-get to value
        doc value json-string? 0= if
            s" QueryFailed errorMessage must be a string" cvx-raise-protocol
        then
        sub 0< if exit then
        pending-error live sub pending-kind !
        node live sub pending-node !
        exit
    then
    kind-addr kind-count s" QueryRemoved" str= if
        sub 0< if exit then
        pending-none live sub pending-kind !
        exit
    then
    s" unsupported Live modification" cvx-raise-protocol ;

: live-commit-pending ( live doc -- )
    0 0 0 0 0 { live doc node value index data-node logs-node }
    cvx-max-subscriptions 0 ?do
        live i pending-kind @ pending-value = if
            live i  doc live i pending-node @ json-raw  live-publish-value
        then
        live i pending-kind @ pending-error = if
            live i pending-node @ to node
            doc node s" errorMessage" json-get to value
            live i s" FunctionError" doc value json-string@ live-publish-error
            to index
            index 0< 0= if
                doc node s" errorData" json-get to data-node
                doc node s" logLines" json-get to logs-node
                live index
                data-node 0< if s" " else doc data-node json-raw then
                logs-node 0< if s" " else doc logs-node json-raw then
                live-attach-error-detail
            then
        then
    loop ;

\ A Transition is validated completely before any of it is published. A
\ half-applied transition would leave the client claiming a version it never
\ fully understood.
: live-handle-transition ( live doc root -- )
    0 0 0 0 0 { live doc root start end modifications child end-ts }
    doc root s" startVersion" json-get to start
    doc root s" endVersion" json-get to end
    doc root s" modifications" json-get to modifications
    live doc start live-check-start-version
    doc end json-object? 0= if
        s" Live end version must be an object" cvx-raise-protocol
    then
    doc end live-version-ts to end-ts
    end-ts live lv>remote-ts + @ u< if
        s" Live timestamp moved backwards" cvx-raise-protocol
    then
    doc modifications json-array? 0= if
        s" Live modifications must be an array" cvx-raise-protocol
    then
    live live-clear-pending
    doc modifications json-first to child
    begin child 0>= while
        live doc child live-record-modification
        doc child json-next to child
    repeat
    \ Everything validated: commit the version, then publish.
    live doc end s" querySet" live-version-field live lv>remote-query-set + !
    live doc end s" identity" live-version-field live lv>remote-identity + !
    end-ts live lv>remote-ts + !
    end-ts live lv-max-ts u> if end-ts live lv>max-ts + ! then
    live doc live-commit-pending
    \ A valid transition proves the connection is healthy, so the transport
    \ backoff must not carry an old failure's delay into the next reconnect.
    cvx-initial-backoff live lv>backoff + !
    0 live lv>next-connect + ! ;

: live-handle-message ( live addr u -- )
    0 0 0 { live addr count doc root kind }
    count cvx-max-message-bytes u> if
        s" Live message exceeds the message limit" cvx-raise-protocol
    then
    live lv-doc to doc
    addr count doc json-parse
    doc doc-root to root
    doc root s" type" json-get to kind
    doc kind json-string? 0= if
        s" Live message type is missing" cvx-raise-protocol
    then
    doc kind json-string@ 2dup s" Transition" str= if
        2drop live doc root live-handle-transition exit
    then
    2dup s" Ping" str= if 2drop exit then
    2dup s" MutationResponse" str= if 2drop exit then
    s" ActionResponse" str= if exit then
    s" unsupported Live server message" cvx-raise-protocol ;

\ ---------------------------------------------------------------------------
\ The owner loop
\ ---------------------------------------------------------------------------

variable live-current
variable live-slice-deadline

: live-connect-now ( -- )
    0 0 { live absolute }
    live-current @ to live
    live-slice-deadline @ to absolute
    live lv>client + @ client-dep
    cvx-sync-endpoint
    cvx-ws-connect-deadline deadline+ absolute min
    ws-connect live lv>ws + !
    live absolute live-send-connect
    live absolute live-send-full-query-set
    0 live lv>remote-query-set + !
    0 live lv>remote-identity + !
    0 live lv>remote-ts + !
    0 live lv>next-connect + !
    \ A completed handshake is a healthy connection, so the delay resets here
    \ rather than only after the first transition.
    cvx-initial-backoff live lv>backoff + !
    1 live lv>connection-count + +! ;

: live-service ( -- )
    0 0 0 { live absolute result }
    live-current @ to live
    live-slice-deadline @ to absolute
    live lv-ws absolute ws-pump to result
    result ws-got-message = if
        live live lv-ws ws-message@ live-handle-message
    then
    result ws-got-close = if
        s" Live server closed the WebSocket" cvx-raise-transport
    then ;

\ One bounded slice of owner work. Failures retire the connection, publish a
\ structured error to every active subscription and schedule a reconnect; they
\ never strand a subscription, because the next connection resends its Add.
: live-pump ( live absolute -- )
    0 { live absolute code }
    live lv>closed + @ if exit then
    live live-current !
    absolute live-slice-deadline !
    live lv-ws 0= if
        live lv>next-connect + @ now u> if
            \ Held off by backoff. Wait rather than spin, but never past the
            \ caller's own deadline.
            live lv>next-connect + @ now -
            absolute deadline-remaining min
            dup 0> if io-sleep else drop then
            exit
        then
        ['] live-connect-now catch to code
        code 0<> if
            code cvx-adopt-fault
            live cvx-error-message@ live-retire
            live live-schedule-reconnect
            live s" TransportError" cvx-error-message@ live-publish-to-all
        then
        exit
    then
    ['] live-service catch to code
    code 0<> if
        code cvx-adopt-fault
        live cvx-error-message@ live-retire
        live live-schedule-reconnect
        live cvx-error-name@ cvx-error-message@ live-publish-to-all
    then ;

\ ---------------------------------------------------------------------------
\ Public Live API
\ ---------------------------------------------------------------------------

: live-ensure ( client -- live )
    { client }
    client client-live 0= if
        client live-new client cl>live + !
    then
    client client-live ;

: live-charge ( path-u args-u -- charge )  + 512 + ;

: live-free-subscription ( live -- sub )    \ -1 when the table is full
    { live }
    -1
    cvx-max-subscriptions 0 ?do
        live i lv-sub sub>active + @ 0= if drop i leave then
    loop ;

: live-subscribe ( client path-addr path-u args-addr args-u -- sub )
    0 0 0 0 0 { client path-addr path-count args-addr args-count live sub charge absolute code }
    s" subscribe" cvx-operation!
    path-addr path-count convex-valid-path? 0= if
        s" function path must be module:function" cvx-raise-protocol
    then
    client live-ensure to live
    path-count args-count live-charge to charge
    live lv>sub-bytes + @ charge + cvx-max-subscription-bytes u> if
        s" Live subscription capacity exceeded" cvx-raise-protocol
    then
    live live-free-subscription to sub
    sub 0< if
        s" Live subscription capacity exceeded" cvx-raise-protocol
    then
    live lv>next-query-id + @ max-uint32 u< 0= if
        s" Live query ID space is exhausted" cvx-raise-protocol
    then
    live sub lv-sub sub>path + @ buf-reset
    path-addr path-count live sub lv-sub sub>path + @ buf-append
    live sub lv-sub sub>args + @ buf-reset
    args-addr args-count live sub lv-sub sub>args + @ buf-append
    live lv>next-query-id + @ live sub lv-sub sub>query-id + !
    1 live lv>next-query-id + +!
    charge live sub lv-sub sub>charge + !
    charge live lv>sub-bytes + +!
    false live sub lv-sub sub>have-last + !
    1 live sub lv-sub sub>epoch + +!
    true live sub lv-sub sub>active + !
    cvx-ws-connect-deadline deadline+ to absolute
    live lv-ws 0= if
        \ Connect first; the fresh connection carries this Add in its full
        \ query set, so there is nothing extra to send afterwards.
        0 live lv>next-connect + !
        live absolute live-pump
        live lv-ws 0= if
            false live sub lv-sub sub>active + !
            charge negate live lv>sub-bytes + +!
            msg-start s" Live connection failed: " msg+ live lv-close-reason msg+
            s" TransportError" cvx-raise-msg
        then
    else
        live sub true absolute ['] live-send-modification catch to code
        code 0<> if
            \ The write may have partly happened, so retire before failing.
            code cvx-adopt-fault
            false live sub lv-sub sub>active + !
            charge negate live lv>sub-bytes + +!
            live s" SubscribeFailed" live-retire
            live live-schedule-reconnect
            cvx-error-code throw
        then
    then
    sub ;

: live-unsubscribe ( client sub -- )
    0 0 0 { client sub live absolute code }
    s" unsubscribe" cvx-operation!
    client client-live to live
    live 0= if exit then
    live sub lv-sub sub>active + @ 0= if exit then
    \ The barrier: the epoch moves and the queue is purged before the caller
    \ can observe the acknowledgement, so no stale event can cross it.
    1 live sub lv-sub sub>epoch + +!
    false live sub lv-sub sub>active + !
    false live sub lv-sub sub>have-last + !
    live sub lv-sub sub>charge + @ negate live lv>sub-bytes + +!
    live sub live-purge-subscription
    live lv-ws 0<> if
        cvx-close-deadline deadline+ to absolute
        live sub false absolute ['] live-send-modification catch to code
        code 0<> if
            2drop 2drop            \ the arguments catch left behind
            \ Retirement is itself a valid Remove barrier: the retired
            \ connection can publish nothing even though its write failed.
            live s" UnsubscribeFailed" live-retire
            live live-schedule-reconnect
        then
    then ;

\ Fault injection for the conformance adapter only. The acknowledgement is
\ returned after the old connection is retired and the reconnect scheduled, so
\ the controller can trust that nothing from the old socket follows it.
: live-debug-disconnect ( client -- generation )
    0 { client live }
    client client-live to live
    live 0= if
        s" Live WebSocket is not connected" cvx-raise-transport
    then
    live lv-ws 0= if
        s" Live WebSocket is not connected" cvx-raise-transport
    then
    live s" DebugDisconnect" live-retire
    live live-purge-all
    now cvx-initial-backoff + live lv>next-connect + !
    cvx-initial-backoff 2* live lv>backoff + !
    live lv-generation ;

: live-close ( client -- )
    0 0 0 { client live absolute code }
    client client-live to live
    live 0= if exit then
    live lv>closed + @ if exit then
    true live lv>closed + !
    cvx-max-subscriptions 0 ?do
        false live i lv-sub sub>active + !
        1 live i lv-sub sub>epoch + +!
    loop
    0 live lv>sub-bytes + !
    live live-purge-all
    live lv-ws 0<> if
        cvx-close-deadline deadline+ to absolute
        live lv-ws absolute ['] ws-send-close catch to code
        code 0<> if 2drop then  \ the arguments catch left behind
    then
    live s" ClientClosed" live-retire ;

\ ---------------------------------------------------------------------------
\ Consuming deliveries
\ ---------------------------------------------------------------------------

0 constant live-none
1 constant live-value
2 constant live-error

\ Fields of the delivery most recently taken. Reading them through the manager
\ keeps the caller from holding a pointer into a slot that has been released.
variable live-taken

: live-taken-kind ( live -- kind )  live-taken @ lv-delivery dl>kind + @ ;
: live-taken-value ( live -- addr u )  live-taken @ lv-delivery dl>value + @ buf-span ;
: live-taken-name ( live -- addr u )  live-taken @ lv-delivery dl>name + @ buf-span ;
: live-taken-message ( live -- addr u )  live-taken @ lv-delivery dl>message + @ buf-span ;
: live-taken-data ( live -- addr u )  live-taken @ lv-delivery dl>data + @ buf-span ;
: live-taken-logs ( live -- addr u )  live-taken @ lv-delivery dl>logs + @ buf-span ;

\ Take a delivery only if it still belongs to the current subscription epoch.
\ This is the second half of the unsubscribe and replacement barrier: a value
\ produced for a subscription that has since been removed or replaced is
\ discarded after dequeue rather than handed to the caller. The connection
\ barrier is enforced separately, by purging the queue when a connection is
\ retired, and the recorded generation is exposed for the adapter to check.
: live-accept? ( live index -- flag )
    0 { live index sub }
    live index lv-delivery dl>sub + @ to sub
    sub 0< if false exit then
    live index lv-delivery dl>epoch + @ live sub lv-sub sub>epoch + @ = ;

: live-take-for ( live sub -- kind )
    0 { live sub index }
    begin
        live sub delivery-oldest-for to index
        index 0< if live-none exit then
        live index live-accept? 0=
    while
        live index delivery-release
    repeat
    index live-taken !
    live index lv-delivery dl>kind + @ ;

: live-release-taken ( live -- )
    { live }
    live live-taken @ delivery-release ;

\ Wait for the next delivery on one subscription, pumping the owner loop while
\ waiting. Every wait is bounded by an absolute deadline.
: live-next ( client sub timeout-ms -- kind )
    0 0 0 { client sub timeout live absolute kind }
    client client-live to live
    live 0= if live-none exit then
    timeout deadline+ to absolute
    begin
        live sub live-take-for to kind
        kind live-none = if
            absolute deadline-expired? if live-none exit then
            live  now cvx-poll-slice + absolute min  live-pump
        then
        kind live-none <>
    until
    kind ;

\ Adapter-facing variants: any subscription, oldest first.
: live-take-any ( live -- sub kind )
    0 { live index }
    begin
        live delivery-oldest to index
        index 0< if -1 live-none exit then
        live index live-accept? 0=
    while
        live index delivery-release
    repeat
    index live-taken !
    live index lv-delivery dl>sub + @
    live index lv-delivery dl>kind + @ ;

: live-connected? ( client -- flag )
    0 { client live }
    client client-live to live
    live 0= if false exit then
    live lv-ws 0<> ;
