! Test-only conformance adapter. This is not part of the educational client.
!
! It speaks NDJSON adapter protocol v1 on stdin/stdout, or over TCP when
! ADAPTER_LISTEN is set, and calls the real Factor client for every
! operation. stdout carries protocol events only; diagnostics go to stderr.
!
! Two properties matter beyond echoing the protocol. First, output admission
! is bounded by both a count and a byte budget, and a reader that stopped
! consuming is answered with an absolute write deadline rather than unbounded
! retention. Second, a subscription is invalidated before the acknowledgement
! that retires it, so no stale event can cross an unsubscribe or a same-id
! replacement.

USING: accessors arrays assocs calendar combinators
concurrency.mailboxes continuations debugger destructors environment io
io.encodings.utf8 io.sockets io.timeouts kernel locals make math
math.parser namespaces sequences splitting strings system threads
vectors convex convex.json convex.live convex.transport ;
IN: convex.adapter

! DEBUG: print full error diagnostics for ANY uncaught error in ANY
! thread, before Factor's default handler calls die. Temporary, for
! diagnosing the hosted-only VM crash. Explicitly flushed because die's
! abrupt exit does not appear to flush stdout's own buffer.
[
    "DEBUG uncaught error in thread: " write dup name>> print flush
    "DEBUG error class: " write dup class>> name>> print flush
    "DEBUG error object: " write over error. flush
    die drop rethrow
] thread-error-hook set-global

CONSTANT: adapter-language "factor"
CONSTANT: adapter-implementation
    "native-factor-http-and-pinned-sync-0.1.0"
CONSTANT: adapter-runtime "factor-0.101"

! --- bounded output --------------------------------------------------------

CONSTANT: max-outbox-events 16
CONSTANT: max-outbox-bytes 6291456
CONSTANT: outbox-event-overhead 1024
CONSTANT: reserved-control-events 4
CONSTANT: reserved-control-bytes 65536
CONSTANT: outbox-write-nanos 5000000000
CONSTANT: outbox-drain-nanos 2000000000

TUPLE: outbox-entry line control? charge ;

TUPLE: outbox stream queue bytes dropped stalls last-wait in-flight?
    closed? ;

: <outbox> ( stream -- outbox )
    outbox new
        swap >>stream
        V{ } clone >>queue
        0 >>bytes
        0 >>dropped
        0 >>stalls
        0 >>last-wait
        f >>in-flight?
        f >>closed? ;

! Each entry is charged its exact encoded length, the NDJSON newline, and a
! conservative allowance for the tuple, the vector slot, and the encoder's
! own working copy. An event count alone is not a memory bound when one
! Convex value can approach the maximum frame size.
: entry-charge ( line -- n )
    length 1 + outbox-event-overhead + ;

:: outbox-droppable-bytes ( outbox -- n )
    0 :> total!
    outbox queue>> [
        dup control?>> [ drop ] [ charge>> total + total! ] if
    ] each
    total ;

: outbox-droppable-count ( outbox -- n )
    queue>> [ control?>> not ] count ;

:: outbox-over-budget? ( outbox -- ? )
    outbox queue>> length max-outbox-events >
    outbox bytes>> max-outbox-bytes > or
    outbox outbox-droppable-count
    max-outbox-events reserved-control-events - > or
    outbox outbox-droppable-bytes
    max-outbox-bytes reserved-control-bytes - > or ;

:: outbox-drop-oldest ( outbox -- ? )
    outbox queue>> [ control?>> not ] find drop :> index
    index [
        index outbox queue>> remove-nth >vector outbox queue<<
        outbox queue>> [ charge>> ] map sum outbox bytes<<
        outbox dropped>> 1 + outbox dropped<<
        t
    ] [ f ] if ;

! A control event -- ready, result, error, ack, or closed -- answers a
! specific controller request, so it is never dropped. Subscription events
! are droppable, and the reserved slots and bytes keep a burst of large Live
! values from starving a controller answer.
:: outbox-offer ( outbox line control? -- )
    outbox-entry new
        line >>line
        control? >>control?
        line entry-charge >>charge :> entry
    entry outbox queue>> push
    outbox bytes>> entry charge>> + outbox bytes<<
    [
        outbox outbox-droppable-count 0 >
        outbox outbox-over-budget? and
    ] [ outbox outbox-drop-oldest drop ] while ;

