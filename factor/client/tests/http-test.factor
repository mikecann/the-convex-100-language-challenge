! Native HTTP tests against real loopback fixtures.
!
! Every case here drives the actual client over a real socket, so response
! framing, envelope classification, and the streaming byte bound are proved
! rather than asserted about a mock.

USING: accessors continuations destructors io io.encodings.utf8
kernel locals make math math.parser namespaces sequences strings
convex convex.json convex.transport convex.tests.support ;
IN: convex.tests.http

SYMBOL: recorded-head
SYMBOL: recorded-body

! Serves exactly one request with a canned response, recording what the
! client sent so the request envelope can be asserted too.
:: canned-fixture ( response -- port )
    [| stream |
        stream read-request :> ( head body )
        head recorded-head set-global
        body recorded-body set-global
        stream response write-text
        stream dispose
    ] start-fixture ;

:: fixture-client ( port -- client )
    "http://127.0.0.1:" port number>string append <convex-client> ;

:: json-response ( code body -- text )
    code "application/json" body http-fixture-response ;

: state-args ( -- json )
    { { "room" "\"demo\"" } } json-object ;

! Envelope fixtures are assembled from short pieces so the checked-in source
! stays inside the repository's presentation width.
:: success-envelope ( value logs -- text )
    { "{\"status\":\"success\",\"value\":" } value suffix
    ",\"logLines\":" suffix logs suffix "}" suffix concat ;

:: error-envelope ( code -- text )
    { "{\"status\":\"error\",\"errorMessage\":\"boom\"," }
    "\"errorData\":{\"code\":\"" suffix code suffix
    "\"},\"logLines\":[]}" suffix concat ;

! --- successful envelope ---------------------------------------------------

:: test-success ( -- )
    200 "{\"count\":1.0}" "[\"a\"]" success-envelope
    json-response canned-fixture :> port
    port fixture-client "demo:state" state-args client-query :> result
    result result-value "{\"count\":1.0}" "exact value subtree" check-equal
    result result-logs "[\"a\"]" "exact log lines" check-equal ;

! The request envelope must carry Convex's documented fields and the client
! header, and must not send an Authorization header when no token is set.
:: test-request-shape ( -- )
    200 "null" "[]" success-envelope
    json-response canned-fixture :> port
    port fixture-client "demo:state" state-args client-query drop
    recorded-head get-global :> head
    head "POST /api/query HTTP/1.1" head? t "method and path" check-equal
    head "content-type" request-header "application/json"
    "content type" check-equal
    head "convex-client" request-header "factor-0.1.0"
    "client header" check-equal
    head "authorization" request-header f "no bearer token" check-equal
    recorded-body get-global :> body
    body "path" json-field "\"demo:state\"" "request path" check-equal
    body "args" json-field state-args "request args" check-equal
    body "format" json-field "\"json\"" "request format" check-equal ;

:: test-bearer-token ( -- )
    200 "null" "[]" success-envelope
    json-response canned-fixture :> port
    port fixture-client :> client
    client "secret-token" client-set-auth
    client "demo:state" state-args client-query drop
    recorded-head get-global "authorization" request-header
    "Bearer secret-token" "bearer token header" check-equal ;

:: test-cleared-token ( -- )
    200 "null" "[]" success-envelope
    json-response canned-fixture :> port
    port fixture-client :> client
    client "secret-token" client-set-auth
    client "" client-set-auth
    client "demo:state" state-args client-query drop
    recorded-head get-global "authorization" request-header f
    "cleared bearer token" check-equal ;

! --- structured failures ---------------------------------------------------

:: expect-function-error ( port code -- )
    f :> caught!
    [
        port fixture-client "demo:fail" state-args client-query drop
    ] [
        dup function-error? [
            data>> "code" json-field json-string-value caught!
        ] [ drop ] if
    ] recover
    caught code "structured error code" check-equal ;

! A failed Convex function is reported inside a successful HTTP exchange.
:: test-envelope-error ( -- )
    200 "E200" error-envelope
    json-response canned-fixture "E200" expect-function-error ;

