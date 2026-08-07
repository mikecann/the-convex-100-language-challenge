! Native transport for the educational Convex client.
!
! Factor supplies ordinary TCP, TLS, and byte-stream primitives. Everything
! Convex-specific -- the JSON HTTP envelope, the RFC 6455 framing the sync
! profile rides on, and the deadlines that keep a stalled peer from holding a
! connection forever -- is implemented here in Factor rather than delegated to
! another Convex client, a shell command, or a second language runtime.
!
! Two deadline kinds appear throughout. A stream timeout bounds one blocking
! read. An absolute deadline is fixed once, before the first byte of a record
! is consumed, so a peer that dribbles one byte at a time can never extend it.
! Both are needed: the stream timeout stops an idle peer from blocking, and
! the absolute deadline stops a slow one from stalling forever.

USING: accessors arrays assocs base64 byte-arrays calendar checksums
checksums.sha combinators continuations destructors environment
io io.encodings.binary io.encodings.string io.encodings.utf8
io.sockets io.sockets.secure io.timeouts kernel locals make math
math.bitwise math.order math.parser namespaces random sequences
splitting strings system convex.json ;
IN: convex.transport

ERROR: transport-error message ;
ERROR: protocol-error message ;

! Convex's HTTP envelope reports a failed function with a structured payload
! rather than a transport failure. DATA and LOGS stay as raw JSON text so the
! conformance adapter can forward them without a lossy decode.
ERROR: function-error message data logs ;

! Failures are reported through the client's own error classes rather than
! through a debugger-dependent printer, so the deployed image needs no
! reflection machinery to explain what went wrong.
: error-message ( error -- string )
    {
        { [ dup transport-error? ] [ message>> ] }
        { [ dup protocol-error? ] [ message>> ] }
        { [ dup function-error? ] [ message>> ] }
        { [ dup json-error? ] [ message>> ] }
        { [ dup string? ] [ ] }
        [ drop "unexpected transport failure" ]
    } cond ;

! Maps a raised condition onto the adapter protocol's error name, keeping a
! function failure, a protocol violation, and a transport fault distinct
! instead of flattening them into one shape.
: error-name ( error -- string )
    {
        { [ dup function-error? ] [ drop "FunctionError" ] }
        { [ dup protocol-error? ] [ drop "ProtocolError" ] }
        { [ dup json-error? ] [ drop "ProtocolError" ] }
        [ drop "TransportError" ]
    } cond ;

CONSTANT: max-response-bytes 2097152
CONSTANT: max-header-bytes 32768
CONSTANT: max-frame-bytes 2097152

CONSTANT: websocket-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

! A single blocking read waits this long before the connection is abandoned.
SYMBOL: read-timeout-seconds
read-timeout-seconds [ 15 ] initialize

! Once any byte of a record has been consumed the parser is committed. This is
! the absolute budget for finishing that record. Tests shorten it explicitly,
! so the deadline itself is asserted rather than a cooperative fixture peer.
SYMBOL: partial-record-nanos
partial-record-nanos [ 5000000000 ] initialize

: deadline-from-now ( nanos -- deadline )
    nano-count + ;

:: check-deadline ( deadline what -- )
    nano-count deadline > [
        what " did not complete before its deadline" append transport-error
    ] when ;