:: outbox-take ( outbox -- entry/f )
    outbox queue>> empty? [ f ] [
        outbox queue>> first :> entry
        outbox queue>> rest >vector outbox queue<<
        ! Floors at zero rather than calling `max`: nested this deep inside a
        ! `::` word, `math`'s `max` failed to resolve when this vocab was
        ! compiled as a dependency of convex.tests.adapter (a plain top-level
        ! `require` of this vocab does not trigger the same failure), the
        ! same class of Factor-toolchain stack/vocab-resolution limitation
        ! worked around elsewhere in this codebase by restructuring rather
        ! than by patching around it in the toolchain itself.
        outbox bytes>> entry charge>> - dup 0 < [ drop 0 ] when
        outbox bytes<<
        entry
    ] if ;

! The writer never waits forever on a reader that stopped consuming. When the
! absolute write deadline expires the event is abandoned and counted, so
! retained memory stays inside the admission budget above.
:: outbox-write-once ( outbox entry -- )
    nano-count :> started
    t outbox in-flight?<<
    [
        outbox-write-nanos nanoseconds outbox stream>> set-timeout
        entry line>> outbox stream>> stream-write
        outbox stream>> stream-flush
    ] [
        drop
        outbox stalls>> 1 + outbox stalls<<
    ] recover
    f outbox in-flight?<<
    nano-count started - outbox last-wait<< ;

:: outbox-writer-loop ( outbox -- )
    [ outbox closed?>> not outbox queue>> empty? not or ] [
        outbox outbox-take :> entry
        entry [ outbox entry outbox-write-once ] [ 2 milliseconds sleep ] if
    ] while ;

: start-outbox ( outbox -- )
    [ outbox-writer-loop ] curry "convex-adapter-writer" spawn drop ;

! Draining waits for the queue to empty AND for the writer to finish the
! record it already dequeued. Waiting only on the queue would let the process
! exit while the terminal `closed` event was still in flight.
:: outbox-drain ( outbox -- )
    outbox-drain-nanos deadline-from-now :> deadline
    [
        outbox queue>> empty? not outbox in-flight?>> or
        nano-count deadline < and
    ] [ 2 milliseconds sleep ] while ;

! --- adapter state ---------------------------------------------------------

TUPLE: adapter client outbox subscriptions generations running? ;

:: <adapter> ( client stream -- adapter )
    adapter new
        client >>client
        stream <outbox> >>outbox
        H{ } clone >>subscriptions
        H{ } clone >>generations
        t >>running? ;

:: diagnostic ( message -- )
    [
        error-stream get :> es
        message es stream-write
        "\n" es stream-write
        es stream-flush
    ] [ drop ] recover ;

: emit ( adapter line control? -- )
    [ outbox>> ] 2dip [ "\n" append ] dip outbox-offer ;

:: emit-event ( adapter pairs control? -- )
    adapter pairs json-object control? emit ;

! --- event shapes ----------------------------------------------------------
!
! Optional fields are omitted rather than serialized as null. The shared
! controller validates every emitted line against the adapter schema, so an
! absent id, subscriptionId, value, or error must not appear at all.

:: emit-ready ( adapter id -- )
    adapter [
        "protocolVersion" "1" 2array ,
        "id" id json-escape-string 2array ,
        "type" "\"ready\"" 2array ,
        "language" adapter-language json-escape-string 2array ,
        "implementation" adapter-implementation json-escape-string 2array ,
        "runtime" adapter-runtime json-escape-string 2array ,
    ] { } make t emit-event ;

:: emit-result ( adapter id value logs -- )
    adapter [
        "id" id json-escape-string 2array ,
        "type" "\"result\"" 2array ,
        "value" value 2array ,
        "logs" logs 2array ,
    ] { } make t emit-event ;

:: error-payload ( error -- json )
    [
        "name" error error-name json-escape-string 2array ,
        "message" error error-message json-escape-string 2array ,
        error function-error? [
            "data" error data>> [ "null" ] unless* 2array ,
        ] when
    ] { } make json-object ;

:: emit-error ( adapter id error -- )
    adapter [
        "id" id json-escape-string 2array ,
        "type" "\"error\"" 2array ,
        "error" error error-payload 2array ,
    ] { } make t emit-event ;

:: emit-anonymous-error ( adapter error -- )
    adapter [
        "type" "\"error\"" 2array ,
        "error" error error-payload 2array ,
    ] { } make t emit-event ;

:: emit-ack ( adapter id -- )
    adapter [
        "id" id json-escape-string 2array ,
        "type" "\"ack\"" 2array ,
    ] { } make t emit-event ;

