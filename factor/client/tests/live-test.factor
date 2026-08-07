! Live acceptance tests.
!
! A real loopback peer speaks the pinned sync profile, so reconnects,
! rehydration, and reactive failure recovery are demonstrated end to end
! rather than asserted about a stub. The relay and version tests drive the
! owner's own primitives directly, which is the only way to observe an
! invalidated generation or a byte-driven drop deterministically.

USING: accessors arrays assocs calendar concurrency.mailboxes
continuations kernel locals make math math.bitwise math.parser
namespaces sequences sorting strings system threads convex
convex.json convex.live convex.transport convex.tests.support ;
IN: convex.tests.live

SYMBOL: connect-log
SYMBOL: add-log
SYMBOL: remove-log
SYMBOL: live-streams

! What the fixture has last told this client its state version is. A
! ModifyQuerySet does not advance it; only a Transition does, which is
! exactly the rule the client's start-version check enforces.
SYMBOL: remote-query-set
SYMBOL: remote-timestamp
SYMBOL: pending-query-set
SYMBOL: timestamp-counter

: reset-connection-state ( -- )
    0 remote-query-set set-global
    initial-timestamp remote-timestamp set-global
    0 pending-query-set set-global
    1 timestamp-counter set-global ;

: reset-fixture-state ( -- )
    V{ } clone connect-log set-global
    V{ } clone add-log set-global
    V{ } clone remove-log set-global
    V{ } clone live-streams set-global
    reset-connection-state ;

: next-server-timestamp ( -- text )
    timestamp-counter get-global 1 + dup timestamp-counter set-global
    timestamp-base64 ;

:: version-json ( query-set timestamp -- json )
    [
        "querySet" query-set number>string 2array ,
        "identity" "0" 2array ,
        "ts" timestamp json-escape-string 2array ,
    ] { } make json-object ;

! Builds a Transition that advances from the version the fixture last
! published to the query set the client most recently requested, so the
! client's start-version check is exercised rather than bypassed.
:: transition ( modifications -- json )
    remote-query-set get-global :> old-set
    remote-timestamp get-global :> old-timestamp
    pending-query-set get-global :> new-set
    next-server-timestamp :> new-timestamp
    new-set remote-query-set set-global
    new-timestamp remote-timestamp set-global
    [
        "type" "\"Transition\"" 2array ,
        "startVersion" old-set old-timestamp version-json 2array ,
        "endVersion" new-set new-timestamp version-json 2array ,
        "modifications" modifications json-array 2array ,
    ] { } make json-object ;

:: query-updated ( query-id value -- json )
    [
        "type" "\"QueryUpdated\"" 2array ,
        "queryId" query-id number>string 2array ,
        "value" value 2array ,
        "logLines" "[]" 2array ,
    ] { } make json-object ;

:: query-failed ( query-id code -- json )
    [
        "type" "\"QueryFailed\"" 2array ,
        "queryId" query-id number>string 2array ,
        "errorMessage" "\"reactive failure\"" 2array ,
        "errorData" [
            "code" code json-escape-string 2array ,
        ] { } make json-object 2array ,
        "logLines" "[]" 2array ,
    ] { } make json-object ;

: count-value ( n -- json )
    [ "count" swap number>string 2array , ] { } make json-object ;

! --- fixture ---------------------------------------------------------------

! Records every Add and Remove the client sends, so a reconnect test can
! prove that each new connection resent the active query set.
:: record-modify ( text -- )
    text "modifications" json-field json-elements [| mod |
        mod "type" json-field json-string-value :> kind
        mod "queryId" json-field "fixture queryId" json-uint32 :> query-id
        kind "Add" = [
            query-id mod "udfPath" json-field json-string-value 2array
            add-log get-global push
        ] [
            kind "Remove" = [ query-id remove-log get-global push ] when
        ] if
    ] each ;

! One connection of the pinned profile: Connect, then a query-set change,
! then whatever the test pushes through the recorded stream.
:: sync-connection ( stream -- )
    stream websocket-fixture-handshake
    stream read-client-text :> connect
    connect connect-log get-global push
    reset-connection-state
    stream live-streams get-global push
    [
        stream read-client-text :> text
        text "type" json-field json-string-value "ModifyQuerySet" = [
            text record-modify
            text "newVersion" json-field "fixture newVersion" json-uint32
            pending-query-set set-global
        ] when
        t
    ] loop ;

: start-sync-fixture ( -- port )
    [ sync-connection ] start-repeating-fixture ;

:: current-stream ( -- stream )
    5000000000 deadline-from-now :> deadline
    f :> found!
    [ found not ] [
        live-streams get-global empty? [
            deadline "fixture connection" check-deadline
            5 milliseconds sleep
        ] [ live-streams get-global last found! ] if
    ] while
    found ;

