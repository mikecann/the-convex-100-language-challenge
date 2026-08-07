! Shared support for the language-local Factor tests.
!
! The fixtures below are real loopback servers, not mocks. A test that wants
! to prove a deadline, a framing rule, or a reconnect starts an actual socket
! peer and drives the real client against it, because a cooperative stub
! cannot demonstrate any of those properties.

USING: accessors arrays base64 byte-arrays checksums
checksums.sha combinators continuations destructors io
io.encodings.binary io.encodings.string io.encodings.utf8
io.sockets kernel locals make math math.bitwise math.parser
namespaces sequences splitting strings system threads
convex.transport ;
IN: convex.tests.support

ERROR: assertion-failed message ;

SYMBOL: failure-count
failure-count [ 0 ] initialize

: describe ( obj -- string )
    {
        { [ dup string? ] [ ] }
        { [ dup number? ] [ number>string ] }
        { [ dup not ] [ drop "f" ] }
        [ drop "<value>" ]
    } cond ;

: check ( ? message -- )
    swap [ drop ] [ assertion-failed ] if ;

:: check-equal ( actual expected message -- )
    actual expected = [
        message ": expected " append expected describe append
        " but got " append actual describe append assertion-failed
    ] unless ;

:: check-raises ( quot message -- )
    f :> raised!
    [ quot call( -- ) ] [ drop t raised! ] recover
    raised [ message ": expected a failure" append assertion-failed ] unless ;

! Returns the condition a quotation raised. Building an error object this
! way keeps the tests using the same constructors the client uses instead of
! reaching around them.
:: caught ( quot -- error )
    f :> raised!
    [ quot call( -- ) ] [ raised! ] recover
    raised [ "expected a failure" assertion-failed ] unless
    raised ;

: problem-message ( error -- string )
    dup assertion-failed? [ message>> ] [ error-message ] if ;

:: record-failure ( name message -- )
    failure-count get-global 1 + failure-count set-global
    "FAIL " name append ": " append message append print ;

:: run-test ( name quot -- )
    [ quot call( -- ) "PASS " name append print ]
    [ name swap problem-message record-failure ] recover ;

: finish-tests ( -- )
    ! exit terminates the process immediately; without a flush first, any
    ! buffered PASS/FAIL lines are silently lost whenever stdout is a pipe
    ! rather than a line-buffered terminal, as it is under `docker build`.
    flush
    failure-count get-global 0 = [ 0 ] [ 1 ] if exit ;

! --- loopback fixtures -----------------------------------------------------

! Starts a server on an ephemeral loopback port and hands the first accepted
! connection to HANDLER in its own thread. Returns the bound port so the test
! can build a URL for the real client.
:: start-fixture ( handler -- port )
    "127.0.0.1" 0 <inet4> binary <server> :> server
    server addr>> port>> :> port
    [
        [ server accept drop handler call( stream -- ) ] [ drop ] recover
        [ server dispose ] [ drop ] recover
    ] "convex-fixture" spawn drop
    port ;

! Accepts repeatedly, which is what a reconnect test needs: the same fixture
! must serve five successive connections.
:: start-repeating-fixture ( handler -- port )
    "127.0.0.1" 0 <inet4> binary <server> :> server
    server addr>> port>> :> port
    [
        [
            [
                server accept drop :> stream
                [ stream handler call( stream -- ) ] [ drop ] recover
                t
            ] loop
        ] [ drop ] recover
    ] "convex-repeating-fixture" spawn drop
    port ;

: write-bytes ( stream bytes -- )
    over stream-write stream-flush ;

: write-text ( stream text -- )
    utf8 encode write-bytes ;

! --- fixture-side HTTP -----------------------------------------------------

:: read-request-head ( stream -- text )
    30000000000 deadline-from-now :> deadline
    stream deadline read-header-text ;

:: request-header ( head name -- value/f )
    head "\r\n" split rest [ ":" split1 2array ] map
    [ first ascii-lower name ascii-lower = ] find nip :> pair
    pair [ pair second [ " \t" member? ] trim ] [ f ] if ;