:: emit-closed ( adapter id -- )
    adapter [
        "id" id json-escape-string 2array ,
        "type" "\"closed\"" 2array ,
    ] { } make t emit-event ;

:: emit-subscription-value ( adapter subscription-id value logs -- )
    adapter [
        "type" "\"subscription\"" 2array ,
        "subscriptionId" subscription-id json-escape-string 2array ,
        "value" value 2array ,
        "logs" logs 2array ,
    ] { } make f emit-event ;

:: emit-subscription-error ( adapter subscription-id error -- )
    adapter [
        "type" "\"subscription\"" 2array ,
        "subscriptionId" subscription-id json-escape-string 2array ,
        "error" error 2array ,
    ] { } make f emit-event ;

! --- command validation ----------------------------------------------------
!
! The controller's schema is authoritative, so a command that carries an
! unexpected field, a missing required field, or a wrong JSON type is refused
! here instead of being partially honoured.

:: require-field ( command name -- raw )
    command name json-field [
        "command omitted " name append protocol-error
    ] unless* ;

: require-string ( command name -- string )
    require-field json-string-value ;

:: check-keys ( command allowed -- )
    command json-keys [| key |
        key allowed member? [
            "command has an unexpected field: " key append protocol-error
        ] unless
    ] each ;

:: command-op ( command -- op )
    command json-object-text? [
        "command must be a JSON object" protocol-error
    ] unless
    command "op" require-string ;

:: check-call-command ( command -- )
    command { "id" "op" "path" "args" } check-keys
    command "id" require-string drop
    command "path" require-string length 3 >= [
        "command path is too short" protocol-error
    ] unless
    command "args" require-field json-object-text? [
        "command args must be a JSON object" protocol-error
    ] unless ;

:: check-subscription-command ( command op -- )
    command { "id" "op" "subscriptionId" "path" "args" } check-keys
    command "id" require-string drop
    command "subscriptionId" require-string drop
    op "subscribe" = [
        command "path" require-string drop
        command "args" require-field json-object-text? [
            "command args must be a JSON object" protocol-error
        ] unless
    ] when ;

:: check-command ( command op -- )
    {
        { [ op "hello" = ] [
            command { "protocolVersion" "id" "op" } check-keys
            command "protocolVersion" require-field
            "protocolVersion" json-uint32 1 = [
                "unsupported adapter protocol version" protocol-error
            ] unless
            command "id" require-string drop
        ] }
        { [ op "setAuth" = ] [
            command { "id" "op" "token" } check-keys
            command "id" require-string drop
            command "token" require-string drop
        ] }
        { [ op { "query" "mutation" "action" } member? ] [
            command check-call-command
        ] }
        { [ op { "subscribe" "unsubscribe" } member? ] [
            command op check-subscription-command
        ] }
        { [ op { "close" "debugDisconnect" } member? ] [
            command { "id" "op" } check-keys
            command "id" require-string drop
        ] }
        [ "unknown adapter operation" protocol-error ]
    } cond ;

! --- subscriptions ---------------------------------------------------------

: subscription-generation ( adapter subscription-id -- n )
    swap generations>> at [ 0 ] unless* ;

:: bump-generation ( adapter subscription-id -- )
    adapter subscription-id subscription-generation 1 +
    subscription-id adapter generations>> set-at ;

! The generation is re-read immediately before admission, with no yield point
! in between, so an unsubscribe that bumped it can never be crossed by an
! event this watcher already dequeued.
:: publish-update ( adapter subscription-id generation update -- ? )
    adapter subscription-id subscription-generation generation = [
        update error>> [
            adapter subscription-id update error>> emit-subscription-error
        ] [
            adapter subscription-id update value>>
            update logs>> [ "[]" ] unless* emit-subscription-value
        ] if
        t
    ] [ f ] if ;

:: watch-subscription ( adapter subscription-id sub generation -- )
    [
        [
            adapter running?>>
            adapter subscription-id subscription-generation generation =
            and
        ] [
            sub 1 subscription-next :> update
            update [
                adapter subscription-id generation update publish-update drop
            ] when
        ] while
    ] [
        error-message "subscription watcher stopped: " prepend diagnostic
    ] recover ;

:: retire-subscription ( adapter subscription-id -- )
    subscription-id adapter subscriptions>> at [| sub |
        ! Bump first: the watcher and the client relay are both invalidated
        ! before this command's acknowledgement is admitted to the outbox.
        adapter subscription-id bump-generation
        subscription-id adapter subscriptions>> delete-at
        adapter client>> sub 5 client-unsubscribe
    ] when* ;

