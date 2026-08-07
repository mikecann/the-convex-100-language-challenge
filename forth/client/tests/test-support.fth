\ test-support.fth - assertions and deterministic fixtures for the Forth
\ Convex client's language-local tests.
\
\ Two kinds of fixture are provided.
\
\ A memory stream carries bytes that are already present, with no descriptor
\ behind it. It exercises the real parsers over the real stream buffer while
\ making "what has arrived so far" exactly controllable, which is how the
\ mid-frame and partial-header cases are made deterministic rather than timing
\ dependent.
\
\ A loopback pair is two real sockets through the native transport. Writing the
\ fixture bytes into the peer before the client reads them keeps a single
\ threaded test deterministic while still proving the native path end to end.

require convex.fth

\ JSON fixtures are full of double quotes, so a literal delimited by | keeps
\ them readable instead of burying them in escapes. The text must stay on one
\ line, which the fixtures below all do.
: s| ( "ccc|" -- addr u )
    [char] | parse
    state @ if postpone sliteral then ; immediate

variable checks-run
variable checks-failed

: ok ( flag addr u -- )
    1 checks-run +!
    rot if 2drop exit then
    1 checks-failed +!
    s" FAIL " note note-line ;

: same ( addr1 u1 addr2 u2 name-addr name-u -- )
    2>r str= 2r> ok ;

: same-n ( n1 n2 name-addr name-u -- )
    2>r = 2r> ok ;

: tests-done ( addr u -- )
    note
    s" : " note
    checks-run @ u>string note
    s"  checks, " note
    checks-failed @ u>string note
    s"  failed" note-cr
    checks-failed @ 0<> if 1 convex-exit then ;

\ ---------------------------------------------------------------------------
\ Memory streams
\ ---------------------------------------------------------------------------

\ Handle -1 is never a live descriptor, so any attempt to read past the
\ supplied bytes fails loudly instead of silently blocking.
: memory-stream ( addr u -- stream )
    0 { addr count stream }
    -1 stream-wrap to stream
    addr count stream stream-in buf-append
    stream ;

: memory-append ( addr u stream -- )  stream-in buf-append ;

\ ---------------------------------------------------------------------------
\ Loopback pairs
\ ---------------------------------------------------------------------------

: loopback-pair ( port-addr port-u -- client server )
    0 0 0 { port-addr port-count listener client server }
    s" 127.0.0.1" port-addr port-count listener-open to listener
    s" 127.0.0.1" port-addr port-count 0
    cvx-connect-deadline deadline+ stream-open to client
    listener 2000 deadline+ listener-accept to server
    listener listener-close
    client server ;

: preload ( addr u stream -- )
    { addr count stream }
    addr count stream cvx-write-deadline deadline+ stream-write ;

\ ---------------------------------------------------------------------------
\ Probes
\
\ catch needs a word with no arguments, so inputs are staged in these
\ variables. Each suite defines its own probe word and reuses the helpers.
\ ---------------------------------------------------------------------------

variable probe-addr
variable probe-len
variable probe-a
variable probe-b

: >probe ( addr u -- )  probe-len ! probe-addr ! ;
: probe@ ( -- addr u )  probe-addr @ probe-len @ ;

: throws? ( xt -- flag )  catch 0<> ;

: raises ( xt name-addr name-u -- )
    2>r throws? 2r> ok ;

: succeeds ( xt name-addr name-u -- )
    2>r throws? 0= 2r> ok ;

\ Assert the structured error name recorded by the most recent failure.
: raised-name ( expected-addr expected-u name-addr name-u -- )
    2>r cvx-error-name@ 2swap str= 2r> ok ;
