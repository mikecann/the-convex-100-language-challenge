\ convex-ws.fth - RFC 6455 in Forth: SHA-1, base64, the upgrade handshake and
\ an incremental frame codec.
\
\ The framing is small enough to audit directly, and writing it here rather
\ than delegating to another runtime is what keeps Convex Live a native Forth
\ capability.
\
\ The codec never consumes a byte until the entire frame is buffered. That one
\ rule is what makes a mid-frame timeout safe: the partial frame stays in the
\ stream's inbound buffer, and the next attempt resumes at the same offset
\ instead of re-synchronising on a byte that only looks like a frame header. A
\ frame's declared payload length is validated against the configured ceiling
\ before any payload byte is requested, so an inflated length header can never
\ make the client reserve memory on a peer's behalf.

require convex-config.fth
require convex-error.fth
require convex-buffer.fth
require convex-json.fth
require convex-io.fth

\ ---------------------------------------------------------------------------
\ 32-bit arithmetic on 64-bit cells
\ ---------------------------------------------------------------------------

: u32 ( x -- x )  $FFFFFFFF and ;

: rotl32 ( x count -- x )
    2dup lshift u32
    -rot 32 swap - rshift
    or ;

\ ---------------------------------------------------------------------------
\ SHA-1, needed only to compute and check Sec-WebSocket-Accept
\ ---------------------------------------------------------------------------

create sha-w 80 cells allot
create sha-h 5 cells allot
create sha-block 64 allot

: sha-init ( -- )
    $67452301 sha-h !
    $EFCDAB89 sha-h 1 cells + !
    $98BADCFE sha-h 2 cells + !
    $10325476 sha-h 3 cells + !
    $C3D2E1F0 sha-h 4 cells + ! ;

: sha-compress ( addr -- )
    0 0 0 0 0 0 0 0 { addr a b c d e f k temp }
    16 0 ?do
        addr i 4 * + c@ 24 lshift
        addr i 4 * + 1+ c@ 16 lshift or
        addr i 4 * + 2 + c@ 8 lshift or
        addr i 4 * + 3 + c@ or
        sha-w i cells + !
    loop
    80 16 ?do
        sha-w i 3 - cells + @
        sha-w i 8 - cells + @ xor
        sha-w i 14 - cells + @ xor
        sha-w i 16 - cells + @ xor
        1 rotl32 sha-w i cells + !
    loop
    sha-h @ to a
    sha-h 1 cells + @ to b
    sha-h 2 cells + @ to c
    sha-h 3 cells + @ to d
    sha-h 4 cells + @ to e
    80 0 ?do
        i 20 < if
            b c and  b invert d and  or u32 to f
            $5A827999 to k
        else i 40 < if
            b c xor d xor to f
            $6ED9EBA1 to k
        else i 60 < if
            b c and  b d and or  c d and or to f
            $8F1BBCDC to k
        else
            b c xor d xor to f
            $CA62C1D6 to k
        then then then
        a 5 rotl32  f +  e +  k +  sha-w i cells + @ +  u32 to temp
        d to e
        c to d
        b 30 rotl32 to c
        a to b
        temp to a
    loop
    sha-h @ a + u32 sha-h !
    sha-h 1 cells + @ b + u32 sha-h 1 cells + !
    sha-h 2 cells + @ c + u32 sha-h 2 cells + !
    sha-h 3 cells + @ d + u32 sha-h 3 cells + !
    sha-h 4 cells + @ e + u32 sha-h 4 cells + ! ;

: sha1 ( addr u destination -- )        \ destination receives 20 bytes
    0 0 0 { addr count destination blocks remainder bits }
    sha-init
    count 64 / to blocks
    blocks 0 ?do addr i 64 * + sha-compress loop
    count 64 mod to remainder
    sha-block 64 erase
    addr blocks 64 * +  sha-block  remainder move
    $80 sha-block remainder + c!
    remainder 56 u< 0= if
        sha-block sha-compress
        sha-block 64 erase
    then
    count 8 * to bits
    8 0 ?do
        bits 56 i 8 * - rshift 255 and  sha-block 56 i + + c!
    loop
    sha-block sha-compress
    5 0 ?do
        sha-h i cells + @
        dup 24 rshift 255 and  destination i 4 * + c!
        dup 16 rshift 255 and  destination i 4 * + 1+ c!
        dup 8 rshift 255 and   destination i 4 * + 2 + c!
        255 and                destination i 4 * + 3 + c!
    loop ;

