#!/usr/local/bin/apl --script
⍝ NDJSON adapter protocol v1 for the native GNU APL Convex client.
⍝
⍝ This is test infrastructure, not public client code: a thin
⍝ translator between the shared harness's newline-delimited JSON
⍝ commands and the real client operations in
⍝ /opt/convex/client/convex.apl (the same file the canonical example
⍝ uses). Every HTTP request happens inside that file; this file only
⍝ decodes commands, calls it, and encodes the results.
⍝
⍝ Without ADAPTER_LISTEN this reads stdin (handle 0) and writes stdout
⍝ (handle 1) -- both pre-registered ⎕FIO handles, kept as two separate
⍝ handles throughout this file rather than one, since a single "the
⍝ handle" would otherwise try to write NDJSON events back into stdin.
⍝ With ADAPTER_LISTEN, it binds that address, accepts exactly one
⍝ controller connection, and uses that one accepted socket handle for
⍝ both directions instead. ⎕FIO[41]/[42] (read/write) work identically
⍝ on a plain fd or an accepted socket fd, so one pair of helpers below
⍝ serves both modes -- no Conn* wrapper needed here, and no
⍝ non-blocking polling either, since this adapter (Live not yet
⍝ implemented) only ever does one blocking read at a time between
⍝ commands.

)COPY /opt/convex/client/convex.apl
ConvexInit '/opt/convex/client/shim.so'

∇Z←ReadBytes HANDLE
  Z←65536 ⎕FIO[41] HANDLE
∇

∇WriteBytes PARAMS;HANDLE;BYTES;SENT;TOTAL;N
  HANDLE←1⊃PARAMS
  BYTES←2⊃PARAMS
  TOTAL←⍴BYTES
  SENT←0
LOOP:
  →(SENT≥TOTAL)⍴DONE
  N←(SENT↓BYTES) ⎕FIO[42] HANDLE
  →(N>0)⍴PROGRESS
  →DONE                          ⍝ write failed: nothing more we can do
PROGRESS:
  SENT←SENT+N
  →LOOP
DONE:
∇

∇Emit PARAMS;OUTHANDLE;TEXT
  OUTHANDLE←1⊃PARAMS
  TEXT←2⊃PARAMS
  WriteBytes (OUTHANDLE (BytesOfStr TEXT,⎕UCS 10))
∇

⍝ Reads one NDJSON line (without its trailing LF) from INHANDLE, using
⍝ BUF as carried-over bytes from the previous call. Returns
⍝ ('k' (line newBuf)) | ('c' newBuf) closed | ('e' msg).
∇Z←INHANDLE ReadLine BUF;POS;R;LINE
LOOP:
  POS←(,10)⍷BUF
  POS←POS⍳1
  →(POS≤⍴BUF)⍴GOTLINE
  R←ReadBytes INHANDLE
  →((⍴R)>0)⍴MORE
  →(0=⍴BUF)⍴CLOSED
  Z←'k' ((StrOfBytes BUF) ⍬)      ⍝ final partial line before EOF
  →0
MORE:
  BUF←BUF,R
  →LOOP
GOTLINE:
  LINE←StrOfBytes (POS-1)↑BUF
  ⍝ Tolerate a trailing CR (CRLF-terminated controller stream).
  →((0<⍴LINE)∧(13=⎕UCS(⍴LINE)⊃LINE))⍴TRIMCR
  Z←'k' (LINE ((POS)↓BUF))
  →0
TRIMCR:
  Z←'k' (((⍴LINE)-1)↑LINE) ((POS)↓BUF)
  →0
CLOSED:
  Z←'c' BUF
∇

∇Z←RawGetString PARAMS;DOC;KEY;FIELD
 ⍝⍝ PARAMS=(doc key). Returns ('k' text) if key is present and a
 ⍝⍝ string, else ('e' ⍬).
  DOC←1⊃PARAMS
  KEY←2⊃PARAMS
  →(KEY JHas DOC)⍴HAS
  Z←'e' ⍬
  →0
HAS:
  FIELD←KEY JGet DOC
  →('s'≡1⊃FIELD)⍴ISSTR
  Z←'e' ⍬
  →0
ISSTR:
  Z←'k' (2⊃FIELD)
∇

∇EmitProtocolError PARAMS;OUTHANDLE;ID;MSG;IDPART
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  MSG←3⊃PARAMS
  IDPART←''
  →(0=⍴ID)⍴NOID
  IDPART←'"id":',(JEscapeString ID),','
NOID:
  Emit (OUTHANDLE ('{',IDPART,'"type":"error","error":{"name":"ProtocolError","message":',(JEscapeString MSG),'}}'))
∇

⍝ Splices "id":<id>, into a {"type":...}-leading JSON object literal
⍝ produced by HttpClassify, so the emitted event carries the command's
⍝ id without re-parsing/re-serialising the whole envelope.
∇Z←WithId PARAMS;ID;JSON
  ID←1⊃PARAMS
  JSON←2⊃PARAMS
  Z←'{"id":',(JEscapeString ID),',',(1↓JSON)
∇

∇HandleHello PARAMS;OUTHANDLE;ID;DOC;PV
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  DOC←3⊃PARAMS
  →('protocolVersion' JHas DOC)⍴HASPV
  EmitProtocolError (OUTHANDLE ID 'command omitted protocolVersion')
  →0
HASPV:
  PV←'protocolVersion' JGet DOC
  →(('n'≡1⊃PV)∧(1=2⊃PV))⍴PVOK
  EmitProtocolError (OUTHANDLE ID 'unsupported protocolVersion')
  →0
PVOK:
  Emit (OUTHANDLE ('{"protocolVersion":1,"id":',(JEscapeString ID),',"type":"ready","language":"apl","implementation":"native-gnu-apl-0.1.0","runtime":"GNU APL 2.0"}'))
