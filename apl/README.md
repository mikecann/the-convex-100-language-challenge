<img src="logo.png" alt="APL logo" width="120">
<!-- Logo source: https://www.dyalog.com/uploads/images/apl_logo.png -->

# APL

APL is an array-oriented language whose compact symbols apply operations to
whole collections of values. It grew from Kenneth Iverson's mathematical
notation, named by his 1962 book
[*A Programming Language*](https://computerhistory.org/blog/the-apl-programming-language-source-code/),
and became an interactive programming system at IBM. Modern implementations
include Dyalog APL and GNU APL, while Iverson's later J continued the same broad
array-language family. APL is now a specialist language with an active niche in
[data-heavy work](https://www.dyalog.com/application-development-partners/index.htm)
such as finance, insurance, research, and modelling. This client uses
[GNU APL](https://www.gnu.org/software/apl/), a free implementation of the
extended ISO APL standard.

This is an educational, unofficial demonstration. It is not a production SDK,
an officially sanctioned Convex client, or a package intended for publication.

## Getting Started

The canonical [`examples/basics/main.apl`](examples/basics/main.apl) queries a
fresh counter, subscribes before mutating it, and observes the count change from
`0` to `1` through Live rather than issuing a second query.

From the repository root, run:

```sh
./run verify-example apl
```

That command builds the example and its minimal GNU APL runtime in Docker, gives
it a unique room on the approved local test deployment, and checks its exact
output. It does not install GNU APL on your host.

## Interesting Parts

### Convex objects cross the APL boundary as explicit JSON

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const room = "apl-readme";
  const state = useQuery(api.demo.state, { room }); // Arguments and results are typed.

  if (state === undefined) return <p>Loading...</p>;
  return <p>Count: {state.count}</p>; // state.count stays reactive and type-safe.
}
```

**APL**

```apl
ROOM←'apl-readme'
CONVEXURL←EnvGet 'CONVEX_URL'

⍝ StateArgs builds {"room":"apl-readme"}; HttpCall sends one HTTP query.
CURRENT←HttpCall ('query' 'demo:state' (StateArgs ROOM) CONVEXURL '')

⍝ The parser represents each JSON value as a tagged pair such as ('n' 0).
VALUE←ResultValue CURRENT
COUNT←RequireWholeCount VALUE 'current query' ⍝ Pull out count and reject fractions.
```

React's `useQuery` manages a subscription and rerenders when the value changes.
This APL `HttpCall` is deliberately a one-off snapshot. The explicit JSON text
and tagged parsed values are choices made by this small client because GNU APL
does not supply the TypeScript-style generated object types a React app gets.
The full encoding and decoding helpers live in
[`client/convex.apl`](client/convex.apl).

### A command-line subscription has an explicit service loop

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CounterButton() {
  const room = "apl-readme";
  const state = useQuery(api.demo.state, { room }); // React owns subscription cleanup.
  const increment = useMutation(api.demo.increment);

  async function addOne() {
    // Create one key for this action. Reuse it only if this same call is retried.
    const runId = crypto.randomUUID();
    const result = await increment({ room, language: "TypeScript", runId });
    console.log(result.state.count); // The mutation returns the new state.
  }

  return <button onClick={addOne}>Count: {state?.count ?? "..."}</button>;
}
```

**APL**

```apl
CONVEXURL←EnvGet 'CONVEX_URL'
ROOM←'apl-readme'
SUBID←'readme-state'

ConvexInit '/opt/convex/client/shim.so' ⍝ Load the narrow TLS and crypto helper.
OK←LiveInit CONVEXURL              ⍝ Configure Live; the first service tick connects.
LiveSubscribe (SUBID 'demo:state' (StateArgs ROOM))
INITIAL←WaitForLiveValue (SUBID 0 'live initial value') ⍝ Drive ticks until count is 0.

RUNID←'apl-',(⍕NowMs)
MUTATION←HttpCall ('mutation' 'demo:increment' (IncrementArgs (ROOM RUNID)) CONVEXURL '')
MUTATIONCOUNT←RequireWholeCount ('state' JGet ResultValue MUTATION) 'mutation'
UPDATED←WaitForLiveValue (SUBID 1 'live updated value') ⍝ Keep ticking until Live sends 1.

LiveUnsubscribe SUBID              ⍝ Remove the tracked query explicitly.
LiveClose                          ⍝ Close the WebSocket before the process exits.
```

GNU APL has no worker thread behind this client. `LiveServiceTick` performs one
non-blocking read, and the example's `WaitForLiveValue` helper calls it until the
expected update arrives. That blocking helper is an API decision for a linear
command-line example, not a claim that APL cannot express callbacks or other
application structures. In React, the framework and Convex hooks own this
lifecycle for the component.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified on local and hosted profiles | Query, mutation, and action calls pass the shared conformance suite, including nested JSON, logs, structured function errors, UTF-8, document IDs, idempotency, and bearer-token lifecycle. |
| Live | Verified on local and hosted profiles | Subscribing, reactive updates, unsubscribe, error recovery, and five real reconnects pass shared conformance. The implementation also handles WebSocket masking, fragmentation, control frames, and reconnect backoff. |

Both capabilities are recorded in [`manifest.yaml`](manifest.yaml). The existing
evidence reports all 31 shared cases passing on each deployment profile and
`Earned capabilities: http, live`; this README edit does not claim a fresh run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.apl -->
```text
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
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native GNU APL client. [`client/convex.apl`](client/convex.apl)
implements JSON, HTTP framing, result classification, authentication, and
transport helpers. [`client/convexlive.apl`](client/convexlive.apl) implements
WebSocket framing and the Live state machine. No JavaScript, Python, Convex
CLI, or existing Convex SDK performs those jobs.

Plain HTTP and WebSocket connections use GNU APL's built-in `⎕FIO` socket
operations. HTTPS and secure WebSockets use
[`client/shim.cc`](client/shim.cc), a deliberately narrow native function for
TLS, DNS resolution, SHA-1, and secure random bytes. The C++ layer does not
know about JSON, HTTP messages, subscriptions, or Convex functions.

Live has single-process ownership rather than a background reader. Each
`LiveServiceTick` makes one non-blocking socket read and immediately returns
any subscription events it decoded. There is no separate application-level
delivery queue. The kernel socket buffer is bounded, and an individual
reassembled WebSocket message is capped at 4 MiB.

The Docker build pins GNU APL 2.0 and builds it from the official source
release. The exported images contain only the interpreter, the APL client, the
small native helper and its runtime libraries, certificate data, and the
minimal shell tools required by the shared verifier. Both runtime entrypoints
run as user `65532:65532`.

For the other test layers:

```sh
./run test apl            # offline source and language-local checks
./run verify apl          # example plus local shared conformance
./run verify-hosted apl   # example plus hosted drift conformance
./run verify-all apl      # both deployment profiles from one source
```

`test` covers JSON, whole-number decoding, URL and HTTP helpers, result
envelopes, and adapter startup. The `verify*` commands add real deployment
behaviour, so a compiling image or a passing offline test is not by itself
evidence for HTTP or Live.

## Known Issues

1. The offline self-test has no adversarial mock WebSocket server. Live
   fragmentation, control-frame interleaving, reconnects, and error recovery
   are covered by shared real-backend evidence, but not by deterministic
   language-local fixtures.
2. GNU APL has no threads in this implementation, so an application must keep
   calling `LiveServiceTick` while it wants updates. A stalled caller also
   stalls subscription delivery.
3. GNU APL's `⎕FIO[40]` `select` operation raised `DOMAIN ERROR` for the
   expected argument shape in this build. The client works around it with
   non-blocking `fcntl`, `recv`, and `read` polling.
4. GNU APL prints `)COPY` banners and a final blank line that cannot be
   suppressed from the scripts. The two shell entrypoints filter those lines
   so example output and adapter output remain machine-readable; that pipeline
   does not preserve the interpreter's own exit status.
