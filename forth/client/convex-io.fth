\ convex-io.fth - the boundary between Forth and the one native support
\ library, and the deadline discipline every byte of Convex traffic obeys.
\
\ Standard Forth has no sockets, no TLS and no monotonic clock. client/
\ convexrt.c supplies exactly those primitives and nothing else: it opens a
\ stream, moves bytes, reports readiness and reads a clock. It contains no
\ HTTP, no WebSocket framing and no Convex knowledge.
\
\ Every policy lives here in Forth instead:
\
\   * An absolute deadline is captured before the first byte of an operation.
\     No amount of slow progress can extend it.
\   * A dribble deadline bounds how long a read may go without any forward
\     progress once a message is already partly consumed. A peer that sends one
\     byte at a time therefore fails on the dribble bound long before the
\     absolute one.
\   * Unconsumed bytes stay in the stream's inbound buffer. A timeout leaves
\     that buffer intact, so a partly read frame resumes where it stopped
\     rather than restarting at a byte that only looks like a boundary.

require convex-config.fth
require convex-error.fth
require convex-buffer.fth

require libcc.fs

\ The native surface. Every value crossing this boundary is a cell-sized
\ integer or an address, and the C side uses `long` throughout so the return
\ value is never a sign-extended 32-bit register.
c-library convexrt
    s" convexrt" add-lib
    \c extern long cvx_open(const char *host, const char *port, long tls, long deadline_ms);
    \c extern long cvx_adopt(long fd);
    \c extern long cvx_listen(const char *host, const char *port);
    \c extern long cvx_accept(long handle, long timeout_ms);
    \c extern long cvx_read(long handle, char *buffer, long length);
    \c extern long cvx_write(long handle, const char *buffer, long length);
    \c extern long cvx_poll(long h0, long w0, long h1, long w1, long h2, long w2, long timeout_ms);
    \c extern long cvx_close(long handle);
    \c extern long cvx_now_ms(void);
    \c extern long cvx_error_text(char *buffer, long length);
    \c extern void cvx_exit(long code);
    c-function native-open cvx_open a a n n -- n
    c-function native-adopt cvx_adopt n -- n
    c-function native-listen cvx_listen a a -- n
    c-function native-accept cvx_accept n n -- n
    c-function native-read cvx_read n a n -- n
    c-function native-write cvx_write n a n -- n
    c-function native-poll cvx_poll n n n n n n n -- n
    c-function native-close cvx_close n -- n
    c-function native-now cvx_now_ms -- n
    c-function native-error cvx_error_text a n -- n
    c-function native-exit cvx_exit n -- void
end-c-library

-1 constant io-again        \ open but not ready yet
-2 constant io-failed       \ unusable, must be closed

0 constant io-want-read
1 constant io-want-write

create native-error-scratch 256 allot

: native-error@ ( -- addr u )
    native-error-scratch 256 native-error
    native-error-scratch swap ;

\ Raise a TransportError that keeps the native detail attached, so a TLS
\ verification failure reaches the adapter as a message rather than as a bare
\ error number.
: io-fail ( addr u -- )
    msg-start msg+ s" : " msg+ native-error@ msg+
    s" TransportError" cvx-raise-msg ;

\ ---------------------------------------------------------------------------
\ Absolute deadlines
\ ---------------------------------------------------------------------------

: now ( -- ms )  native-now ;
: deadline+ ( ms -- absolute )  now + ;
: deadline-remaining ( absolute -- ms )  now - dup 0< if drop 0 then ;
: deadline-expired? ( absolute -- flag )  now - 0> 0= ;

\ ---------------------------------------------------------------------------
\ Streams
\ ---------------------------------------------------------------------------

0 cells constant st>handle
1 cells constant st>in       \ bytes received but not yet parsed
2 cells constant st>closed
3 cells constant st-size

: stream-handle ( stream -- handle )  st>handle + @ ;
: stream-in ( stream -- buf )  st>in + @ ;
: stream-closed? ( stream -- flag )  st>closed + @ ;
: stream-buffered ( stream -- u )  stream-in buf-len ;

: stream-wrap ( handle -- stream )
    st-size allocate throw { handle stream }
    handle stream st>handle + !
    4096 buf-new stream st>in + !
    false stream st>closed + !
    stream ;

: stream-open ( host-addr host-u port-addr port-u tls absolute -- stream )
    0 { host-addr host-count port-addr port-count tls absolute handle }
    host-addr host-count zscratch-host >z
    port-addr port-count zscratch-port >z
    tls absolute native-open to handle
    handle 0< if s" connect failed" io-fail then
    handle stream-wrap ;

