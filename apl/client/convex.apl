#!/usr/local/bin/apl --script
⍝!
⍝ Convex from GNU APL: the client library.
⍝
⍝ This is a GNU APL library workspace file, loaded by every dependent
⍝ script (the conformance adapter and the canonical example) with
⍝   )COPY '/opt/convex/client/convex.apl'
⍝ exactly the way GNU APL's own shipped wslib5 libraries are loaded.
⍝
⍝ JSON encoding/decoding, HTTP/1.1 request and response framing, RFC 6455
⍝ WebSocket handshake and frame handling (masking, fragmentation, control
⍝ frames), and the Convex /api/sync state machine are all implemented
⍝ here, in APL. The only things delegated outside APL are raw
⍝ TCP/TLS bytes and one hash primitive; see client/shim.cc's own header
⍝ comment for exactly what and why.
⍝
⍝ Transport layering:
⍝   - Plain (ws://, http://) connections use GNU APL's own built-in
⍝     ⎕FIO[32..41] (socket/connect/send/recv), which needs no shim at
⍝     all.
⍝   - TLS (wss://, https://) connections use the native function
⍝     CONVEXTLS, loaded from client/shim.cc via ⎕FX (see ConvexInit
⍝     below).
⍝ Both are wrapped by ConnConnect/ConnSend/ConnRecv/ConnClose below so
⍝ the rest of this file never has to know which transport a connection
⍝ uses.
⍝
⍝ Wire bytes (anything that has crossed or will cross a socket) are
⍝ represented as APL integer vectors, one element per byte, 0 to 255 --
⍝ never as APL characters, which GNU APL's own "Ac" ⎕FIO variants would
⍝ silently UTF-8-encode on the way out. BytesOfStr/StrOfBytes convert
⍝ between that wire representation and ordinary APL character vectors
⍝ (used for JSON text, HTTP header text, and every printable value in
⍝ this file) via ⎕UCS, which GNU APL documents as a lossless codepoint
⍝ <-> character conversion in both directions.

⍝ ================================================================
⍝ Setup
⍝ ================================================================

⍝ Loads the native TLS/SHA-1 function from the shared library sitting
⍝ next to this file, and remembers its own directory (⎕FIO[26] cannot
⍝ resolve a relative path once the caller's own cwd has changed) so it
⍝ only has to be found once per process.
∇ConvexInit B;SOPATH
 ⍝⍝ B: path to shim.cc's compiled shared object. Call this once, before
 ⍝⍝ any Conn*/Live* function.
  SOPATH←B
  SOPATH ⎕FX 'CONVEXTLS'
∇

⍝ ================================================================
⍝ Byte <-> character conversion
⍝ ================================================================

∇Z←BytesOfStr B
 ⍝⍝ character vector -> integer byte vector (codepoints 0-255).
  Z←⎕UCS B
∇

∇Z←StrOfBytes B
 ⍝⍝ integer byte vector -> character vector.
  Z←⎕UCS B
∇

⍝ ================================================================
⍝ JSON
⍝
⍝ A parsed JSON value is represented as a 2-element nested vector
⍝ (tag payload):
⍝   'n' payload         number,  payload is a numeric scalar
⍝   's' payload         string,  payload is a character vector
⍝   'b' payload         bool,    payload is 0 or 1
⍝   'z' payload         null,    payload is ⍬ (ignored)
⍝   'a' payload         array,   payload is a (possibly empty) nested
⍝                                vector of tagged values
⍝   'o' payload         object,  payload is a (possibly empty) nested
⍝                                vector of 2-element (key tagged-value)
⍝                                pairs, key a character vector
⍝ ================================================================

∇Z←JNum B
  Z←'n' B
∇
∇Z←JStr B
  Z←'s' B
∇
∇Z←JBool B
  Z←'b' B
∇
∇Z←JNull
  Z←'z' ⍬
∇
∇Z←JArr B
  Z←'a' B
∇
∇Z←JObj B
  Z←'o' B
∇

⍝ Looks up KEY in an 'o' tagged value B. Returns the tagged value, or
⍝ ('z' ⍬) (JSON null's own tag) with an ok flag of 0 when absent -- the
⍝ caller distinguishes "absent" from "present and null" with JHas.
∇Z←KEY JGet B;PAIRS;I
  PAIRS←2⊃B
  Z←JNull
  →(0=⍴PAIRS)⍴0
  I←1
LOOP:
  →(I>⍴PAIRS)⍴0
  →(KEY≡1⊃I⊃PAIRS)⍴FOUND
  I←I+1
  →LOOP
FOUND:
  Z←2⊃I⊃PAIRS
∇

∇Z←KEY JHas B;PAIRS;I
  PAIRS←2⊃B
  Z←0
  →(0=⍴PAIRS)⍴0
  I←1
LOOP:
  →(I>⍴PAIRS)⍴0
  →(KEY≡1⊃I⊃PAIRS)⍴FOUND
  I←I+1
  →LOOP
FOUND:
  Z←1
∇

⍝ Whole-number extraction that accepts Convex's integral-decimal JSON
⍝ numbers (0, 0.0, 1.0, ...) while rejecting fractional, non-finite, or
⍝ out-of-range values, per this project's shared example rules.
∇Z←JWholeNumber B;N
  Z←¯1
  →('n'≡1⊃B)⍴OK
  →0
OK:
  N←2⊃B
  →((N=⌊N)∧(|N)<2*53)⍴GOOD
  →0
GOOD:
  Z←N
∇

⍝ ---- stringify ----

∇Z←JStringify B;TAG;PAY
  TAG←1⊃B
  PAY←2⊃B
  →('n'≡TAG)⍴NUM
  →('s'≡TAG)⍴STR
  →('b'≡TAG)⍴BOOL
  →('z'≡TAG)⍴NUL
  →('a'≡TAG)⍴ARR
  →('o'≡TAG)⍴OBJ
  Z←'null'
  →0
NUM:
  Z←JStringifyNumber PAY
  →0
STR:
  Z←JEscapeString PAY
  →0
BOOL:
  →(PAY≠0)⍴TRUEV
  Z←'false'
  →0
TRUEV:
  Z←'true'
  →0
NUL:
  Z←'null'
  →0
ARR:
  Z←JStringifyArray PAY
  →0
OBJ:
  Z←JStringifyObject PAY
  →0
∇

⍝ GNU APL formats integral floats as e.g. "1" not "1.0"; Convex accepts
⍝ a bare integral JSON number, so no special-casing is needed here.
∇Z←JStringifyNumber B;S;NEG
 ⍝⍝ GNU APL's ⍕ formats a negative number with the high-minus glyph ¯
 ⍝⍝ (e.g. ¯1), which JSON does not accept; substitute an ASCII '-' in
 ⍝⍝ its place, in the leading position only.
  S←⍕B
  NEG←(⍴S)≥1
  →(NEG∧('¯'=1⊃S))⍴HASNEG
  Z←S
  →0
HASNEG:
  Z←'-',1↓S
∇

∇Z←JEscapeString B;I;C;OUT
 ⍝⍝ B←,B: a single-character argument like 'x' is an APL SCALAR (rank
 ⍝⍝ 0), not a length-1 vector, and ⍴ of a scalar is empty -- ravelling
 ⍝⍝ first guarantees a real vector so ⍴B/I⊃B behave as this loop needs.
  B←,B
  OUT←,'"'
  I←1
LOOP:
  →(I>⍴B)⍴DONE
  C←I⊃B
  →(C='"')⍴Q
  →(C='\')⍴BS
  →(C=⎕UCS 10)⍴NL
  →(C=⎕UCS 13)⍴CR
  →(C=⎕UCS 9)⍴TB
  →((⎕UCS C)<32)⍴CTRL
  OUT←OUT,C
  →NEXT
Q:
  OUT←OUT,'\"'
  →NEXT
BS:
  OUT←OUT,'\\'
  →NEXT
NL:
  OUT←OUT,'\n'
  →NEXT
CR:
  OUT←OUT,'\r'
  →NEXT
TB:
  OUT←OUT,'\t'
  →NEXT
CTRL:
  OUT←OUT,'\u',HexPad4 (⎕UCS C)
  →NEXT
NEXT:
  I←I+1
  →LOOP
DONE:
  Z←OUT,'"'
∇

∇Z←JStringifyArray B;I;OUT
  OUT←''
  →(0=⍴B)⍴EMPTY
  I←1
LOOP:
  OUT←OUT,JStringify I⊃B
  →(I=⍴B)⍴DONE
  OUT←OUT,','
  I←I+1
  →LOOP
DONE:
  Z←'[',OUT,']'
  →0
EMPTY:
  Z←'[]'
∇

∇Z←JStringifyObject B;I;OUT;PAIR
  OUT←''
  →(0=⍴B)⍴EMPTY
  I←1
LOOP:
  PAIR←I⊃B
  OUT←OUT,(JEscapeString 1⊃PAIR),':',JStringify 2⊃PAIR
  →(I=⍴B)⍴DONE
  OUT←OUT,','
  I←I+1
  →LOOP
DONE:
  Z←'{',OUT,'}'
  →0
EMPTY:
  Z←'{}'
∇

⍝ ---- parse ----
⍝ Every JParse* function takes (TEXT START) and returns (VALUE NEXT),
⍝ where START/NEXT are 1-origin character indices into TEXT and NEXT is
⍝ the index just past what was consumed. Malformed input returns a
⍝ ('e' message) tagged value; callers propagate that tag upward instead
⍝ of trying to recover.

∇Z←TEXT JSkipWs START;I
  I←START
LOOP:
  →(I>⍴TEXT)⍴DONE
  →(~(I⊃TEXT)∊' ',(⎕UCS 9),(⎕UCS 10),(⎕UCS 13))⍴DONE
  I←I+1
  →LOOP
DONE:
  Z←I
∇

∇Z←TEXT JParse START;I;C
  I←TEXT JSkipWs START
  →(I>⍴TEXT)⍴EOF
  C←I⊃TEXT
  →('"'=C)⍴STR
  →('{'=C)⍴OBJ
  →('['=C)⍴ARR
  →('t'=C)⍴TRUE
  →('f'=C)⍴FALSE
  →('n'=C)⍴NUL
  →((C='-')∨(C≥'0')∧(C≤'9'))⍴NUM
  Z←(JErr 'unexpected character in JSON') I
  →0
EOF:
  Z←(JErr 'unexpected end of JSON') I
  →0
STR:
  Z←TEXT JParseString I
  →0
OBJ:
  Z←TEXT JParseObject I
  →0
ARR:
  Z←TEXT JParseArray I
  →0
TRUE:
  →((4≤(⍴TEXT)-I+1)∧('true'≡TEXT[I+0 1 2 3]))⍴TRUEOK
  Z←(JErr 'invalid literal') I
  →0
TRUEOK:
  Z←(JBool 1) (I+4)
  →0
FALSE:
  →((5≤(⍴TEXT)-I+1)∧('false'≡TEXT[I+0 1 2 3 4]))⍴FALSEOK
  Z←(JErr 'invalid literal') I
  →0
FALSEOK:
  Z←(JBool 0) (I+5)
  →0
NUL:
  →((4≤(⍴TEXT)-I+1)∧('null'≡TEXT[I+0 1 2 3]))⍴NULOK
  Z←(JErr 'invalid literal') I
  →0
NULOK:
  Z←JNull (I+4)
  →0
NUM:
  Z←TEXT JParseNumber I
  →0
∇

∇Z←JErr B
  Z←'e' B
∇

∇Z←TEXT JParseNumber START;I;N
  I←START
  →((I≤⍴TEXT)∧('-'=I⊃TEXT))⍴NEG
  →SCAN
NEG:
  I←I+1
SCAN:
LOOP:
  →(I>⍴TEXT)⍴END
  →(~(I⊃TEXT)∊'0123456789+-.eE')⍴END
  I←I+1
  →LOOP
END:
  →(I=START)⍴BAD
  N←⍎(I-START)↑(START-1)↓TEXT  ⍝ ⍎ (execute) parses the numeric literal
  Z←(JNum N) I
  →0
BAD:
  Z←(JErr 'invalid number') I
∇

∇Z←TEXT JParseString START;I;OUT;C;HEX
  →((START≤⍴TEXT)∧('"'=START⊃TEXT))⍴OPEN
  Z←(JErr 'expected string') START
  →0
OPEN:
  I←START+1
  OUT←''
LOOP:
  →(I>⍴TEXT)⍴UNTERM
  C←I⊃TEXT
  →('"'=C)⍴DONE
  →('\'=C)⍴ESC
  OUT←OUT,C
  I←I+1
  →LOOP
ESC:
  →(I≥⍴TEXT)⍴UNTERM
  I←I+1
  C←I⊃TEXT
  →('"'=C)⍴EQ
  →('\'=C)⍴EBS
  →('/'=C)⍴ESL
  →('n'=C)⍴ENL
  →('t'=C)⍴ETB
  →('r'=C)⍴ECR
  →('b'=C)⍴EBK
  →('f'=C)⍴EFF
  →('u'=C)⍴EU
  Z←(JErr 'invalid escape') I
  →0
EQ:
  OUT←OUT,'"' ⋄ I←I+1 ⋄ →LOOP
EBS:
  OUT←OUT,'\' ⋄ I←I+1 ⋄ →LOOP
ESL:
  OUT←OUT,'/' ⋄ I←I+1 ⋄ →LOOP
ENL:
  OUT←OUT,⎕UCS 10 ⋄ I←I+1 ⋄ →LOOP
ETB:
  OUT←OUT,⎕UCS 9 ⋄ I←I+1 ⋄ →LOOP
ECR:
  OUT←OUT,⎕UCS 13 ⋄ I←I+1 ⋄ →LOOP
EBK:
  OUT←OUT,⎕UCS 8 ⋄ I←I+1 ⋄ →LOOP
EFF:
  OUT←OUT,⎕UCS 12 ⋄ I←I+1 ⋄ →LOOP
EU:
  →((I+4)≤⍴TEXT)⍴UOK
  Z←(JErr 'truncated \u escape') I
  →0
UOK:
  HEX←TEXT[I+1,I+2,I+3,I+4]
  OUT←OUT,⎕UCS 16⊥16|(⎕UCS HEX)-('0'=HEX)×48-(('A'≤HEX)∧(HEX≤'F'))×55-(('a'≤HEX)∧(HEX≤'f'))×87
  I←I+5
  →LOOP
DONE:
  Z←(JStr OUT) (I+1)
  →0
UNTERM:
  Z←(JErr 'unterminated string') I
∇

∇Z←TEXT JParseArray START;I;ITEMS;V;NX
  I←TEXT JSkipWs START+1
  ITEMS←⍬
  →((I≤⍴TEXT)∧(']'=I⊃TEXT))⍴EMPTY
LOOP:
  V←TEXT JParse I
  →('e'≡1⊃1⊃V)⍴PROP
  ITEMS←ITEMS,⊂1⊃V
  I←TEXT JSkipWs 2⊃V
  →(I>⍴TEXT)⍴UNTERM
  →(','=I⊃TEXT)⍴NEXT
  →(']'=I⊃TEXT)⍴DONE
  Z←(JErr 'expected , or ] in array') I
  →0
NEXT:
  I←TEXT JSkipWs I+1
  →LOOP
DONE:
  Z←(JArr ITEMS) (I+1)
  →0
EMPTY:
  Z←(JArr ⍬) (I+1)
  →0
UNTERM:
  Z←(JErr 'unterminated array') I
  →0
PROP:
  Z←V
∇

∇Z←TEXT JParseObject START;I;PAIRS;KEYV;VALV;KEY
  I←TEXT JSkipWs START+1
  PAIRS←⍬
  →((I≤⍴TEXT)∧('}'=I⊃TEXT))⍴EMPTY
LOOP:
  I←TEXT JSkipWs I
  KEYV←TEXT JParseString I
  →('e'≡1⊃1⊃KEYV)⍴PROPK
  KEY←2⊃1⊃KEYV
  I←TEXT JSkipWs 2⊃KEYV
  →((I≤⍴TEXT)∧(':'=I⊃TEXT))⍴COLONOK
  Z←(JErr 'expected : in object') I
  →0
COLONOK:
  I←TEXT JSkipWs I+1
  VALV←TEXT JParse I
  →('e'≡1⊃1⊃VALV)⍴PROPV
  PAIRS←PAIRS,⊂(KEY(1⊃VALV))
  I←TEXT JSkipWs 2⊃VALV
  →(I>⍴TEXT)⍴UNTERM
  →(','=I⊃TEXT)⍴NEXT
  →('}'=I⊃TEXT)⍴DONE
  Z←(JErr 'expected , or } in object') I
  →0
NEXT:
  I←TEXT JSkipWs I+1
  →LOOP
DONE:
  Z←(JObj PAIRS) (I+1)
  →0
EMPTY:
  Z←(JObj ⍬) (I+1)
  →0
UNTERM:
  Z←(JErr 'unterminated object') I
  →0
PROPK:
  Z←KEYV
  →0
PROPV:
  Z←VALV
∇

⍝ Parses TEXT as a complete JSON document (trailing whitespace allowed,
⍝ trailing garbage rejected). Returns a tagged value, 'e' on failure.
∇Z←JParseDocument TEXT;R;I
  R←TEXT JParse 1
  →('e'≡1⊃1⊃R)⍴BAD
  I←TEXT JSkipWs 2⊃R
  →(I≤⍴TEXT)⍴TRAILING
  Z←1⊃R
  →0
BAD:
  Z←1⊃R
  →0
TRAILING:
  Z←JErr 'trailing data after JSON document'
∇

⍝ ================================================================
⍝ Connections
⍝
⍝ A connection is a 2-element vector (kind handle): kind is 'p' for a
⍝ plain ⎕FIO socket or 't' for a CONVEXTLS handle. Every function below
⍝ takes/returns byte vectors (integers 0-255), never characters.
⍝ ================================================================

∇Z←HOST ResolveHost B;R
 ⍝⍝ B is ignored (dyadic only to read naturally at call sites);
 ⍝⍝ resolves HOST to a host-byte-order uint32. Returns ('k' ip) or
 ⍝⍝ ('e' message).
  R←CONVEXTLS[6] BytesOfStr HOST
  →('K'=1⊃R)⍴OK
  Z←JErr 2↓R
  →0
OK:
  Z←'k' (⍎2↓R)
∇

∇Z←USETLS ConnConnect HOSTPORT;HOST;PORT;R;IP;SOCK;ADDR;ERR
 ⍝⍝ HOSTPORT is (host port), port a number. USETLS is 1 for TLS.
  HOST←1⊃HOSTPORT
  PORT←2⊃HOSTPORT
  →(USETLS≠0)⍴TLS
  R←HOST ResolveHost 0
  →('k'≡1⊃R)⍴PLAINOK
  Z←JErr 2⊃R
  →0
PLAINOK:
  IP←2⊃R
  SOCK←⎕FIO[32] 2               ⍝ AF_INET, SOCK_STREAM
  →(SOCK≥0)⍴SOCKOK
  Z←JErr 'socket() failed'
  →0
SOCKOK:
  ADDR←2 IP PORT
  ERR←ADDR ⎕FIO[36] SOCK        ⍝ connect(Bh, Aa)
  →(ERR=0)⍴CONNOK
  ⎕FIO[4] SOCK                  ⍝ ⎕FIO's socket and file handles share one
                                 ⍝ table; FUN[4] closes either.
  Z←JErr 'connect() failed'
  →0
CONNOK:
  ⍝ F_SETFL O_NONBLOCK (4 2048 on Linux): ConnRecv below polls this
  ⍝ socket with recv() itself rather than ⎕FIO[40] select(), whose
  ⍝ dyadic (readfds writefds exceptfds timeout) argument -- despite
  ⍝ matching Quad_FIO.cc's documented shape exactly (verified with ⍴/≡/
  ⍝ ⊃ before ever reaching select()) -- reliably raised DOMAIN ERROR in
  ⍝ this GNU APL 2.0 build; recv() itself does not have that problem.
  (4 2048) ⎕FIO[59] SOCK
  Z←'k' ('p' SOCK)
  →0
TLS:
  R←CONVEXTLS[1] BytesOfStr HOST,' ',⍕PORT
  →('K'=1⊃R)⍴TLSOK
  Z←JErr 2↓R
  →0
TLSOK:
  Z←'k' ('t' (⍎2↓R))
∇

∇Z←CONN ConnSend BYTES;KIND;HANDLE;R
  KIND←1⊃CONN
  HANDLE←2⊃CONN
  →('t'≡KIND)⍴TLS
  Z←BYTES ⎕FIO[38] HANDLE       ⍝ returns bytes sent, or negative on error
  →0
TLS:
  R←BYTES CONVEXTLS[2] HANDLE
  →('K'=1⊃R)⍴OK
  Z←¯1
  →0
OK:
  Z←⍎2↓R
∇

⍝ Sends the whole byte vector, looping over short writes. Returns
⍝ ('k' totalSent) or ('e' message).
∇Z←CONN ConnSendAll BYTES;SENT;N;TOTAL
  TOTAL←⍴BYTES
  SENT←0
LOOP:
  →(SENT≥TOTAL)⍴DONE
  N←CONN ConnSend (SENT↓BYTES)
  →(N>0)⍴PROGRESS
  Z←JErr 'send made no progress'
  →0
PROGRESS:
  SENT←SENT+N
  →LOOP
DONE:
  Z←'k' SENT
∇

⍝ Reads up to MAXBYTES with a bound of TIMEOUTMS. Returns a tagged
⍝ value: ('d' bytes) | ('t' ⍬) timed out | ('c' ⍬) closed | ('e' msg).
⍝
⍝ The plain-socket path polls a non-blocking recv() in a short ⎕DL
⍝ sleep loop (see ConnConnect's comment on why, instead of select()).
⍝ ⎕FIO[37] recv() returns a byte vector (possibly empty, meaning EOF)
⍝ on success and a *negative scalar* -errno on failure; EAGAIN/EWOULDBLOCK
⍝ (errno 11 on Linux) means "no data yet", not an error.
∇Z←CONN ConnRecv PARAMS;KIND;HANDLE;MAXBYTES;TIMEOUTMS;R;DEADLINE
  KIND←1⊃CONN
  HANDLE←2⊃CONN
  MAXBYTES←1⊃PARAMS
  TIMEOUTMS←2⊃PARAMS
  →('t'≡KIND)⍴TLS
  DEADLINE←NowMs+TIMEOUTMS
PLAINPOLL:
  R←MAXBYTES ⎕FIO[37] HANDLE
  →(0=⍴⍴R)⍴PLAINERR
  →((⍴R)>0)⍴GOTDATA
  Z←'c' ⍬                       ⍝ 0-length vector: peer closed
  →0
PLAINERR:
  →(R=¯11)⍴PLAINWOULDBLOCK
  Z←JErr 'recv() failed'
  →0
PLAINWOULDBLOCK:
  →(NowMs>DEADLINE)⍴PLAINTIMEOUT
  ⎕DL 0.02
  →PLAINPOLL
PLAINTIMEOUT:
  Z←'t' ⍬
  →0
GOTDATA:
  Z←'d' R
  →0
TLS:
  R←(MAXBYTES TIMEOUTMS) CONVEXTLS[3] HANDLE
  →('D'=1⊃R)⍴TLSDATA
  →('T'=1⊃R)⍴TLSTIME
  →('C'=1⊃R)⍴TLSCLOSED
  Z←JErr 2↓R
  →0
TLSDATA:
  Z←'d' (⎕UCS 2↓R)
  →0
TLSTIME:
  Z←'t' ⍬
  →0
TLSCLOSED:
  Z←'c' ⍬
∇

∇Z←ConnClose CONN;KIND;HANDLE
  KIND←1⊃CONN
  HANDLE←2⊃CONN
  →('t'≡KIND)⍴TLS
  ⎕FIO[4] HANDLE
  Z←0
  →0
TLS:
  CONVEXTLS[4] HANDLE
  Z←0
∇

⍝ ================================================================
⍝ Timing
⍝
⍝ ⎕AI[3] is GNU APL's session elapsed time in milliseconds (ISO APL2's
⍝ ⎕AI: [1] user id [2] computation time [3] session/connect time [4]
⍝ keying time) -- real wall-clock elapsed time since the interpreter
⍝ started, unlike a CPU-time counter that would barely advance while
⍝ blocked in a socket read.
⍝ ================================================================

∇Z←NowMs
  Z←3⊃⎕AI
∇

⍝ ================================================================
⍝ HTTP/1.1
⍝ ================================================================

⍝ Splits a Convex base URL into (useTls host port). Accepts
⍝ scheme://host[:port] with no path.
∇Z←UrlParse URL;SCHEMEEND;REST;COLON;USETLS;HOST;PORT;SCHEMEPOS
  SCHEMEPOS←('://'⍷URL)⍳1        ⍝ index where "://" starts
  →(SCHEMEPOS≤(⍴URL)-2)⍴HASSCHEME  ⍝ a real match leaves room for all 3 bytes
  Z←JErr 'URL missing scheme'
  →0
HASSCHEME:
  SCHEMEEND←SCHEMEPOS-1           ⍝ length of the scheme prefix
  USETLS←('https'≡SCHEMEEND↑URL)∨('wss'≡SCHEMEEND↑URL)
  REST←(SCHEMEEND+3)↓URL
  COLON←REST⍳':'
  →(COLON≤⍴REST)⍴HASPORT
  HOST←REST
  →(USETLS≠0)⍴DEFHTTPS
  PORT←80
  →DONE
DEFHTTPS:
  PORT←443
  →DONE
HASPORT:
  HOST←(COLON-1)↑REST
  PORT←⍎(COLON)↓REST
DONE:
  Z←'k' (USETLS HOST PORT)
∇

⍝ Builds a POST /api/<op> request. BODYSTR is the JSON body as a
⍝ character vector; returns the full request as a byte vector.
∇Z←HttpBuildRequest PARAMS;OP;PATHTEXT;HOST;BODYSTR;TOKEN;REQ;CRLF
  OP←1⊃PARAMS
  BODYSTR←2⊃PARAMS
  HOST←3⊃PARAMS
  TOKEN←4⊃PARAMS
  CRLF←(⎕UCS 13),(⎕UCS 10)
  REQ←'POST /api/',OP,' HTTP/1.1',CRLF
  REQ←REQ,'Host: ',HOST,CRLF
  REQ←REQ,'Content-Type: application/json',CRLF
  REQ←REQ,'Accept: application/json',CRLF
  REQ←REQ,'Convex-Client: apl-0.1.0',CRLF
  →(0=⍴TOKEN)⍴NOAUTH
  REQ←REQ,'Authorization: Bearer ',TOKEN,CRLF
NOAUTH:
  REQ←REQ,'Content-Length: ',(⍕⍴BODYSTR),CRLF
  REQ←REQ,'Connection: close',CRLF,CRLF
  REQ←REQ,BODYSTR
  Z←BytesOfStr REQ
∇

⍝ Reads a full HTTP response (status line, headers, body) from CONN,
⍝ honouring Content-Length or chunked transfer-encoding, bounded by an
⍝ 8 MiB budget and a 15-second deadline. Returns ('k' (statusCode
⍝ bodyChars)) or ('e' message).
∇Z←HttpReadResponse CONN;BUF;DEADLINE;R;HEADEREND;HEADERTEXT;BODYSOFAR;STATUSLINE;RESTHEADERS;CONTENTLENGTH;CHUNKED;HEADERLINE;COLONPOS;HNAME;HVALUE;MAXBYTES;DECODED
  MAXBYTES←8388608
  DEADLINE←NowMs+15000
  BUF←⍬
  HEADEREND←0
HDRLOOP:
  →(HEADEREND>0)⍴HDRDONE
  →(NowMs>DEADLINE)⍴HDRTIMEOUT
  R←CONN ConnRecv (65536 5000)
  →('d'≡1⊃R)⍴HDRDATA
  →('t'≡1⊃R)⍴HDRLOOP
  →('c'≡1⊃R)⍴HDRCLOSED
  Z←R
  →0
HDRDATA:
  BUF←BUF,2⊃R
  →((⍴BUF)>MAXBYTES)⍴HDRTOOBIG
  HEADEREND←((13 10 13 10)⍷BUF)⍳1
  →(HEADEREND≤(⍴BUF)-3)⍴HDRLOOP  ⍝ a real match leaves room for all 4 bytes
  HEADEREND←0                    ⍝ ⍳1's "not found" value; keep looping
  →HDRLOOP
HDRCLOSED:
  Z←JErr 'connection closed before headers completed'
  →0
HDRTIMEOUT:
  Z←JErr 'timed out reading response headers'
  →0
HDRTOOBIG:
  Z←JErr 'response headers exceeded budget'
  →0
HDRDONE:
  HEADERTEXT←StrOfBytes (HEADEREND-1)↑BUF
  BODYSOFAR←(HEADEREND+3)↓BUF
  R←HEADERTEXT HeaderSplitFirstLine 0
  STATUSLINE←1⊃R
  RESTHEADERS←2⊃R
  CONTENTLENGTH←¯1
  CHUNKED←0
HPARSE:
  →(0=⍴RESTHEADERS)⍴HPARSEDONE
  R←RESTHEADERS HeaderSplitFirstLine 0
  HEADERLINE←1⊃R
  RESTHEADERS←2⊃R
  COLONPOS←HEADERLINE⍳':'
  →(COLONPOS>⍴HEADERLINE)⍴HPARSE
  HNAME←UpperStr HStrip (COLONPOS-1)↑HEADERLINE
  HVALUE←HStrip COLONPOS↓HEADERLINE
  →('CONTENT-LENGTH'≡HNAME)⍴SETLEN
  →('TRANSFER-ENCODING'≡HNAME)⍴SETCHUNK
  →HPARSE
SETLEN:
  CONTENTLENGTH←⍎HVALUE
  →HPARSE
SETCHUNK:
  →(~'CHUNKED'≡UpperStr HVALUE)⍴HPARSE
  CHUNKED←1
  →HPARSE
HPARSEDONE:
  →(CHUNKED≠0)⍴DOCHUNK
  →(CONTENTLENGTH≥0)⍴READLEN
  →READCLOSE
DOCHUNK:
  R←CONN HttpDechunk (BODYSOFAR DEADLINE)
  →('k'≡1⊃R)⍴CHUNKOK
  Z←R
  →0
CHUNKOK:
  Z←'k' ((HttpStatusCode STATUSLINE) (StrOfBytes 2⊃R))
  →0
READLEN:
  →((⍴BODYSOFAR)≥CONTENTLENGTH)⍴LENDONE
  →(NowMs>DEADLINE)⍴BODYTIMEOUT
  R←CONN ConnRecv (65536 5000)
  →('d'≡1⊃R)⍴LENDATA
  →('t'≡1⊃R)⍴READLEN
  →('c'≡1⊃R)⍴LENDONE
  Z←R
  →0
LENDATA:
  BODYSOFAR←BODYSOFAR,2⊃R
  →((⍴BODYSOFAR)>MAXBYTES)⍴BODYTOOBIG
  →READLEN
LENDONE:
  Z←'k' ((HttpStatusCode STATUSLINE) (StrOfBytes CONTENTLENGTH↑BODYSOFAR))
  →0
READCLOSE:
  →(NowMs>DEADLINE)⍴BODYTIMEOUT
  R←CONN ConnRecv (65536 5000)
  →('d'≡1⊃R)⍴CLOSEDATA
  →('t'≡1⊃R)⍴READCLOSE
  →('c'≡1⊃R)⍴CLOSEDONE
  Z←R
  →0
CLOSEDATA:
  BODYSOFAR←BODYSOFAR,2⊃R
  →((⍴BODYSOFAR)>MAXBYTES)⍴BODYTOOBIG
  →READCLOSE
CLOSEDONE:
  Z←'k' ((HttpStatusCode STATUSLINE) (StrOfBytes BODYSOFAR))
  →0
BODYTIMEOUT:
  Z←JErr 'timed out reading response body'
  →0
BODYTOOBIG:
  Z←JErr 'response body exceeded budget'
∇

∇Z←HttpStatusCode STATUSLINE
  Z←⍎2⊃HStrSplitWords STATUSLINE
∇

⍝ Splits TEXT (a character vector) at the first CRLF, into that line
⍝ (without the CRLF) and the remainder (also without it).
∇Z←TEXT HeaderSplitFirstLine DUMMY;POS;CRLF
  CRLF←⎕UCS 13 10
  POS←(CRLF⍷TEXT)⍳1
  →(POS≤(⍴TEXT)-1)⍴FOUND         ⍝ a real match leaves room for both bytes
  Z←TEXT ''
  →0
FOUND:
  Z←((POS-1)↑TEXT) ((POS+1)↓TEXT)
∇

∇Z←HStrip B;S;E
  S←1
  E←⍴B
LSTRIP:
  →(S>E)⍴EMPTY
  →(~(S⊃B)∊' ',(⎕UCS 9))⍴RSTRIP
  S←S+1
  →LSTRIP
RSTRIP:
  →(~(E⊃B)∊' ',(⎕UCS 9))⍴DONE
  E←E-1
  →RSTRIP
DONE:
  Z←(S-1)↓(E↑B)
  →0
EMPTY:
  Z←''
∇

∇Z←UpperStr B;ISLOWER
 ⍝⍝ ASCII-only uppercase, used for case-insensitive HTTP header names.
  ISLOWER←('a'≤B)∧(B≤'z')
  Z←⎕UCS (⎕UCS B)-32×ISLOWER
∇

∇Z←HStrSplitWords B;PARTS;CUR;I;C
  PARTS←⍬
  CUR←''
  I←1
LOOP:
  →(I>⍴B)⍴FLUSH
  C←I⊃B
  →(C=' ')⍴SPACE
  CUR←CUR,C
  I←I+1
  →LOOP
SPACE:
  →(0=⍴CUR)⍴SKIP
  PARTS←PARTS,⊂CUR
  CUR←''
SKIP:
  I←I+1
  →LOOP
FLUSH:
  →(0=⍴CUR)⍴Z1
  PARTS←PARTS,⊂CUR
Z1:
  Z←PARTS
∇

⍝ Converts a hex character vector to a nonnegative integer.
∇Z←HexToDec B;I;V;C
 ⍝⍝ B←,B: see JEscapeString's comment on scalar vs. vector characters.
  B←,B
  Z←0
  I←1
LOOP:
  →(I>⍴B)⍴DONE
  C←I⊃B
  →((C≥'0')∧(C≤'9'))⍴DIGIT
  →((C≥'a')∧(C≤'f'))⍴LOWER
  →((C≥'A')∧(C≤'F'))⍴UPPER
  →NEXT
DIGIT:
  V←(⎕UCS C)-⎕UCS '0'
  →ADD
LOWER:
  V←10+(⎕UCS C)-⎕UCS 'a'
  →ADD
UPPER:
  V←10+(⎕UCS C)-⎕UCS 'A'
ADD:
  Z←(16×Z)+V
NEXT:
  I←I+1
  →LOOP
DONE:
∇

⍝ Formats a non-negative integer B (0..65535) as exactly 4 lowercase
⍝ hex digits, using ⊤ (encode) into base 16 -- an array-language way to
⍝ do fixed-width radix conversion without a manual digit loop.
∇Z←HexPad4 B;DIGITS;HEXCHARS
  HEXCHARS←'0123456789abcdef'
  DIGITS←(4⍴16)⊤B
  Z←HEXCHARS[DIGITS+1]
∇

⍝ Decodes an HTTP chunked body already partially buffered in
⍝ (1⊃PARAMS), reading more from CONN as needed up to (2⊃PARAMS), a
⍝ deadline in ms. Returns ('k' bytes) or ('e' message).
∇Z←CONN HttpDechunk PARAMS;BUF;DEADLINE;OUT;R;LINEEND;SIZELINE;SIZE;SEMIPOS;CRLF
  BUF←1⊃PARAMS
  DEADLINE←2⊃PARAMS
  OUT←⍬
  CRLF←13 10
LOOP:
  LINEEND←(CRLF⍷BUF)⍳1
  →(LINEEND≤(⍴BUF)-1)⍴GOTLINE
  →(NowMs>DEADLINE)⍴TIMEOUTSIZE
  R←CONN ConnRecv (65536 5000)
  →('d'≡1⊃R)⍴MOREDATA
  →('t'≡1⊃R)⍴LOOP
  Z←JErr 'connection closed mid chunk'
  →0
MOREDATA:
  BUF←BUF,2⊃R
  →LOOP
GOTLINE:
  SIZELINE←(LINEEND-1)↑BUF
  BUF←(LINEEND+1)↓BUF
  SEMIPOS←SIZELINE⍳';'
  →(SEMIPOS≤⍴SIZELINE)⍴HASSEMI
  →SIZEOK
HASSEMI:
  SIZELINE←(SEMIPOS-1)↑SIZELINE
SIZEOK:
  SIZE←HexToDec StrOfBytes SIZELINE
BODYWAIT:
  →((⍴BUF)≥SIZE+2)⍴BODYOK
  →(NowMs>DEADLINE)⍴TIMEOUTBODY
  R←CONN ConnRecv (65536 5000)
  →('d'≡1⊃R)⍴BODYMORE
  →('t'≡1⊃R)⍴BODYWAIT
  Z←JErr 'connection closed mid chunk body'
  →0
BODYMORE:
  BUF←BUF,2⊃R
  →BODYWAIT
BODYOK:
  →(SIZE=0)⍴FINAL
  OUT←OUT,SIZE↑BUF
  BUF←(SIZE+2)↓BUF
  →LOOP
FINAL:
  Z←'k' OUT
  →0
TIMEOUTSIZE:
  Z←JErr 'timed out reading chunk size'
  →0
TIMEOUTBODY:
  Z←JErr 'timed out reading chunk body'
∇

⍝ ================================================================
⍝ http_call: query / mutation / action
⍝
⍝ PARAMS = (op path argsJsonText baseUrl token), op one of "query",
⍝ "mutation", "action"; argsJsonText is already-encoded JSON object
⍝ text; token is '' for none. Returns one JSON envelope as a character
⍝ vector:
⍝   {"type":"result","value":<json>}
⍝   {"type":"error","error":{"name":...,"message":...}}
⍝ matching the adapter protocol's own result/error shape.
⍝ ================================================================

∇Z←TransportError MSG
  Z←'{"type":"error","error":{"name":"TransportError","message":',(JEscapeString MSG),'}}'
∇

∇Z←ProtocolError MSG
  Z←'{"type":"error","error":{"name":"ProtocolError","message":',(JEscapeString MSG),'}}'
∇

∇Z←HttpCall PARAMS;OP;PATH;ARGSJSON;BASEURL;TOKEN;U;USETLS;HOST;PORT;BODYSTR;REQBYTES;CR;CONN;SR;RR;STATUSCODE;BODYTEXT
  OP←1⊃PARAMS
  PATH←2⊃PARAMS
  ARGSJSON←3⊃PARAMS
  BASEURL←4⊃PARAMS
  TOKEN←5⊃PARAMS

  U←UrlParse BASEURL
  →('k'≡1⊃U)⍴URLOK
  Z←ProtocolError 'invalid CONVEX_URL'
  →0
URLOK:
  USETLS←1⊃2⊃U
  HOST←2⊃2⊃U
  PORT←3⊃2⊃U

  BODYSTR←'{"path":',(JEscapeString PATH),',"args":',ARGSJSON,',"format":"json"}'
  REQBYTES←HttpBuildRequest (OP BODYSTR HOST TOKEN)

  CR←USETLS ConnConnect (HOST PORT)
  →('k'≡1⊃CR)⍴CONNOK
  Z←TransportError 'connect failed: ',2⊃CR
  →0
CONNOK:
  CONN←2⊃CR

  SR←CONN ConnSendAll REQBYTES
  →('k'≡1⊃SR)⍴SENDOK
  ConnClose CONN
  Z←TransportError 'send failed: ',2⊃SR
  →0
SENDOK:
  RR←HttpReadResponse CONN
  ConnClose CONN
  →('k'≡1⊃RR)⍴READOK
  Z←TransportError 2⊃RR
  →0
READOK:
  STATUSCODE←1⊃2⊃RR
  BODYTEXT←2⊃2⊃RR
  Z←HttpClassify (STATUSCODE BODYTEXT)
∇

⍝ Classifies a raw HTTP status + JSON body into the adapter-style
⍝ envelope, per the documented "format":"json" contract: 200 with
⍝ status:"success" is a result; 200 with status:"error", or HTTP 560
⍝ (Convex's function-threw status), is a structured FunctionError;
⍝ everything else is a ProtocolError.
∇Z←HttpClassify PARAMS;STATUSCODE;BODYTEXT;DOC;STATUSFIELD;MESSAGE;MSGFIELD;VALUEFIELD
  STATUSCODE←1⊃PARAMS
  BODYTEXT←2⊃PARAMS
  →((STATUSCODE=200)∨(STATUSCODE=560))⍴MAYBEJSON
  Z←TransportError 'unexpected HTTP status ',(⍕STATUSCODE)
  →0
MAYBEJSON:
  DOC←JParseDocument BODYTEXT
  →('e'≡1⊃DOC)⍴BADJSON
  →('o'≡1⊃DOC)⍴ISOBJ
  Z←ProtocolError 'HTTP response body was not a JSON object'
  →0
BADJSON:
  Z←ProtocolError 'HTTP response body was not valid JSON'
  →0
ISOBJ:
  →('status' JHas DOC)⍴HASSTATUS
  Z←ProtocolError 'HTTP response omitted status'
  →0
HASSTATUS:
  STATUSFIELD←'status' JGet DOC
  →(('s'≡1⊃STATUSFIELD)∧('success'≡2⊃STATUSFIELD)∧(STATUSCODE=200))⍴SUCCESS
  →FUNCERROR
SUCCESS:
  →('value' JHas DOC)⍴HASVALUE
  Z←ProtocolError 'HTTP success response omitted value'
  →0
HASVALUE:
  VALUEFIELD←'value' JGet DOC
  Z←'{"type":"result","value":',(JStringify VALUEFIELD),'}'
  →0
FUNCERROR:
  MESSAGE←'Convex function failed'
  →('errorMessage' JHas DOC)⍴HASERRMSG
  →('message' JHas DOC)⍴HASMSG
  →BUILDERR
HASERRMSG:
  MSGFIELD←'errorMessage' JGet DOC
  →('s'≡1⊃MSGFIELD)⍴USEMSG
  →BUILDERR
HASMSG:
  MSGFIELD←'message' JGet DOC
  →('s'≡1⊃MSGFIELD)⍴USEMSG
  →BUILDERR
USEMSG:
  MESSAGE←2⊃MSGFIELD
BUILDERR:
  Z←'{"type":"error","error":{"name":"FunctionError","message":',(JEscapeString MESSAGE),'}}'
∇

⍝ Reads environment variable NAME. ⎕ENV NAME returns a 1x2 matrix
⍝ (name value) when set, or an empty 0x2 matrix when not -- never a
⍝ plain vector, so a bare `2⊃` on it raises RANK ERROR when set and
⍝ INDEX ERROR when not; this normalises both cases to a character
⍝ vector, empty when unset.
∇Z←EnvGet NAME;X
  X←⎕ENV NAME
  →(0=1⊃⍴X)⍴NOTFOUND
  Z←2⊃,X
  →0
NOTFOUND:
  Z←''
∇

⍝ Writes TEXT plus a trailing newline to stderr (handle 2), looping
⍝ over short writes via ⎕FIO[42] (a plain write() syscall, unlike the
⍝ printf-style ⎕FIO[22], whose left-argument shape this project's own
⍝ testing found error-prone for a simple diagnostic line).
∇TEXT StdErr DUMMY;BYTES;SENT;TOTAL;N
  BYTES←BytesOfStr TEXT,⎕UCS 10
  TOTAL←⍴BYTES
  SENT←0
LOOP:
  →(SENT≥TOTAL)⍴DONE
  N←(SENT↓BYTES) ⎕FIO[42] 2
  →(N>0)⍴PROGRESS
  →DONE
PROGRESS:
  SENT←SENT+N
  →LOOP
DONE:
∇