! Header field names are compared case-insensitively. Doing the fold here in
! ASCII keeps the client free of a Unicode case-table dependency it does not
! otherwise need.
: ascii-lower ( string -- string' )
    [ dup CHAR: A CHAR: Z between? [ 32 + ] when ] map ;

! --- endpoints -------------------------------------------------------------

TUPLE: endpoint secure? host port path ;

:: parse-endpoint ( url -- endpoint )
    url "://" split1 :> ( scheme rest )
    rest [ "Convex URL must be absolute" transport-error ] unless
    scheme {
        { "http" [ f 80 ] }
        { "https" [ t 443 ] }
        { "ws" [ f 80 ] }
        { "wss" [ t 443 ] }
        [ drop "unsupported URL scheme" transport-error ]
    } case :> ( secure? default-port )
    rest "/" split1 :> ( authority path )
    authority ":" split1 :> ( host port-text )
    host empty? [ "Convex URL has no host" transport-error ] when
    port-text [
        port-text string>number :> parsed
        parsed [ parsed 1 65535 between? ] [ f ] if [
            "Convex URL has an invalid port" transport-error
        ] unless
        parsed
    ] [ default-port ] if :> port
    endpoint new
        secure? >>secure?
        host >>host
        port >>port
        path [ "/" prepend ] [ "/" ] if* >>path ;

: ca-bundle-path ( -- path )
    "SSL_CERT_FILE" os-env [ "/etc/ssl/certs/ca-certificates.crt" ] unless* ;

! TLS verification stays on and is pinned to a real CA bundle. Without a
! bundle OpenSSL would happily complete an unverified handshake.
: <convex-secure-config> ( -- config )
    <secure-config>
        ca-bundle-path >>ca-file
        t >>verify ;

:: connect-stream ( endpoint -- stream )
    endpoint host>> endpoint port>> <inet>
    endpoint secure?>> [ endpoint host>> <secure> ] when
    binary <client> drop :> stream
    read-timeout-seconds get seconds stream set-timeout
    stream ;

! The TLS context is a disposable OpenSSL object. A caller that holds a socket
! across many operations runs its whole loop inside this word, so the context
! outlives every read and write on that connection.
: with-convex-tls ( endpoint quot -- )
    swap secure?>> [
        <convex-secure-config> swap with-secure-context
    ] [ call ] if ; inline

! --- bounded byte reading --------------------------------------------------

:: read-exactly ( stream deadline count what -- bytes )
    V{ } clone :> parts
    0 :> got!
    [ got count < ] [
        deadline what check-deadline
        count got - stream stream-read-partial :> chunk
        chunk [ what " ended early" append transport-error ] unless
        chunk length 0 = [ what " stalled" append transport-error ] when
        chunk parts push
        got chunk length + got!
    ] while
    parts concat >byte-array ;

! A header block is read one byte at a time so a partial terminator can never
! be mistaken for a boundary. The limit stops an endless header stream.
:: read-header-text ( stream deadline -- text )
    V{ } clone :> bytes
    f :> done!
    [ done not ] [
        deadline "HTTP header block" check-deadline
        stream stream-read1 :> b
        b [ "connection closed inside HTTP headers" transport-error ] unless
        b bytes push
        bytes length max-header-bytes > [
            "HTTP headers exceed the size limit" transport-error
        ] when
        bytes length 4 >= [
            bytes bytes length 4 - tail-slice >array { 13 10 13 10 } = done!
        ] when
    ] while
    bytes >byte-array >string ;

! --- HTTP ------------------------------------------------------------------

TUPLE: http-response code headers body ;

:: parse-header-text ( text -- code headers )
    text "\r\n" split harvest :> lines
    lines empty? [ "empty HTTP response" transport-error ] when
    lines first " " split1 nip :> after-version
    after-version [ "malformed HTTP status line" transport-error ] unless
    after-version " " split1 drop string>number :> code
    code [ "malformed HTTP status code" transport-error ] unless
    H{ } clone :> headers
    lines rest [
        ":" split1 :> ( name value )
        value [
            value [ " \t" member? ] trim
            name ascii-lower headers set-at
        ] when
    ] each
    code headers ;

! A chunked message ends with an optional trailer followed by a blank line.
:: read-chunk-trailer ( stream deadline -- )
    V{ } clone :> bytes
    f :> done!
    [ done not ] [
        deadline "chunked trailer" check-deadline
        stream stream-read1 :> b
        b [
            b bytes push
            bytes length max-header-bytes > [
                "chunked trailer exceeds the size limit" transport-error
            ] when
            bytes length 2 >= [
                bytes bytes length 2 - tail-slice >array { 13 10 } = done!
            ] when
        ] [ t done! ] if
    ] while ;

:: read-chunk-size ( stream deadline -- size )
    V{ } clone :> line
    f :> done!
    [ done not ] [
        stream stream-read1 :> b
        b [ "connection closed inside a chunk header" transport-error ] unless
        b 10 = [ t done! ] [ b line push ] if
        line length 64 > [ "chunk header is too long" transport-error ] when
    ] while
    line >byte-array >string [ " \r\t" member? ] trim
    ";" split1 drop hex> :> size
    size [ "malformed chunk size" transport-error ] unless
    size ;

:: read-chunked-body ( stream deadline -- bytes )
    V{ } clone :> parts
    0 :> total!
    f :> done!
    [ done not ] [
        deadline "chunked HTTP body" check-deadline
        stream deadline read-chunk-size :> size
        size 0 = [
            t done!
        ] [
            total size + total!
            total max-response-bytes > [
                "HTTP response exceeds the byte limit" transport-error
            ] when
            stream deadline size "chunk body" read-exactly parts push
            stream deadline 2 "chunk terminator" read-exactly
            >array { 13 10 } = [
                "malformed chunk terminator" transport-error
            ] unless
        ] if
    ] while
    stream deadline read-chunk-trailer
    parts concat >byte-array ;

:: read-until-close ( stream deadline -- bytes )
    V{ } clone :> parts
    0 :> total!
    f :> done!
    [ done not ] [
        deadline "HTTP response body" check-deadline
        65536 stream stream-read-partial :> chunk
        chunk [
            chunk parts push
            total chunk length + total!
            total max-response-bytes > [
                "HTTP response exceeds the byte limit" transport-error
            ] when
        ] [ t done! ] if
    ] while
    parts concat >byte-array ;

:: read-http-response ( stream deadline -- response )
    stream deadline read-header-text parse-header-text :> ( code headers )
    "content-length" headers at :> length-text
    "transfer-encoding" headers at :> encoding
    {
        { [ encoding "chunked" = ] [ stream deadline read-chunked-body ] }
        { [ length-text ] [
            length-text [ " \t" member? ] trim string>number :> size
            size [ "malformed Content-Length" transport-error ] unless
            size max-response-bytes > [
                "HTTP response exceeds the byte limit" transport-error
            ] when
            stream deadline size "HTTP response body" read-exactly
        ] }
        [ stream deadline read-until-close ]
    } cond :> body
    http-response new
        code >>code
        headers >>headers
        body utf8 decode >>body ;

:: build-http-request ( endpoint method headers body -- text )
    endpoint secure?>> 443 80 ? :> default-port
    [
        method % " " % endpoint path>> % " HTTP/1.1\r\n" %
        "Host: " % endpoint host>> %
        endpoint port>> default-port = [
            ":" % endpoint port>> number>string %
        ] unless
        "\r\n" %
        headers [
            first2 :> ( name value )
            name % ": " % value % "\r\n" %
        ] each
        "Content-Length: " % body length number>string % "\r\n" %
        "Connection: close\r\n\r\n" %
    ] "" make ;

! One request, one connection. Convex's JSON HTTP endpoints are short calls,
! and a fresh connection keeps response framing unambiguous.
:: http-post ( url headers body-text seconds -- response )
    url parse-endpoint :> endpoint
    seconds 1000000000 * deadline-from-now :> deadline
    endpoint [
        endpoint connect-stream [| stream |
            body-text utf8 encode :> body
            endpoint "POST" headers body build-http-request
            utf8 encode stream stream-write
            body stream stream-write
            stream stream-flush
            stream deadline read-http-response
        ] with-disposal
    ] with-convex-tls ;

! --- RFC 6455 --------------------------------------------------------------

TUPLE: websocket stream endpoint fragment-opcode fragment-parts
    fragment-bytes closed? ;

: <websocket> ( stream endpoint -- websocket )
    websocket new
        swap >>endpoint
        swap >>stream
        -1 >>fragment-opcode
        V{ } clone >>fragment-parts
        0 >>fragment-bytes
        f >>closed? ;

:: header-pairs ( lines -- pairs )
    lines [ ":" split1 2array ] map ;

:: websocket-handshake ( stream endpoint client-version -- )
    16 random-bytes >base64 >string :> key
    [
        "GET " % endpoint path>> % " HTTP/1.1\r\n" %
        "Host: " % endpoint host>> % "\r\n" %
        "Upgrade: websocket\r\n" %
        "Connection: Upgrade\r\n" %
        "Sec-WebSocket-Key: " % key % "\r\n" %
        "Sec-WebSocket-Version: 13\r\n" %
        "Convex-Client: " % client-version % "\r\n\r\n" %
    ] "" make utf8 encode stream stream-write
    stream stream-flush
    partial-record-nanos get deadline-from-now :> deadline
    stream deadline read-header-text "\r\n" split harvest :> lines
    lines empty? [ "empty WebSocket upgrade response" protocol-error ] when
    lines first " " split1 nip :> after-version
    after-version [ "malformed WebSocket upgrade status" protocol-error ]
    unless
    after-version " " split1 drop "101" = [
        "WebSocket upgrade was not 101" protocol-error
    ] unless
    lines rest header-pairs
    [ first ascii-lower "sec-websocket-accept" = ] find nip :> pair
    pair [ pair second ] [ f ] if [
        "WebSocket upgrade omitted the accept header" protocol-error
    ] unless
    pair second [ " \t" member? ] trim :> accept
    key websocket-guid append utf8 encode sha1 checksum-bytes
    >base64 >string :> expected
    accept expected = [
        "WebSocket upgrade acceptance failed" protocol-error
    ] unless ;

:: websocket-connect ( url client-version -- websocket )
    url parse-endpoint :> endpoint
    endpoint connect-stream :> stream
    [
        stream endpoint client-version websocket-handshake
        stream endpoint <websocket>
    ] [ stream dispose rethrow ] recover ;

:: mask-payload ( payload key -- masked )
    payload length <byte-array> :> out
    payload length <iota> [| i |
        i payload nth i 4 mod key nth bitxor i out set-nth
    ] each
    out ;

! Every client-to-server frame is masked, as RFC 6455 requires.
:: websocket-frame ( opcode payload -- bytes )
    payload length :> size
    size max-frame-bytes > [
        "outbound WebSocket frame exceeds the frame limit" protocol-error
    ] when
    4 random-bytes :> key
    [
        0x80 opcode bitor ,
        {
            { [ size 126 < ] [ 0x80 size bitor , ] }
            { [ size 65535 <= ] [
                254 ,
                size -8 shift 0xff bitand ,
                size 0xff bitand ,
            ] }
            [
                255 ,
                8 <iota> [| i | size 7 i - 8 * neg shift 0xff bitand , ] each
            ]
        } cond
        key %
        payload key mask-payload %
    ] B{ } make ;

:: websocket-write-frame ( websocket opcode payload -- )
    websocket stream>> :> stream
    opcode payload websocket-frame stream stream-write
    stream stream-flush ;

: websocket-send-text ( websocket text -- )
    utf8 encode [ 1 ] dip websocket-write-frame ;

! Status 1000, "normal closure", in the two-byte close payload.
: websocket-send-close ( websocket -- )
    8 B{ 3 232 } websocket-write-frame ;

TUPLE: websocket-record fin? opcode payload ;

! The frame length either fits in the 7-bit short form, or is spelled out as
! an explicit 16-bit or 64-bit extension immediately after it (RFC 6455
! section 5.2). Factored out to its own word, taking its inputs as ordinary
! parameters rather than closing over `read-websocket-frame`'s locals: inlined
! as a `cond` capturing those outer locals, this compiled to a stack-effect
! mismatch under this Factor build's inference (`if`/`cond` branches must
! statically agree on stack height, and evidently a locals-capturing `cond`
! nested this deep in a `::` word does not, even though every branch pushes
! exactly one value) -- a Factor toolchain limitation, not a Convex protocol
! concern, that a plain top-level word sidesteps entirely.
:: websocket-frame-length ( stream deadline short-length -- size )
    {
        { [ short-length 126 = ] [
            stream deadline 2 "WebSocket length" read-exactly :> b
            b first 8 shift b second bitor
        ] }
        { [ short-length 127 = ] [
            stream deadline 8 "WebSocket length" read-exactly :> b
            0 :> total!
            b [ total 8 shift swap bitor total! ] each
            total
        ] }
        [ short-length ]
    } cond ;

