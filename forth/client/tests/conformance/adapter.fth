\ adapter.fth - the test-only conformance executable.
\
\ This is not part of the educational client. It speaks NDJSON adapter
\ protocol v1 so the shared controller can drive the real Forth client
\ black-box, over stdin and stdout or, when ADAPTER_LISTEN is set, over one
\ accepted TCP connection carrying the same stream.
\
\ Stdout carries protocol events and nothing else; every diagnostic goes to
\ stderr. Each event is composed whole before it is queued, so a partial write
\ can never emit half a JSON line.
\
\ Outbound events are queued in a bounded outbox. When the controller stops
\ reading, the adapter first tries to flush; only then does it drop the oldest
\ droppable event, which is always a subscription update rather than the answer
\ to a command. Both the count and the byte budget are enforced, and the byte
\ budget includes the encoded event plus a fixed per-item overhead, so sixteen
\ near-maximum values stay far below the shared 128 MiB container limit.

require convex.fth

: adapter-language ( -- addr u )  s" forth" ;
: adapter-implementation ( -- addr u )  s" native-forth-0.1.0" ;

\ Pinned at build time so the reported runtime cannot drift from the image.
: adapter-runtime ( -- addr u )
    s" FORTH_RUNTIME" getenv dup 0= if 2drop s" gforth-unknown" then ;

\ ---------------------------------------------------------------------------
\ Streams
\ ---------------------------------------------------------------------------

variable adapter-in           \ controller stream, read side
variable adapter-out          \ controller stream, write side
variable adapter-listener
variable adapter-client
variable adapter-running

\ ---------------------------------------------------------------------------
\ Bounded outbox
\ ---------------------------------------------------------------------------

create outbox-used cvx-max-outbox cells allot
create outbox-seq cvx-max-outbox cells allot
create outbox-drop-ok cvx-max-outbox cells allot
create outbox-charges cvx-max-outbox cells allot
create outbox-bufs cvx-max-outbox cells allot
variable outbox-next-seq
variable outbox-count
variable outbox-bytes
variable outbox-current       \ slot being written, -1 when between events
variable outbox-offset        \ bytes of the current event already accepted
variable outbox-drops

4096 buf-new constant adapter-scratch
4096 buf-new constant adapter-line

: outbox-buf ( index -- buf )  cells outbox-bufs + @ ;

: outbox-init ( -- )
    cvx-max-outbox 0 ?do
        4096 buf-new  outbox-bufs i cells + !
        false outbox-used i cells + !
        0 outbox-seq i cells + !
        false outbox-drop-ok i cells + !
        0 outbox-charges i cells + !
    loop
    0 outbox-next-seq !
    0 outbox-count !
    0 outbox-bytes !
    -1 outbox-current !
    0 outbox-offset !
    0 outbox-drops ! ;

: outbox-oldest ( -- index )        \ -1 when nothing is queued
    0 0 { best best-seq }
    -1 to best  0 to best-seq
    cvx-max-outbox 0 ?do
        outbox-used i cells + @ if
            best 0< outbox-seq i cells + @ best-seq u< or if
                i to best
                outbox-seq i cells + @ to best-seq
            then
        then
    loop
    best ;

: outbox-release ( index -- )
    { index }
    outbox-used index cells + @ 0= if exit then
    false outbox-used index cells + !
    outbox-charges index cells + @ negate outbox-bytes +!
    -1 outbox-count +!
    index outbox-buf buf-shrink ;

\ Write as much of the queued stream as the controller will take right now.
\ A partial write is normal and resumes on the next pass, which is what keeps
\ the adapter responsive to the Convex socket while a controller is slow.
: outbox-flush ( -- )
    0 0 { index written }
    begin
        outbox-current @ 0< if outbox-oldest outbox-current ! 0 outbox-offset ! then
        outbox-current @ to index
        index 0< if exit then
        index outbox-buf buf-len outbox-offset @ u> 0= if
            index outbox-release
            -1 outbox-current !
            0 outbox-offset !
            outbox-count @ 0=
        else
            index outbox-buf buf-data outbox-offset @ +
            index outbox-buf buf-len outbox-offset @ -
            adapter-out @ stream-write-some to written
            written outbox-offset +!
            written 0=
        then
    until ;

