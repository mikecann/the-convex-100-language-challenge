#!/usr/local/bin/apl --script
⍝ Convex from GNU APL: the canonical shared-counter walk. This is the
⍝ exact source shown in the README and on the website, and it is also
⍝ what Docker verification runs against a live deployment -- there is
⍝ no separate "test" copy of this file.
⍝
⍝ It reuses the same client library the conformance adapter calls
⍝ into: client/convex.apl (the Convex HTTP protocol itself, in APL --
⍝ JSON encoding/decoding and HTTP/1.1 request/response framing) and
⍝ client/convexlive.apl (RFC 6455 WebSocket framing and the Convex
⍝ /api/sync sync-protocol state machine, also in APL), both installed
⍝ under /opt/convex/client/. The only things either delegates outside
⍝ APL are raw TCP/TLS bytes, SHA-1, and CSPRNG bytes, via a small
⍝ native function (client/shim.cc) loaded with dyadic ⎕FX -- GNU APL's
⍝ documented foreign-function mechanism.

)COPY /opt/convex/client/convex.apl
)COPY /opt/convex/client/convexlive.apl
ConvexInit '/opt/convex/client/shim.so'

⍝ GNU APL's top-level (non-function) script statements cannot use
⍝ labels/branches ("Illegal : in immediate execution" -- discovered
⍝ while writing this client's own tests), so all of this example's
⍝ control flow lives in one function, Main, called at the bottom.
∇Main;CONVEXURL;ROOM;CURRENT;CURRENTCOUNT;RUNID;MUTATION;MUTVALUE;APPLIED;MUTATIONCOUNT;SUBID;LIVEINITIAL
  CONVEXURL←EnvGet 'CONVEX_URL'
  →(0<⍴CONVEXURL)⍴HASURL
  'CONVEX_URL is required' StdErr 0
  →0
HASURL:
  ROOM←RoomArg
  →(0<⍴ROOM)⍴HASROOM
  ROOM←'apl-example'
HASROOM:

  ⍝ The initial HTTP query.
  CURRENT←HttpCall ('query' 'demo:state' (StateArgs ROOM) CONVEXURL '')
  →(ResultOk CURRENT)⍴CURRENTOK
  RequireResult CURRENT 'current query'
  →0
CURRENTOK:
  CURRENTCOUNT←RequireWholeCount (ResultValue CURRENT) 'current query'
  →(CURRENTCOUNT=0)⍴CURRENTZEROOK
  ('current count was ',(⍕CURRENTCOUNT),', expected 0') StdErr 0
  →0
CURRENTZEROOK:
  'current count: ',⍕CURRENTCOUNT

  ⍝ Live is started before the mutation, exactly like this project's
  ⍝ other clients, so no reactive update can land before this process
  ⍝ is subscribed to see it. LiveInit opens no socket by itself --
  ⍝ ConnectNow (inside the first LiveServiceTick call, driven from
  ⍝ WaitForLiveValue below) does the real TCP/TLS connect, the RFC 6455
  ⍝ handshake, and the initial Connect/ModifyQuerySet messages.
  →(LiveInit CONVEXURL)⍴LIVEINITOK
  'could not start Live: CONVEX_URL was not a usable endpoint' StdErr 0
  →0
LIVEINITOK:
  SUBID←'apl-example-state'
  LiveSubscribe (SUBID 'demo:state' (StateArgs ROOM))
  LIVEINITIAL←WaitForLiveValue (SUBID 0 'live initial value')
  →(LIVEINITIAL≠¯1)⍴LIVEINITIALOK
  →0
LIVEINITIALOK:
  'live initial count: ',⍕LIVEINITIAL

  ⍝ A unique runId is the mutation's idempotency key: retrying this
  ⍝ exact logical request would not double-increment the room.
  RUNID←'apl-',(⍕NowMs)
  MUTATION←HttpCall ('mutation' 'demo:increment' (IncrementArgs (ROOM RUNID)) CONVEXURL '')
  →(ResultOk MUTATION)⍴MUTOK
  RequireResult MUTATION 'mutation'
  →0
MUTOK:
  MUTVALUE←ResultValue MUTATION
  APPLIED←'applied' JGet MUTVALUE
  →(('b'≡1⊃APPLIED)∧(0≠2⊃APPLIED))⍴APPLIEDOK
  'mutation was not applied' StdErr 0
  →0
APPLIEDOK:
  'mutation applied: true'
  MUTATIONCOUNT←RequireWholeCount ('state' JGet MUTVALUE) 'mutation'
  →(MUTATIONCOUNT=1)⍴MUTATIONONEOK
  ('mutation count was ',(⍕MUTATIONCOUNT),', expected 1') StdErr 0
  →0
MUTATIONONEOK:
  'mutation count: ',⍕MUTATIONCOUNT

  ⍝ Rather than a follow-up HTTP query, the mutation's durability is
  ⍝ proven by the same Live subscription observing the change reactively
  ⍝ -- the array-language habit above of keeping "current state" as one
  ⍝ value applies just as well here: the subscription already tracks
  ⍝ demo:state for this room, so its next delivered update is simply
  ⍝ awaited, not re-queried.
  →(¯1≠WaitForLiveValue (SUBID 1 'live updated value'))⍴LIVEUPDATEDOK
  →0
LIVEUPDATEDOK:
  'live updated count: 1'
  LiveUnsubscribe SUBID
  LiveClose

  'verified count: 0 -> 1'
∇

⍝ ---- helpers ----
⍝ Each handles one failure a real run can hit and explains why it is
⍝ checked, rather than trusting the shape of a successful response.

∇Z←RoomArg;ARGV;I
 ⍝⍝ ⎕ARG is a NESTED vector of separate argument tokens (not one flat
 ⍝⍝ command-line string, despite printing space-separated with no
 ⍝⍝ visible brackets -- confirmed with ⍴/≡ before trusting it here);
 ⍝⍝ the room is whatever token follows this script's own "--" token.
  ARGV←⎕ARG
  I←1
LOOP:
  →(I>⍴ARGV)⍴NOTFOUND
  →('--'≡I⊃ARGV)⍴FOUNDSEP
  I←I+1
  →LOOP
FOUNDSEP:
  →((I+1)≤⍴ARGV)⍴HASROOM
NOTFOUND:
  Z←''
  →0
HASROOM:
  Z←(I+1)⊃ARGV
∇

∇Z←StateArgs ROOM
  Z←'{"room":',(JEscapeString ROOM),'}'
∇

∇Z←IncrementArgs PARAMS;ROOM;RUNID
  ROOM←1⊃PARAMS
  RUNID←2⊃PARAMS
  Z←'{"room":',(JEscapeString ROOM),',"language":"APL","runId":',(JEscapeString RUNID),'}'
∇

∇Z←ResultOk ENVELOPE;DOC
  DOC←JParseDocument ENVELOPE
  Z←('o'≡1⊃DOC)∧('type' JHas DOC)∧('s'≡1⊃('type' JGet DOC))∧('result'≡2⊃('type' JGet DOC))
∇

∇Z←ResultValue ENVELOPE
  Z←'value' JGet JParseDocument ENVELOPE
∇

∇RequireResult PARAMS;ENVELOPE;LABEL
  ENVELOPE←1⊃PARAMS
  LABEL←2⊃PARAMS
  (LABEL,' failed: ',ENVELOPE) StdErr 0
∇

∇Z←RequireWholeCount PARAMS;VALUE;LABEL;COUNTFIELD;N
  VALUE←1⊃PARAMS
  LABEL←2⊃PARAMS
  →('count' JHas VALUE)⍴HASCOUNT
  (LABEL,' response omitted count') StdErr 0
  Z←¯1
  →0
HASCOUNT:
  COUNTFIELD←'count' JGet VALUE
  N←JWholeNumber COUNTFIELD
  →(N≠¯1)⍴GOOD
  (LABEL,' count was not a finite whole number') StdErr 0
  Z←¯1
  →0
GOOD:
  Z←N
∇

⍝ Polls Live (one LiveServiceTick per pass -- the same non-blocking
⍝ single-worker pattern the adapter uses, documented in convexlive.apl)
⍝ until SUBID's tracked subscription delivers a value whose count
⍝ matches EXPECTED, a delivery error, or a 10-second deadline passes.
⍝ Returns EXPECTED on a match, ¯1 (StdErr already told the operator
⍝ why) otherwise.
∇Z←WaitForLiveValue PARAMS;SUBID;EXPECTED;LABEL;DEADLINE;EVENTS;I;EV;COUNT;IGNORED
  SUBID←1⊃PARAMS
  EXPECTED←2⊃PARAMS
  LABEL←3⊃PARAMS
  DEADLINE←NowMs+10000
LOOP:
  →(NowMs≤DEADLINE)⍴TRYTICK
  (LABEL,' timed out waiting for a Live update') StdErr 0
  Z←¯1
  →0
TRYTICK:
  EVENTS←LiveServiceTick
  I←1
SCAN:
  →(I≤⍴EVENTS)⍴CHK
  →SLEEP
CHK:
  EV←I⊃EVENTS
  →(SUBID≡1⊃EV)⍴MATCHSUB
  I←I+1
  →SCAN
MATCHSUB:
  →('v'≡2⊃EV)⍴GOTVALUE
  (LABEL,' received a Live error instead of a value') StdErr 0
  Z←¯1
  →0
GOTVALUE:
  COUNT←RequireWholeCount (3⊃EV) LABEL
  Z←¯1                            ⍝ default result: failure (Z is reassigned below on a match)
  →(COUNT=¯1)⍴0                  ⍝ RequireWholeCount already reported why
  →(COUNT=EXPECTED)⍴MATCHOK
  (LABEL,' live count was ',(⍕COUNT),', expected ',⍕EXPECTED) StdErr 0
  →0
MATCHOK:
  Z←COUNT
  →0
SLEEP:
  IGNORED←⎕DL 0.02                ⍝ unassigned would auto-echo the seconds slept
  →LOOP
∇

Main
)OFF
