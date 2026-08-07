\ convex-buffer.fth - growable byte buffers and the string helpers the rest of
\ the Forth Convex client is written in.
\
\ Forth has no string type, so every layer above this file works in ( addr u )
\ byte ranges. A buffer adds the one thing those ranges cannot do on their
\ own: accumulate bytes whose final length is not known in advance, which is
\ exactly the shape of an HTTP response and of a fragmented WebSocket message.

require convex-config.fth
require convex-error.fth

\ ---------------------------------------------------------------------------
\ Byte buffers
\
\ Three cells: heap pointer, used length, capacity. Growth doubles so that
\ appending one byte at a time while streaming stays affordable.
\ ---------------------------------------------------------------------------

0 cells constant buf>data
1 cells constant buf>len
2 cells constant buf>cap
3 cells constant buf-size

: buf-data ( buf -- addr )  buf>data + @ ;
: buf-len ( buf -- u )  buf>len + @ ;
: buf-cap ( buf -- u )  buf>cap + @ ;
: buf-span ( buf -- addr u )  dup buf-data swap buf-len ;
: buf-reset ( buf -- )  buf>len + 0 swap ! ;
: buf-empty? ( buf -- flag )  buf-len 0= ;

: buf-new ( capacity -- buf )
    16 max  buf-size allocate throw  { capacity buf }
    capacity allocate throw  buf buf>data + !
    0 buf buf>len + !
    capacity buf buf>cap + !
    buf ;

: buf-free ( buf -- )
    dup 0= if drop exit then
    dup buf-data ?dup if free throw then
    free throw ;

\ Grow so that at least extra more bytes fit. The configured ceiling is
\ checked before any allocation, so a length taken from the wire can never
\ make the client reserve memory on a peer's behalf.
: buf-ensure ( extra buf -- )
    { extra buf }
    buf buf-len extra +
    dup cvx-max-buffer u> if
        drop s" buffered value exceeds the client byte limit" cvx-raise-protocol
    then
    dup buf buf-cap u> 0= if drop exit then
    buf buf-cap
    begin 2dup swap u< while 2* repeat
    nip
    buf buf-data over resize throw
    buf buf>data + !
    buf buf>cap + ! ;

: buf-append ( addr u buf -- )
    { source count buf }
    count 0= if exit then
    count buf buf-ensure
    source buf buf-data buf buf-len + count move
    count buf buf>len + +! ;

: buf-char ( c buf -- )
    { ch buf }
    1 buf buf-ensure
    ch buf buf-data buf buf-len + c!
    1 buf buf>len + +! ;

\ Reserve room and hand back the address to write into directly. The transport
\ layer reads straight into a buffer this way instead of through a bounce
\ buffer; buf-advance then commits however many bytes actually arrived.
: buf-reserve ( extra buf -- addr )
    { extra buf }
    extra buf buf-ensure
    buf buf-data buf buf-len + ;

: buf-advance ( count buf -- )  buf>len + +! ;

\ Release a buffer that grew for one large message. Without this a single
\ near-maximum Live value would keep its capacity resident for the rest of the
\ run, so the queue's byte accounting would understate real memory use.
4096 constant buf-retain

: buf-shrink ( buf -- )
    dup buf-cap buf-retain u> 0= if drop exit then
    dup buf-reset
    dup buf-data buf-retain resize throw
    over buf>data + !
    buf-retain swap buf>cap + ! ;

\ Drop the first count bytes. The HTTP and WebSocket readers parse a prefix and
\ consume it, keeping the unparsed remainder. That is what lets a read timeout
\ resume in the middle of a frame instead of restarting at a false boundary.
: buf-consume ( count buf -- )
    { count buf }
    count buf buf-len u> if buf buf-len to count then
    count 0= if exit then
    buf buf-data count +  buf buf-data  buf buf-len count -  move
    count negate buf buf>len + +! ;

\ ---------------------------------------------------------------------------
\ Byte range helpers
\ ---------------------------------------------------------------------------

: str= ( addr1 u1 addr2 u2 -- flag )  compare 0= ;

: str-prefix? ( addr u prefix-addr prefix-u -- flag )
    { addr count prefix-addr prefix-count }
    prefix-count count u> if false exit then
    addr prefix-count prefix-addr prefix-count str= ;

