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
⍝ serves both modes.
⍝
⍝ Live needs command reads and WebSocket delivery to interleave on one
⍝ thread (see convexlive.apl's header comment on why this whole process
⍝ is the one worker), so INHANDLE is set non-blocking (the same fcntl
⍝ F_SETFL/O_NONBLOCK pattern client/convex.apl's own ConnConnect uses,
⍝ for the same ⎕FIO[40]-select-crashes reason) and RunAdapter's loop
⍝ polls it once per pass rather than blocking on a full line: a partial
⍝ command is carried in BUF across passes, and LiveServiceTick runs
⍝ once every pass so a query update is written out promptly instead of
⍝ waiting for the next command. WriteBytes tolerates EAGAIN (retrying
⍝ instead of truncating) because ADAPTER_LISTEN mode's OUTHANDLE is the
⍝ same fd as INHANDLE and therefore shares its non-blocking flag.

)COPY /opt/convex/client/convex.apl
)COPY /opt/convex/client/convexlive.apl
ConvexInit '/opt/convex/client/shim.so'

⍝ One non-blocking read attempt (never loops, never sleeps -- the
⍝ caller interleaves this with LiveServiceTick). Returns
⍝ ('d' bytes) | ('t' ⍬) no data available right now | ('c' ⍬) peer
⍝ closed | ('e' msg) a real read error.
∇Z←TryReadOnce HANDLE;R
  R←65536 ⎕FIO[41] HANDLE
  →(0=⍴⍴R)⍴ERRCASE
  →((⍴R)>0)⍴GOTDATA
  Z←'c' ⍬
  →0
ERRCASE:
  →(R=¯11)⍴WOULDBLOCK
  Z←JErr 'read() failed'
  →0
WOULDBLOCK:
  Z←'t' ⍬
  →0
GOTDATA:
  Z←'d' R
∇

⍝ Retries on EAGAIN (-11) instead of giving up, since ADAPTER_LISTEN
⍝ mode's OUTHANDLE shares INHANDLE's non-blocking flag (they are the
⍝ same accepted-socket fd) -- see this file's header comment.
∇WriteBytes PARAMS;HANDLE;BYTES;SENT;TOTAL;N;IGNORED
  HANDLE←1⊃PARAMS
  BYTES←2⊃PARAMS
  TOTAL←⍴BYTES
  SENT←0
LOOP:
  →(SENT≥TOTAL)⍴DONE
  N←(SENT↓BYTES) ⎕FIO[42] HANDLE
  →(N>0)⍴PROGRESS
  →(N=¯11)⍴WOULDBLOCK
  →DONE                          ⍝ write failed: nothing more we can do
WOULDBLOCK:
  IGNORED←⎕DL 0.005              ⍝ unassigned would auto-echo the seconds slept
  →LOOP
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

⍝ Pulls at most one complete NDJSON line (without its trailing LF) out
⍝ of the front of BUF. Pure: never touches a handle. Returns
⍝ ('k' (line newBuf)) one line consumed | ('n' ⍬) BUF holds no full
⍝ line yet -- keep accumulating.
∇Z←ExtractLine BUF;POS;LINE
  POS←(,10)⍷BUF
  POS←POS⍳1
  →(POS≤⍴BUF)⍴GOTLINE
  Z←'n' ⍬
  →0
GOTLINE:
  LINE←StrOfBytes (POS-1)↑BUF
  ⍝ Tolerate a trailing CR (CRLF-terminated controller stream).
  →((0<⍴LINE)∧(13=⎕UCS(⍴LINE)⊃LINE))⍴TRIMCR
  Z←'k' (LINE ((POS)↓BUF))
  →0
TRIMCR:
  Z←'k' (((⍴LINE)-1)↑LINE) ((POS)↓BUF)
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

⍝ Live: subscribe/unsubscribe/debugDisconnect are backed by the real
⍝ WebSocket /api/sync client in client/convexlive.apl. LIVEACTIVE (a
⍝ RunAdapter-scope global, 0 until the first Live command) gates
⍝ whether the main loop's per-tick LiveServiceTick call runs at all --
⍝ a pure-HTTP conformance run never opens a socket it does not need.
∇EnsureLiveInit;OK
  →(LIVEACTIVE≠0)⍴0
  OK←LiveInit CONVEXURL
  →(OK≠0)⍴INITOK
  LIVEACTIVE←0
  →0
INITOK:
  LIVEACTIVE←1
∇