! Convex reports a user-visible function failure with HTTP 560 and the same
! envelope, so the client must not treat that status as transport drift.
:: test-560-error ( -- )
    560 "E560" error-envelope
    json-response canned-fixture "E560" expect-function-error ;

! A 400 that is still JSON carries a usable message, so it becomes a
! structured failure rather than an opaque socket error.
:: test-400-error ( -- )
    400 "{\"errorMessage\":\"bad request\",\"errorData\":{\"code\":\"E400\"}}"
    json-response canned-fixture "E400" expect-function-error ;

! A 500 whose body is not JSON must not be guessed at. It surfaces as a
! transport failure that names the status code.
:: test-500-non-json ( -- )
    500 "text/plain" "upstream exploded" http-fixture-response
    canned-fixture :> port
    f :> message!
    [
        port fixture-client "demo:state" state-args client-query drop
    ] [ error-message message! ] recover
    message "Convex returned HTTP 500" "non-JSON 500" check-equal ;

! --- response framing ------------------------------------------------------

:: test-chunked-body ( -- )
    [
        "HTTP/1.1 200 FIXTURE\r\n" %
        "Content-Type: application/json\r\n" %
        "Transfer-Encoding: chunked\r\n\r\n" %
        "18\r\n{\"status\":\"success\",\"val\r\n" %
        "1a\r\nue\":{\"count\":2},\"logLines\"\r\n" %
        "4\r\n:[]}\r\n" %
        "0\r\n\r\n" %
    ] "" make canned-fixture :> port
    port fixture-client "demo:state" state-args client-query result-value
    "{\"count\":2}" "chunked response value" check-equal ;

:: test-connection-close-body ( -- )
    [
        "HTTP/1.1 200 FIXTURE\r\n" %
        "Content-Type: application/json\r\n" %
        "Connection: close\r\n\r\n" %
        "{\"status\":\"success\",\"value\":3,\"logLines\":[]}" %
    ] "" make canned-fixture :> port
    port fixture-client "demo:state" state-args client-query result-value
    "3" "connection-close response value" check-equal ;

! The streaming bound is enforced before the body is read, so an oversized
! declared length can never be buffered.
:: test-oversized-body ( -- )
    [
        "HTTP/1.1 200 FIXTURE\r\n" %
        "Content-Type: application/json\r\n" %
        "Content-Length: 4194304\r\n\r\n" %
    ] "" make canned-fixture :> port
    [
        port fixture-client "demo:state" state-args client-query drop
    ] "oversized response is refused" check-raises ;

:: test-malformed-status ( -- )
    "GARBAGE\r\n\r\n" canned-fixture :> port
    [
        port fixture-client "demo:state" state-args client-query drop
    ] "malformed status line is refused" check-raises ;

! --- argument and path validation ------------------------------------------

:: test-argument-validation ( -- )
    "http://127.0.0.1:1" <convex-client> :> client
    [ client "demo:state" "[]" client-query drop ]
    "array arguments are refused" check-raises
    [ client "nocolon" state-args client-query drop ]
    "path without a module is refused" check-raises ;

: run-http-tests ( -- )
    "http/success" [ test-success ] run-test
    "http/request-shape" [ test-request-shape ] run-test
    "http/bearer-token" [ test-bearer-token ] run-test
    "http/cleared-token" [ test-cleared-token ] run-test
    "http/envelope-error" [ test-envelope-error ] run-test
    "http/560-error" [ test-560-error ] run-test
    "http/400-error" [ test-400-error ] run-test
    "http/500-non-json" [ test-500-non-json ] run-test
    "http/chunked-body" [ test-chunked-body ] run-test
    "http/connection-close-body" [ test-connection-close-body ] run-test
    "http/oversized-body" [ test-oversized-body ] run-test
    "http/malformed-status" [ test-malformed-status ] run-test
    "http/argument-validation" [ test-argument-validation ] run-test
    finish-tests ;

MAIN: run-http-tests