! --- command dispatch ------------------------------------------------------

:: do-call ( adapter command op id -- )
    adapter client>> op
    command "path" require-string
    command "args" require-field convex-call :> result
    adapter id result result-value result result-logs emit-result ;

:: do-subscribe ( adapter command id -- )
    command "subscriptionId" require-string :> subscription-id
    adapter subscription-id retire-subscription
    adapter client>>
    command "path" require-string
    command "args" require-field client-subscribe :> sub
    sub subscription-id adapter subscriptions>> set-at
    adapter subscription-id subscription-generation :> generation
    [ adapter subscription-id sub generation watch-subscription ]
    "convex-adapter-subscription" spawn drop
    adapter id emit-ack ;

:: do-unsubscribe ( adapter command id -- )
    adapter command "subscriptionId" require-string retire-subscription
    adapter id emit-ack ;

! Adapter-only. Forcing a reconnect is conformance machinery, so it is not
! part of the educational client API and is declared in manifest.yaml under
! adapter.adapterOnlyCommands.
:: do-debug-disconnect ( adapter id -- )
    adapter client>> live>> [
        "no active Live connection to disconnect" transport-error
    ] unless* :> live
    <mailbox> :> reply
    live "disconnect" reply 2array post-command
    reply 5 "debugDisconnect" await-reply :> answer
    answer t = [ answer transport-error ] unless
    adapter id emit-ack ;

:: do-close ( adapter id -- )
    adapter subscriptions>> keys [ adapter swap retire-subscription ] each
    adapter client>> 5 client-close
    f adapter running?<<
    adapter id emit-closed
    adapter outbox>> outbox-drain
    t adapter outbox>> closed?<<
    0 exit ;

:: dispatch-command ( adapter command op id -- )
    {
        { [ op "hello" = ] [ adapter id emit-ready ] }
        { [ op { "query" "mutation" "action" } member? ] [
            adapter command op id do-call
        ] }
        { [ op "setAuth" = ] [
            adapter client>> command "token" require-string client-set-auth
            adapter id emit-ack
        ] }
        { [ op "subscribe" = ] [ adapter command id do-subscribe ] }
        { [ op "unsubscribe" = ] [ adapter command id do-unsubscribe ] }
        { [ op "debugDisconnect" = ] [ adapter id do-debug-disconnect ] }
        { [ op "close" = ] [ adapter id do-close ] }
        [ "unknown adapter operation" protocol-error ]
    } cond ;

:: handle-command ( adapter line -- )
    line check-json drop
    line command-op :> op
    line op check-command
    line "id" require-string :> id
    [ adapter line op id dispatch-command ]
    [ adapter id rot emit-error ] recover ;

! A line that is not valid JSON has no usable id, so its error event omits
! the field rather than inventing one.
:: handle-line ( adapter line -- )
    [ adapter line handle-command ] [
        :> problem
        [ line "id" json-field json-string-value ] [ drop f ] recover :> id
        [
            id [ adapter id problem emit-error ]
            [ adapter problem emit-anonymous-error ] if
        ] [ drop ] recover
    ] recover ;

:: adapter-loop ( adapter stream -- )
    [ adapter running?>> ] [
        stream stream-readln :> line
        line [ adapter line handle-line ] [ f adapter running?<< ] if
    ] while ;

:: run-adapter ( url in-stream out-stream -- )
    url <convex-client> out-stream <adapter> :> adapter
    adapter outbox>> start-outbox
    adapter in-stream adapter-loop
    adapter outbox>> outbox-drain ;

:: listen-address ( text -- addrspec )
    text ":" split1 :> ( host port-text )
    port-text [ "ADAPTER_LISTEN must be host:port" transport-error ] unless
    host port-text string>number [
        "ADAPTER_LISTEN port must be a number" transport-error
    ] unless* <inet4> ;

:: adapter-main ( -- )
    "CONVEX_URL" os-env [ "CONVEX_URL is required" transport-error ]
    unless* :> url
    "ADAPTER_LISTEN" os-env :> listen
    listen [
        listen listen-address utf8 <server> [| server |
            server accept drop :> stream
            url stream stream run-adapter
        ] with-disposal
    ] [
        url input-stream get output-stream get run-adapter
    ] if ;

MAIN: adapter-main
