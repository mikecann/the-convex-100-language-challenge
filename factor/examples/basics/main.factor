! The canonical Convex-from-Factor example.
!
! It reads one counter room over HTTP, starts a Live subscription before
! changing anything, applies an idempotent mutation, and proves the same
! 0 -> 1 journey arrived through the subscription. Every line it prints is
! part of the shared happy-path transcript, so diagnostics go to stderr.

USING: accessors arrays command-line continuations environment io
kernel locals make math math.parser namespaces random sequences
system convex convex.json convex.transport ;
IN: convex.example

ERROR: example-error message ;

! Convex JSON may spell a whole number as 0.0. This helper accepts a value
! that is mathematically integral and in range while rejecting fractional,
! quoted, non-finite, and overflowing spellings, which is exactly the
! boundary the client's decoder promises.
:: example-count ( raw operation -- n )
    raw [ operation " returned no value" append example-error ] unless
    raw "count" json-field operation " count" append json-whole-number :> n
    n 0 < [ operation " returned a negative count" append example-error ]
    when
    n ;

! A fresh runId is the mutation's idempotency key. Reading it from the
! operating system's entropy source keeps the example from delegating
! randomness to a CLI or another language runtime.
: run-id ( -- text )
    [ 16 random-bytes [ >hex 2 CHAR: 0 pad-head % ] each ] "" make ;

! The example must never hang waiting for a reactive value that will not
! arrive, so every Live wait carries its own bounded deadline.
:: next-example-value ( subscription operation -- raw )
    subscription 15 subscription-next :> update
    update [ operation " timed out" append example-error ] unless
    update update-error [
        operation " failed: " append
        update update-error "message" json-field json-string-value append
        example-error
    ] when
    update update-value ;

: room-argument ( -- room )
    command-line get dup empty? [ drop f ] [ first ] if
    [ "EXAMPLE_ROOM" os-env ] unless*
    [ "factor-example" ] unless* ;

:: example-main ( -- )
    "CONVEX_URL" os-env [ "CONVEX_URL is required" example-error ] unless*
    :> deployment
    room-argument :> room
    ! One native Factor client for the deployment the container supplies.
    deployment <convex-client> :> client
    f :> subscription!
    [
        room json-escape-string "room" swap 2array 1array json-object
        :> room-args

        ! Ask Convex over its documented JSON HTTP endpoint first, so the
        ! room's starting value is established before anything changes it.
        client "demo:state" room-args client-query result-value
        "current query" example-count :> current
        "current count: " current number>string append print

        ! Start Live before mutating. Subscribing first is what proves the
        ! update below arrived reactively rather than being read back later.
        client "demo:state" room-args client-subscribe subscription!

        ! The first Live value hydrates the same state the HTTP query saw.
        subscription "initial Live value" next-example-value
        "initial Live value" example-count :> initial
        initial current = [
            "initial Live count disagreed with HTTP" example-error
        ] unless
        "live initial count: " initial number>string append print

        ! Reusing this runId would return the prior result instead of
        ! incrementing twice, which is what makes the mutation safe to retry.
        [
            "room" room json-escape-string 2array ,
            "language" "\"Factor\"" 2array ,
            "runId" run-id json-escape-string 2array ,
        ] { } make json-object :> increment-args
        client "demo:increment" increment-args client-mutation result-value
        :> mutation-value
        mutation-value "applied" json-field "applied" json-boolean [
            "mutation was not applied" example-error
        ] unless
        mutation-value "state" json-field "mutation" example-count
        :> mutation-count
        mutation-count current 1 + = [
            "mutation returned an unexpected count" example-error
        ] unless
        "mutation applied: true" print
        "mutation count: " mutation-count number>string append print

        ! Receive the change through Live rather than polling HTTP again.
        subscription "updated Live value" next-example-value
        "updated Live value" example-count :> updated
        updated mutation-count = [
            "updated Live count disagreed with the mutation" example-error
        ] unless
        "live updated count: " updated number>string append print

        ! Only printed once the HTTP query, the initial Live value, the
        ! mutation, and the Live update all agreed.
        "verified count: " current number>string append " -> " append
        updated number>string append print
    ] [
        ! Cleanup uses the client's own acknowledged, bounded shutdown so a
        ! failure still releases the socket and the owner thread.
        subscription [ client subscription 2 client-unsubscribe ] when
        [ client 2 client-close ] [ drop ] recover
    ] [ ] cleanup ;

:: report-failure ( problem -- )
    error-stream get :> es
    "Factor example failed: " es stream-write
    problem example-error? [ problem message>> ] [ problem error-message ] if
    es stream-write
    "\n" es stream-write
    es stream-flush ;

: run-example ( -- )
    ! exit terminates the process immediately, and stdout is fully
    ! buffered rather than line-buffered once it is a pipe rather than a
    ! terminal, so the transcript above must be flushed explicitly or a
    ! verifier reading it back would see nothing.
    [ example-main flush 0 exit ] [ report-failure 1 exit ] recover ;

MAIN: run-example
