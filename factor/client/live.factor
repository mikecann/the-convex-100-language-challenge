! Live subscriptions over Convex's pinned sync profile.
!
! One owner thread owns the WebSocket, the query-set version, the reconnect
! lifecycle, and every subscription record. Application threads never touch
! the socket: they post a command with a reply mailbox and wait for the owner
! to answer, which is why unsubscribe, disconnect, and close can be
! acknowledged only after the owner has already retired what the
! acknowledgement claims.
!
! Delivery buffering belongs to this client rather than to a runtime mailbox.
! Each subscription has an explicitly bounded relay that keeps the newest
! events within both a count and a conservatively charged byte budget, so a
! slow consumer cannot grow the process without limit. A relay carries a
! generation, so an unsubscribe or a same-id replacement invalidates queued
! work before its acknowledgement is published.
!
! Factor's green threads are cooperative: a thread yields only at an I/O
! operation, a sleep, or a mailbox operation. Every critical section below is
! a short run of pure data manipulation with no yield point, which is what
! makes the owner's single-writer discipline sufficient.

USING: accessors arrays assocs base64 calendar combinators
concurrency.mailboxes continuations kernel locals make math
math.bitwise math.order math.parser random sequences sorting
splitting strings system threads vectors convex.json
convex.transport ;
IN: convex.live

! The unversioned sync profile starts every connection at this state version.
CONSTANT: initial-timestamp "AAAAAAAAAAA="

CONSTANT: max-relay-events 16
CONSTANT: max-relay-bytes 8388608
CONSTANT: relay-overhead-bytes 512
CONSTANT: max-subscriptions 64

CONSTANT: base-reconnect-nanos 100000000
CONSTANT: max-reconnect-nanos 15000000000

! How often the owner wakes to notice a due reconnect or a queued command.
CONSTANT: owner-tick-millis 5

! --- updates and relays ----------------------------------------------------

! VALUE, ERROR, and LOGS are raw JSON text. Keeping them unparsed is what
! lets a Convex value reach the example or the controller byte-exact.
TUPLE: live-update value error logs ;

: <live-value-update> ( value logs -- update )
    live-update new swap >>logs swap >>value ;

: <live-error-update> ( error logs -- update )
    live-update new swap >>logs swap >>error ;

TUPLE: relay generation queue bytes dropped closed? ;

: <relay> ( -- relay )
    relay new
        0 >>generation
        V{ } clone >>queue
        0 >>bytes
        0 >>dropped
        f >>closed? ;

! Each queued event is charged its exact encoded length plus a conservative
! allowance for the tuple, the vector slot, and the runtime's own overhead.
! An event count alone is not a memory bound when one Convex value can
! approach the maximum frame size.
:: update-charge ( update -- n )
    update value>> [ length ] [ 0 ] if*
    update error>> [ length ] [ 0 ] if* +
    update logs>> [ length ] [ 0 ] if* +
    relay-overhead-bytes + ;

! Admission is deliberately newest-wins. Dropping the oldest event keeps a
! stalled consumer from pinning memory while still delivering the value a
! reactive client actually needs: the current one.
:: relay-admit ( relay update -- )
    update relay queue>> push
    relay bytes>> update update-charge + relay bytes<<
    [
        relay queue>> length 1 >
        relay queue>> length max-relay-events >
        relay bytes>> max-relay-bytes > or
        and
    ] [
        relay queue>> first update-charge :> old-charge
        relay queue>> rest >vector relay queue<<
        ! Floors at zero rather than calling `max`: see the comment on
        ! `outbox-take` in client/tests/conformance/adapter.factor for why.
        relay bytes>> old-charge - dup 0 < [ drop 0 ] when relay bytes<<
        relay dropped>> 1 + relay dropped<<
    ] while ;

! Returns f when GENERATION is stale, which is how an unsubscribe or a
! same-id replacement invalidates queued work before it is acknowledged.
:: relay-publish ( relay generation update -- ? )
    relay generation>> generation = relay closed?>> not and [
        relay update relay-admit t
    ] [ f ] if ;

:: relay-invalidate ( relay -- )
    relay generation>> 1 + relay generation<<
    V{ } clone relay queue<<
    0 relay bytes<< ;

:: relay-take ( relay -- update/f )
    relay queue>> empty? [ f ] [
        relay queue>> first :> update
        relay queue>> rest >vector relay queue<<
        ! Floors at zero rather than calling `max`: see the comment on
        ! `outbox-take` in client/tests/conformance/adapter.factor for why.
        relay bytes>> update update-charge - dup 0 < [ drop 0 ] when
        relay bytes<<
        update
    ] if ;

! --- client state ----------------------------------------------------------

TUPLE: subscription query-id path args relay signature ;