⍝ Registers the subscription and acks immediately, matching the
⍝ reference JS adapter: the ack means "tracked", not "first value
⍝ delivered" -- the value itself arrives later as a separate
⍝ {"type":"subscription",...} event, from EmitLiveEvents below.
∇HandleSubscribe PARAMS;OUTHANDLE;ID;DOC;SUBIDR;PATHR;ARGSR;ARGSJSON
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  DOC←3⊃PARAMS
  SUBIDR←RawGetString (DOC 'subscriptionId')
  →('k'≡1⊃SUBIDR)⍴HASSUBID
  EmitProtocolError (OUTHANDLE ID 'subscribe command omitted subscriptionId')
  →0
HASSUBID:
  PATHR←RawGetString (DOC 'path')
  →('k'≡1⊃PATHR)⍴HASPATH
  EmitProtocolError (OUTHANDLE ID 'subscribe command omitted a valid path')
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
  EnsureLiveInit
  →(LIVEACTIVE≠0)⍴LIVEOK
  EmitProtocolError (OUTHANDLE ID 'CONVEX_URL is not a usable Live endpoint')
  →0
LIVEOK:
  LiveSubscribe ((2⊃SUBIDR) (2⊃PATHR) ARGSJSON)
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"ack"}'))
∇

∇HandleUnsubscribe PARAMS;OUTHANDLE;ID;DOC;SUBIDR
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  DOC←3⊃PARAMS
  SUBIDR←RawGetString (DOC 'subscriptionId')
  →('k'≡1⊃SUBIDR)⍴HASSUBID
  EmitProtocolError (OUTHANDLE ID 'unsubscribe command omitted subscriptionId')
  →0
HASSUBID:
  →(LIVEACTIVE≠0)⍴LIVEOK
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"ack"}'))
  →0
LIVEOK:
  LiveUnsubscribe (2⊃SUBIDR)
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"ack"}'))
∇

⍝ Acks only after the old connection is fully retired and the next
⍝ reconnect attempt is scheduled (both happen synchronously inside
⍝ LiveDebugDisconnect -- see its header comment in convexlive.apl) so a
⍝ controller that has already seen this ack can safely require the
⍝ next Connect to observe the new connectionCount.
∇HandleDebugDisconnect PARAMS;OUTHANDLE;ID
  OUTHANDLE←1⊃PARAMS
  ID←2⊃PARAMS
  EnsureLiveInit
  →(LIVEACTIVE≠0)⍴LIVEOK
  EmitProtocolError (OUTHANDLE ID 'CONVEX_URL is not a usable Live endpoint')
  →0
LIVEOK:
  LiveDebugDisconnect
  Emit (OUTHANDLE ('{"id":',(JEscapeString ID),',"type":"ack"}'))
∇

⍝ Writes out every (subscriptionId kind payload) triple LiveServiceTick
⍝ just produced, as {"type":"subscription",...} events -- 'v' becomes a
⍝ value delivery, 'e' a structured FunctionError.
∇EmitLiveEvents PARAMS;OUTHANDLE;EVENTS;I;EV;SUBID;KIND;PAYLOAD;NAME;MSG;HASDATA;DATATEXT
  OUTHANDLE←1⊃PARAMS
  EVENTS←2⊃PARAMS
  I←1
LOOP:
  →(I≤⍴EVENTS)⍴ONE
  →0
ONE:
  EV←I⊃EVENTS
  SUBID←1⊃EV
  KIND←2⊃EV
  PAYLOAD←3⊃EV
  →('v'≡KIND)⍴DOVALUE
  →DOERROR
DOVALUE:
  Emit (OUTHANDLE ('{"type":"subscription","subscriptionId":',(JEscapeString SUBID),',"value":',(JStringify PAYLOAD),',"logs":[]}'))
  →NEXT
DOERROR:
  NAME←1⊃PAYLOAD
  MSG←2⊃PAYLOAD
  HASDATA←3⊃PAYLOAD
  DATATEXT←'null'
  →(HASDATA=0)⍴NEXTDATA
  DATATEXT←JStringify 4⊃PAYLOAD
NEXTDATA:
  Emit (OUTHANDLE ('{"type":"subscription","subscriptionId":',(JEscapeString SUBID),',"error":{"name":',(JEscapeString NAME),',"message":',(JEscapeString MSG),',"data":',DATATEXT,'}}'))
NEXT:
  I←I+1
  →LOOP
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
  →('subscribe'≡OP)⍴DOSUB
  →('unsubscribe'≡OP)⍴DOUNSUB
  →('debugDisconnect'≡OP)⍴DODEBUG
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
DOSUB:
  HandleSubscribe (OUTHANDLE ID DOC)
  →0