\ ---------------------------------------------------------------------------
\ Base64
\ ---------------------------------------------------------------------------

: b64-alphabet ( -- addr )
    s" ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" drop ;

: base64-encode ( addr u buf -- )
    0 0 0 { addr count buf index remaining chunk }
    0 to index
    begin index count u< while
        count index - to remaining
        addr index + c@ 16 lshift to chunk
        remaining 1 > if chunk addr index 1+ + c@ 8 lshift or to chunk then
        remaining 2 > if chunk addr index 2 + + c@ or to chunk then
        chunk 18 rshift 63 and b64-alphabet + c@ buf buf-char
        chunk 12 rshift 63 and b64-alphabet + c@ buf buf-char
        remaining 1 > if
            chunk 6 rshift 63 and b64-alphabet + c@ buf buf-char
        else
            [char] = buf buf-char
        then
        remaining 2 > if
            chunk 63 and b64-alphabet + c@ buf buf-char
        else
            [char] = buf buf-char
        then
        index 3 + to index
    repeat ;

\ ---------------------------------------------------------------------------
\ Connection state
\ ---------------------------------------------------------------------------

0 constant ws-opcode-continuation
1 constant ws-opcode-text
2 constant ws-opcode-binary
8 constant ws-opcode-close
9 constant ws-opcode-ping
10 constant ws-opcode-pong

\ ws-pump results
0 constant ws-idle             \ nothing complete arrived before the deadline
1 constant ws-got-message      \ a whole text message is in the message buffer
2 constant ws-got-close        \ the peer sent a close frame

0 cells constant ws>stream
1 cells constant ws>fragment-opcode   \ 0 when no message is being reassembled
2 cells constant ws>fragment-buf
3 cells constant ws>fragment-count
4 cells constant ws>frame-buf         \ payload of the frame just decoded
5 cells constant ws>message-buf       \ complete message handed to the caller
6 cells constant ws>out-buf           \ scratch for one outgoing frame
7 cells constant ws>closed
8 cells constant ws-size

: ws-stream ( ws -- stream )  ws>stream + @ ;
: ws-fragment-buf ( ws -- buf )  ws>fragment-buf + @ ;
: ws-frame-buf ( ws -- buf )  ws>frame-buf + @ ;
: ws-message-buf ( ws -- buf )  ws>message-buf + @ ;
: ws-message@ ( ws -- addr u )  ws-message-buf buf-span ;
: ws-out-buf ( ws -- buf )  ws>out-buf + @ ;
: ws-closed? ( ws -- flag )  ws>closed + @ ;

: ws-reset-fragments ( ws -- )
    dup ws-fragment-buf buf-reset
    0 over ws>fragment-opcode + !
    0 swap ws>fragment-count + ! ;

: ws-new ( stream -- ws )
    ws-size allocate throw { stream ws }
    stream ws ws>stream + !
    0 ws ws>fragment-opcode + !
    4096 buf-new ws ws>fragment-buf + !
    0 ws ws>fragment-count + !
    4096 buf-new ws ws>frame-buf + !
    4096 buf-new ws ws>message-buf + !
    4096 buf-new ws ws>out-buf + !
    false ws ws>closed + !
    ws ;

: ws-free ( ws -- )
    dup 0= if drop exit then
    dup ws-fragment-buf buf-free
    dup ws-frame-buf buf-free
    dup ws-message-buf buf-free
    dup ws-out-buf buf-free
    dup ws-stream stream-close
    free throw ;

\ ---------------------------------------------------------------------------
\ Sending
\
\ Every client frame is masked with four fresh random bytes, as RFC 6455
\ requires. A frame is composed whole in one buffer and written under a single
\ absolute deadline, so two frames can never interleave on the wire.
\ ---------------------------------------------------------------------------

create ws-mask 4 allot