! Waits until the fixture has seen COUNT Add operations, which is how a
! reconnect test knows the resent query set arrived before pushing a value.
:: wait-for-adds ( count -- )
    5000000000 deadline-from-now :> deadline
    [ add-log get-global length count < ] [
        deadline "resent Add operations" check-deadline
        5 milliseconds sleep
    ] while ;

:: push-transition ( modifications -- )
    current-stream modifications transition send-server-text ;

:: live-client-for ( port -- client )
    "http://127.0.0.1:" port number>string append <convex-client> ;

! --- end-to-end scenarios --------------------------------------------------

:: test-initial-and-external-update ( -- )
    reset-fixture-state
    start-sync-fixture live-client-for :> client
    client "demo:state" "{\"room\":\"r\"}" client-subscribe :> sub
    1 wait-for-adds
    add-log get-global first second "demo:state" "Add carries the path"
    check-equal
    0 count-value 0 swap query-updated 1array push-transition
    sub 5 subscription-next :> initial
    initial update-value "{\"count\":0}" "initial Live value" check-equal
    0 count-value 1 swap query-updated 1array push-transition
    sub 5 subscription-next f "unchanged value is suppressed" check-equal
    1 count-value 0 swap query-updated 1array push-transition
    sub 5 subscription-next :> updated
    updated update-value "{\"count\":1}" "external Live update" check-equal
    client 5 client-close ;

! QueryFailed must reach the subscriber as a structured error without
! stranding the subscription, and a later valid value must still arrive.
:: test-query-error-recovery ( -- )
    reset-fixture-state
    start-sync-fixture live-client-for :> client
    client "demo:requiresNonzero" "{\"room\":\"r\"}" client-subscribe :> sub
    1 wait-for-adds
    0 "ROOM_EMPTY" query-failed 1array push-transition
    sub 5 subscription-next :> failed
    failed update-error "data" json-field "code" json-field
    json-string-value "ROOM_EMPTY" "QueryFailed carries structured data"
    check-equal
    failed update-error "name" json-field "\"FunctionError\""
    "QueryFailed is a function error" check-equal
    1 count-value 0 swap query-updated 1array push-transition
    sub 5 subscription-next :> repaired
    repaired update-value "{\"count\":1}" "recovery after QueryFailed"
    check-equal
    client 5 client-close ;

! Five genuine reconnect and hydration cycles. Each cycle proves the old
! connection was retired before the acknowledgement, that the new connection
! resent the active Add, that an unchanged rehydration is suppressed, and
! that the changed value still arrives.
:: test-five-reconnects ( -- )
    reset-fixture-state
    start-sync-fixture live-client-for :> client
    client "demo:state" "{\"room\":\"r\"}" client-subscribe :> sub
    1 wait-for-adds
    0 count-value 0 swap query-updated 1array push-transition
    sub 5 subscription-next update-value "{\"count\":0}"
    "cycle 0 initial value" check-equal
    client live>> :> live
    5 <iota> [| cycle |
        <mailbox> :> reply
        live "disconnect" reply 2array post-command
        reply 5 "debugDisconnect" await-reply t
        "disconnect acknowledged" check-equal
        live websocket>> f "old connection retired before the ack"
        check-equal
        live last-close-reason>> "DebugDisconnect"
        "close reason recorded" check-equal
        cycle 2 + wait-for-adds
        ! The rehydration repeats the value the subscriber already has, so a
        ! correct client publishes nothing for it. That value is 0 before the
        ! first cycle and `cycle` at the start of every cycle after, since
        ! each cycle advances it to `cycle + 1` below.
        cycle count-value 0 swap query-updated 1array push-transition
        sub 1 subscription-next f "rehydration is suppressed" check-equal
        cycle 1 + count-value 0 swap query-updated 1array push-transition
        sub 10 subscription-next update-value
        cycle 1 + count-value "value after reconnect" check-equal
    ] each
    live connection-count>> 5 >= t "connection count advanced" check-equal
    live handshakes>> 6 >= t "six real handshakes" check-equal
    live reconnect-delay>> base-reconnect-nanos
    "backoff reset after a healthy handshake" check-equal
    client 5 client-close ;

! Unsubscribe must invalidate the relay before its acknowledgement, and the
! Remove must reach the server.
:: test-unsubscribe ( -- )
    reset-fixture-state
    start-sync-fixture live-client-for :> client
    client "demo:state" "{\"room\":\"r\"}" client-subscribe :> sub
    1 wait-for-adds
    0 count-value 0 swap query-updated 1array push-transition
    sub 5 subscription-next drop
    client sub 5 client-unsubscribe
    sub relay>> queue>> length 0 "relay drained by unsubscribe" check-equal
    5000000000 deadline-from-now :> deadline
    [ remove-log get-global empty? ] [
        deadline "Remove operation" check-deadline
        5 milliseconds sleep
    ] while
    remove-log get-global first 0 "Remove carries the query id" check-equal
    client 5 client-close ;

