! Conformance adapter tests.
!
! Event serialization is asserted byte-for-byte, because the shared
! controller validates every emitted line against the adapter schema and an
! absent field serialized as null is a shape mismatch it will reject.
!
! The stopped-reader case is a real socket whose peer never reads. That is
! the only way to observe the writer's absolute deadline and to prove the
! admission budget holds while output cannot drain.

USING: accessors arrays byte-arrays calendar continuations
destructors io io.encodings.binary io.encodings.utf8 io.sockets
kernel locals make math math.parser namespaces sequences strings
system threads convex convex.adapter convex.json convex.live
convex.transport convex.tests.support ;
IN: convex.tests.adapter

! --- event shapes ----------------------------------------------------------

! A discarding outbox lets a test read the exact bytes an event would put on
! the wire without needing a peer at all.
:: <test-adapter> ( -- adapter )
    "http://127.0.0.1:1" <convex-client> f <adapter> ;

:: emitted-line ( adapter -- line )
    adapter outbox>> outbox-take [
        "no event was admitted" assertion-failed
    ] unless* line>> ;

! Expected lines are assembled from short pieces so the checked-in source
! stays inside the repository's presentation width. The assertion is still on
! the exact byte sequence the adapter would put on the wire.
: expected ( pieces -- line )
    concat "\n" append ;

:: test-ready-event ( -- )
    <test-adapter> :> adapter
    adapter "h1" emit-ready
    adapter emitted-line {
        "{\"protocolVersion\":1,\"id\":\"h1\",\"type\":\"ready\","
        "\"language\":\"factor\","
        "\"implementation\":\"native-factor-http-and-pinned-sync-0.1.0\","
        "\"runtime\":\"factor-0.101\"}"
    } expected "ready event" check-equal ;

:: test-result-event ( -- )
    <test-adapter> :> adapter
    adapter "q1" "{\"count\":1}" "[\"log\"]" emit-result
    adapter emitted-line {
        "{\"id\":\"q1\",\"type\":\"result\","
        "\"value\":{\"count\":1},\"logs\":[\"log\"]}"
    } expected "result event keeps the value byte-exact" check-equal ;

! A structured function failure keeps its data. Nothing optional is spelled
! as null, and the transport case omits data entirely.
:: test-error-events ( -- )
    <test-adapter> :> adapter
    adapter "q2"
    [ "boom" "{\"code\":\"E\"}" "[]" function-error ] caught emit-error
    adapter emitted-line {
        "{\"id\":\"q2\",\"type\":\"error\",\"error\":{"
        "\"name\":\"FunctionError\",\"message\":\"boom\","
        "\"data\":{\"code\":\"E\"}}}"
    } expected "function error event" check-equal
    adapter "q3" [ "gone" transport-error ] caught emit-error
    adapter emitted-line {
        "{\"id\":\"q3\",\"type\":\"error\",\"error\":{"
        "\"name\":\"TransportError\",\"message\":\"gone\"}}"
    } expected "transport error event omits data" check-equal
    adapter "q4" [ "drift" protocol-error ] caught emit-error
    adapter emitted-line {
        "{\"id\":\"q4\",\"type\":\"error\",\"error\":{"
        "\"name\":\"ProtocolError\",\"message\":\"drift\"}}"
    } expected "protocol error event" check-equal ;

:: test-ack-and-closed-events ( -- )
    <test-adapter> :> adapter
    adapter "a1" emit-ack
    adapter emitted-line "{\"id\":\"a1\",\"type\":\"ack\"}\n" "ack event"
    check-equal
    adapter "c1" emit-closed
    adapter emitted-line "{\"id\":\"c1\",\"type\":\"closed\"}\n"
    "closed event" check-equal ;

! A subscription event carries either a value or an error, never both and
! never an id.
:: test-subscription-events ( -- )
    <test-adapter> :> adapter
    adapter "s1" "{\"count\":0}" "[]" emit-subscription-value
    adapter emitted-line {
        "{\"type\":\"subscription\",\"subscriptionId\":\"s1\","
        "\"value\":{\"count\":0},\"logs\":[]}"
    } expected "subscription value event" check-equal
    adapter "s1" "{\"name\":\"FunctionError\",\"message\":\"x\"}"
    emit-subscription-error
    adapter emitted-line {
        "{\"type\":\"subscription\",\"subscriptionId\":\"s1\","
        "\"error\":{\"name\":\"FunctionError\",\"message\":\"x\"}}"
    } expected "subscription error event" check-equal ;

! --- command validation ----------------------------------------------------

:: check-rejected ( line message -- )
    [ line line command-op check-command ] message check-raises ;