\ Drop the oldest event that may be dropped, which is always a subscription
\ update. The answer to a command is never dropped, so a stalled controller
\ loses reactive updates rather than seeing a reply that no longer matches
\ its request. The event being written is never dropped either.
: outbox-drop-one ( -- flag )
    0 0 { best best-seq }
    -1 to best  0 to best-seq
    cvx-max-outbox 0 ?do
        outbox-used i cells + @
        outbox-drop-ok i cells + @ and
        i outbox-current @ <> and if
            best 0< outbox-seq i cells + @ best-seq u< or if
                i to best
                outbox-seq i cells + @ to best-seq
            then
        then
    loop
    best 0< if false exit then
    best outbox-release
    1 outbox-drops +!
    true ;

: outbox-free-slot ( -- index )
    -1
    cvx-max-outbox 0 ?do
        outbox-used i cells + @ 0= if drop i leave then
    loop ;

: outbox-room? ( charge -- flag )
    { charge }
    outbox-count @ cvx-max-outbox u<
    outbox-bytes @ charge + cvx-max-outbox-bytes u> 0= and ;

: outbox-push ( droppable -- )
    0 0 { droppable charge index }
    adapter-scratch buf-len cvx-delivery-overhead + to charge
    charge cvx-max-outbox-bytes u> if
        s" adapter event exceeds the outbox byte budget" cvx-raise-protocol
    then
    begin charge outbox-room? 0= while
        outbox-flush
        charge outbox-room? 0= if
            outbox-drop-one 0= if
                s" adapter outbox is full and nothing may be dropped"
                cvx-raise-transport
            then
        then
    repeat
    outbox-free-slot to index
    index outbox-buf buf-reset
    adapter-scratch buf-span index outbox-buf buf-append
    true outbox-used index cells + !
    droppable outbox-drop-ok index cells + !
    charge outbox-charges index cells + !
    outbox-next-seq @ 1+ dup outbox-next-seq !
    outbox-seq index cells + !
    charge outbox-bytes +!
    1 outbox-count +! ;

\ ---------------------------------------------------------------------------
\ Event composition
\ ---------------------------------------------------------------------------

128 string-slot adapter-id
variable adapter-has-id

: event-start ( -- )  adapter-scratch dup buf-reset jw-start jw{ ;
: event-finish ( droppable -- )  jw} 10 adapter-scratch buf-char outbox-push ;

\ The controller validates every event strictly, so an absent id is omitted
\ rather than serialized as null.
: event-id ( -- )
    adapter-has-id @ if
        s" id" adapter-id slot@ jw-pair-string
    then ;

: emit-ready ( -- )
    event-start
        s" protocolVersion" 1 jw-pair-uint
        event-id
        s" type" s" ready" jw-pair-string
        s" language" adapter-language jw-pair-string
        s" implementation" adapter-implementation jw-pair-string
        s" runtime" adapter-runtime jw-pair-string
    false event-finish ;

: emit-result ( value-addr value-u logs-addr logs-u -- )
    { value-addr value-count logs-addr logs-count }
    event-start
        event-id
        s" type" s" result" jw-pair-string
        s" value" value-addr value-count jw-pair-raw
        s" logs" logs-addr logs-count jw-pair-raw
    false event-finish ;

: emit-ack ( -- )
    event-start
        event-id
        s" type" s" ack" jw-pair-string
    false event-finish ;

: emit-closed ( -- )
    event-start
        event-id
        s" type" s" closed" jw-pair-string
    false event-finish ;

\ Serialize the structured error record. Optional detail is omitted when the
\ failure carried none, never emitted as null.
: emit-error-object ( -- )
    s" error" jw-key
    jw{
        s" name" cvx-error-name@ jw-pair-string
        s" message" cvx-error-message@ jw-pair-string
        cvx-error-data@ nip 0<> if
            s" data" cvx-error-data@ jw-pair-raw
        then
    jw} ;

: emit-error ( -- )
    event-start
        event-id
        s" type" s" error" jw-pair-string
        emit-error-object
    false event-finish ;