\ Adopt an already open descriptor such as the adapter's stdin or stdout. The
\ native side switches it to non-blocking so the adapter can wait on the
\ controller stream and the Convex WebSocket in one place.
: stream-adopt ( fd -- stream )
    native-adopt dup 0< if s" adopt failed" io-fail then stream-wrap ;

: stream-close ( stream -- )
    dup 0= if drop exit then
    dup stream-closed? 0= if dup stream-handle native-close drop then
    true over st>closed + !
    dup stream-in buf-free
    free throw ;

\ Wait for one stream, never sleeping longer than one poll slice so an expired
\ deadline is always noticed promptly.
: stream-wait ( stream want absolute -- ready )
    0 { stream want absolute result }
    stream stream-handle want -1 0 -1 0
    absolute deadline-remaining cvx-poll-slice min
    native-poll to result
    result 0< if s" wait failed" io-fail then
    result 1 and 0<> ;

\ Wait for either of two streams. The adapter uses this so one worker owns the
\ controller stream and the WebSocket without either starving the other.
: stream-wait2 ( stream-a stream-b absolute -- mask )
    0 { stream-a stream-b absolute result }
    stream-a stream-handle io-want-read
    stream-b stream-handle io-want-read
    -1 0
    absolute deadline-remaining cvx-poll-slice min
    native-poll to result
    result 0< if s" wait failed" io-fail then
    result ;

\ Wait with nothing to watch. Used while a reconnect is held off by backoff, so
\ the owner loop waits instead of spinning on the clock.
: io-sleep ( ms -- )
    { ms }
    -1 0 -1 0 -1 0 ms native-poll drop ;

4096 constant io-chunk

\ One read attempt, waiting until the stream is readable or the deadline
\ passes. Returns the byte count, or 0 at end of stream.
: stream-read-once ( stream absolute -- got )
    0 0 0 { stream absolute in target result }
    stream stream-in to in
    begin
        io-chunk in buf-reserve to target
        stream stream-handle target io-chunk native-read to result
        result io-again =
    while
        absolute deadline-expired? if
            s" read timed out" cvx-raise-transport
        then
        stream io-want-read absolute stream-wait drop
    repeat
    result io-failed = if s" read failed" io-fail then
    result in buf-advance
    result ;

\ Read until the inbound buffer holds at least count bytes. The dribble bound
\ is refreshed on progress; the absolute bound never is.
: stream-need ( count stream absolute -- )
    0 0 { count stream absolute dribble got }
    cvx-dribble-deadline deadline+ to dribble
    begin stream stream-buffered count u< while
        stream  absolute dribble min  stream-read-once to got
        got 0= if
            s" connection closed before the expected bytes" cvx-raise-transport
        then
        cvx-dribble-deadline deadline+ to dribble
    repeat ;

\ Write every byte or fail. The deadline is absolute, so a peer that accepts
\ one byte per wakeup still fails instead of holding the socket owner forever.
: stream-write ( addr u stream absolute -- )
    0 0 { addr count stream absolute sent result }
    0 to sent
    begin sent count u< while
        stream stream-handle  addr sent +  count sent -  native-write to result
        result io-again = if
            absolute deadline-expired? if
                s" write timed out" cvx-raise-transport
            then
            stream io-want-write absolute stream-wait drop
        else
            result io-failed = if s" write failed" io-fail then
            result sent + to sent
        then
    repeat ;

\ Write whatever the peer will take right now and report how much that was.
\ The conformance adapter drains its outbox with this so a controller that has
\ stopped reading slows the adapter down instead of stalling it inside a write.
: stream-write-some ( addr u stream -- written )
    0 { addr count stream result }
    count 0= if 0 exit then
    stream stream-handle addr count native-write to result
    result io-again = if 0 exit then
    result io-failed = if s" write failed" io-fail then
    result ;

\ Read one line terminated by LF into line, without the CRLF, and consume it
\ from the stream. Used for the HTTP status line, HTTP headers and the
\ WebSocket upgrade response.
: stream-line ( stream absolute line -- )
    0 0 0 0 { stream absolute line in index dribble got }
    stream stream-in to in
    line buf-reset
    cvx-dribble-deadline deadline+ to dribble
    begin
        in buf-span 10 str-index to index
        index 0<
    while
        in buf-len cvx-max-header-bytes u> if
            s" header line exceeds the client limit" cvx-raise-protocol
        then
        stream  absolute dribble min  stream-read-once to got
        got 0= if
            s" connection closed inside headers" cvx-raise-transport
        then
        cvx-dribble-deadline deadline+ to dribble
    repeat
    in buf-data index line buf-append
    index 1+ in buf-consume
    line buf-len 0> if
        line buf-data line buf-len 1- + c@ 13 = if
            line buf-len 1- line buf>len + !
        then
    then ;

