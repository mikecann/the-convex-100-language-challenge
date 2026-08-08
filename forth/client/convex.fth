\ convex.fth - the public vocabulary of the Forth Convex client.
\
\ Loading this file loads the whole client. Nothing above it needs to know how
\ the pieces are split up, so the example and the conformance adapter both
\ start with a single require.
\
\ The layers, innermost first:
\
\   convex-config   every size and time bound in one readable place
\   convex-error    a structured Convex failure that survives THROW
\   convex-buffer   growable byte buffers and the string helpers
\   convex-json     a strict JSON reader and writer, with no floating point
\   convex-io       the native transport boundary and absolute deadlines
\   convex-http     Convex's documented JSON HTTP functions
\   convex-ws       RFC 6455 framing, SHA-1 and base64
\   convex-live     the sync profile, its single socket owner and its queue

require convex-config.fth
require convex-error.fth
require convex-buffer.fth
require convex-json.fth
require convex-io.fth
require convex-http.fth
require convex-ws.fth
require convex-live.fth

\ ---------------------------------------------------------------------------
\ Live, under names that read the same way as the HTTP words
\ ---------------------------------------------------------------------------

: convex-subscribe ( client path-addr path-u args-addr args-u -- sub )
    live-subscribe ;

: convex-unsubscribe ( client sub -- )  live-unsubscribe ;

\ Wait up to timeout milliseconds for the next Live delivery on one
\ subscription. The result is convex-live-none, convex-live-value or
\ convex-live-error.
: convex-live-wait ( client sub timeout-ms -- kind )  live-next ;

live-none constant convex-live-none
live-value constant convex-live-value
live-error constant convex-live-error

: convex-live-value@ ( client -- addr u )  client-live live-taken-value ;
: convex-live-error-name@ ( client -- addr u )  client-live live-taken-name ;
: convex-live-error-message@ ( client -- addr u )
    client-live live-taken-message ;
: convex-live-error-data@ ( client -- addr u )  client-live live-taken-data ;
: convex-live-error-logs@ ( client -- addr u )  client-live live-taken-logs ;

\ Release the delivery just taken. Doing this explicitly is what lets the
\ bounded queue reclaim a large value immediately instead of at the next
\ garbage-producing event.
: convex-live-release ( client -- )  client-live live-release-taken ;

: convex-live-generation ( client -- n )  client-live lv-generation ;
: convex-live-connections ( client -- n )  client-live lv-connection-count ;
: convex-live-close-reason ( client -- addr u )  client-live lv-close-reason ;
: convex-live-dropped ( client -- n )  client-live lv-drops ;

\ ---------------------------------------------------------------------------
\ Shutdown
\ ---------------------------------------------------------------------------

: convex-close ( client -- )
    dup client-live 0<> if dup live-close then
    drop ;

: convex-free ( client -- )
    dup 0= if drop exit then
    dup convex-close
    dup cl>dep + @ deployment-free
    dup cl>auth + @ buf-free
    dup cl>doc + @ json-free
    dup cl>body + @ buf-free
    dup cl>args + @ buf-free
    dup cl>resp + @ buf-free
    dup cl>line + @ buf-free
    dup cl>req + @ buf-free
    free throw ;

\ ---------------------------------------------------------------------------
\ Diagnostics and process exit
\
\ Stdout belongs to the shared happy-path transcript and to the NDJSON adapter
\ protocol, so every diagnostic goes to stderr.
\ ---------------------------------------------------------------------------

: note ( addr u -- )  stderr write-file drop ;
: note-cr ( -- )  s\" \n" note ;
: note-line ( addr u -- )  note note-cr ;

: report-error ( -- )
    cvx-error-name@ note
    s" : " note
    cvx-error-message@ note
    cvx-error-op@ nip 0<> if
        s"  (" note cvx-error-op@ note s" )" note
    then
    note-cr ;

: convex-exit ( code -- )
    stdout flush-file drop
    stderr flush-file drop
    native-exit ;