: ws-write-length ( length opcode buf -- )
    { length opcode buf }
    $80 opcode or buf buf-char
    length 126 u< if
        $80 length or buf buf-char
    else
        length 65536 u< if
            $FE buf buf-char
            length 8 rshift 255 and buf buf-char
            length 255 and buf buf-char
        else
            $FF buf buf-char
            8 0 ?do
                length 56 i 8 * - rshift 255 and buf buf-char
            loop
        then
    then ;

: ws-send-frame ( addr u opcode ws absolute -- )
    0 { addr count opcode ws absolute out }
    ws ws-closed? if s" Live WebSocket is closed" cvx-raise-transport then
    count cvx-max-frame-bytes u> if
        s" outgoing WebSocket frame is too large" cvx-raise-protocol
    then
    ws ws-out-buf to out
    out buf-reset
    count opcode out ws-write-length
    ws-mask 4 random-bytes
    ws-mask 4 out buf-append
    count 0 ?do
        addr i + c@  ws-mask i 4 mod + c@  xor  out buf-char
    loop
    out buf-span ws ws-stream absolute stream-write ;

: ws-send-text ( addr u ws absolute -- )
    { addr count ws absolute }
    addr count ws-opcode-text ws absolute ws-send-frame ;

: ws-send-pong ( addr u ws absolute -- )
    { addr count ws absolute }
    addr count ws-opcode-pong ws absolute ws-send-frame ;

create ws-close-payload 2 allot

\ 1000 is the normal closure status. Sending it before dropping the socket is
\ what makes an ordinary client close bounded and polite rather than a reset.
: ws-send-close ( ws absolute -- )
    { ws absolute }
    1000 8 rshift ws-close-payload c!
    1000 255 and ws-close-payload 1+ c!
    ws-close-payload 2 ws-opcode-close ws absolute ws-send-frame ;

\ ---------------------------------------------------------------------------
\ The upgrade handshake
\
\ Handshake scratch buffers are allocated once. The client dials one Live
\ socket at a time, and reusing these buffers means a failed handshake in a
\ reconnect loop cannot leak a buffer per attempt.
\ ---------------------------------------------------------------------------

: ws-guid ( -- addr u )  s" 258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ;

create ws-key-bytes 16 allot
create ws-digest 20 allot

64 buf-new constant ws-key-buf
64 buf-new constant ws-accept-buf
1024 buf-new constant ws-line-buf
2048 buf-new constant ws-request-buf

variable ws-pending-stream
variable ws-pending-dep
variable ws-pending-path
variable ws-pending-path-len
variable ws-pending-deadline

: ws-request ( dep path-addr path-u buf -- )
    { dep path-addr path-count buf }
    buf buf-reset
    s" GET " buf buf-append
    path-addr path-count buf buf-append
    s\"  HTTP/1.1\r\nHost: " buf buf-append
    dep deployment-host buf buf-append
    dep deployment-tls? if s" 443" else s" 80" then
    dep deployment-port str= 0= if
        [char] : buf buf-char
        dep deployment-port buf buf-append
    then
    s\" \r\nUpgrade: websocket" buf buf-append
    s\" \r\nConnection: Upgrade" buf buf-append
    s\" \r\nSec-WebSocket-Version: 13" buf buf-append
    s\" \r\nSec-WebSocket-Key: " buf buf-append
    ws-key-buf buf-span buf buf-append
    s\" \r\nConvex-Client: " buf buf-append
    cvx-client-version buf buf-append
    s\" \r\n\r\n" buf buf-append ;