: emit-subscription-value ( sid-addr sid-u value-addr value-u logs-addr logs-u -- )
    { sid-addr sid-count value-addr value-count logs-addr logs-count }
    event-start
        s" type" s" subscription" jw-pair-string
        s" subscriptionId" sid-addr sid-count jw-pair-string
        s" value" value-addr value-count jw-pair-raw
        s" logs" logs-addr logs-count jw-pair-raw
    true event-finish ;

: emit-subscription-error ( sid-addr sid-u -- )
    { sid-addr sid-count }
    event-start
        s" type" s" subscription" jw-pair-string
        s" subscriptionId" sid-addr sid-count jw-pair-string
        emit-error-object
    true event-finish ;

\ ---------------------------------------------------------------------------
\ Subscription registry
\
\ The controller names subscriptions with its own identifiers. Subscribing
\ again with a live identifier replaces the old one, and the replacement
\ removes the previous subscription before the acknowledgement is queued, so
\ nothing from the old relay can cross it.
\ ---------------------------------------------------------------------------

create registry-ids cvx-max-subscriptions cells allot
create registry-subs cvx-max-subscriptions cells allot

: registry-init ( -- )
    cvx-max-subscriptions 0 ?do
        128 buf-new registry-ids i cells + !
        -1 registry-subs i cells + !
    loop ;

: registry-find ( addr u -- slot )      \ -1 when the identifier is unknown
    { addr count }
    -1
    cvx-max-subscriptions 0 ?do
        registry-subs i cells + @ 0< 0= if
            registry-ids i cells + @ buf-span addr count str= if drop i leave then
        then
    loop ;

: registry-free-slot ( -- slot )
    -1
    cvx-max-subscriptions 0 ?do
        registry-subs i cells + @ 0< if drop i leave then
    loop ;

: registry-slot-for-sub ( sub -- slot )
    { sub }
    -1
    cvx-max-subscriptions 0 ?do
        registry-subs i cells + @ sub = if drop i leave then
    loop ;

: registry-set ( addr u sub slot -- )
    { addr count sub slot }
    registry-ids slot cells + @ buf-reset
    addr count registry-ids slot cells + @ buf-append
    sub registry-subs slot cells + ! ;

: registry-clear ( slot -- )  cells registry-subs + -1 swap ! ;

\ ---------------------------------------------------------------------------
\ Command handling
\ ---------------------------------------------------------------------------

json-new constant adapter-doc

: command-string ( root key-addr key-u -- addr u )
    0 { root key-addr key-count child }
    adapter-doc root key-addr key-count json-get to child
    adapter-doc child json-string? 0= if s" " exit then
    adapter-doc child json-string@ ;

: command-args ( root -- addr u )
    0 { root child }
    adapter-doc root s" args" json-get to child
    adapter-doc child json-object? 0= if s" {}" exit then
    adapter-doc child json-raw ;

: adapter-result ( -- )
    0 0 0 0 { value-addr value-count logs-addr logs-count }
    adapter-client @ convex-value json-raw to value-count to value-addr
    adapter-client @ convex-logs dup 0< if
        2drop s" []" to logs-count to logs-addr
    else
        json-raw to logs-count to logs-addr
    then
    value-addr value-count logs-addr logs-count emit-result ;

: handle-call ( root operation-addr operation-u -- )
    0 0 { root operation-addr operation-count path-addr path-count }
    root s" path" command-string to path-count to path-addr
    adapter-client @ path-addr path-count root command-args
    operation-addr operation-count s" query" str= if
        convex-query
    else
        operation-addr operation-count s" mutation" str= if
            convex-mutation
        else
            convex-action
        then
    then
    adapter-result ;

: handle-subscribe ( root -- )
    0 0 0 0 0 0 { root sid-addr sid-count path-addr path-count slot sub }
    root s" subscriptionId" command-string to sid-count to sid-addr
    root s" path" command-string to path-count to path-addr
    sid-addr sid-count registry-find to slot
    slot 0< 0= if
        \ Same-identifier replacement: remove the old subscription and purge
        \ its queued deliveries before this acknowledgement is queued.
        adapter-client @ registry-subs slot cells + @ convex-unsubscribe
        slot registry-clear
    then
    registry-free-slot to slot
    slot 0< if
        s" adapter subscription table is full" cvx-raise-protocol
    then
    adapter-client @ path-addr path-count root command-args
    convex-subscribe to sub
    sid-addr sid-count sub slot registry-set
    emit-ack ;

