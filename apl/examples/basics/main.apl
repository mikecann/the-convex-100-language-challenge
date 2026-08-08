#!/usr/local/bin/apl --script
⍝ Convex from GNU APL: the canonical shared-counter walk. This is the
⍝ exact source shown in the README and on the website, and it is also
⍝ what Docker verification runs against a live deployment -- there is
⍝ no separate "test" copy of this file.
⍝
⍝ It reuses the same client library the conformance adapter calls
⍝ into, client/convex.apl, installed at /opt/convex/client/convex.apl.
⍝ convex.apl implements the Convex HTTP protocol itself in APL (JSON
⍝ encoding/decoding and HTTP/1.1 request/response framing); the only
⍝ things it delegates outside APL are raw TCP/TLS bytes and one hash
⍝ primitive, via a small native function (client/shim.cc) loaded with
⍝ dyadic ⎕FX -- GNU APL's documented foreign-function mechanism.
⍝
⍝ LIMITATION, stated up front rather than hidden in a comment at the
⍝ bottom: Live (the WebSocket /api/sync subscription this project's
⍝ other clients use for their "live initial count"/"live updated
⍝ count" lines) is not implemented yet. This example demonstrates the
⍝ HTTP half of the walk only -- the initial query, the mutation and
⍝ its idempotency key, and a follow-up query proving the mutation
⍝ landed -- and its output does not (yet) match this project's shared
⍝ basics.expected.txt, which requires both transports. See the
⍝ project's manifest.yaml/README for the honest capability list.

)COPY /opt/convex/client/convex.apl
ConvexInit '/opt/convex/client/shim.so'

⍝ GNU APL's top-level (non-function) script statements cannot use
⍝ labels/branches ("Illegal : in immediate execution" -- discovered
⍝ while writing this client's own tests), so all of this example's
⍝ control flow lives in one function, Main, called at the bottom.
∇Main;CONVEXURL;ROOM;CURRENT;CURRENTCOUNT;RUNID;MUTATION;MUTVALUE;APPLIED;MUTATIONCOUNT;FOLLOWUP;FOLLOWUPCOUNT;FIELDNAMES;FIELDVALUES;I
  CONVEXURL←EnvGet 'CONVEX_URL'
  →(0<⍴CONVEXURL)⍴HASURL
  'CONVEX_URL is required' StdErr 0
  →0
HASURL:
  ROOM←RoomArg
  →(0<⍴ROOM)⍴HASROOM
  ROOM←'apl-example'
HASROOM:

  ⍝ The initial HTTP query, decoded into an idiomatic APL value: rather
  ⍝ than picking just "count" back out of the JSON object, FieldTable
  ⍝ lays every field of the room's state out as a small two-column
  ⍝ nested array (names down one side, values down the other) -- the
  ⍝ array-language habit of keeping related data together in one
  ⍝ structured value instead of a clutch of separate scalars.
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

  ⍝ A follow-up query proves the mutation is durably visible over HTTP.
  ⍝ (The other language clients in this project prove the same thing
  ⍝ over Live instead, without a second request; that transport is not
  ⍝ implemented here yet -- see the limitation noted at the top.)
  FOLLOWUP←HttpCall ('query' 'demo:state' (StateArgs ROOM) CONVEXURL '')
  →(ResultOk FOLLOWUP)⍴FOLLOWUPOK
  RequireResult FOLLOWUP 'follow-up query'
  →0
FOLLOWUPOK:
  FOLLOWUPCOUNT←RequireWholeCount (ResultValue FOLLOWUP) 'follow-up query'
  →(FOLLOWUPCOUNT=1)⍴FOLLOWUPONEOK
  ('follow-up count was ',(⍕FOLLOWUPCOUNT),', expected 1') StdErr 0
  →0
FOLLOWUPONEOK:

  ⍝ The room's whole state, laid out as one small array: FieldTable
  ⍝ turns the decoded JSON object into parallel name/value vectors so
  ⍝ printing "every field" is one indexed walk, not five separate
  ⍝ lines of hand-picked JGet calls.
  FIELDNAMES←1⊃FieldTable FOLLOWUP
  FIELDVALUES←2⊃FieldTable FOLLOWUP
  I←1
PRINTLOOP:
  →(I>⍴FIELDNAMES)⍴PRINTDONE
  (I⊃FIELDNAMES),': ',⍕I⊃FIELDVALUES
  I←I+1
  →PRINTLOOP
PRINTDONE:

  'verified count: 0 -> ',⍕FOLLOWUPCOUNT
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

⍝ Lays a decoded 'o' (object) tagged value out as parallel name/value
⍝ vectors, values formatted for printing (JStringify for nested
⍝ structure, otherwise the field's own JStringify text with its
⍝ surrounding quotes stripped for a plain string field).
∇Z←FieldTable ENVELOPE;VALUE;PAIRS;NAMES;VALUES;I;PAIR;TAG;TEXT
  VALUE←ResultValue ENVELOPE
  PAIRS←2⊃VALUE
  NAMES←⍬
  VALUES←⍬
  I←1
LOOP:
  →(I>⍴PAIRS)⍴DONE
  PAIR←I⊃PAIRS
  NAMES←NAMES,⊂1⊃PAIR
  TAG←1⊃2⊃PAIR
  TEXT←JStringify 2⊃PAIR
  →('s'≡TAG)⍴ISSTR
  VALUES←VALUES,⊂TEXT
  →NEXT
ISSTR:
  VALUES←VALUES,⊂(¯2+⍴TEXT)↑1↓TEXT ⍝ drop the leading quote, take up to (not including) the trailing one
NEXT:
  I←I+1
  →LOOP
DONE:
  Z←NAMES VALUES
∇

Main
)OFF