! Reads one complete frame. The absolute deadline is fixed before the second
! header byte is consumed, so a dribbling peer cannot extend it, and a
! deadline failure abandons the connection instead of resuming at a boundary
! the parser never actually reached.
:: read-websocket-frame ( websocket -- record )
    websocket stream>> :> stream
    stream stream-read1 :> first-byte
    first-byte [ "WebSocket peer closed the connection" transport-error ]
    unless
    partial-record-nanos get deadline-from-now :> deadline
    stream deadline 1 "WebSocket frame header" read-exactly first :> second
    first-byte 0x80 bitand 0 > :> fin?
    first-byte 0x0f bitand :> opcode
    first-byte 0x70 bitand 0 > second 0x80 bitand 0 > or [
        "invalid WebSocket frame flags" protocol-error
    ] when
    second 0x7f bitand :> short-length
    stream deadline short-length websocket-frame-length :> size
    size max-frame-bytes > [
        "WebSocket frame exceeds the frame limit" protocol-error
    ] when
    opcode 8 >= fin? not size 125 > or and [
        "invalid WebSocket control frame" protocol-error
    ] when
    size 0 = [ B{ } ] [
        stream deadline size "WebSocket payload" read-exactly
    ] if :> payload
    websocket-record new fin? >>fin? opcode >>opcode payload >>payload ;