∇

∇HandleCall PARAMS;OUTHANDLE;ID;DOC;OP;PATHR;ARGSR;ARGSJSON;ENVELOPE
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  DOC←3⊃PARAMS
  OP←4⊃PARAMS
  PATHR←RawGetString (DOC 'path')
  →('k'≡1⊃PATHR)⍴HASPATH
  EmitProtocolError (OUTHANDLE ID 'command omitted a valid path')
  →0
HASPATH:
  ARGSJSON←'{}'
  →('args' JHas DOC)⍴HASARGS
  →CALLIT
HASARGS:
  ARGSR←'args' JGet DOC
  →('o'≡1⊃ARGSR)⍴ARGSOBJ
  →CALLIT
ARGSOBJ:
  ARGSJSON←JStringify ARGSR
CALLIT:
  ENVELOPE←HttpCall (OP (2⊃PATHR) ARGSJSON CONVEXURL AUTHTOKEN)
  Emit (OUTHANDLE (WithId (ID ENVELOPE)))
∇

∇HandleSetAuth PARAMS;OUTHANDLE;ID;DOC;TOKR
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  DOC←3⊃PARAMS
  TOKR←RawGetString (DOC 'token')
  →('k'≡1⊃TOKR)⍴HASTOK
  AUTHTOKEN←''
  →ACKIT
HASTOK:
  AUTHTOKEN←2⊃TOKR
ACKIT:
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"ack"}'))
∇

⍝ Live is not yet implemented in this client: subscribe/unsubscribe/
⍝ debugDisconnect answer honestly with a structured error rather than
⍝ a fabricated ack, so shared conformance fails those tests cleanly
⍝ instead of hanging or reporting a false success.
∇HandleLiveUnsupported PARAMS;OUTHANDLE;ID
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"error","error":{"name":"ProtocolError","message":"Live is not implemented in this client"}}'))
∇

∇Z←HandleClose PARAMS;OUTHANDLE;ID
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  →(0=⍴ID)⍴NOID
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"closed"}'))
  Z←1
  →0
NOID:
  Emit (OUTHANDLE ('{"type":"closed"}'))
  Z←1
∇

∇Z←DispatchLine PARAMS;OUTHANDLE;LINE;DOC;OPR;IDR;OP;ID
  OUTHANDLE←1⊃PARAMS
  LINE←2⊃PARAMS
  Z←0
  →(0<⍴LINE)⍴NONEMPTY
  →0
NONEMPTY:
  DOC←JParseDocument LINE
  →('o'≡1⊃DOC)⍴ISOBJ
  EmitProtocolError (OUTHANDLE '' 'command was not a JSON object')
  →0
ISOBJ:
  IDR←RawGetString (DOC 'id')
  ID←''
  →('k'≢1⊃IDR)⍴NOIDFIELD
  ID←2⊃IDR
NOIDFIELD:
  OPR←RawGetString (DOC 'op')
  →('k'≡1⊃OPR)⍴HASOP
  EmitProtocolError (OUTHANDLE ID 'command omitted a valid op')
  →0
HASOP:
  OP←2⊃OPR
  →('hello'≡OP)⍴DOHELLO
  →(('query'≡OP)∨('mutation'≡OP)∨('action'≡OP))⍴DOCALL
  →('setAuth'≡OP)⍴DOAUTH
  →(('subscribe'≡OP)∨('unsubscribe'≡OP)∨('debugDisconnect'≡OP))⍴DOLIVE
  →('close'≡OP)⍴DOCLOSE
  EmitProtocolError (OUTHANDLE ID 'unrecognised op ',OP)
  →0
DOHELLO:
  HandleHello (OUTHANDLE ID DOC)
  →0
DOCALL:
  HandleCall (OUTHANDLE ID DOC OP)
  →0
DOAUTH:
  HandleSetAuth (OUTHANDLE ID DOC)
  →0
DOLIVE:
  HandleLiveUnsupported (OUTHANDLE ID)
  →0
DOCLOSE:
  Z←HandleClose (OUTHANDLE ID)
∇

∇RunAdapter;LISTENSPEC;INHANDLE;OUTHANDLE;BUF;R;CLOSEDFLAG;LISTENHANDLE;COLONPOS;BINDPORT;ACCEPTR
  CONVEXURL←EnvGet 'CONVEX_URL'
  AUTHTOKEN←''
  LISTENSPEC←EnvGet 'ADAPTER_LISTEN'
  →(0=⍴LISTENSPEC)⍴STDIO
  COLONPOS←LISTENSPEC⍳':'          ⍝ single-char search: fine as-is
  BINDPORT←⍎(COLONPOS)↓LISTENSPEC
  LISTENHANDLE←⎕FIO[32] 2
  ((2 0 BINDPORT) ⎕FIO[33] LISTENHANDLE)
  (10 ⎕FIO[34] LISTENHANDLE)
  ACCEPTR←⎕FIO[35] LISTENHANDLE
  ⎕FIO[4] LISTENHANDLE
  INHANDLE←1⊃ACCEPTR
  OUTHANDLE←INHANDLE
  →SETUP
STDIO:
  INHANDLE←0
  OUTHANDLE←1
SETUP:
  BUF←⍬
  CLOSEDFLAG←0
LOOP:
  →(CLOSEDFLAG≠0)⍴DONE
  R←INHANDLE ReadLine BUF
  →('k'≡1⊃R)⍴GOTLINE
  →DONE                          ⍝ 'c' (closed) or 'e': stop the loop
GOTLINE:
  BUF←2⊃2⊃R
  CLOSEDFLAG←DispatchLine (OUTHANDLE (1⊃2⊃R))
  →LOOP
DONE:
∇

RunAdapter
)OFF