\ HTTP header names arrive in any case, so comparisons on them must fold case.
: lower ( c -- c )  dup [char] A [char] Z 1+ within if 32 + then ;

: istr= ( addr1 u1 addr2 u2 -- flag )
    { addr1 count1 addr2 count2 }
    count1 count2 <> if false exit then
    true
    count1 0 ?do
        addr1 i + c@ lower  addr2 i + c@ lower  <> if drop false leave then
    loop ;

: str-index ( addr u c -- index )       \ -1 when the byte is absent
    { addr count ch }
    -1
    count 0 ?do
        addr i + c@ ch = if drop i leave then
    loop ;

: str-last-index ( addr u c -- index )  \ -1 when the byte is absent
    { addr count ch }
    -1
    count 0 ?do
        count 1- i -  dup addr + c@ ch = if nip leave else drop then
    loop ;

: space? ( c -- flag )  dup bl = swap 9 = or ;

: str-trim ( addr u -- addr u )         \ strip leading and trailing blanks
    { addr count }
    begin
        count 0> if addr c@ space? else false then
    while
        addr 1+ to addr  count 1- to count
    repeat
    begin
        count 0> if addr count 1- + c@ space? else false then
    while
        count 1- to count
    repeat
    addr count ;

\ Parse a non-negative decimal, rejecting anything that is not entirely
\ digits. HTTP status codes, Content-Length and ports all use this: a lenient
\ parse would let malformed framing through as a plausible number.
: str>u ( addr u -- value flag )
    { addr count }
    count 0= if 0 false exit then
    count cvx-max-digits u> if 0 false exit then
    0
    count 0 ?do
        addr i + c@ dup [char] 0 [char] 9 1+ within 0= if
            2drop 0 false unloop exit
        then
        [char] 0 - swap 10 * +
    loop
    true ;

\ ---------------------------------------------------------------------------
\ Zero-terminated copies for the native transport layer
\
\ Only a host name and a port number ever cross into C. Both are bounded here
\ so a hostile deployment URL cannot overrun the scratch area.
\ ---------------------------------------------------------------------------

create zscratch-host cvx-max-zstring 1+ allot
create zscratch-port cvx-max-zstring 1+ allot

: >z ( addr u destination -- destination )
    { source count destination }
    count cvx-max-zstring u> if
        s" host or port text is too long" cvx-raise-protocol
    then
    source destination count move
    0 destination count + c!
    destination ;

\ ---------------------------------------------------------------------------
\ Hexadecimal, randomness and decimal output
\ ---------------------------------------------------------------------------

: hex-digits ( -- addr )  s" 0123456789abcdef" drop ;
: >hex-digit ( n -- c )  hex-digits + c@ ;

: bytes>buf-hex ( addr u buf -- )
    { source count buf }
    count 0 ?do
        source i + c@
        dup 4 rshift >hex-digit buf buf-char
        15 and >hex-digit buf buf-char
    loop ;

create random-scratch cvx-max-random allot

\ A session id and a mutation idempotency key both need unpredictable bytes.
\ Reading /dev/urandom keeps that inside Forth rather than delegating to a
\ shell, and a short read is a hard failure instead of a weaker identifier.
: random-bytes ( addr u -- )
    0 0 0 { destination count fd got ior }
    s" /dev/urandom" r/o open-file throw to fd
    destination count fd read-file to ior to got
    fd close-file drop
    ior throw
    got count <> if
        s" could not read /dev/urandom" cvx-raise-transport
    then ;

: random-hex ( byte-count buf -- )      \ appends twice byte-count hex digits
    { count buf }
    count cvx-max-random u> if
        s" random identifier is too long" cvx-raise-protocol
    then
    random-scratch count random-bytes
    random-scratch count buf bytes>buf-hex ;

\ Forth's `.` appends a space, which would corrupt the canonical example's
\ byte-for-byte stdout comparison. These never do.
: u>string ( u -- addr len )  0 <# #s #> ;
: n>string ( n -- addr len )  dup abs 0 <# #s rot sign #> ;
: u-type ( u -- )  u>string type ;
: n-type ( n -- )  n>string type ;
: u>buf ( u buf -- )  { buf } u>string buf buf-append ;
: n>buf ( n buf -- )  { buf } n>string buf buf-append ;
