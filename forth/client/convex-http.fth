\ convex-http.fth - Convex's documented JSON HTTP functions, spoken by Forth.
\
\ The request side is small: one POST to /api/query, /api/mutation or
\ /api/action carrying { path, args, format }. The interesting work is on the
\ response side, because Convex reports a failing function with an ordinary
\ JSON envelope rather than with the HTTP status alone. A 560 carrying
\ {"status":"error", ...} is a FunctionError with a message the caller can act
\ on; a 500 carrying an HTML error page is a TransportError; a 400 carrying a
\ Convex envelope is still a Convex answer. Collapsing all three into "the
\ request failed" would lose exactly the distinction the conformance harness
\ checks, so the status code is recorded and the body is always parsed.
\
\ Response framing is bounded at every step: the status line and each header
\ line are length limited, the header block is line limited, a chunked body is
\ bounded per chunk and in total, and a body without a declared length is read
\ to end of stream under the same absolute deadline as the rest of the call.

require convex-config.fth
require convex-error.fth
require convex-buffer.fth
require convex-json.fth
require convex-io.fth

\ ---------------------------------------------------------------------------
\ The client record
\
\ Live state hangs off the same record so the example and the conformance
\ adapter cannot accidentally exercise two different implementations.
\ ---------------------------------------------------------------------------

0 cells constant cl>dep
1 cells constant cl>auth        \ empty when the client is unauthenticated
2 cells constant cl>doc         \ parsed response, reused between calls
3 cells constant cl>body        \ outgoing request body
4 cells constant cl>args        \ argument object under construction
5 cells constant cl>resp        \ response body bytes
6 cells constant cl>line        \ one header line
7 cells constant cl>req         \ the full request, headers and body
8 cells constant cl>status      \ HTTP status of the last call
9 cells constant cl>live        \ Live manager, 0 until the first subscribe
10 cells constant cl-size

: client-dep ( client -- dep )  cl>dep + @ ;
: client-auth ( client -- addr u )  cl>auth + @ buf-span ;
: client-doc ( client -- doc )  cl>doc + @ ;
: client-body ( client -- buf )  cl>body + @ ;
: client-args-buf ( client -- buf )  cl>args + @ ;
: client-resp ( client -- buf )  cl>resp + @ ;
: client-line ( client -- buf )  cl>line + @ ;
: client-req ( client -- buf )  cl>req + @ ;
: client-status ( client -- code )  cl>status + @ ;
: client-live ( client -- live )  cl>live + @ ;

: convex-open ( url-addr url-u -- client )
    cl-size allocate throw { url-addr url-count client }
    url-addr url-count deployment-parse client cl>dep + !
    256 buf-new client cl>auth + !
    json-new client cl>doc + !
    1024 buf-new client cl>body + !
    1024 buf-new client cl>args + !
    4096 buf-new client cl>resp + !
    1024 buf-new client cl>line + !
    2048 buf-new client cl>req + !
    0 client cl>status + !
    0 client cl>live + !
    client ;

: convex-set-auth ( addr u client -- )
    { addr count client }
    client cl>auth + @ buf-reset
    addr count client cl>auth + @ buf-append ;

: convex-clear-auth ( client -- )  cl>auth + @ buf-reset ;

\ ---------------------------------------------------------------------------
\ Building arguments
\
\ Convex takes named arguments, so an example reads best when it names them at
\ the call site. These wrap the JSON writer so the example never has to hand
\ assemble JSON text.
\ ---------------------------------------------------------------------------

: convex-args ( client -- )
    client-args-buf dup buf-reset jw-start jw{ ;

: convex-arg-string ( key-addr key-u value-addr value-u -- )  jw-pair-string ;
: convex-arg-uint ( key-addr key-u value -- )  jw-pair-uint ;
: convex-arg-bool ( key-addr key-u flag -- )  jw-pair-bool ;

: convex-args-done ( client -- addr u )  jw} client-args-buf buf-span ;

: convex-no-args ( client -- addr u )
    dup client-args-buf dup buf-reset jw-start jw{ jw} client-args-buf buf-span ;

\ ---------------------------------------------------------------------------
\ Request
\ ---------------------------------------------------------------------------

\ A Convex function reference is module:function. Rejecting anything else here
\ turns a typo into a clear client error instead of a puzzling 404.
: convex-valid-path? ( addr u -- flag )
    0 { addr count colon }
    count 3 u< if false exit then
    addr count [char] : str-index to colon
    colon 0< if false exit then
    colon 1 < if false exit then
    colon count 1- < 0= if false exit then
    addr colon 1+ + count colon - 1- [char] : str-index 0< ;

: http-build-body ( client path-addr path-u args-addr args-u -- )
    { client path-addr path-count args-addr args-count }
    client client-body dup buf-reset jw-start
    jw{
        s" path" path-addr path-count jw-pair-string
        s" args" args-addr args-count jw-pair-raw
        s" format" s" json" jw-pair-string
    jw} ;