TUPLE: live-client url version mailbox subscriptions next-query-id
    query-set remote-version connection-count last-close-reason
    max-timestamp websocket generation reconnect-delay reconnect-at
    running? closed? handshakes ;

:: state-version-json ( query-set identity timestamp -- json )
    [
        "querySet" query-set json-number 2array ,
        "identity" identity json-number 2array ,
        "ts" timestamp json-escape-string 2array ,
    ] { } make json-object ;

: <live-client> ( url version -- client )
    live-client new
        swap >>version
        swap >>url
        <mailbox> >>mailbox
        H{ } clone >>subscriptions
        0 >>next-query-id
        0 >>query-set
        0 0 initial-timestamp state-version-json >>remote-version
        0 >>connection-count
        "InitialConnect" >>last-close-reason
        f >>max-timestamp
        f >>websocket
        0 >>generation
        base-reconnect-nanos >>reconnect-delay
        0 >>reconnect-at
        t >>running?
        f >>closed?
        0 >>handshakes ;

! --- sync protocol encoding ------------------------------------------------

: session-id ( -- text )
    [ 16 random-bytes [ >hex 2 CHAR: 0 pad-head % ] each ] "" make ;

:: connect-message ( client -- json )
    [
        "type" "\"Connect\"" 2array ,
        "sessionId" session-id json-escape-string 2array ,
        "connectionCount" client connection-count>> json-number 2array ,
        "lastCloseReason" client last-close-reason>> json-escape-string
        2array ,
        "clientTs" "0" 2array ,
        client max-timestamp>> [
            "maxObservedTimestamp" swap json-escape-string 2array ,
        ] when*
    ] { } make json-object ;

:: add-modification ( sub -- json )
    [
        "type" "\"Add\"" 2array ,
        "queryId" sub query-id>> json-number 2array ,
        "udfPath" sub path>> json-escape-string 2array ,
        "args" sub args>> 1array json-array 2array ,
    ] { } make json-object ;

:: remove-modification ( query-id -- json )
    [
        "type" "\"Remove\"" 2array ,
        "queryId" query-id json-number 2array ,
    ] { } make json-object ;

:: modify-query-set ( client modifications -- json )
    client query-set>> :> base
    [
        "type" "\"ModifyQuerySet\"" 2array ,
        "baseVersion" base json-number 2array ,
        "newVersion" base 1 + json-number 2array ,
        "modifications" modifications json-array 2array ,
    ] { } make json-object ;

! The profile encodes a timestamp as eight little-endian bytes in base64.
! Comparing decoded integers keeps maxObservedTimestamp monotonic without
! trusting the textual ordering of base64.
:: timestamp-key ( text -- n )
    text base64> :> bytes
    bytes length 8 = [ "invalid canonical timestamp" protocol-error ] unless
    0 :> total!
    8 <iota> [| i | i bytes nth 8 i * shift total bitor total! ] each
    total ;

:: normalize-state-version ( raw -- json )
    raw "querySet" json-field "state version querySet" json-uint32
    raw "identity" json-field "state version identity" json-uint32
    raw "ts" json-field [
        "state version ts is missing" protocol-error
    ] unless* json-string-value
    dup timestamp-key drop
    state-version-json ;