: handle-unsubscribe ( root -- )
    0 0 0 { root sid-addr sid-count slot }
    root s" subscriptionId" command-string to sid-count to sid-addr
    sid-addr sid-count registry-find to slot
    slot 0< 0= if
        adapter-client @ registry-subs slot cells + @ convex-unsubscribe
        slot registry-clear
    then
    emit-ack ;

: handle-set-auth ( root -- )
    0 0 { root token-addr token-count }
    root s" token" command-string to token-count to token-addr
    token-count 0= if
        adapter-client @ convex-clear-auth
    else
        token-addr token-count adapter-client @ convex-set-auth
    then
    emit-ack ;

: handle-close ( -- )
    adapter-client @ convex-close
    emit-closed
    false adapter-running ! ;

: handle-command ( root -- )
    0 0 { root op-addr op-count }
    root s" op" command-string to op-count to op-addr
    op-addr op-count s" hello" str= if
        adapter-doc root s" protocolVersion" json-get
        adapter-doc swap json-integer 0= swap 1 <> or if
            s" unsupported adapter protocol version" cvx-raise-protocol
        then
        emit-ready exit
    then
    op-addr op-count s" query" str= if root s" query" handle-call exit then
    op-addr op-count s" mutation" str= if root s" mutation" handle-call exit then
    op-addr op-count s" action" str= if root s" action" handle-call exit then
    op-addr op-count s" setAuth" str= if root handle-set-auth exit then
    op-addr op-count s" subscribe" str= if root handle-subscribe exit then
    op-addr op-count s" unsubscribe" str= if root handle-unsubscribe exit then
    op-addr op-count s" debugDisconnect" str= if
        adapter-client @ live-debug-disconnect drop
        emit-ack exit
    then
    op-addr op-count s" close" str= if handle-close exit then
    s" unknown adapter operation" cvx-raise-protocol ;

variable command-root

: dispatch-command ( -- )  command-root @ handle-command ;