: http-build-request ( client operation-addr operation-u buf -- )
    { client operation-addr operation-count buf }
    buf buf-reset
    s" POST /api/" buf buf-append
    operation-addr operation-count buf buf-append
    s\"  HTTP/1.1\r\nHost: " buf buf-append
    client client-dep deployment-host buf buf-append
    client client-dep deployment-tls? if s" 443" else s" 80" then
    client client-dep deployment-port str= 0= if
        [char] : buf buf-char
        client client-dep deployment-port buf buf-append
    then
    s\" \r\nContent-Type: application/json" buf buf-append
    s\" \r\nAccept: application/json" buf buf-append
    s\" \r\nConnection: close" buf buf-append
    s\" \r\nConvex-Client: " buf buf-append
    cvx-client-version buf buf-append
    client client-auth nip 0<> if
        s\" \r\nAuthorization: Bearer " buf buf-append
        client client-auth buf buf-append
    then
    s\" \r\nContent-Length: " buf buf-append
    client client-body buf-len buf u>buf
    s\" \r\n\r\n" buf buf-append
    client client-body buf-span buf buf-append ;

\ ---------------------------------------------------------------------------
\ Response framing
\ ---------------------------------------------------------------------------

: str>hex ( addr u -- value flag )
    0 0 { addr count value ch }
    count 0= if 0 false exit then
    count 16 u> if 0 false exit then
    0 to value
    true
    count 0 ?do
        addr i + c@ to ch
        value 16 * to value
        ch [char] 0 [char] 9 1+ within if
            value ch [char] 0 - + to value
        else
            ch lower [char] a [char] f 1+ within if
                value ch lower [char] a - 10 + + to value
            else
                drop false leave
            then
        then
    loop
    value swap ;

: http-status ( line-addr line-u -- code )
    0 0 { addr count value ok }
    count 12 u< if
        s" HTTP status line is too short" cvx-raise-protocol
    then
    addr count s" HTTP/1." str-prefix? 0= if
        s" HTTP response is not HTTP/1.x" cvx-raise-protocol
    then
    addr 9 + 3 str>u to ok to value
    ok 0= if s" HTTP status code is not numeric" cvx-raise-protocol then
    value ;

\ Read the header block, returning the declared body length (-1 when absent)
\ and whether the body is chunked.
: http-read-headers ( client stream absolute -- length chunked )
    0 0 0 0 0 0 0 0 0 0 { client stream absolute
       line length chunked lines colon name-addr name-count value-addr value-count ok }
    client client-line to line
    -1 to length  false to chunked  0 to lines
    begin
        stream absolute line stream-line
        line buf-len 0>
    while
        lines 1+ to lines
        lines cvx-max-header-lines u> if
            s" too many HTTP response headers" cvx-raise-protocol
        then
        line buf-span [char] : str-index to colon
        colon 0< 0= if
            line buf-data to name-addr
            colon to name-count
            line buf-data colon + 1+  line buf-len colon - 1-
            str-trim to value-count to value-addr
            name-addr name-count s" Content-Length" istr= if
                value-addr value-count str>u to ok to length
                ok 0= if
                    s" HTTP Content-Length is not numeric" cvx-raise-protocol
                then
                length cvx-max-json-bytes u> if
                    s" HTTP response body exceeds the client byte limit"
                    cvx-raise-protocol
                then
            then
            name-addr name-count s" Transfer-Encoding" istr= if
                value-addr value-count s" chunked" istr= if
                    true to chunked
                else
                    s" unsupported HTTP transfer encoding" cvx-raise-protocol
                then
            then
        then
    repeat
    length chunked ;

: http-read-chunked ( client stream absolute -- )
    0 0 0 0 { client stream absolute line body size ok }
    client client-line to line
    client client-resp to body
    begin
        stream absolute line stream-line
        \ A chunk extension after ";" is legal and ignored by this client.
        line buf-span [char] ; str-index dup 0< if drop line buf-len then
        line buf-data swap str-trim str>hex to ok to size
        ok 0= if s" HTTP chunk size is not hexadecimal" cvx-raise-protocol then
        body buf-len size + cvx-max-json-bytes u> if
            s" HTTP response body exceeds the client byte limit"
            cvx-raise-protocol
        then
        size 0>
    while
        size stream absolute stream-need
        stream stream-in buf-data size body buf-append
        size stream stream-in buf-consume
        stream absolute line stream-line       \ the CRLF after each chunk
        line buf-len 0<> if
            s" HTTP chunk was not terminated correctly" cvx-raise-protocol
        then
    repeat
    \ Trailers, then the terminating blank line.
    begin
        stream absolute line stream-line
        line buf-len 0>
    while
    repeat ;

: http-read-body ( client stream absolute length chunked -- )
    0 0 { client stream absolute length chunked body got }
    client client-resp to body
    body buf-reset
    chunked if
        client stream absolute http-read-chunked
        exit
    then
    length 0< 0= if
        length stream absolute stream-need
        stream stream-in buf-data length body buf-append
        length stream stream-in buf-consume
        exit
    then
    \ No declared length: the request asked for Connection: close, so read to
    \ end of stream under the same absolute deadline.
    begin
        stream absolute stream-read-once to got
        got 0>
    while
        stream stream-in buf-span body buf-append
        stream stream-in buf-reset
        body buf-len cvx-max-json-bytes u> if
            s" HTTP response body exceeds the client byte limit"
            cvx-raise-protocol
        then
    repeat
    stream stream-in buf-span body buf-append
    stream stream-in buf-reset ;

