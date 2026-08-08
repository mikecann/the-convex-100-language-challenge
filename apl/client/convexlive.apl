#!/usr/local/bin/apl --script
⍝!
⍝ Convex from GNU APL: Live (the WebSocket /api/sync subscription
⍝ protocol).
⍝
⍝ Loaded with )COPY the same way client/convex.apl is, and after it --
⍝ this file uses convex.apl's connection (Conn*), JSON (J*), and URL
⍝ (UrlParse) helpers directly rather than redefining them.
⍝
⍝ RFC 6455 (the WebSocket handshake and frame format) and the Convex
⍝ sync-protocol state machine (Connect/ModifyQuerySet/Transition,
⍝ reconnect with backoff, the subscription table) are both implemented
⍝ here, in APL. The only things delegated outside APL are SHA-1 (the
⍝ handshake's Sec-WebSocket-Accept check) and CSPRNG bytes (the
⍝ handshake key and every frame's masking key), both via the native
⍝ CONVEXTLS function in client/shim.cc, on the same reasoning that puts
⍝ TLS itself there instead of in APL.
⍝
⍝ Single-worker ownership without threads: GNU APL has no way to call a
⍝ function through a runtime-computed pointer and so, like this
⍝ project's XPL client, has no threads of its own. Rather than
⍝ approximate a background worker thread, the WHOLE PROCESS (the
⍝ conformance adapter's command loop, or the canonical example's linear
⍝ script) is the one worker: LiveServiceTick performs at most one
⍝ non-blocking read of the socket and drains whatever complete frames
⍝ that produced, and every subscribe/unsubscribe/debugDisconnect call
⍝ runs to completion (updating the subscription table, and sending on
⍝ the socket if connected) before the caller's next statement -- there
⍝ is no separate thread that could ever touch LVCONN/LVSUBS
⍝ concurrently with the one that's already running. This trivially
⍝ satisfies "one worker owns the socket": there is only ever one worker
⍝ in this process at all. It also trivially satisfies "invalidate the
⍝ old relay before the acknowledgement": LiveUnsubscribe removes the
⍝ subscription-table entry before returning, and ProcessTransition
⍝ looks a queryId up in that same table synchronously, so a caller
⍝ that has already unsubscribed can never receive a stale delivery for
⍝ it -- there is no separate relay to race in the first place.
⍝
⍝ ⎕FIO[40] (select) is not used here either, for the same reason
⍝ documented in client/convex.apl's ConnConnect: it reliably raised
⍝ DOMAIN ERROR in this build. LiveServiceTick instead polls with one
⍝ ConnRecv call per tick at a zero-millisecond timeout (a single
⍝ non-blocking recv(), returning immediately either way) -- the same
⍝ non-blocking fcntl()+recv() pattern client/convex.apl's own transport
⍝ already uses, just called once per tick instead of looped to a
⍝ deadline.
⍝
⍝ Delivery buffering: this client keeps no separate delivery queue.
⍝ LiveServiceTick returns delivered (subscriptionId kind payload)
⍝ triples straight from the one non-blocking recv() it just performed;
⍝ the caller (the adapter or the example) writes them out immediately.
⍝ The only buffering is therefore the kernel's own socket receive
⍝ buffer -- bounded by the OS, not by anything this client allocates --
⍝ plus a conservative 4 MiB cap (WSMAXMESSAGE below) on any one
⍝ reassembled message and the raw frame-stream buffer, comfortably
⍝ under the shared 128 MiB budget even with a stopped reader.

⍝ ================================================================
⍝ Crypto/encoding: Base64, SHA-1, CSPRNG bytes
⍝ ================================================================

⍝ Standard Base64 (RFC 4648 with '='-padding), vectorised with ⊤/⊥
⍝ (encode/decode into 8-bit then regroup into 6-bit bit planes) rather
⍝ than a byte-at-a-time loop -- verified against the RFC 6455 own
⍝ handshake test vector during development (see the "Toolchain" note
⍝ in README.md).
∇Z←Base64Encode BYTES;N;PAD;PADDED;M;BITS;SEXT;ALPHA;NCHARS
  N←⍴BYTES
  →(N>0)⍴NONEMPTY
  Z←''
  →0
NONEMPTY:
  PAD←3|-N                         ⍝ zero bytes of padding needed: 0, 1, or 2
  PADDED←BYTES,(PAD⍴0)
  M←(⍴PADDED)×8÷6                  ⍝ exact: ⍴PADDED is always a multiple of 3
  BITS←,⍉(8⍴2)⊤PADDED              ⍝ every padded byte's bits, MSB first, concatenated
  SEXT←(6⍴2)⊥⍉(M,6)⍴BITS           ⍝ regrouped into M 6-bit values, 0..63
  ALPHA←'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  Z←ALPHA[SEXT+1]
  NCHARS←⍴Z
  →(PAD=0)⍴0
  →(PAD=1)⍴PAD1
  Z←((NCHARS-2)↑Z),'=='
  →0
PAD1:
  Z←((NCHARS-1)↑Z),'='
∇

⍝ SHA-1 digest of an integer byte vector, via the native CONVEXTLS[5]
⍝ (OpenSSL EVP_sha1 -- see shim.cc's own header comment on why this one
⍝ general-purpose primitive is delegated). Returns a 20-element integer
⍝ byte vector.
∇Z←Sha1 BYTES;R
  R←CONVEXTLS[5] BYTES
  Z←BytesOfStr 2↓R
∇

⍝ N bytes of CSPRNG output (native CONVEXTLS[7], OpenSSL RAND_bytes).
∇Z←RandomBytes N;R
  R←CONVEXTLS[7] N
  Z←BytesOfStr 2↓R
∇

⍝ RFC 6455 5.2.2: base64(sha1(key ++ the fixed handshake GUID)).
∇Z←WsAcceptValue KEY
  Z←Base64Encode Sha1 BytesOfStr KEY,'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
∇

⍝ A version-4 UUID from CSPRNG bytes (RFC 4122 ⌗4.4), used only as a
⍝ per-connection sessionId Convex's Connect message carries -- this
⍝ client never parses one back, so nothing here needs to be
⍝ cryptographically unpredictable, only unique per connection.
∇Z←HexPad2 B;DIGITS;HEXCHARS
  HEXCHARS←'0123456789abcdef'
  DIGITS←(2⍴16)⊤B
  Z←HEXCHARS[DIGITS+1]
∇

∇Z←Uuid4;B;H
  B←RandomBytes 16
  B[7]←64+(15|7⊃B)                 ⍝ version nibble = 0100
  B[9]←128+(63|9⊃B)                ⍝ variant bits = 10
  H←⍬
  H←H,⊂HexPad2 1⊃B ⋄ H←H,⊂HexPad2 2⊃B ⋄ H←H,⊂HexPad2 3⊃B ⋄ H←H,⊂HexPad2 4⊃B
  H←H,⊂'-'
  H←H,⊂HexPad2 5⊃B ⋄ H←H,⊂HexPad2 6⊃B
  H←H,⊂'-'
  H←H,⊂HexPad2 7⊃B ⋄ H←H,⊂HexPad2 8⊃B
  H←H,⊂'-'
  H←H,⊂HexPad2 9⊃B ⋄ H←H,⊂HexPad2 10⊃B
  H←H,⊂'-'
  H←H,⊂HexPad2 11⊃B ⋄ H←H,⊂HexPad2 12⊃B ⋄ H←H,⊂HexPad2 13⊃B
  H←H,⊂HexPad2 14⊃B ⋄ H←H,⊂HexPad2 15⊃B ⋄ H←H,⊂HexPad2 16⊃B
  Z←⊃,/H
∇

⍝ ================================================================
⍝ RFC 6455 frames: masking, encode, decode
⍝ ================================================================

WSOPCONT←0 ⋄ WSOPTEXT←1 ⋄ WSOPCLOSE←8 ⋄ WSOPPING←9 ⋄ WSOPPONG←10
WSMAXFRAME←4194304                 ⍝ 4 MiB: comfortably above one Convex frame
WSMAXMESSAGE←4194304               ⍝ 4 MiB: bound on one reassembled message

⍝ XORs BYTES with MASK (a 4-element integer vector) repeated cyclically
⍝ -- the same operation masks an outgoing frame and unmasks an incoming
⍝ one, since XOR is its own inverse. Vectorised via bit-plane
⍝ decomposition (⊤/⊥/≠) across the whole payload at once rather than a
⍝ byte-at-a-time loop, in keeping with this client's array-language
⍝ idiom; verified against a hand-computed XOR during development.
∇Z←BYTES WsXorMask MASK;N;MASKREP;BITSDATA;BITSMASK
  N←⍴BYTES
  →(N>0)⍴NONEMPTY
  Z←⍬
  →0
NONEMPTY:
  MASKREP←MASK[1+4|(⍳N)-1]
  BITSDATA←(8⍴2)⊤BYTES
  BITSMASK←(8⍴2)⊤MASKREP
  Z←2⊥BITSDATA≠BITSMASK
∇

⍝ Builds one complete client-to-server frame (always masked, per RFC
⍝ 6455 5.1) carrying PAYLOAD (an integer byte vector) with the given
⍝ OPCODE and FIN bit. A fresh CSPRNG mask key is drawn for every frame.
⍝ Left argument is (opcode fin): a GNU APL function header cannot
⍝ destructure a parenthesized strand into two formal names directly
⍝ ("DEFN ERROR", discovered by an end-to-end run against a real
⍝ backend -- everything inside the ∇ silently fell through to
⍝ immediate execution instead), so OPCODE/FIN are picked out of the
⍝ single left-argument name LEFT in the body instead.
∇Z←LEFT WsBuildFrame PAYLOAD;OPCODE;FIN;LEN;HDR;MASK
  OPCODE←1⊃LEFT
  FIN←2⊃LEFT
  LEN←⍴PAYLOAD
  HDR←,(128×FIN)+OPCODE
  MASK←RandomBytes 4
  →(LEN<126)⍴SHORTLEN
  →(LEN<65536)⍴MEDLEN
  HDR←HDR,(128+127)
  HDR←HDR,0,0,0,0
  HDR←HDR,(256|⌊LEN÷16777216),(256|⌊LEN÷65536),(256|⌊LEN÷256),(256|LEN)
  →BUILT
MEDLEN:
  HDR←HDR,(128+126)
  HDR←HDR,(256|⌊LEN÷256),(256|LEN)
  →BUILT
SHORTLEN:
  HDR←HDR,(128+LEN)
BUILT:
  Z←HDR,MASK,(PAYLOAD WsXorMask MASK)
∇

∇Z←CONN WsSendFrame PARAMS;OPCODE;FIN;PAYLOAD;FRAME;SR
  OPCODE←1⊃PARAMS
  FIN←2⊃PARAMS
  PAYLOAD←3⊃PARAMS
  FRAME←(OPCODE FIN) WsBuildFrame PAYLOAD
  SR←CONN ConnSendAll FRAME
  Z←'k'≡1⊃SR
∇

∇Z←CONN WsSendText TEXT
  Z←CONN WsSendFrame (WSOPTEXT 1 (BytesOfStr TEXT))
∇

∇Z←CONN WsSendClose DUMMY
  Z←CONN WsSendFrame (WSOPCLOSE 1 ⍬)
∇

∇Z←CONN WsSendPong PAYLOAD
  Z←CONN WsSendFrame (WSOPPONG 1 PAYLOAD)
∇

⍝ Extracts at most one complete frame from the front of BUF (an integer
⍝ byte vector of everything read from the socket so far and not yet
⍝ consumed). Pure: never touches the connection. Returns
⍝   ('k' ((fin opcode payload) rest))   one full frame consumed
⍝   ('n' ⍬)                             BUF does not hold a whole frame yet
⍝   ('e' message)                       malformed or oversized
⍝ The server's mask bit is honoured if set (unmasking with its key)
⍝ even though RFC 6455 forbids a server from masking -- tolerated
⍝ rather than rejected, the same choice this project's Harbour client
⍝ made, since it costs nothing and a real Convex deployment never sets
⍝ it anyway.
∇Z←WsTryExtractFrame BUF;N;B0;B1;FIN;REM;RSV;OPCODE;MASKED;LEN7;HDRLEN;LEN;NEEDED;MASKBYTES;PAYLOAD
  N←⍴BUF
  →(N≥2)⍴HAVEHDR
  Z←'n' ⍬
  →0
HAVEHDR:
  B0←1⊃BUF
  B1←2⊃BUF
  FIN←B0≥128
  REM←B0-128×FIN
  RSV←⌊REM÷16
  →(RSV=0)⍴RSVOK
  Z←JErr 'WebSocket frame set a reserved bit'
  →0
RSVOK:
  OPCODE←16|REM
  MASKED←B1≥128
  LEN7←B1-128×MASKED
  →(LEN7=126)⍴EXT16
  →(LEN7=127)⍴EXT64
  LEN←LEN7
  HDRLEN←2
  →HAVELEN
EXT16:
  →(N≥4)⍴EXT16OK
  Z←'n' ⍬
  →0
EXT16OK:
  LEN←(256×3⊃BUF)+4⊃BUF
  HDRLEN←4
  →HAVELEN
EXT64:
  →(N≥10)⍴EXT64OK
  Z←'n' ⍬
  →0
EXT64OK:
  →(0=(3⊃BUF)+(4⊃BUF)+(5⊃BUF)+(6⊃BUF))⍴EXT64SMALL
  Z←JErr 'WebSocket frame exceeded the maximum size'
  →0
EXT64SMALL:
  LEN←((7⊃BUF)×16777216)+((8⊃BUF)×65536)+((9⊃BUF)×256)+(10⊃BUF)
  HDRLEN←10
HAVELEN:
  →(LEN≤WSMAXFRAME)⍴LENOK
  Z←JErr 'WebSocket frame exceeded the maximum size'
  →0
LENOK:
  NEEDED←HDRLEN+LEN+(4×MASKED)
  →(N≥NEEDED)⍴HAVEALL
  Z←'n' ⍬
  →0
HAVEALL:
  →(MASKED≠0)⍴ISMASKED
  PAYLOAD←BUF[HDRLEN+⍳LEN]
  Z←'k' ((FIN OPCODE PAYLOAD) (NEEDED↓BUF))
  →0
ISMASKED:
  MASKBYTES←BUF[HDRLEN+1 2 3 4]
  PAYLOAD←BUF[HDRLEN+4+⍳LEN]
  PAYLOAD←PAYLOAD WsXorMask MASKBYTES
  Z←'k' ((FIN OPCODE PAYLOAD) (NEEDED↓BUF))
∇

⍝ UTF-8 validation, applied once to a fully reassembled message rather
⍝ than per fragment (a fragment boundary can legally split a multi-byte
⍝ codepoint) -- see the header comment on WsPumpOne below for where
⍝ this is called from.
∇Z←ContByte B
  Z←(B≥128)∧(B≤191)
∇

∇Z←Utf8Valid BYTES;N;I;B;B1;B2;B3
  N←⍴BYTES
  Z←1
  I←1
LOOP:
  →(I≤N)⍴CHECK
  →0
CHECK:
  B←I⊃BYTES
  →(B<128)⍴ASCII
  →((B≥194)∧(B≤223))⍴LEN2
  →((B≥224)∧(B≤239))⍴LEN3
  →((B≥240)∧(B≤244))⍴LEN4
  Z←0
  →0
ASCII:
  I←I+1
  →LOOP
LEN2:
  →((I+1)≤N)⍴LEN2LEN
  Z←0 ⋄ →0
LEN2LEN:
  B1←(I+1)⊃BYTES
  →(ContByte B1)⍴LEN2OK
  Z←0 ⋄ →0
LEN2OK:
  I←I+2
  →LOOP
LEN3:
  →((I+2)≤N)⍴LEN3LEN
  Z←0 ⋄ →0
LEN3LEN:
  B1←(I+1)⊃BYTES
  B2←(I+2)⊃BYTES
  →(ContByte B1)⍴LEN3C1
  Z←0 ⋄ →0
LEN3C1:
  →(ContByte B2)⍴LEN3C2
  Z←0 ⋄ →0
LEN3C2:
  →((B=224)∧(B1<160))⍴BAD          ⍝ overlong
  →((B=237)∧(B1≥160))⍴BAD          ⍝ UTF-16 surrogate range
  I←I+3
  →LOOP
LEN4:
  →((I+3)≤N)⍴LEN4LEN
  Z←0 ⋄ →0
LEN4LEN:
  B1←(I+1)⊃BYTES
  B2←(I+2)⊃BYTES
  B3←(I+3)⊃BYTES
  →(ContByte B1)⍴LEN4C1
  Z←0 ⋄ →0
LEN4C1:
  →((ContByte B2)∧(ContByte B3))⍴LEN4C23
  Z←0 ⋄ →0
LEN4C23:
  →((B=240)∧(B1<144))⍴BAD          ⍝ overlong
  →((B=244)∧(B1>143))⍴BAD          ⍝ above U+10FFFF
  I←I+4
  →LOOP
BAD:
  Z←0
∇

⍝ One frame off LVBUF, folded into the fragmentation/control-frame
⍝ state machine. Control frames (close/ping/pong) are handled the
⍝ instant they arrive, interleaved freely with an in-progress
⍝ fragmented text message, exactly as RFC 6455 5.4 allows; a ping
⍝ during fragmentation is answered immediately without disturbing
⍝ LVFRAGBYTES. Returns
⍝   ('n' ⍬)         LVBUF does not hold a whole frame yet -- stop for this tick
⍝   ('g' ⍬)         one frame was consumed with nothing to deliver yet
⍝                    (a ping/pong, or a fragment that is not yet FIN) --
⍝                    keep pumping, since LVBUF may hold more already
⍝   ('c' message)   the peer sent a close frame
⍝   ('e' message)   a protocol violation; the caller must reconnect
⍝   ('m' text)       one complete, UTF-8-validated text message
∇Z←WsPumpOne;R;FRAME;REST;FIN;OPCODE;PAYLOAD;IGNORED
  R←WsTryExtractFrame LVBUF
  →('k'≡1⊃R)⍴GOTFRAME
  Z←R
  →0
GOTFRAME:
  FRAME←1⊃2⊃R
  REST←2⊃2⊃R
  LVBUF←REST
  FIN←1⊃FRAME
  OPCODE←2⊃FRAME
  PAYLOAD←3⊃FRAME
  →(OPCODE=WSOPCLOSE)⍴CLOSEFRAME
  →(OPCODE=WSOPPING)⍴PINGFRAME
  →(OPCODE=WSOPPONG)⍴PONGFRAME
  →(OPCODE=WSOPTEXT)⍴TEXTFRAME
  →(OPCODE=WSOPCONT)⍴CONTFRAME
  Z←'e' 'WebSocket sent an unsupported frame opcode'
  →0
CLOSEFRAME:
  Z←'c' 'Live server closed the WebSocket'
  →0
PINGFRAME:
  →((FIN≠0)∧((⍴PAYLOAD)≤125))⍴PINGOK
  Z←'e' 'WebSocket ping frame was fragmented or oversized'
  →0
PINGOK:
  IGNORED←LVCONN WsSendPong PAYLOAD
  Z←'g' ⍬
  →0
PONGFRAME:
  →((FIN≠0)∧((⍴PAYLOAD)≤125))⍴PONGOK
  Z←'e' 'WebSocket pong frame was fragmented or oversized'
  →0
PONGOK:
  Z←'g' ⍬
  →0
TEXTFRAME:
  →(LVFRAGACTIVE=0)⍴TEXTSTARTOK
  Z←'e' 'WebSocket started a new message before finishing the last one'
  →0
TEXTSTARTOK:
  →(FIN≠0)⍴TEXTSINGLE
  LVFRAGACTIVE←1
  LVFRAGBYTES←PAYLOAD
  Z←'g' ⍬
  →0
TEXTSINGLE:
  →(Utf8Valid PAYLOAD)⍴TEXTSINGLEOK
  Z←'e' 'WebSocket text frame was not valid UTF-8'
  →0
TEXTSINGLEOK:
  Z←'m' (StrOfBytes PAYLOAD)
  →0
CONTFRAME:
  →(LVFRAGACTIVE≠0)⍴CONTOK
  Z←'e' 'WebSocket sent a continuation frame with no message in progress'
  →0
CONTOK:
  LVFRAGBYTES←LVFRAGBYTES,PAYLOAD
  →((⍴LVFRAGBYTES)≤WSMAXMESSAGE)⍴CONTSIZEOK
  LVFRAGACTIVE←0
  Z←'e' 'WebSocket reassembled message exceeded the maximum size'
  →0
CONTSIZEOK:
  →(FIN≠0)⍴CONTDONE
  Z←'g' ⍬
  →0
CONTDONE:
  LVFRAGACTIVE←0
  →(Utf8Valid LVFRAGBYTES)⍴CONTDONEOK
  Z←'e' 'WebSocket reassembled message was not valid UTF-8'
  →0
CONTDONEOK:
  Z←'m' (StrOfBytes LVFRAGBYTES)
∇

⍝ ================================================================
⍝ RFC 6455 handshake
⍝ ================================================================

⍝ Sends the GET /api/sync Upgrade request and validates the 101
⍝ response (Upgrade: websocket present, Sec-WebSocket-Accept correct).
⍝ PARAMS = (host path budgetMs). Returns ('k' leftoverBytes) --
⍝ anything already read past the header block, which is the start of
⍝ the frame stream and must not be discarded -- or ('e' message).
∇Z←CONN WsHandshake PARAMS;HOST;PATH;DEADLINE;KEY;CRLF;REQ;R;BUF;HEADEREND;HEADERTEXT;R2;STATUSLINE;RESTHEADERS;UPGRADEOK;ACCEPTHEADER;HEADERLINE;COLONPOS;HNAME;HVALUE;EXPECTED
  HOST←1⊃PARAMS
  PATH←2⊃PARAMS
  DEADLINE←NowMs+3⊃PARAMS
  KEY←Base64Encode RandomBytes 16
  CRLF←⎕UCS 13 10
  REQ←'GET ',PATH,' HTTP/1.1',CRLF
  REQ←REQ,'Host: ',HOST,CRLF
  REQ←REQ,'Upgrade: websocket',CRLF
  REQ←REQ,'Connection: Upgrade',CRLF
  REQ←REQ,'Sec-WebSocket-Key: ',KEY,CRLF
  REQ←REQ,'Sec-WebSocket-Version: 13',CRLF
  REQ←REQ,'Convex-Client: apl-0.1.0',CRLF,CRLF
  R←CONN ConnSendAll (BytesOfStr REQ)
  →('k'≡1⊃R)⍴SENTOK
  Z←JErr 'failed writing WebSocket handshake'
  →0
SENTOK:
  BUF←⍬
  HEADEREND←0
HDRLOOP:
  →(HEADEREND=0)⍴HDRNEED
  →HDRDONE
HDRNEED:
  →(NowMs≤DEADLINE)⍴HDRREAD
  Z←JErr 'timed out reading WebSocket handshake response'
  →0
HDRREAD:
  R←CONN ConnRecv (65536 500)
  →('d'≡1⊃R)⍴HDRDATA
  →('t'≡1⊃R)⍴HDRLOOP
  Z←JErr 'connection closed before WebSocket handshake completed'
  →0
HDRDATA:
  BUF←BUF,2⊃R
  →((⍴BUF)≤65536)⍴HDRSIZEOK
  Z←JErr 'WebSocket handshake response headers exceeded budget'
  →0
HDRSIZEOK:
  HEADEREND←((13 10 13 10)⍷BUF)⍳1
  →(HEADEREND≤(⍴BUF)-3)⍴HDRLOOP
  HEADEREND←0
  →HDRLOOP
HDRDONE:
  HEADERTEXT←StrOfBytes (HEADEREND-1)↑BUF
  R2←HEADERTEXT HeaderSplitFirstLine 0
  STATUSLINE←1⊃R2
  RESTHEADERS←2⊃R2
  →(∨/' 101 '⍷' ',STATUSLINE,' ')⍴STATUSOK
  Z←JErr 'WebSocket upgrade was refused'
  →0
STATUSOK:
  UPGRADEOK←0
  ACCEPTHEADER←''
HPARSE:
  →(0=⍴RESTHEADERS)⍴HPARSEDONE
  R2←RESTHEADERS HeaderSplitFirstLine 0
  HEADERLINE←1⊃R2
  RESTHEADERS←2⊃R2
  COLONPOS←HEADERLINE⍳':'
  →(COLONPOS>⍴HEADERLINE)⍴HPARSE
  HNAME←UpperStr HStrip (COLONPOS-1)↑HEADERLINE
  HVALUE←HStrip COLONPOS↓HEADERLINE
  →('UPGRADE'≡HNAME)⍴SETUPGRADE
  →('SEC-WEBSOCKET-ACCEPT'≡HNAME)⍴SETACCEPT
  →HPARSE
SETUPGRADE:
  →(~'WEBSOCKET'≡UpperStr HVALUE)⍴HPARSE
  UPGRADEOK←1
  →HPARSE
SETACCEPT:
  ACCEPTHEADER←HVALUE
  →HPARSE
HPARSEDONE:
  →(UPGRADEOK≠0)⍴UPGOK
  Z←JErr 'WebSocket response is missing Upgrade: websocket'
  →0
UPGOK:
  EXPECTED←WsAcceptValue KEY
  →(ACCEPTHEADER≡EXPECTED)⍴ACCEPTOK
  Z←JErr 'WebSocket Sec-WebSocket-Accept did not match'
  →0
ACCEPTOK:
  Z←'k' ((HEADEREND+3)↓BUF)
∇

⍝ ================================================================
⍝ Sync protocol state: globals
⍝
⍝ LVURL              (useTls host port), from CONVEXURL
⍝ LVCONN             active connection tuple, or ⍬ when not connected
⍝ LVCONNECTED        0/1
⍝ LVBUF              raw bytes read but not yet parsed into frames
⍝ LVFRAGACTIVE        0/1: a fragmented text message is in progress
⍝ LVFRAGBYTES         its payload bytes so far
⍝ LVCONNECTIONCOUNT   completed-connection counter, sent in Connect
⍝ LVLASTCLOSEREASON   reason text for the previous disconnect
⍝ LVMAXOBSERVEDTS     highest Transition endVersion.ts seen, or ''
⍝ LVREMOTEQS/ID/TS    the remote query-set version this client has
⍝                     applied (querySet, identity, ts)
⍝ LVSUBS              nested vector of subscription records:
⍝                     (subId queryId path argsJson rehydrating
⍝                      haveLastValue lastValueText)
⍝ LVNEXTQUERYID       next fresh queryId to assign
⍝ LVLOCALQSV          local ModifyQuerySet version counter
⍝ LVBACKOFFMS         current reconnect backoff
⍝ LVNEXTCONNECTAT     NowMs deadline for the next connect attempt
⍝ LVSESSIONID         this client's session UUID
⍝ ================================================================

∇LiveReset URL;U
  U←UrlParse URL
  →('k'≡1⊃U)⍴URLOK
  LVURL←⍬
  →0
URLOK:
  LVURL←2⊃U
  LVCONN←⍬
  LVCONNECTED←0
  LVBUF←⍬
  LVFRAGACTIVE←0
  LVFRAGBYTES←⍬
  LVCONNECTIONCOUNT←0
  LVLASTCLOSEREASON←'InitialConnect'
  LVMAXOBSERVEDTS←''
  LVREMOTEQS←0
  LVREMOTEID←0
  ⍝ "AAAAAAAAAAA=" is the sync protocol's own encoding of timestamp
  ⍝ zero -- every fresh connection's Transition stream starts here
  ⍝ (querySet 0, identity 0, ts "AAAAAAAAAAA=") regardless of
  ⍝ maxObservedTimestamp, which is a separate staleness hint. Confirmed
  ⍝ against a real backend: an empty LVREMOTETS made
  ⍝ TransitionVersionMatches reject the very first Transition outright.
  LVREMOTETS←'AAAAAAAAAAA='
  LVSUBS←⍬
  LVNEXTQUERYID←1
  LVLOCALQSV←0
  LVBACKOFFMS←100
  LVNEXTCONNECTAT←0
  LVSESSIONID←Uuid4
∇

∇Z←SubIndexById SUBID;I
  Z←0
  I←1
LOOP:
  →(I≤⍴LVSUBS)⍴CHK
  →0
CHK:
  →(SUBID≡1⊃I⊃LVSUBS)⍴FOUND
  I←I+1
  →LOOP
FOUND:
  Z←I
∇

∇Z←SubIndexByQueryId QID;I
  Z←0
  I←1
LOOP:
  →(I≤⍴LVSUBS)⍴CHK
  →0
CHK:
  →(QID=2⊃I⊃LVSUBS)⍴FOUND
  I←I+1
  →LOOP
FOUND:
  Z←I
∇

⍝ Tears the connection down and marks every currently-tracked
⍝ subscription for rehydration-suppression, but never touches the
⍝ subscription table itself -- an earlier subscribe/unsubscribe is not
⍝ undone by a transport failure.
∇Retire REASON;I;REC;IGNORED
  →(0=⍴LVCONN)⍴NOCONN
  IGNORED←ConnClose LVCONN
NOCONN:
  LVCONN←⍬
  LVCONNECTED←0
  LVBUF←⍬
  LVFRAGACTIVE←0
  LVFRAGBYTES←⍬
  LVCONNECTIONCOUNT←LVCONNECTIONCOUNT+1
  LVLASTCLOSEREASON←REASON
  LVREMOTEQS←0
  LVREMOTEID←0
  LVREMOTETS←'AAAAAAAAAAA='          ⍝ see LiveReset's comment on this sentinel
  I←1
LOOP:
  →(I≤⍴LVSUBS)⍴MARK
  →0
MARK:
  REC←I⊃LVSUBS
  REC←(1⊃REC)(2⊃REC)(3⊃REC)(4⊃REC)1(6⊃REC)(7⊃REC)
  LVSUBS[I]←⊂REC
  I←I+1
  →LOOP
∇

∇ScheduleReconnect
  LVNEXTCONNECTAT←NowMs+LVBACKOFFMS
  →(LVBACKOFFMS<7500)⍴DOUBLE
  LVBACKOFFMS←15000
  →0
DOUBLE:
  LVBACKOFFMS←LVBACKOFFMS×2
∇

⍝ One full resnapshot Add for every currently-tracked subscription --
⍝ simpler than replaying incremental history, and safe because
⍝ ApplyQueryUpdated (inside ProcessTransition) suppresses a value that
⍝ has not actually changed.
∇Z←BuildFullQuerySetMessage;I;REC;MODS
  MODS←''
  I←1
LOOP:
  →(I≤⍴LVSUBS)⍴ONE
  →DONE
ONE:
  REC←I⊃LVSUBS
  MODS←MODS,'{"type":"Add","queryId":',(⍕2⊃REC),',"udfPath":',(JEscapeString 3⊃REC),',"args":[',(4⊃REC),']}'
  →(I=⍴LVSUBS)⍴NEXTCHECK
  MODS←MODS,','
NEXTCHECK:
  I←I+1
  →LOOP
DONE:
  Z←'{"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,"modifications":[',MODS,']}'
∇

⍝ Establishes a fresh connection: TCP/TLS connect, RFC 6455 handshake,
⍝ Connect message, then one ModifyQuerySet resnapshotting every
⍝ tracked subscription. On any failure, schedules the next reconnect
⍝ attempt with backoff and leaves LVCONNECTED 0 -- the caller
⍝ (LiveServiceTick) is expected to retry on its own schedule.
∇ConnectNow;USETLS;HOST;PORT;CR;HS;CONNMSG;OK;IGNORED
  USETLS←1⊃LVURL
  HOST←2⊃LVURL
  PORT←3⊃LVURL
  CR←USETLS ConnConnect (HOST PORT)
  →('k'≡1⊃CR)⍴CONNOK
  ScheduleReconnect
  →0
CONNOK:
  LVCONN←2⊃CR
  HS←LVCONN WsHandshake (HOST '/api/sync' 5000)
  →('k'≡1⊃HS)⍴HSOK
  IGNORED←ConnClose LVCONN
  LVCONN←⍬
  ScheduleReconnect
  →0
HSOK:
  LVBUF←2⊃HS
  LVFRAGACTIVE←0
  LVFRAGBYTES←⍬
  LVCONNECTED←1

  CONNMSG←'{"type":"Connect","sessionId":',(JEscapeString LVSESSIONID),',"connectionCount":',(⍕LVCONNECTIONCOUNT),',"lastCloseReason":',(JEscapeString LVLASTCLOSEREASON),',"clientTs":0'
  →(0=⍴LVMAXOBSERVEDTS)⍴NOMAXTS
  CONNMSG←CONNMSG,',"maxObservedTimestamp":',(JEscapeString LVMAXOBSERVEDTS)
NOMAXTS:
  CONNMSG←CONNMSG,'}'
  OK←LVCONN WsSendText CONNMSG
  →(OK)⍴SENTCONNECT
  Retire 'failed sending Connect'
  ScheduleReconnect
  →0
SENTCONNECT:
  LVLOCALQSV←0
  →(0=⍴LVSUBS)⍴NOSUBS
  OK←LVCONN WsSendText BuildFullQuerySetMessage
  →(OK)⍴SENTMODS
  Retire 'failed sending initial ModifyQuerySet'
  ScheduleReconnect
  →0
SENTMODS:
  LVLOCALQSV←1
NOSUBS:
  LVBACKOFFMS←100
∇

∇Z←TransitionVersionMatches STARTVER;QSF;IDF;TSF
  QSF←'querySet' JGet STARTVER
  IDF←'identity' JGet STARTVER
  TSF←'ts' JGet STARTVER
  Z←0
  →('n'≡1⊃QSF)⍴C1
  →0
C1:
  →('n'≡1⊃IDF)⍴C2
  →0
C2:
  →('s'≡1⊃TSF)⍴C3
  →0
C3:
  →((2⊃QSF)=LVREMOTEQS)⍴C4
  →0
C4:
  →((2⊃IDF)=LVREMOTEID)⍴C5
  →0
C5:
  Z←(2⊃TSF)≡LVREMOTETS
∇

∇Z←ModShapeOk MOD;TYPEFIELD;MODTYPE
  Z←0
  →('o'≡1⊃MOD)⍴HASOBJ
  →0
HASOBJ:
  →(('type' JHas MOD)∧('queryId' JHas MOD))⍴HASBASIC
  →0
HASBASIC:
  TYPEFIELD←'type' JGet MOD
  →('s'≡1⊃TYPEFIELD)⍴HASTYPESTR
  →0
HASTYPESTR:
  →('n'≡1⊃('queryId' JGet MOD))⍴HASQIDNUM
  →0
HASQIDNUM:
  MODTYPE←2⊃TYPEFIELD
  →('QueryUpdated'≡MODTYPE)⍴CHKUPDATED
  →('QueryFailed'≡MODTYPE)⍴CHKFAILED
  →('QueryRemoved'≡MODTYPE)⍴OK
  →0
CHKUPDATED:
  →('value' JHas MOD)⍴OK
  →0
CHKFAILED:
  →('errorMessage' JHas MOD)⍴CHKFAILEDSTR
  →0
CHKFAILEDSTR:
  →('s'≡1⊃('errorMessage' JGet MOD))⍴OK
  →0
OK:
  Z←1
∇

⍝ Validates a whole Transition (shape, and that its startVersion
⍝ matches the version this client has already applied) before applying
⍝ any modification, so a malformed message never leaves the
⍝ subscription table half-updated. Returns ('k' events) | ('e' ⍬).
⍝ events is a nested vector of (subscriptionId kind payload) triples,
⍝ kind 'v' (payload a tagged JSON value) or 'e' (payload
⍝ (name message hasData dataTaggedValue)).
∇Z←ProcessTransition DOC;STARTVER;ENDVER;MODS;I;MOD;MODTYPE;QID;IDX;REC;EVENTS;SUBID;VALFIELD;VALTEXT;SUPPRESS;ERRMSGFIELD;ERRDATAFIELD;HASDATA;TSF
  →(('startVersion' JHas DOC)∧('endVersion' JHas DOC)∧('modifications' JHas DOC))⍴HASALL
  Z←'e' ⍬
  →0
HASALL:
  STARTVER←'startVersion' JGet DOC
  ENDVER←'endVersion' JGet DOC
  MODS←'modifications' JGet DOC
  →(('o'≡1⊃STARTVER)∧('o'≡1⊃ENDVER)∧('a'≡1⊃MODS))⍴SHAPESOK
  Z←'e' ⍬
  →0
SHAPESOK:
  →(('querySet' JHas ENDVER)∧('identity' JHas ENDVER)∧('ts' JHas ENDVER))⍴ENDFIELDSOK
  Z←'e' ⍬
  →0
ENDFIELDSOK:
  →(TransitionVersionMatches STARTVER)⍴VERSIONOK
  Z←'e' ⍬
  →0
VERSIONOK:
  I←1
VALIDATELOOP:
  →(I≤⍴2⊃MODS)⍴VALIDATECHK
  →VALIDATEDONE
VALIDATECHK:
  →(ModShapeOk I⊃2⊃MODS)⍴VALIDATENEXT
  Z←'e' ⍬
  →0
VALIDATENEXT:
  I←I+1
  →VALIDATELOOP
VALIDATEDONE:
  EVENTS←⍬
  I←1
APPLYLOOP:
  →(I≤⍴2⊃MODS)⍴APPLYCHK
  →APPLYDONE
APPLYCHK:
  MOD←I⊃2⊃MODS
  MODTYPE←2⊃'type' JGet MOD
  QID←2⊃'queryId' JGet MOD
  IDX←SubIndexByQueryId QID
  →(IDX≠0)⍴HAVEIDX
  →APPLYNEXT
HAVEIDX:
  REC←IDX⊃LVSUBS
  SUBID←1⊃REC
  →('QueryUpdated'≡MODTYPE)⍴DOUPDATED
  →('QueryFailed'≡MODTYPE)⍴DOFAILED
  →APPLYNEXT
DOUPDATED:
  VALFIELD←'value' JGet MOD
  VALTEXT←JStringify VALFIELD
  SUPPRESS←((5⊃REC)≠0)∧((6⊃REC)≠0)∧(VALTEXT≡7⊃REC)
  REC←(1⊃REC)(2⊃REC)(3⊃REC)(4⊃REC)0 1 VALTEXT
  LVSUBS[IDX]←⊂REC
  →(SUPPRESS≠0)⍴APPLYNEXT
  EVENTS←EVENTS,⊂(SUBID 'v' VALFIELD)
  →APPLYNEXT
DOFAILED:
  ERRMSGFIELD←'errorMessage' JGet MOD
  HASDATA←'errorData' JHas MOD
  ERRDATAFIELD←JNull
  →(HASDATA=0)⍴NODATAFIELD
  ERRDATAFIELD←'errorData' JGet MOD
NODATAFIELD:
  REC←(1⊃REC)(2⊃REC)(3⊃REC)(4⊃REC)0 0 ''
  LVSUBS[IDX]←⊂REC
  EVENTS←EVENTS,⊂(SUBID 'e' ('FunctionError' (2⊃ERRMSGFIELD) HASDATA ERRDATAFIELD))
APPLYNEXT:
  I←I+1
  →APPLYLOOP
APPLYDONE:
  LVREMOTEQS←2⊃'querySet' JGet ENDVER
  LVREMOTEID←2⊃'identity' JGet ENDVER
  TSF←'ts' JGet ENDVER
  LVREMOTETS←2⊃TSF
  LVMAXOBSERVEDTS←2⊃TSF
  Z←'k' EVENTS
∇

⍝ Decodes and dispatches one complete text-message payload. Returns
⍝ ('k' events) | ('e' message).
∇Z←HandleServerText TEXT;DOC;TYPEFIELD;TYPETEXT;PR
  DOC←JParseDocument TEXT
  →('o'≡1⊃DOC)⍴ISOBJ
  Z←'e' 'Live received a malformed message'
  →0
ISOBJ:
  →('type' JHas DOC)⍴HASTYPE
  Z←'e' 'Live message omitted type'
  →0
HASTYPE:
  TYPEFIELD←'type' JGet DOC
  →('s'≡1⊃TYPEFIELD)⍴TYPEOK
  Z←'e' 'Live message type was not a string'
  →0
TYPEOK:
  TYPETEXT←2⊃TYPEFIELD
  →('Transition'≡TYPETEXT)⍴DOTRANSITION
  →(('Ping'≡TYPETEXT)∨('MutationResponse'≡TYPETEXT)∨('ActionResponse'≡TYPETEXT)∨('FatalError'≡TYPETEXT)∨('AuthError'≡TYPETEXT))⍴IGNORETYPE
  Z←'e' 'Live received an unrecognized message type'
  →0
DOTRANSITION:
  PR←ProcessTransition DOC
  →('k'≡1⊃PR)⍴TRANSITIONOK
  Z←'e' 'Live received an invalid Transition'
  →0
TRANSITIONOK:
  LVBACKOFFMS←100                  ⍝ reset backoff after a valid server transition
  Z←'k' (2⊃PR)
  →0
IGNORETYPE:
  Z←'k' ⍬
∇

⍝ Services the Live connection for at most one tick: if disconnected
⍝ and a reconnect is due, attempt it; if connected, perform one
⍝ non-blocking recv() and drain every complete frame/message that
⍝ produced. Returns a (possibly empty) nested vector of
⍝ (subscriptionId kind payload) delivery events -- see ProcessTransition's
⍝ header comment for their shape. Never blocks longer than one recv()
⍝ at a zero timeout and, when connecting, ConnectNow's own bounded
⍝ handshake budget.
∇Z←LiveServiceTick;R;PR;PUMPRESULT
  Z←⍬
  →(LVCONNECTED≠0)⍴CONNECTEDBRANCH
  →(NowMs≥LVNEXTCONNECTAT)⍴DOCONNECT
  →0
DOCONNECT:
  ConnectNow
  →0
CONNECTEDBRANCH:
  R←LVCONN ConnRecv (65536 0)
  →('d'≡1⊃R)⍴GOTDATA
  →('t'≡1⊃R)⍴PUMPLOOP
  Retire 'Live connection failed'
  ScheduleReconnect
  →0
GOTDATA:
  LVBUF←LVBUF,2⊃R
PUMPLOOP:
  PUMPRESULT←WsPumpOne
  →('g'≡1⊃PUMPRESULT)⍴PUMPLOOP
  →('m'≡1⊃PUMPRESULT)⍴GOTMESSAGE
  →('n'≡1⊃PUMPRESULT)⍴0
  Retire 2⊃PUMPRESULT
  ScheduleReconnect
  →0
GOTMESSAGE:
  PR←HandleServerText 2⊃PUMPRESULT
  →('k'≡1⊃PR)⍴MERGE
  Retire 2⊃PR
  ScheduleReconnect
  →0
MERGE:
  Z←Z,2⊃PR
  →PUMPLOOP
∇

⍝ ================================================================
⍝ Public Live operations, called by the adapter and the example
⍝ ================================================================

⍝ Must be called once, after ConvexInit, before any other Live
⍝ function. Sets the next connect attempt to "now" so the first
⍝ LiveServiceTick call establishes a connection even before any
⍝ subscribe.
∇Z←LiveInit URL
  LiveReset URL
  Z←0≠⍴LVURL
∇

⍝ Registers a subscription and, if connected, sends its Add
⍝ immediately; always succeeds locally regardless of connection state
⍝ -- a disconnected client just resnapshots every tracked subscription,
⍝ including this new one, the next time ConnectNow succeeds. A repeat
⍝ SUBID replaces the old entry (dropped from the table first) so a
⍝ Transition modification already in flight for the old queryId can
⍝ never resolve to it again.
∇LiveSubscribe PARAMS;SUBID;PATH;ARGSJSON;IDX;QID;REC;MSG;IGNORED
  SUBID←1⊃PARAMS
  PATH←2⊃PARAMS
  ARGSJSON←3⊃PARAMS
  IDX←SubIndexById SUBID
  →(IDX=0)⍴NEWSUB
  LVSUBS←((IDX-1)↑LVSUBS),(IDX↓LVSUBS)
NEWSUB:
  QID←LVNEXTQUERYID
  LVNEXTQUERYID←LVNEXTQUERYID+1
  REC←SUBID QID PATH ARGSJSON 0 0 ''
  LVSUBS←LVSUBS,⊂REC
  →(LVCONNECTED≠0)⍴SENDADD
  →0
SENDADD:
  LVLOCALQSV←LVLOCALQSV+1
  MSG←'{"type":"ModifyQuerySet","baseVersion":',(⍕LVLOCALQSV-1),',"newVersion":',(⍕LVLOCALQSV),',"modifications":[{"type":"Add","queryId":',(⍕QID),',"udfPath":',(JEscapeString PATH),',"args":[',ARGSJSON,']}]}'
  IGNORED←LVCONN WsSendText MSG
∇

∇LiveUnsubscribe SUBID;IDX;REC;MSG;IGNORED
  IDX←SubIndexById SUBID
  →(IDX≠0)⍴HAVEIDX
  →0
HAVEIDX:
  REC←IDX⊃LVSUBS
  LVSUBS←((IDX-1)↑LVSUBS),(IDX↓LVSUBS)
  →(LVCONNECTED≠0)⍴SENDREMOVE
  →0
SENDREMOVE:
  LVLOCALQSV←LVLOCALQSV+1
  MSG←'{"type":"ModifyQuerySet","baseVersion":',(⍕LVLOCALQSV-1),',"newVersion":',(⍕LVLOCALQSV),',"modifications":[{"type":"Remove","queryId":',(⍕2⊃REC),'}]}'
  IGNORED←LVCONN WsSendText MSG
∇

⍝ Retires the current connection (if any) and schedules the next
⍝ connect attempt almost immediately, before returning -- by the time a
⍝ caller sees this return, the old connection is already closed and a
⍝ reconnect is already scheduled, so nothing the old connection could
⍝ still deliver can race whatever the caller does next.
∇LiveDebugDisconnect
  →(LVCONNECTED=0)⍴SKIPRETIRE
  Retire 'DebugDisconnect'
SKIPRETIRE:
  LVNEXTCONNECTAT←NowMs+50
  LVBACKOFFMS←100
∇

∇LiveClose;IGNORED
  →(LVCONNECTED=0)⍴0
  IGNORED←LVCONN WsSendClose 0
  Retire 'shutdown'
∇