! Reads a complete fixture-side request so a test can assert the method, the
! path, the headers, and the exact JSON envelope the client actually sent.
:: read-request ( stream -- head body )
    stream read-request-head :> head
    head "content-length" request-header :> length-text
    length-text [
        30000000000 deadline-from-now :> deadline
        stream deadline length-text string>number "fixture body"
        read-exactly utf8 decode
    ] [ "" ] if :> body
    head body ;

:: http-fixture-response ( code content-type body -- text )
    [
        "HTTP/1.1 " % code number>string % " FIXTURE\r\n" %
        "Content-Type: " % content-type % "\r\n" %
        "Content-Length: " % body utf8 encode length number>string % "\r\n" %
        "Connection: close\r\n\r\n" %
        body %
    ] "" make ;

! The sync profile spells a timestamp as eight little-endian bytes in
! base64, so a fixture has to encode one the same way the server does.
:: timestamp-base64 ( n -- text )
    8 <iota> [| i | n 8 i * neg shift 0xff bitand ] map >byte-array
    >base64 >string ;

! --- fixture-side RFC 6455 -------------------------------------------------

:: websocket-accept-key ( request -- key )
    request "\r\n" split [ ":" split1 2array ] map
    [ first ascii-lower "sec-websocket-key" = ] find nip :> pair
    pair [ "fixture saw no Sec-WebSocket-Key" assertion-failed ] unless
    pair second [ " \t" member? ] trim ;

:: websocket-fixture-handshake ( stream -- )
    stream read-request-head :> request
    request websocket-accept-key websocket-guid append utf8 encode
    sha1 checksum-bytes >base64 >string :> accept
    stream [
        "HTTP/1.1 101 Switching Protocols\r\n" %
        "Upgrade: websocket\r\n" %
        "Connection: Upgrade\r\n" %
        "Sec-WebSocket-Accept: " % accept % "\r\n\r\n" %
    ] "" make write-text ;

! A server frame is never masked, so the fixture writes the header directly.
:: server-frame ( opcode payload -- bytes )
    payload length :> size
    [
        0x80 opcode bitor ,
        {
            { [ size 126 < ] [ size , ] }
            { [ size 65535 <= ] [
                126 , size -8 shift 0xff bitand , size 0xff bitand ,
            ] }
            [
                127 ,
                8 <iota> [| i | size 7 i - 8 * neg shift 0xff bitand , ] each
            ]
        } cond
        payload %
    ] B{ } make ;

: send-server-text ( stream text -- )
    utf8 encode [ 1 ] dip server-frame write-bytes ;

! Sends one logical text message in several frames, so a multi-byte character
! can straddle a frame boundary. Every piece stays under 126 bytes, which
! keeps the fixture's own header encoding trivial.
:: send-server-fragments ( stream pieces -- )
    pieces length :> count
    pieces [| piece index |
        piece length 126 < [
            "fixture fragment is too large" assertion-failed
        ] unless
        index 0 = [ 1 ] [ 0 ] if :> opcode
        index count 1 - = [ 0x80 ] [ 0 ] if opcode bitor :> first-byte
        stream [
            first-byte ,
            piece length ,
            piece %
        ] B{ } make write-bytes
    ] each-index ;

! Reads one masked client frame and returns its opcode and unmasked payload.
:: read-client-frame ( stream -- opcode payload )
    30000000000 deadline-from-now :> deadline
    stream deadline 2 "fixture frame header" read-exactly :> header
    header first 0x0f bitand :> opcode
    header second 0x7f bitand :> short-length
    header second 0x80 bitand 0 = [
        "fixture received an unmasked client frame" assertion-failed
    ] when
    {
        { [ short-length 126 = ] [
            stream deadline 2 "fixture length" read-exactly :> b
            b first 8 shift b second bitor
        ] }
        { [ short-length 127 = ] [
            stream deadline 8 "fixture length" read-exactly :> b
            0 :> total!
            b [ total 8 shift swap bitor total! ] each
            total
        ] }
        [ short-length ]
    } cond :> size
    stream deadline 4 "fixture mask" read-exactly :> key
    size 0 = [ B{ } ] [
        stream deadline size "fixture payload" read-exactly
    ] if :> masked
    opcode masked key mask-payload ;

: read-client-text ( stream -- text )
    read-client-frame swap drop utf8 decode ;