\ ---------------------------------------------------------------------------
\ One Convex call
\ ---------------------------------------------------------------------------

variable http-pending-client
variable http-pending-stream
variable http-pending-deadline

: http-exchange ( -- )
    0 0 0 0 0 { client stream absolute length chunked }
    http-pending-client @ to client
    http-pending-stream @ to stream
    http-pending-deadline @ to absolute
    client client-req buf-span stream absolute stream-write
    stream absolute client client-line stream-line
    client client-line buf-span http-status client cl>status + !
    client stream absolute http-read-headers to chunked to length
    client stream absolute length chunked http-read-body ;

\ Parse the envelope. Convex reports a failing function inside a successful
\ looking body, so the status field decides the outcome and the HTTP code only
\ colours the message.
: http-decode-envelope ( client operation-addr operation-u -- )
    0 0 0 0 0 0 0 0 { client operation-addr operation-count
       doc root status-node status-addr status-count logs value code }
    client client-status to code
    client client-doc to doc
    client client-resp buf-span doc ['] json-parse catch if
        msg-start s" HTTP " msg+ code msg+u
        s"  returned non-Convex JSON" msg+
        s" TransportError" cvx-raise-msg
    then
    doc doc-root to root
    doc root json-object? 0= if
        msg-start s" HTTP " msg+ code msg+u
        s"  response was not a Convex envelope" msg+
        s" ProtocolError" cvx-raise-msg
    then
    doc root s" logLines" json-get to logs
    doc logs json-log-lines? 0= if
        s" Convex logLines must be an array of strings" cvx-raise-protocol
    then
    doc root s" status" json-get to status-node
    doc status-node json-string? 0= if
        msg-start s" HTTP " msg+ code msg+u
        s"  response has no Convex status" msg+
        s" ProtocolError" cvx-raise-msg
    then
    doc status-node json-string@ to status-count to status-addr
    status-addr status-count s" success" str= if
        doc root s" value" json-has? 0= if
            s" Convex success envelope has no value" cvx-raise-protocol
        then
        exit
    then
    status-addr status-count s" error" str= if
        cvx-error-reset
        s" FunctionError" cvx-error-name!
        doc root s" errorMessage" json-get to value
        doc value json-string? if
            doc value json-string@ cvx-error-message!
        else
            s" Convex function failed" cvx-error-message!
        then
        doc root s" errorData" json-get to value
        value 0< 0= if doc value json-raw cvx-error-data! then
        logs 0< 0= if doc logs json-raw cvx-error-logs! then
        operation-addr operation-count cvx-error-op!
        cvx-error-code throw
    then
    msg-start s" HTTP " msg+ code msg+u
    s"  response has an unknown Convex status" msg+
    s" ProtocolError" cvx-raise-msg ;

: convex-call ( client operation-addr operation-u path-addr path-u args-addr args-u -- )
    0 0 0 { client operation-addr operation-count path-addr path-count args-addr args-count
       absolute stream code }
    operation-addr operation-count cvx-operation!
    path-addr path-count convex-valid-path? 0= if
        s" function path must be module:function" cvx-raise-protocol
    then
    cvx-http-deadline deadline+ to absolute
    client path-addr path-count args-addr args-count http-build-body
    client operation-addr operation-count client client-req http-build-request
    client client-dep  cvx-connect-deadline deadline+  absolute min
    deployment-connect to stream
    client http-pending-client !
    stream http-pending-stream !
    absolute http-pending-deadline !
    ['] http-exchange catch to code
    stream stream-close
    0 http-pending-stream !
    code 0<> if
        code cvx-adopt-fault
        cvx-error-code throw
    then
    client operation-addr operation-count http-decode-envelope ;

: convex-query ( client path-addr path-u args-addr args-u -- )
    { client path-addr path-count args-addr args-count }
    client s" query" path-addr path-count args-addr args-count convex-call ;

: convex-mutation ( client path-addr path-u args-addr args-u -- )
    { client path-addr path-count args-addr args-count }
    client s" mutation" path-addr path-count args-addr args-count convex-call ;

: convex-action ( client path-addr path-u args-addr args-u -- )
    { client path-addr path-count args-addr args-count }
    client s" action" path-addr path-count args-addr args-count convex-call ;

\ ---------------------------------------------------------------------------
\ Reading the result
\ ---------------------------------------------------------------------------

: convex-value ( client -- doc node )
    { client }
    client client-doc dup dup doc-root s" value" json-get ;

: convex-logs ( client -- doc node )
    { client }
    client client-doc dup dup doc-root s" logLines" json-get ;

\ Convex may encode an integral number in decimal form, so this accepts 0 and
\ 0.0 alike while rejecting fractional, quoted, non-finite and overflowing
\ values.
: convex-integer ( doc node -- value )
    0 0 { doc node value ok }
    doc node json-integer to ok to value
    ok 0= if
        s" Convex value is not an integral number in range" cvx-raise-protocol
    then
    value ;