DOUNSUB:
  HandleUnsubscribe (OUTHANDLE ID DOC)
  →0
DODEBUG:
  HandleDebugDisconnect (OUTHANDLE ID)
  →0
DOCLOSE:
  →(LIVEACTIVE≠0)⍴DOCLOSELIVE
  Z←HandleClose (OUTHANDLE ID)
  →0
DOCLOSELIVE:
  LiveClose
  Z←HandleClose (OUTHANDLE ID)
∇

∇RunAdapter;LISTENSPEC;INHANDLE;OUTHANDLE;BUF;R;CLOSEDFLAG;LISTENHANDLE;COLONPOS;BINDPORT;ACCEPTR;IGNORED;ER;RR
  CONVEXURL←EnvGet 'CONVEX_URL'
  AUTHTOKEN←''
  LIVEACTIVE←0
  LISTENSPEC←EnvGet 'ADAPTER_LISTEN'
  →(0=⍴LISTENSPEC)⍴STDIO
  COLONPOS←LISTENSPEC⍳':'          ⍝ single-char search: fine as-is
  BINDPORT←⍎(COLONPOS)↓LISTENSPEC
  LISTENHANDLE←⎕FIO[32] 2
  IGNORED←(2 0 BINDPORT) ⎕FIO[33] LISTENHANDLE  ⍝ unassigned would auto-echo
  IGNORED←(10 ⎕FIO[34] LISTENHANDLE)
  ACCEPTR←⎕FIO[35] LISTENHANDLE
  IGNORED←⎕FIO[4] LISTENHANDLE
  INHANDLE←1⊃ACCEPTR
  OUTHANDLE←INHANDLE
  →SETUP
STDIO:
  INHANDLE←0
  OUTHANDLE←1
SETUP:
  ⍝ F_SETFL O_NONBLOCK (4 2048 on Linux) -- see this file's header
  ⍝ comment. Harmless in the pure-HTTP case too: EAGAIN just means
  ⍝ "no command yet", handled the same as a slow controller.
  IGNORED←(4 2048) ⎕FIO[59] INHANDLE   ⍝ unassigned would auto-echo
  BUF←⍬
  CLOSEDFLAG←0
LOOP:
  →(CLOSEDFLAG≠0)⍴DONE
  ⍝ Drain every complete command already sitting in BUF before asking
  ⍝ for more bytes, so a controller that pipelines several lines in one
  ⍝ write doesn't wait a whole tick per line.
EXTRACT:
  ER←ExtractLine BUF
  →('k'≡1⊃ER)⍴GOTLINE
  →READMORE
GOTLINE:
  BUF←2⊃2⊃ER
  CLOSEDFLAG←DispatchLine (OUTHANDLE (1⊃2⊃ER))
  →(CLOSEDFLAG≠0)⍴DONE
  →EXTRACT
READMORE:
  RR←TryReadOnce INHANDLE
  →('d'≡1⊃RR)⍴GOTDATA
  →('t'≡1⊃RR)⍴TICK
  →DONE                          ⍝ 'c' closed or 'e' error: stop
GOTDATA:
  BUF←BUF,2⊃RR
  →EXTRACT
TICK:
  ⍝ BUG FOUND (and fixed) only under a long sustained conformance run
  ⍝ against the hosted target: this used to `→LOOP` straight back to
  ⍝ EXTRACT/READMORE without ever reaching IDLE's sleep whenever
  ⍝ LIVEACTIVE was set, turning the whole loop into an unthrottled
  ⍝ busy-spin the instant any Live command had been issued -- tens of
  ⍝ thousands of TryReadOnce/LiveServiceTick passes per second, each a
  ⍝ handful of small APL allocations that add up under that much
  ⍝ churn. Confirmed with a cgroup memory trace: flat around 22 MiB
  ⍝ through every HTTP and the first Live test, then climbing
  ⍝ continuously (not one spike) to past a 128 MiB limit within about
  ⍝ two seconds of Live going active, OOM-killing the adapter
  ⍝ mid-pilot-run. Falling through to IDLE's sleep here regardless of
  ⍝ LIVEACTIVE, the same one-tick-per-pass cadence the rest of this
  ⍝ loop already uses, fixed it.
  →(LIVEACTIVE=0)⍴IDLE
  EmitLiveEvents (OUTHANDLE LiveServiceTick)
IDLE:
  IGNORED←⎕DL 0.01               ⍝ unassigned would auto-echo the seconds slept
  →LOOP
DONE:
  →(LIVEACTIVE=0)⍴0
  LiveClose
∇

RunAdapter
)OFF