\ ---------------------------------------------------------------------------
\ Deployment addressing
\
\ A Convex deployment URL is parsed once into scheme, host and port. Both the
\ HTTP endpoint and the Live WebSocket dial the same parsed target, so they
\ cannot drift apart, and a URL carrying a path, a query or credentials is
\ rejected rather than silently ignored.
\ ---------------------------------------------------------------------------

0 cells constant dep>tls
1 cells constant dep>host
2 cells constant dep>port
3 cells constant dep-size

: deployment-tls? ( dep -- flag )  dep>tls + @ ;
: deployment-host ( dep -- addr u )  dep>host + @ buf-span ;
: deployment-port ( dep -- addr u )  dep>port + @ buf-span ;

: deployment-free ( dep -- )
    dup 0= if drop exit then
    dup dep>host + @ buf-free
    dup dep>port + @ buf-free
    free throw ;

: deployment-parse ( addr u -- dep )
    0 0 0 0 0 { addr count dep tls authority host-count colon }
    dep-size allocate throw to dep
    32 buf-new dep dep>host + !
    8 buf-new dep dep>port + !
    false to tls
    addr count s" https://" str-prefix? if
        true to tls
        addr 8 + to addr  count 8 - to count
    else
        addr count s" http://" str-prefix? 0= if
            s" deployment URL must start with http:// or https://" cvx-raise-protocol
        then
        addr 7 + to addr  count 7 - to count
    then
    tls dep dep>tls + !
    \ Everything up to the first slash is the authority. A trailing slash is
    \ accepted; any other path, query or userinfo is a configuration error.
    addr count [char] / str-index to authority
    authority 0< if count to authority then
    authority count <> authority 1+ count <> and if
        s" deployment URL must not contain a path" cvx-raise-protocol
    then
    addr authority [char] @ str-index 0< 0= if
        s" deployment URL must not contain credentials" cvx-raise-protocol
    then
    authority to count
    \ An IPv6 literal would need bracket stripping before the native resolver
    \ sees it. The demonstration deployments are named hosts, so this is a
    \ declared limitation rather than a half-implemented parse.
    addr count [char] [ str-index 0< 0= if
        s" IPv6 literal deployment URLs are not supported" cvx-raise-protocol
    then
    addr count [char] : str-last-index to colon
    colon 0< if count else colon then to host-count
    host-count 0= if
        s" deployment URL host must not be empty" cvx-raise-protocol
    then
    addr host-count dep dep>host + @ buf-append
    colon 0< if
        tls if s" 443" else s" 80" then
    else
        addr colon 1+ +  count colon 1+ -    ( port-addr port-count )
        2dup str>u                           ( port-addr port-count value flag )
        0= if
            drop 2drop
            s" deployment URL port must be numeric" cvx-raise-protocol
        then
        dup 0= over 65535 u> or if
            drop 2drop
            s" deployment URL port is out of range" cvx-raise-protocol
        then
        drop
    then
    dep dep>port + @ buf-append
    dep ;

: deployment-connect ( dep absolute -- stream )
    { dep absolute }
    dep deployment-host dep deployment-port
    dep deployment-tls? if 1 else 0 then
    absolute stream-open ;

\ ---------------------------------------------------------------------------
\ Listening, used only by the conformance adapter's TCP mode
\ ---------------------------------------------------------------------------

: listener-open ( host-addr host-u port-addr port-u -- handle )
    0 { host-addr host-count port-addr port-count handle }
    host-addr host-count zscratch-host >z
    port-addr port-count zscratch-port >z
    native-listen to handle
    handle 0< if s" listen failed" io-fail then
    handle ;

: listener-close ( handle -- )  native-close drop ;

: listener-accept ( handle absolute -- stream )
    0 { handle absolute result }
    begin
        handle absolute deadline-remaining cvx-poll-slice min native-accept
        to result
        result io-again =
    while
        absolute deadline-expired? if
            s" no controller connected before the deadline" cvx-raise-transport
        then
    repeat
    result 0< if s" accept failed" io-fail then
    result stream-wrap ;