: adapter-consume-line ( addr u -- )
    0 0 { addr count root code }
    false adapter-has-id !
    cvx-error-reset
    s" adapter" cvx-operation!
    addr count adapter-doc ['] json-parse catch to code
    code 0<> if
        \ catch restores the stack depth but not the arguments it consumed,
        \ and this failure is reported rather than rethrown, so they are
        \ discarded here instead of accumulating one line at a time.
        drop 2drop
        code cvx-adopt-fault
        emit-error exit
    then
    adapter-doc doc-root to root
    adapter-doc root json-object? 0= if
        s" adapter command must be a JSON object" cvx-error-message!
        s" ProtocolError" cvx-error-name!
        emit-error exit
    then
    root s" id" command-string dup 0<> if
        adapter-id slot!
        true adapter-has-id !
    else
        2drop
    then
    root command-root !
    ['] dispatch-command catch to code
    code 0<> if
        code cvx-adopt-fault
        emit-error
    then ;

\ ---------------------------------------------------------------------------
\ Relaying Live deliveries
\ ---------------------------------------------------------------------------

: adapter-relay ( -- )
    0 0 0 0 { live sub slot kind }
    adapter-client @ client-live to live
    live 0= if exit then
    begin
        live live-take-any to kind to sub
        kind live-none <>
    while
        sub registry-slot-for-sub to slot
        slot 0< if
            \ The subscription was removed after this value was queued, so the
            \ value is discarded rather than relayed under a stale identifier.
            live live-release-taken
        else
            kind live-value = if
                registry-ids slot cells + @ buf-span
                live live-taken-value
                live live-taken-logs dup 0= if 2drop s" []" then
                emit-subscription-value
            else
                cvx-error-reset
                live live-taken-name cvx-error-name!
                live live-taken-message cvx-error-message!
                live live-taken-data dup 0<> if
                    cvx-error-data!
                else
                    2drop
                then
                registry-ids slot cells + @ buf-span emit-subscription-error
            then
            live live-release-taken
        then
    repeat ;

\ ---------------------------------------------------------------------------
\ Input
\ ---------------------------------------------------------------------------

: adapter-take-line ( -- flag )
    0 0 { in index }
    adapter-in @ stream-in to in
    in buf-span 10 str-index to index
    index 0< if
        in buf-len cvx-max-json-bytes u> if
            s" adapter command line exceeds the client byte limit"
            cvx-raise-protocol
        then
        false exit
    then
    adapter-line buf-reset
    in buf-data index adapter-line buf-append
    index 1+ in buf-consume
    adapter-line buf-len 0> if
        adapter-line buf-data adapter-line buf-len 1- + c@ 13 = if
            adapter-line buf-len 1- adapter-line buf>len + !
        then
    then
    true ;

: adapter-read-input ( absolute -- )
    0 { absolute got }
    adapter-in @ io-want-read absolute stream-wait 0= if exit then
    adapter-in @ absolute stream-read-once to got
    got 0= if
        \ The controller closed its side. Shut down cleanly rather than
        \ spinning on an end-of-stream socket.
        adapter-client @ convex-close
        false adapter-running !
    then ;

\ ---------------------------------------------------------------------------
\ Main loop
\ ---------------------------------------------------------------------------

\ Short slices so neither the controller stream nor the Convex socket waits
\ long behind the other. One worker still owns both.
50 constant adapter-slice-ms

: adapter-slice ( -- )
    0 { absolute }
    now adapter-slice-ms + to absolute
    outbox-flush
    begin adapter-take-line while
        adapter-line buf-span adapter-consume-line
        adapter-running @ 0= if exit then
    repeat
    adapter-relay
    outbox-flush
    adapter-client @ client-live 0<> if
        adapter-client @ client-live absolute live-pump
        adapter-relay
        outbox-flush
    then
    adapter-running @ if absolute adapter-read-input then ;

: adapter-drain ( -- )
    0 { absolute }
    cvx-close-deadline deadline+ to absolute
    begin
        outbox-flush
        outbox-count @ 0>
        absolute deadline-expired? 0= and
    while
    repeat ;

: adapter-serve ( -- )
    true adapter-running !
    begin adapter-running @ while
        adapter-slice
    repeat
    \ Give the final event a bounded chance to reach the controller.
    ['] adapter-drain catch drop ;

: adapter-open-streams ( -- )
    0 0 0 { listen-addr listen-count colon }
    s" ADAPTER_LISTEN" getenv to listen-count to listen-addr
    listen-count 0= if
        0 stream-adopt adapter-in !
        1 stream-adopt adapter-out !
        exit
    then
    listen-addr listen-count [char] : str-last-index to colon
    colon 0< if
        s" ADAPTER_LISTEN must be host:port" cvx-raise-protocol
    then
    listen-addr colon
    listen-addr colon 1+ +  listen-count colon 1+ -
    listener-open adapter-listener !
    adapter-listener @  60000 deadline+  listener-accept
    dup adapter-in ! adapter-out ! ;

: adapter-main ( -- )
    outbox-init
    registry-init
    adapter-open-streams
    s" CONVEX_URL" getenv dup 0= if
        2drop s" CONVEX_URL is required" cvx-raise-transport
    then
    convex-open adapter-client !
    adapter-serve ;

\ IF and THEN are compile-only: standard Forth throws "Interpreting a
\ compile-only word" if they run outside a colon definition, which is
\ exactly the state the [IF] guard below interprets in. So the catch/if/then
\ dispatch is compiled into a word here and merely executed below, instead of
\ appearing directly inside the [IF] block. Inside that colon definition,
\ tick (') is also wrong: compiled into a word body it parses its argument
\ from the input stream at run time, and by then nothing follows on the
\ source line, which throws "zero-length string as a name." The
\ compile-time bracket-tick ([']) below resolves the execution token once,
\ during compilation, and compiles it in as a literal, which is what a word
\ body needs.
: adapter-run ( -- )
    ['] adapter-main catch ?dup if
        cvx-adopt-fault
        s" the Forth adapter failed" note-line
        report-error
        1 convex-exit
    then
    0 convex-exit ;

\ Loading this file with ADAPTER_LIBRARY_ONLY set defines the adapter without
\ starting it, so the language-local tests can drive its event composition and
\ its outbox directly. The shipped entrypoint never sets it.
s" ADAPTER_LIBRARY_ONLY" getenv nip 0= [if]
    adapter-run
[then]