! Close must finish inside its own deadline even though the fixture peer
! stays connected and never cooperates with the shutdown.
:: test-bounded-close ( -- )
    reset-fixture-state
    start-sync-fixture live-client-for :> client
    client "demo:state" "{\"room\":\"r\"}" client-subscribe drop
    1 wait-for-adds
    nano-count :> started
    client 5 client-close
    nano-count started - 5000000000 < t "close respected its deadline"
    check-equal ;

! --- owner primitives ------------------------------------------------------

! A relay event that was queued for a retired generation must not be
! publishable, which is what stops a stale event from crossing an
! acknowledgement.
:: test-stale-relay-rejected ( -- )
    <relay> :> r
    r generation>> :> old
    r old "{\"count\":0}" "[]" <live-value-update> relay-publish t
    "fresh generation publishes" check-equal
    r relay-invalidate
    r old "{\"count\":1}" "[]" <live-value-update> relay-publish f
    "stale generation is rejected" check-equal
    r queue>> length 0 "invalidated relay is empty" check-equal ;

! An event count alone is not a memory bound, so the relay is charged bytes
! as well and drops the oldest event when either budget is exceeded.
:: test-relay-count-bound ( -- )
    <relay> :> r
    40 <iota> [| i |
        r r generation>> i number>string "[]" <live-value-update>
        relay-publish drop
    ] each
    r queue>> length max-relay-events <= t "relay count bound" check-equal
    r dropped>> 0 > t "relay dropped older events" check-equal
    r queue>> last value>> "39" "relay keeps the newest value" check-equal ;

:: test-relay-byte-bound ( -- )
    <relay> :> r
    2000000 CHAR: a <string> :> big
    8 <iota> [| i |
        r r generation>> big "[]" <live-value-update> relay-publish drop
    ] each
    r bytes>> max-relay-bytes <= t "relay byte bound" check-equal
    r queue>> length max-relay-events < t
    "byte budget bounds before the count does" check-equal ;

:: test-relay-take-accounting ( -- )
    <relay> :> r
    r r generation>> "{\"count\":7}" "[]" <live-value-update>
    relay-publish drop
    r relay-take update-value "{\"count\":7}" "relay-take returns the event"
    check-equal
    r bytes>> 0 "relay byte charge is released" check-equal
    r relay-take f "empty relay returns f" check-equal ;

! Timestamps are eight little-endian bytes, so ordering must come from the
! decoded integer rather than the base64 text.
:: test-timestamp-ordering ( -- )
    1 timestamp-base64 timestamp-key 1 "timestamp one" check-equal
    258 timestamp-base64 timestamp-key 258 "timestamp two bytes" check-equal
    [ "AAAA" timestamp-key drop ] "short timestamp is refused" check-raises ;

:: test-strict-counters ( -- )
    [ "\"3\"" "queryId" json-uint32 drop ] "quoted queryId" check-raises
    [ "-1" "queryId" json-uint32 drop ] "negative queryId" check-raises
    "{\"querySet\":1,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}"
    normalize-state-version
    "{\"querySet\":1,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}"
    "state version canonicalizes" check-equal
    [
        "{\"querySet\":\"1\",\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}"
        normalize-state-version drop
    ] "quoted querySet is refused" check-raises ;

:: test-sync-url ( -- )
    "https://x.convex.cloud" sync-url "wss://x.convex.cloud/api/sync"
    "https becomes wss" check-equal
    "http://backend:3210/" sync-url "ws://backend:3210/api/sync"
    "http becomes ws" check-equal ;

: run-live-tests ( -- )
    "live/initial-and-external-update" [ test-initial-and-external-update ]
    run-test
    "live/query-error-recovery" [ test-query-error-recovery ] run-test
    "live/five-reconnects" [ test-five-reconnects ] run-test
    "live/unsubscribe" [ test-unsubscribe ] run-test
    "live/bounded-close" [ test-bounded-close ] run-test
    "live/stale-relay-rejected" [ test-stale-relay-rejected ] run-test
    "live/relay-count-bound" [ test-relay-count-bound ] run-test
    "live/relay-byte-bound" [ test-relay-byte-bound ] run-test
    "live/relay-take-accounting" [ test-relay-take-accounting ] run-test
    "live/timestamp-ordering" [ test-timestamp-ordering ] run-test
    "live/strict-counters" [ test-strict-counters ] run-test
    "live/sync-url" [ test-sync-url ] run-test
    finish-tests ;

MAIN: run-live-tests
