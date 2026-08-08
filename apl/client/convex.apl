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
  OUT←,'"'
  I←1
LOOP:
  →(I>⍴B)⍴DONE
  C←I⊃B
  →(C=34)⍴Q
  →(C=92)⍴BS
  →(C=10)⍴NL
  →(C=13)⍴CR
  →(C=9)⍴TB
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
  OUT←OUT,'\u',4↑(4-⍴,⍕⎕UCS C)⍴'0',⍕⎕UCS C
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