:: sync-url ( url -- url' )
    url "/" ?tail drop :> base
    base "https://" ?head [ "wss://" prepend ] [
        "http://" ?head [ "ws://" prepend ] [
            drop "unsupported Convex URL scheme" transport-error
        ] if
    ] if "/api/sync" append ;

! --- owner mailbox ---------------------------------------------------------

: post-command ( client message -- ) swap mailbox>> mailbox-put ;

! Waiting for the owner's reply is bounded and asserted. Close and unsubscribe
! must not depend on a cooperative peer to finish.
:: await-reply ( reply seconds what -- value )
    seconds 1000000000 * deadline-from-now :> deadline
    f :> result!
    f :> done!
    [ done not ] [
        reply mailbox-empty? [
            ! The deadline is checked on every pass, not only while the
            ! mailbox is empty, so a falsy reply cannot spin here forever.
            deadline what check-deadline
            owner-tick-millis milliseconds sleep
        ] [ reply mailbox-get result! t done! ] if
    ] while
    result ;

: reply-ok ( reply value -- ) swap mailbox-put ;

! --- owner: connection lifecycle -------------------------------------------

:: owner-send ( client text -- )
    client websocket>> [
        "Live WebSocket is not connected" transport-error
    ] unless*
    text websocket-send-text ;

:: owner-active-subscriptions ( client -- seq )
    client subscriptions>> >alist [ [ first ] bi@ <=> ] sort-with
    [ second ] map ;

! Retiring a connection bumps the generation first, so a reader thread still
! parsing an old frame can no longer publish through this client.
:: owner-retire ( client reason reconnect? -- )
    client generation>> 1 + client generation<<
    client websocket>> [ websocket-dispose ] when*
    f client websocket<<
    reason client last-close-reason<<
    client connection-count>> 1 + client connection-count<<
    reconnect? client closed?>> not and [
        nano-count client reconnect-delay>> + client reconnect-at<<
        client reconnect-delay>> 2 * max-reconnect-nanos min
        client reconnect-delay<<
    ] when ;

! A query-set change is a socket write, so a failure here retires the
! connection rather than leaving the client's version counter ahead of the
! server's.
:: owner-modify ( client modifications -- )
    modifications empty? [
        [
            client modifications modify-query-set :> text
            client text owner-send
            client query-set>> 1 + client query-set<<
        ] [ drop client "TransportError" t owner-retire ] recover
    ] unless ;

! Reporting a failure must not strand an otherwise valid subscription. The
! remembered signature is cleared alongside the error, so the first valid
! value after a protocol or transport reconnect is published even when the
! server rehydrates the same value the subscriber last saw.
:: owner-fail-subscriptions ( client name message -- )
    [
        "name" name json-escape-string 2array ,
        "message" message json-escape-string 2array ,
    ] { } make json-object :> payload
    client owner-active-subscriptions [| sub |
        sub relay>> sub relay>> generation>> payload "[]"
        <live-error-update> relay-publish drop
        f sub signature<<
    ] each ;

! The reader owns only this connection's byte reads. It publishes nothing and
! mutates nothing: every decoded frame reaches the owner as a message tagged
! with the generation that produced it.
:: owner-reader-loop ( client ws generation -- )
    [
        f :> stop!
        [ stop not client generation>> generation = and ] [
            ws websocket-next-message :> text
            text [
                client "frame" generation text 3array post-command
            ] [
                client "dead" generation "peer closed" 3array post-command
                t stop!
            ] if
        ] while
    ] [
        error-message :> message
        client "dead" generation message 3array post-command
    ] recover ;

:: owner-connect ( client -- )
    [
        client url>> sync-url client version>> websocket-connect :> ws
        ws client websocket<<
        client handshakes>> 1 + client handshakes<<
        ! A completed handshake is a healthy connection, so the next failure
        ! starts from the base delay instead of inheriting an old maximum.
        base-reconnect-nanos client reconnect-delay<<
        0 client query-set<<
        0 0 initial-timestamp state-version-json client remote-version<<
        client client connect-message owner-send
        ! Every connection resends the active Add operations, which is what
        ! makes a reconnect rehydrate rather than silently lose a query.
        client client owner-active-subscriptions
        [ add-modification ] map owner-modify
        client generation>> :> generation
        [ client ws generation owner-reader-loop ] "convex-live-reader"
        spawn drop
    ] [
        error-message client swap t owner-retire
    ] recover ;

! --- owner: transitions ----------------------------------------------------

:: owner-publish ( client query-id update -- )
    query-id client subscriptions>> at [| sub |
        update value>> [ update error>> ] unless* :> signature
        sub signature>> signature = [
            signature sub signature<<
            sub relay>> sub relay>> generation>> update relay-publish drop
        ] unless
    ] when* ;

:: transition-modification ( mod -- query-id update/f )
    mod "queryId" json-field "Live queryId" json-uint32 :> query-id
    mod "type" json-field [
        "Live modification omitted type" protocol-error
    ] unless* json-string-value :> kind
    query-id
    kind {
        { "QueryUpdated" [
            mod "value" json-field [
                "QueryUpdated omitted value" protocol-error
            ] unless*
            mod "logLines" json-field [ "[]" ] unless*
            <live-value-update>
        ] }
        { "QueryFailed" [
            mod "errorMessage" json-field [
                "QueryFailed omitted errorMessage" protocol-error
            ] unless* json-string-value :> message
            mod "errorData" json-field :> data
            mod "logLines" json-field [ "[]" ] unless* :> logs
            [
                "name" "\"FunctionError\"" 2array ,
                "message" message json-escape-string 2array ,
                data [ "data" swap 2array , ] when*
            ] { } make json-object logs <live-error-update>
        ] }
        { "QueryRemoved" [ f ] }
        [ drop "unsupported Live modification" protocol-error ]
    } case ;

:: owner-apply-transition ( client raw -- )
    raw "startVersion" json-field [
        "Transition omitted startVersion" protocol-error
    ] unless* normalize-state-version :> start
    start client remote-version>> = [
        "transition start version mismatch" protocol-error
    ] unless
    raw "endVersion" json-field [
        "Transition omitted endVersion" protocol-error
    ] unless* :> end-raw
    end-raw normalize-state-version :> end
    end-raw "ts" json-field json-string-value :> end-timestamp
    ! Validate every modification before publishing any of them, and coalesce
    ! repeated changes to one query so a consumer never observes an
    ! intermediate transaction state.
    H{ } clone :> pending
    raw "modifications" json-field [ "[]" ] unless* json-elements [| mod |
        mod transition-modification :> ( query-id update )
        update [ update query-id pending set-at ] when
    ] each
    client max-timestamp>> :> previous
    previous not [
        end-timestamp client max-timestamp<<
    ] [
        end-timestamp timestamp-key previous timestamp-key > [
            end-timestamp client max-timestamp<<
        ] when
    ] if
    end client remote-version<<
    pending >alist [ [ first ] bi@ <=> ] sort-with [| pair |
        client pair first pair second owner-publish
    ] each ;

:: owner-handle-message ( client text -- )
    text check-json drop
    text "type" json-field [
        "Live message omitted type" protocol-error
    ] unless* json-string-value {
        { "Transition" [ client text owner-apply-transition ] }
        { "Ping" [ ] }
        { "MutationResponse" [ ] }
        { "ActionResponse" [ ] }
        { "TransitionChunk" [
            "TransitionChunk is not implemented" protocol-error
        ] }
        { "FatalError" [ "server reported a fatal error" protocol-error ] }
        { "AuthError" [
            "server rejected Live authentication" protocol-error
        ] }
        [ drop "unsupported Live message" protocol-error ]
    } case ;

! --- owner: command dispatch -----------------------------------------------

:: owner-subscribe ( client reply path args -- )
    client subscriptions>> assoc-size max-subscriptions >= [
        reply "too many active subscriptions" reply-ok
    ] [
        client next-query-id>> :> query-id
        query-id 1 + client next-query-id<<
        subscription new
            query-id >>query-id
            path >>path
            args >>args
            <relay> >>relay
            f >>signature :> sub
        sub query-id client subscriptions>> set-at
        client websocket>> [
            client sub add-modification 1array owner-modify
        ] when
        reply sub reply-ok
    ] if ;

:: owner-unsubscribe ( client reply query-id -- )
    query-id client subscriptions>> at [| sub |
        ! Invalidate the relay before anything else, so the acknowledgement
        ! below cannot be crossed by an event queued for the old subscription.
        sub relay>> relay-invalidate
        query-id client subscriptions>> delete-at
        client websocket>> [
            client query-id remove-modification 1array owner-modify
        ] when
    ] when*
    reply t reply-ok ;

:: owner-disconnect ( client reply -- )
    client websocket>> [
        client "DebugDisconnect" t owner-retire
        reply t reply-ok
    ] [ reply "Live WebSocket is not connected" reply-ok ] if ;

:: owner-close ( client reply -- )
    t client closed?<<
    client "client-closed" f owner-retire
    client owner-active-subscriptions [ relay>> relay-invalidate ] each
    H{ } clone client subscriptions<<
    f client running?<<
    reply t reply-ok ;

:: owner-dead ( client generation reason -- )
    client generation>> generation = [
        client "TransportError" reason owner-fail-subscriptions
        client reason t owner-retire
    ] when ;

:: owner-frame ( client generation text -- )
    client generation>> generation = [
        [ client text owner-handle-message ] [
            [ error-name ] [ error-message ] bi :> ( name message )
            client name message owner-fail-subscriptions
            client message t owner-retire
        ] recover
    ] when ;

:: owner-dispatch ( client message -- )
    message first {
        { "subscribe" [
            client message second message third message fourth
            owner-subscribe
        ] }
        { "unsubscribe" [
            client message second message third owner-unsubscribe
        ] }
        { "disconnect" [ client message second owner-disconnect ] }
        { "close" [ client message second owner-close ] }
        { "frame" [ client message second message third owner-frame ] }
        { "dead" [ client message second message third owner-dead ] }
        [ drop ]
    } case ;

:: owner-service ( client -- )
    client closed?>> not
    client websocket>> not and
    client subscriptions>> assoc-empty? not and
    nano-count client reconnect-at>> >= and
    [ client owner-connect ] when ;

:: live-owner-loop ( client -- )
    [ client running?>> ] [
        [ client mailbox>> mailbox-empty? not client running?>> and ] [
            client client mailbox>> mailbox-get owner-dispatch
        ] while
        client running?>> [
            client owner-service
            owner-tick-millis milliseconds sleep
        ] when
    ] while ;

:: start-live-owner ( client -- )
    client url>> parse-endpoint :> endpoint
    [ endpoint [ client live-owner-loop ] with-convex-tls ]
    "convex-live-owner" spawn drop ;
