! Raw RFC 6455 tests against real loopback fixtures.
!
! Framing, control frames, fragmentation, and the absolute dribble deadline
! are all proved against a real socket peer. A cooperative fixture that
! simply closes cannot demonstrate a deadline, so the stalling cases below
! keep the peer alive and assert that the client gives up on its own.

USING: accessors arrays byte-arrays calendar continuations
io.encodings.string io.encodings.utf8 kernel locals make math
math.bitwise math.parser namespaces sequences strings system
threads convex.transport convex.tests.support ;
IN: convex.tests.websocket

SYMBOL: observed-frames

: reset-observations ( -- )
    V{ } clone observed-frames set-global ;

:: fixture-url ( port -- url )
    "ws://127.0.0.1:" port number>string append "/api/sync" append ;

: connect-fixture ( port -- websocket )
    fixture-url "factor-test" websocket-connect ;

! --- handshake -------------------------------------------------------------

:: test-handshake-and-text ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream "{\"type\":\"Ping\"}" send-server-text
    ] start-fixture connect-fixture :> ws
    ws websocket-next-message "{\"type\":\"Ping\"}"
    "text message round trip" check-equal
    ws websocket-dispose ;

! A server that answers 101 with the wrong accept hash is not speaking
! RFC 6455, so the client must refuse the connection rather than proceed.
:: test-bad-accept ( -- )
    [| stream |
        stream read-request-head drop
        stream [
            "HTTP/1.1 101 Switching Protocols\r\n" %
            "Upgrade: websocket\r\n" %
            "Connection: Upgrade\r\n" %
            "Sec-WebSocket-Accept: wrong\r\n\r\n" %
        ] "" make write-text
    ] start-fixture :> port
    [ port connect-fixture drop ] "bad accept hash" check-raises ;

:: test-non-101 ( -- )
    [| stream |
        stream read-request-head drop
        stream "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" write-text
    ] start-fixture :> port
    [ port connect-fixture drop ] "upgrade that is not 101" check-raises ;

! --- fragmentation ---------------------------------------------------------

! The sample splits a three-byte character across a frame boundary, so a
! client that decoded each frame separately would corrupt it.
:: test-fragmented-utf8 ( -- )
    { 104 233 108 108 111 32 19990 30028 } >string :> sample
    sample utf8 encode :> bytes
    bytes 0 4 rot subseq :> piece1
    bytes 4 9 rot subseq :> piece2
    bytes 9 bytes length rot subseq :> piece3
    [| stream |
        stream websocket-fixture-handshake
        stream piece1 piece2 piece3 3array send-server-fragments
    ] start-fixture connect-fixture :> ws
    ws websocket-next-message sample "fragmented UTF-8 message" check-equal
    ws websocket-dispose ;

:: test-unexpected-continuation ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream B{ 0x80 1 65 } write-bytes
    ] start-fixture connect-fixture :> ws
    [ ws websocket-next-message drop ]
    "continuation without a fragment" check-raises
    ws websocket-dispose ;

! --- control frames --------------------------------------------------------

! A ping must be answered with a pong that echoes its payload, and the data
! message that follows must still be delivered.
:: test-ping-pong ( -- )
    reset-observations
    [| stream |
        stream websocket-fixture-handshake
        stream 9 B{ 1 2 3 } server-frame write-bytes
        stream read-client-frame 2array observed-frames get-global push
        stream "{\"type\":\"Ping\"}" send-server-text
    ] start-fixture connect-fixture :> ws
    ws websocket-next-message "{\"type\":\"Ping\"}"
    "message after a ping" check-equal
    observed-frames get-global first :> pong
    pong first 10 "pong opcode" check-equal
    pong second B{ 1 2 3 } "pong echoes the ping payload" check-equal
    ws websocket-dispose ;

:: test-close-frame ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream 8 B{ 3 232 } server-frame write-bytes
    ] start-fixture connect-fixture :> ws
    ws websocket-next-message f "close frame ends the message stream"
    check-equal
    ws closed?>> t "close frame is recorded" check-equal
    ws websocket-dispose ;

! A control frame may not be fragmented and may not exceed 125 bytes.
:: test-fragmented-control ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream B{ 9 0 } write-bytes
    ] start-fixture connect-fixture :> ws
    [ ws websocket-next-message drop ] "fragmented control frame"
    check-raises
    ws websocket-dispose ;

:: test-reserved-bits ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream B{ 0xc1 1 65 } write-bytes
    ] start-fixture connect-fixture :> ws
    [ ws websocket-next-message drop ] "reserved frame bits" check-raises
    ws websocket-dispose ;

! --- bounds and deadlines --------------------------------------------------

! An oversized declared length is refused before any payload byte is read.
:: test-oversized-frame ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream [
            0x81 , 127 ,
            8 <iota> [| i | 4194304 7 i - 8 * neg shift 0xff bitand , ] each
        ] B{ } make write-bytes
    ] start-fixture connect-fixture :> ws
    [ ws websocket-next-message drop ] "oversized frame length" check-raises
    ws websocket-dispose ;

! The peer stays alive and keeps dribbling, so only an absolute deadline can
! end this read. A per-read timeout would be reset by every byte.
:: test-dribble-deadline ( -- )
    partial-record-nanos get-global :> saved
    300000000 partial-record-nanos set-global
    [
        [| stream |
            stream websocket-fixture-handshake
            stream B{ 0x81 100 } write-bytes
            100 <iota> [
                drop
                stream B{ 65 } write-bytes
                60 milliseconds sleep
            ] each
        ] start-fixture connect-fixture :> ws
        nano-count :> started
        [ ws websocket-next-message drop ] "dribbled frame deadline"
        check-raises
        nano-count started - :> elapsed
        elapsed 2000000000 < t "deadline was absolute, not per-read"
        check-equal
        ws websocket-dispose
    ] [ saved partial-record-nanos set-global rethrow ] recover
    saved partial-record-nanos set-global ;

! Sending a frame larger than the client's own limit is refused locally, so a
! caller can never put an unbounded payload on the wire.
:: test-outbound-limit ( -- )
    [| stream |
        stream websocket-fixture-handshake
        stream read-client-frame 2drop
    ] start-fixture connect-fixture :> ws
    [ ws 3000000 65 <string> websocket-send-text ]
    "oversized outbound frame" check-raises
    ws websocket-dispose ;

: run-websocket-tests ( -- )
    "websocket/handshake-and-text" [ test-handshake-and-text ] run-test
    "websocket/bad-accept" [ test-bad-accept ] run-test
    "websocket/non-101" [ test-non-101 ] run-test
    "websocket/fragmented-utf8" [ test-fragmented-utf8 ] run-test
    "websocket/unexpected-continuation" [ test-unexpected-continuation ]
    run-test
    "websocket/ping-pong" [ test-ping-pong ] run-test
    "websocket/close-frame" [ test-close-frame ] run-test
    "websocket/fragmented-control" [ test-fragmented-control ] run-test
    "websocket/reserved-bits" [ test-reserved-bits ] run-test
    "websocket/oversized-frame" [ test-oversized-frame ] run-test
    "websocket/dribble-deadline" [ test-dribble-deadline ] run-test
    "websocket/outbound-limit" [ test-outbound-limit ] run-test
    finish-tests ;

MAIN: run-websocket-tests