! Returns the next complete text message, or f when the peer closed cleanly.
! Control frames are answered here so the caller only ever sees application
! data, and a fragmented UTF-8 message is decoded only once it is complete.
:: websocket-next-message ( websocket -- text/f )
    f :> result!
    f :> done!
    [ done not ] [
        websocket read-websocket-frame :> record
        record opcode>> :> opcode
        record payload>> :> payload
        {
            { [ opcode 8 = ] [ t websocket closed?<< t done! ] }
            { [ opcode 9 = ] [ websocket 10 payload websocket-write-frame ] }
            { [ opcode 10 = ] [ ] }
            { [ opcode 0 = ] [
                websocket fragment-opcode>> 0 < [
                    "unexpected WebSocket continuation" protocol-error
                ] when
                websocket fragment-bytes>> payload length + :> total
                total max-frame-bytes > [
                    "fragmented WebSocket message exceeds the frame limit"
                    protocol-error
                ] when
                total websocket fragment-bytes<<
                payload websocket fragment-parts>> push
                record fin?>> [
                    websocket fragment-opcode>> 1 = [
                        "binary WebSocket data is unsupported" protocol-error
                    ] unless
                    websocket fragment-parts>> concat >byte-array
                    utf8 decode result!
                    -1 websocket fragment-opcode<<
                    V{ } clone websocket fragment-parts<<
                    0 websocket fragment-bytes<<
                    t done!
                ] when
            ] }
            { [ opcode 1 = opcode 2 = or ] [
                websocket fragment-opcode>> 0 >= [
                    "new WebSocket data frame during a fragment" protocol-error
                ] when
                record fin?>> [
                    opcode 1 = [
                        "binary WebSocket data is unsupported" protocol-error
                    ] unless
                    payload utf8 decode result!
                    t done!
                ] [
                    opcode websocket fragment-opcode<<
                    payload websocket fragment-parts>> push
                    payload length websocket fragment-bytes<<
                ] if
            ] }
            [ "unsupported WebSocket opcode" protocol-error ]
        } cond
    ] while
    result ;

: websocket-dispose ( websocket -- )
    stream>> [ dispose ] [ 2drop ] recover ;
