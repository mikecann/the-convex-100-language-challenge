! The educational Convex client for Factor.
!
! This vocabulary is the surface a reader is meant to use. It calls Convex's
! documented JSON HTTP endpoints for queries, mutations, and actions, and it
! keeps a reactive query current through the pinned sync profile. Only
! ordinary Factor facilities sit underneath: TCP, TLS, threads, and this
! repository's own JSON, HTTP, WebSocket, and sync-protocol code.
!
! The adapter-only disconnect hook deliberately does not appear here. Forcing
! a reconnect is conformance machinery, so the test adapter reaches into
! convex.live for it rather than teaching it as part of the client.

USING: accessors arrays calendar combinators concurrency.mailboxes
kernel locals make math math.parser sequences splitting strings
system threads convex.json convex.live convex.transport ;
IN: convex

CONSTANT: default-client-version "factor-0.1.0"

CONSTANT: http-timeout-seconds 20

! VALUE and LOGS stay as raw JSON text, so a Convex value reaches the caller
! exactly as Convex spelled it.
TUPLE: convex-result value logs ;

TUPLE: convex-client url version auth live closed? ;

:: <convex-client> ( url -- client )
    url [ url empty? ] [ t ] if [
        "Convex deployment URL is required" transport-error
    ] when
    url parse-endpoint drop
    convex-client new
        url "/" ?tail drop >>url
        default-client-version >>version
        f >>auth
        f >>live
        f >>closed? ;

: client-set-version ( client version -- )
    >>version drop ;

! An empty token clears authentication, matching the adapter protocol's
! setAuth contract.
:: client-set-auth ( client token -- )
    client closed?>> [ "client is closed" transport-error ] when
    token [ token empty? [ f ] [ token ] if ] [ f ] if client auth<< ;

:: request-headers ( client -- headers )
    [
        "Content-Type" "application/json" 2array ,
        "Accept" "application/json" 2array ,
        "Convex-Client" client version>> 2array ,
        client auth>> [ "Authorization" swap "Bearer " prepend 2array , ]
        when*
    ] { } make ;

! Convex answers a successful call with status "success" and a failed
! function with status "error" plus structured data. A function failure is
! not a transport failure, so it keeps its own error class all the way to the
! caller instead of being flattened into a value or a socket error.
:: read-envelope ( body -- result )
    body check-json drop
    body json-object-text? [
        "Convex response was not a JSON object" protocol-error
    ] unless
    body "status" json-field [
        "Convex response omitted status" protocol-error
    ] unless* json-string-value {
        { "success" [
            convex-result new
                body "value" json-field [
                    "Convex response omitted value" protocol-error
                ] unless* >>value
                body "logLines" json-field [ "[]" ] unless* >>logs
        ] }
        { "error" [
            body "errorMessage" json-field
            [ json-string-value ] [ "Convex function failed" ] if*
            body "errorData" json-field [ "null" ] unless*
            body "logLines" json-field [ "[]" ] unless*
            function-error
        ] }
        [ drop "Convex response had an unknown status" protocol-error ]
    } case ;

! Convex reports a user-visible function failure with HTTP 560 and the same
! envelope shape. Any other non-200 code is transport or gateway drift: the
! body is reported when it is JSON, and refused rather than guessed when it
! is not.
:: read-http-result ( response -- result )
    response code>> :> code
    response body>> :> body
    {
        { [ code 200 = code 560 = or ] [ body read-envelope ] }
        [
            body json-object-text? [
                body "errorMessage" json-field
                [ json-string-value ] [ "Convex rejected the request" ] if*
                body "errorData" json-field [ "null" ] unless*
                "[]" function-error
            ] [
                "Convex returned HTTP " code number>string append
                transport-error
            ] if
        ]
    } cond ;

:: convex-call ( client operation path args -- result )
    client closed?>> [ "client is closed" transport-error ] when
    path CHAR: : swap index [
        "Convex function path must be module:function" protocol-error
    ] unless
    args json-object-text? [
        "Convex arguments must be a JSON object" protocol-error
    ] unless
    [
        "path" path json-escape-string 2array ,
        "args" args 2array ,
        "format" "\"json\"" 2array ,
    ] { } make json-object :> body
    client url>> "/api/" append operation append
    client request-headers body http-timeout-seconds http-post
    read-http-result ;

: client-query ( client path args -- result )
    [ "query" ] 2dip convex-call ;

: client-mutation ( client path args -- result )
    [ "mutation" ] 2dip convex-call ;

: client-action ( client path args -- result )
    [ "action" ] 2dip convex-call ;

! --- Live ------------------------------------------------------------------

! The owner thread starts on the first subscription, so a program that only
! uses HTTP never opens a WebSocket.
:: client-live ( client -- live )
    client live>> [
        client url>> client version>> <live-client> :> live
        live client live<<
        live start-live-owner
        live
    ] unless* ;

:: client-subscribe ( client path args -- subscription )
    client closed?>> [ "client is closed" transport-error ] when
    args json-object-text? [
        "Convex arguments must be a JSON object" protocol-error
    ] unless
    client client-live :> live
    <mailbox> :> reply
    live "subscribe" reply path args 4array post-command
    reply 10 "subscribe" await-reply :> answer
    answer subscription? [ answer transport-error ] unless
    answer ;

! Waits for the next update on this subscription, or returns f when the
! bounded wait expires. Polling the relay keeps the deadline absolute and
! keeps delivery buffering inside the client's own bounded queue.
:: subscription-next ( subscription seconds -- update/f )
    seconds 1000000000 * deadline-from-now :> deadline
    f :> result!
    f :> done!
    [ done not ] [
        subscription relay>> relay-take :> update
        update [
            update result! t done!
        ] [
            nano-count deadline > [ t done! ] [ 5 milliseconds sleep ] if
        ] if
    ] while
    result ;

: update-value ( update -- raw/f ) value>> ;

: update-error ( update -- raw/f ) error>> ;

: update-logs ( update -- raw ) logs>> ;

: result-value ( result -- raw ) value>> ;

: result-logs ( result -- raw ) logs>> ;

:: client-unsubscribe ( client subscription seconds -- )
    client live>> [| live |
        <mailbox> :> reply
        live "unsubscribe" reply subscription query-id>> 3array post-command
        reply seconds "unsubscribe" await-reply drop
    ] when* ;

:: client-close ( client seconds -- )
    client closed?>> [
        t client closed?<<
        client live>> [| live |
            <mailbox> :> reply
            live "close" reply 2array post-command
            reply seconds "close" await-reply drop
        ] when*
    ] unless ;
