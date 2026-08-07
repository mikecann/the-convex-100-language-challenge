\ http-test.fth - HTTP response framing and the Convex envelope.
\
\ The envelope cases are the point of this suite. Convex reports a failing
\ function inside an ordinary JSON body, so the HTTP status alone cannot decide
\ the outcome: a 560 carrying a Convex envelope is a FunctionError with a
\ usable message, a 400 carrying one is still a Convex answer, and a 500
\ carrying an error page is a TransportError. Each is driven from raw bytes so
\ the test proves the real framing code, not a mocked decoder.

require test-support.fth

s" http://127.0.0.1:1" convex-open constant test-client
1024 buf-new constant scratch

variable probe-stream
variable probe-length
variable probe-chunked

: probe-status ( -- )
    probe@ http-status drop ;

: status-raises ( addr u name-addr name-u -- )
    2>r >probe ['] probe-status 2r> raises ;

: test-status-line ( -- )
    s" HTTP/1.1 200 OK" http-status 200 s" ordinary success status" same-n
    s" HTTP/1.1 560 Convex Error" http-status 560
    s" Convex function-error status" same-n
    s" HTTP/1.0 400 Bad Request" http-status 400 s" HTTP/1.0 status" same-n
    s" HTTP/2 200 OK" s" a non HTTP/1.x response is rejected" status-raises
    s" HTTP/1.1 2xx OK" s" a non-numeric status is rejected" status-raises
    s" HTTP/1.1" s" a truncated status line is rejected" status-raises ;

\ ---------------------------------------------------------------------------
\ Header and body framing over memory streams
\ ---------------------------------------------------------------------------

: probe-headers ( -- )
    test-client probe-stream @ 60000 deadline+ http-read-headers
    probe-chunked ! probe-length ! ;

: headers-raises ( addr u name-addr name-u -- )
    2>r
    memory-stream probe-stream !
    ['] probe-headers
    2r> raises ;

: read-headers ( addr u -- length chunked )
    memory-stream probe-stream !
    probe-headers
    probe-length @ probe-chunked @ ;

: test-headers ( -- )
    s\" Content-Length: 12\r\n\r\n" read-headers
    swap 12 s" declared body length" same-n
    0= s" a declared length is not chunked" ok
    s\" Transfer-Encoding: chunked\r\n\r\n" read-headers
    s" chunked framing is detected" ok
    -1 s" chunked framing has no declared length" same-n
    s\" \r\n" read-headers 2drop
    true s" a header block may be empty" ok
    s\" content-length: 5\r\n\r\n" read-headers 2drop
    true s" header names fold case" ok
    s\" Transfer-Encoding: gzip\r\n\r\n"
    s" an unsupported transfer encoding is rejected" headers-raises
    s\" Content-Length: 99999999\r\n\r\n"
    s" a declared length beyond the byte limit is rejected" headers-raises
    s\" Content-Length: many\r\n\r\n"
    s" a non-numeric Content-Length is rejected" headers-raises ;

: probe-body ( -- )
    test-client probe-stream @ 60000 deadline+
    probe-length @ probe-chunked @ http-read-body ;

: read-body ( addr u length chunked -- body-addr body-u )
    probe-chunked ! probe-length !
    memory-stream probe-stream !
    probe-body
    test-client client-resp buf-span ;

: body-raises ( addr u length chunked name-addr name-u -- )
    2>r probe-chunked ! probe-length !
    memory-stream probe-stream !
    ['] probe-body
    2r> raises ;

: test-body ( -- )
    s" hello" 5 false read-body s" hello" s" body with a declared length" same
    s\" 3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n" -1 true read-body
    s" abcde" s" chunked body is reassembled" same
    s\" 0\r\n\r\n" -1 true read-body s" " s" an empty chunked body" same
    s\" 3;ext=1\r\nabc\r\n0\r\n\r\n" -1 true read-body
    s" abc" s" a chunk extension is ignored" same
    s\" ffffffff\r\n" -1 true
    s" a chunk beyond the byte limit is rejected" body-raises
    s\" zz\r\n" -1 true
    s" a non-hexadecimal chunk size is rejected" body-raises ;

\ ---------------------------------------------------------------------------
\ The Convex envelope
\ ---------------------------------------------------------------------------

: envelope ( status body-addr body-u -- )
    { status addr count }
    status test-client cl>status + !
    test-client client-resp buf-reset
    addr count test-client client-resp buf-append ;

: probe-envelope ( -- )  test-client s" query" http-decode-envelope ;

: envelope-raises ( status addr u name-addr name-u -- )
    2>r envelope ['] probe-envelope 2r> raises ;

: envelope-ok ( status addr u name-addr name-u -- )
    2>r envelope ['] probe-envelope 2r> succeeds ;

: test-success-envelope ( -- )
    200 s| {"status":"success","value":{"count":1},"logLines":[]}|
    s" a 200 success envelope decodes" envelope-ok
    test-client convex-value json-raw s| {"count":1}|
    s" the decoded value is the exact bytes Convex sent" same
    200 s| {"status":"success","value":0.0,"logLines":[]}|
    s" an integral decimal value decodes" envelope-ok
    test-client convex-value convex-integer 0
    s" 0.0 is the same count as 0" same-n ;

: test-error-envelope ( -- )
    560 s| {"status":"error","errorMessage":"boom","errorData":{"code":"X"},"logLines":["l"]}|
    s" a 560 Convex error envelope raises" envelope-raises
    s" FunctionError" s" 560 is reported as a FunctionError" raised-name
    cvx-error-message@ s" boom" s" the function message is preserved" same
    cvx-error-data@ s| {"code":"X"}| s" the error data is preserved" same
    cvx-error-logs@ s| ["l"]| s" the log lines are preserved" same
    400 s| {"status":"error","errorMessage":"bad request"}|
    s" a 400 carrying a Convex envelope still raises" envelope-raises
    s" FunctionError" s" 400 with an envelope is a FunctionError" raised-name
    500 s" <html>gateway</html>"
    s" a 500 error page raises" envelope-raises
    s" TransportError" s" a non-Convex body is a TransportError" raised-name
    200 s| {"status":"weird"}|
    s" an unknown status raises" envelope-raises
    s" ProtocolError" s" an unknown status is a ProtocolError" raised-name
    200 s| {"status":"success","logLines":[]}|
    s" a success envelope without a value raises" envelope-raises
    s" ProtocolError" s" a missing value is a ProtocolError" raised-name
    200 s| {"status":"success","value":1,"logLines":[1]}|
    s" non-string log lines raise" envelope-raises
    s" ProtocolError" s" bad log lines are a ProtocolError" raised-name
    200 s| ["not","an","envelope"]|
    s" a non-object body raises" envelope-raises
    s" ProtocolError" s" a non-object body is a ProtocolError" raised-name ;

: test-paths ( -- )
    s" demo:state" convex-valid-path? s" module:function is accepted" ok
    s" demo" convex-valid-path? 0= s" a bare module is rejected" ok
    s" :state" convex-valid-path? 0= s" a missing module is rejected" ok
    s" demo:" convex-valid-path? 0= s" a missing function is rejected" ok
    s" a:b:c" convex-valid-path? 0= s" a second colon is rejected" ok ;

\ ---------------------------------------------------------------------------
\ The native transport, end to end over loopback
\ ---------------------------------------------------------------------------

1024 buf-new constant fixture-body

\ Content-Length is computed rather than hand counted, so editing the fixture
\ body cannot quietly produce a response the client is right to reject.
: fixture-response ( -- addr u )
    fixture-body buf-reset
    s| {"status":"error","errorMessage":"boom","logLines":[]}|
    fixture-body buf-append
    scratch buf-reset
    s\" HTTP/1.1 560 Convex Error\r\n" scratch buf-append
    s\" Content-Type: application/json\r\n" scratch buf-append
    s\" Content-Length: " scratch buf-append
    fixture-body buf-len scratch u>buf
    s\" \r\n\r\n" scratch buf-append
    fixture-body buf-span scratch buf-append
    scratch buf-span ;

variable fixture-client-stream
variable fixture-server-stream

: probe-exchange ( -- )
    test-client http-pending-client !
    fixture-client-stream @ http-pending-stream !
    5000 deadline+ http-pending-deadline !
    http-exchange ;

\ The peer's whole answer is written before the client reads it, which keeps a
\ single threaded test deterministic while still driving the real sockets, the
\ real request writer and the real response framing.
: test-loopback ( -- )
    0 { code }
    s" 45001" loopback-pair fixture-server-stream ! fixture-client-stream !
    fixture-response fixture-server-stream @ preload
    test-client s" demo:state" test-client convex-no-args http-build-body
    test-client s" query" test-client client-req http-build-request
    ['] probe-exchange catch to code
    code 0= s" the exchange completed over a real socket" ok
    test-client client-status 560 s" the status came from the wire" same-n
    ['] probe-envelope throws? s" the wire envelope raises" ok
    s" FunctionError" s" the wire envelope is a FunctionError" raised-name
    cvx-error-message@ s" boom" s" the wire message is preserved" same
    fixture-client-stream @ stream-close
    fixture-server-stream @ stream-close ;

\ An absolute deadline must fire even though the peer is still connected and
\ has sent a well-formed prefix. This is the case a per-read timeout misses.
: probe-stalled-headers ( -- )
    test-client fixture-client-stream @ 300 deadline+ http-read-headers
    2drop ;

: test-absolute-deadline ( -- )
    0 0 { started elapsed }
    s" 45002" loopback-pair fixture-server-stream ! fixture-client-stream !
    s\" Content-Type: application/json\r\n" fixture-server-stream @ preload
    now to started
    ['] probe-stalled-headers throws?
    s" a stalled peer trips the absolute deadline" ok
    now started - to elapsed
    elapsed 250 u> s" the deadline was not short-circuited" ok
    elapsed 5000 u< s" the deadline was not overrun" ok
    fixture-client-stream @ stream-close
    fixture-server-stream @ stream-close ;

test-status-line
test-headers
test-body
test-success-envelope
test-error-envelope
test-paths
test-loopback
test-absolute-deadline

s" http-test" tests-done
0 convex-exit