\ Read and validate the 101 response. Anything other than switching protocols,
\ a websocket upgrade and the exact expected accept value is a transport
\ failure, because framing arbitrary bytes afterwards would be worse than
\ failing here.
: ws-read-response ( stream absolute -- )
    0 0 0 0 0 0 0 0 0 { stream absolute
       saw-upgrade saw-connection saw-accept lines colon name-addr name-count value-addr
       value-count }
    false to saw-upgrade  false to saw-connection  false to saw-accept
    0 to lines
    stream absolute ws-line-buf stream-line
    ws-line-buf buf-span s" HTTP/1.1 101" str-prefix?
    ws-line-buf buf-span s" HTTP/1.0 101" str-prefix? or 0= if
        s" WebSocket upgrade was rejected" cvx-raise-transport
    then
    begin
        stream absolute ws-line-buf stream-line
        ws-line-buf buf-len 0>
    while
        lines 1+ to lines
        lines cvx-max-header-lines u> if
            s" too many WebSocket response headers" cvx-raise-protocol
        then
        ws-line-buf buf-span [char] : str-index to colon
        colon 0< 0= if
            ws-line-buf buf-data to name-addr
            colon to name-count
            ws-line-buf buf-data colon + 1+
            ws-line-buf buf-len colon - 1-
            str-trim to value-count to value-addr
            name-addr name-count s" Upgrade" istr= if
                value-addr value-count s" websocket" istr= if
                    true to saw-upgrade
                then
            then
            name-addr name-count s" Connection" istr= if
                value-addr value-count s" Upgrade" istr= if
                    true to saw-connection
                then
            then
            name-addr name-count s" Sec-WebSocket-Accept" istr= if
                value-addr value-count ws-accept-buf buf-span str= if
                    true to saw-accept
                then
            then
            name-addr name-count s" Sec-WebSocket-Extensions" istr= if
                s" server negotiated an unsupported WebSocket extension"
                cvx-raise-protocol
            then
        then
    repeat
    saw-upgrade saw-connection and saw-accept and 0= if
        s" WebSocket upgrade response was incomplete" cvx-raise-transport
    then ;

: ws-handshake ( -- )
    ws-key-buf buf-reset
    ws-accept-buf buf-reset
    ws-key-bytes 16 random-bytes
    ws-key-bytes 16 ws-key-buf base64-encode
    \ Sec-WebSocket-Accept is base64(sha1(key + GUID)). Computing it here is
    \ what proves the peer really completed a WebSocket handshake rather than
    \ returning an opportunistic 101.
    ws-key-buf buf-span ws-accept-buf buf-append
    ws-guid ws-accept-buf buf-append
    ws-accept-buf buf-span ws-digest sha1
    ws-accept-buf buf-reset
    ws-digest 20 ws-accept-buf base64-encode
    ws-pending-dep @ ws-pending-path @ ws-pending-path-len @ ws-request-buf
    ws-request
    ws-request-buf buf-span
    ws-pending-stream @ ws-pending-deadline @ stream-write
    ws-pending-stream @ ws-pending-deadline @ ws-read-response ;