:: test-command-validation ( -- )
    "{\"protocolVersion\":1,\"id\":\"h\",\"op\":\"hello\"}" :> hello
    hello hello command-op check-command
    "{\"protocolVersion\":2,\"id\":\"h\",\"op\":\"hello\"}"
    "wrong protocol version" check-rejected
    "{\"protocolVersion\":1,\"id\":\"h\",\"op\":\"hello\",\"extra\":1}"
    "unexpected field" check-rejected
    "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}" :> q
    q q command-op check-command
    "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:state\"}"
    "missing args" check-rejected
    "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":[]}"
    "array args" check-rejected
    "{\"id\":\"q\",\"op\":\"query\",\"path\":\"ab\",\"args\":{}}"
    "short path" check-rejected
    "{\"id\":\"s\",\"op\":\"subscribe\",\"subscriptionId\":\"a\"}"
    "subscribe without a path" check-rejected
    "{\"id\":\"u\",\"op\":\"unsubscribe\",\"subscriptionId\":\"a\"}" :> u
    u u command-op check-command
    "{\"id\":\"x\",\"op\":\"teleport\"}" "unknown operation" check-rejected
    "{\"id\":\"a\",\"op\":\"setAuth\",\"token\":7}"
    "non-string token" check-rejected
    "[1,2]" "non-object command" check-rejected ;

! --- output admission ------------------------------------------------------

:: droppable-payload ( n -- line )
    n CHAR: a <string> ;

! The count bound applies to droppable events, and control events keep their
! reserved slots even under a flood of subscription output.
:: test-count-admission ( -- )
    f <outbox> :> box
    40 <iota> [| i | box i number>string f outbox-offer ] each
    box queue>> length max-outbox-events <= t "outbox count bound"
    check-equal
    box outbox-droppable-count
    max-outbox-events reserved-control-events - <= t
    "droppable events leave room for control events" check-equal
    box dropped>> 0 > t "outbox dropped older events" check-equal ;

:: test-control-events-are-kept ( -- )
    f <outbox> :> box
    40 <iota> [| i | box i number>string f outbox-offer ] each
    8 <iota> [| i | box "control" i number>string append t outbox-offer ]
    each
    box queue>> [ control?>> ] count 8 "every control event survived"
    check-equal ;

! An event count alone is not a memory bound. Near-maximum values must be
! bounded by the byte budget well before the count limit is reached.
:: test-byte-admission ( -- )
    f <outbox> :> box
    8 <iota> [| i | box 2000000 droppable-payload f outbox-offer ] each
    box bytes>> max-outbox-bytes <= t "outbox byte bound" check-equal
    box queue>> length max-outbox-events < t
    "byte budget bounds before the count does" check-equal
    box dropped>> 0 > t "byte budget dropped events" check-equal ;

! --- stopped reader --------------------------------------------------------

! A real peer accepts the connection and then never reads. The socket buffer
! fills, the writer's absolute deadline expires, and the admission budget has
! to hold the process steady while output cannot drain.
:: test-stopped-reader ( -- )
    [| stream | 30 seconds sleep stream dispose ] start-fixture :> port
    ! The outbox writes NDJSON text, so the socket carries a UTF-8 encoder
    ! exactly as the real adapter's stdout and TCP streams do.
    "127.0.0.1" port <inet4> utf8 <client> drop :> out
    out <outbox> :> box
    box start-outbox
    12 <iota> [| i | box 2000000 droppable-payload f outbox-offer ] each
    nano-count :> started
    12000000000 deadline-from-now :> deadline
    [ box stalls>> 0 = nano-count deadline < and ]
    [ 20 milliseconds sleep ] while
    box stalls>> 0 > t "the writer hit its absolute deadline" check-equal
    box last-wait>> outbox-write-nanos 2 * < t
    "the stalled write respected its deadline" check-equal
    box queue>> length max-outbox-events <= t
    "queue stays bounded while stalled" check-equal
    box bytes>> max-outbox-bytes <= t
    "retained bytes stay bounded while stalled" check-equal
    box bytes>> 8388608 < t
    "retained bytes stay well under the shared 128 MiB limit" check-equal
    t box closed?<<
    [ out dispose ] [ drop ] recover ;

: run-adapter-tests ( -- )
    "adapter/ready-event" [ test-ready-event ] run-test
    "adapter/result-event" [ test-result-event ] run-test
    "adapter/error-events" [ test-error-events ] run-test
    "adapter/ack-and-closed-events" [ test-ack-and-closed-events ] run-test
    "adapter/subscription-events" [ test-subscription-events ] run-test
    "adapter/command-validation" [ test-command-validation ] run-test
    "adapter/count-admission" [ test-count-admission ] run-test
    "adapter/control-events-are-kept" [ test-control-events-are-kept ]
    run-test
    "adapter/byte-admission" [ test-byte-admission ] run-test
    "adapter/stopped-reader" [ test-stopped-reader ] run-test
    finish-tests ;

MAIN: run-adapter-tests