: ws-connect ( dep path-addr path-u absolute -- ws )
    0 { dep path-addr path-count absolute code }
    dep ws-pending-dep !
    path-addr ws-pending-path !
    path-count ws-pending-path-len !
    absolute ws-pending-deadline !
    dep absolute deployment-connect ws-pending-stream !
    ['] ws-handshake catch to code
    code 0<> if
        ws-pending-stream @ stream-close
        0 ws-pending-stream !
        code throw
    then
    ws-pending-stream @ ws-new ;

\ ---------------------------------------------------------------------------
\ Receiving
\
\ ws-frame-complete? decides whether a whole frame is buffered and, as a side
\ effect, records its header size and payload length for ws-read-frame. The
\ two words are always called as a pair on the same connection from the single
\ socket owner, so sharing that state is safe and keeps the length validation
\ in exactly one place.
\ ---------------------------------------------------------------------------

variable ws-header-size
variable ws-payload-size

: ws-frame-complete? ( ws -- flag )
    0 0 0 0 { ws in available length header }
    ws ws-stream stream-in to in
    in buf-len to available
    available 2 u< if false exit then
    in buf-data 1+ c@ $7F and to length
    2 to header
    length 126 = if
        available 4 u< if false exit then
        4 to header
        in buf-data 2 + c@ 8 lshift  in buf-data 3 + c@ or to length
    else length 127 = if
        available 10 u< if false exit then
        10 to header
        0
        8 0 ?do 8 lshift  in buf-data 2 + i + c@ or loop
        to length
    then then
    length 0< if
        s" WebSocket frame length has the high bit set" cvx-raise-protocol
    then
    length cvx-max-frame-bytes u> if
        s" WebSocket frame exceeds the declared frame limit" cvx-raise-protocol
    then
    header ws-header-size !
    length ws-payload-size !
    available header length + u< 0= ;

: ws-read-frame ( ws -- fin opcode )
    0 0 0 0 0 0 { ws in header length first opcode fin }
    ws ws-stream stream-in to in
    ws-header-size @ to header
    ws-payload-size @ to length
    in buf-data c@ to first
    first $70 and 0<> if
        s" WebSocket reserved bits were set" cvx-raise-protocol
    then
    in buf-data 1+ c@ $80 and 0<> if
        s" server WebSocket frame was masked" cvx-raise-protocol
    then
    first $0F and to opcode
    first $80 and 0<> to fin
    opcode 8 u< 0= if
        fin 0= if
            s" fragmented WebSocket control frame" cvx-raise-protocol
        then
        length 125 u> if
            s" oversized WebSocket control frame" cvx-raise-protocol
        then
    then
    ws ws-frame-buf buf-reset
    in buf-data header +  length  ws ws-frame-buf buf-append
    header length + in buf-consume
    fin opcode ;

: ws-close-payload-valid? ( addr u -- flag )
    { addr count }
    count 0= if true exit then
    count 1 = if false exit then
    count 125 u> if false exit then
    addr 2 + count 2 - utf8-valid? ;

: ws-add-fragment ( addr u ws -- )
    { addr count ws }
    ws ws-fragment-buf buf-len count + cvx-max-message-bytes u> if
        s" fragmented Live message exceeds the message limit" cvx-raise-protocol
    then
    ws ws>fragment-count + @ 1+ dup cvx-max-fragments u> if
        drop s" fragmented Live message has too many frames" cvx-raise-protocol
    then
    ws ws>fragment-count + !
    addr count ws ws-fragment-buf buf-append ;

: ws-publish ( addr u ws -- )
    { addr count ws }
    addr count utf8-valid? 0= if
        s" Live text message is not valid UTF-8" cvx-raise-protocol
    then
    ws ws-message-buf buf-reset
    addr count ws ws-message-buf buf-append ;

\ Move the connection forward until a complete text message is available, the
\ peer closes, or the deadline passes. Ping is answered here so a Convex
\ deployment never sees the client as unresponsive while it is only waiting.
\ Returning ws-idle on a mid-frame deadline is safe precisely because nothing
\ has been consumed from the inbound buffer.
: ws-pump ( ws absolute -- result )
    0 0 { ws absolute fin opcode }
    begin
        ws ws-frame-complete? if
            ws ws-read-frame to opcode to fin
            opcode ws-opcode-ping = if
                ws ws-frame-buf buf-span ws absolute ws-send-pong
            else opcode ws-opcode-pong = if
                \ An unsolicited pong is a valid keepalive; nothing to do.
            else opcode ws-opcode-close = if
                ws ws-frame-buf buf-span ws-close-payload-valid? 0= if
                    s" invalid WebSocket close payload" cvx-raise-protocol
                then
                true ws ws>closed + !
                ws-got-close exit
            else opcode ws-opcode-binary = if
                s" binary Live messages are unsupported" cvx-raise-protocol
            else opcode ws-opcode-text = if
                ws ws>fragment-opcode + @ 0<> if
                    s" WebSocket fragments arrived out of order" cvx-raise-protocol
                then
                fin if
                    ws ws-frame-buf buf-span ws ws-publish
                    ws-got-message exit
                else
                    ws ws-reset-fragments
                    ws-opcode-text ws ws>fragment-opcode + !
                    ws ws-frame-buf buf-span ws ws-add-fragment
                then
            else opcode ws-opcode-continuation = if
                ws ws>fragment-opcode + @ 0= if
                    s" WebSocket continuation without a first frame"
                    cvx-raise-protocol
                then
                ws ws-frame-buf buf-span ws ws-add-fragment
                fin if
                    ws ws-fragment-buf buf-span ws ws-publish
                    ws ws-reset-fragments
                    ws-got-message exit
                then
            else
                s" unsupported WebSocket opcode" cvx-raise-protocol
            then then then then then then
        else
            absolute deadline-expired? if ws-idle exit then
            ws ws-stream io-want-read absolute stream-wait if
                ws ws-stream absolute stream-read-once 0= if
                    s" Live connection closed by the peer" cvx-raise-transport
                then
            then
        then
    again ;
