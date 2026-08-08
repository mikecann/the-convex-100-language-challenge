# Convex from APL

This demonstration uses GNU APL -- an implementation of the array language
itself, not a descendant -- to call Convex's documented JSON HTTP API and its
WebSocket `/api/sync` Live subscription protocol.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.apl`](examples/basics/main.apl) is the canonical
example. It queries a fresh counter room over HTTP, opens a Live subscription
on that same room, applies an idempotent mutation, and observes the `0 -> 1`
journey land reactively over the WebSocket subscription rather than by
re-querying. The block below is generated from that exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified (`./run verify-all apl` awarded it on both profiles) | Query, mutation, and action calls, the `format:"json"` envelope, structured `FunctionError`/`TransportError`/`ProtocolError` classification, response `logs`, and structured `error.data` are implemented in `client/convex.apl` and pass both language-local tests and the shared black-box conformance pilot against the approved local self-hosted backend and the dedicated hosted protocol-drift target. |
| Live | Verified (`./run verify-all apl` awarded it on both profiles) | The WebSocket `/api/sync` state machine -- RFC 6455 handshake/framing/masking/fragmentation, Connect, ModifyQuerySet (Add/Remove), Transition application, `QueryFailed`-then-recovery, and reconnect with exponential backoff reset -- is implemented in `client/convexlive.apl` and passes the shared conformance pilot's `client/live/*` cases, including five real reconnects via `debugDisconnect`, against both deployment profiles. |

## The basic example

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

(The block above is the file's header; the full runnable source, including
`Main` and its helpers, is in
[`examples/basics/main.apl`](examples/basics/main.apl) itself -- the website
build renders the complete file verbatim from that same source.)

## Verify it in Docker

```sh
./run test apl            # builds GNU APL from source, then runs the
                           # language-local self-tests and adapter/example
                           # smoke checks, entirely offline
./run verify-example apl  # runs the example above against a unique room
                           # on the local self-hosted backend
./run verify apl          # verify-example plus shared black-box conformance
```

`./run test apl` builds GNU APL 2.0 from its official source tarball
(Debian only packages GNU APL in `sid`, and only with `--with-gtk3`, which
this build does not need or want -- see "Toolchain" below), compiles the
native transport function with `-Wall -Wextra -Werror`, runs
`client/tests/selftest.apl` (JSON round-trip/escaping, object field lookup,
whole-number acceptance, URL parsing, HTTP status-line/header helpers,
chunked hex sizes, environment-variable handling, and the four
`HttpClassify` envelope shapes -- all with no network dependency), and a
smoke check of the conformance adapter and the canonical example's
`CONVEX_URL is required` error path.

`./run verify-example apl` runs the example above -- both transports, the
whole `0 -> 1` journey -- against a unique room on the local self-hosted
backend and diffs its stdout byte-for-byte against
`_shared/examples/basics.expected.txt`. `./run verify apl` additionally runs
the shared black-box conformance pilot: for both the reference JS oracle and
this client it reports `client/adapter/hello`, all `client/http/*` cases
(query, nested JSON round-trip with `logs`, mutation, idempotent mutation,
document-ID strings, actions, structured errors with `error.data`, UTF-8,
and bearer-token lifecycle), all `client/live/*` cases (initial result,
external update, unsubscribe, five real reconnects via `debugDisconnect`,
and query-error-recovery), and `client/adapter/clean-close` -- and prints
`Earned capabilities: http, live`. `./run verify-hosted apl` repeats example
and conformance verification against the dedicated hosted protocol-drift
target instead, and `./run verify-all apl` runs both deployment profiles
from the same built source; all 31 pilot cases pass on both.

## Toolchain

GNU APL is built from the official upstream source release
(`ftp.gnu.org/gnu/apl`), pinned by URL and sha256, rather than installed
from Debian's `.deb`. Debian packages GNU APL only in `sid` (not yet in
`trixie`/`bookworm`), and its package build enables `--with-gtk3`, which
pulls in the entire GTK/cairo/pango stack for `⎕GTK`/`⎕PLOT`/`⎕PNG` -- none
of which a headless network client uses. The plain upstream tarball's
default configuration has `--with-gtk3` off, producing the same GPL,
Debian-adjacent GNU APL 2.0 with a runtime library closure of just
`libstdc++`/`libm`/`libc`/`libgcc_s` (confirmed with `ldd`).

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync` for both HTTP (query/mutation/action) and Live (the
  WebSocket subscription protocol).
- `client/convex.apl` (HTTP) and `client/convexlive.apl` (RFC 6455
  WebSocket framing and the sync-protocol state machine) are GNU APL
  library workspace files, loaded by the adapter and the example with
  `)COPY '/opt/convex/client/convex.apl'` then
  `)COPY '/opt/convex/client/convexlive.apl'` -- the same mechanism GNU
  APL's own shipped `wslib5` standard-library files use, and, like them,
  both files start with the `⍝!` marker GNU APL's file-format check
  requires to recognise a plain-text file as a library rather than a
  `)DUMP`/XML workspace.
- GNU APL's own `⎕FIO` (`Quad-FIO[32..42]`) supplies raw TCP sockets
  natively -- `socket`/`connect`/`send`/`recv`/`read`/`write`/`fcntl` --
  for the plain (`ws://`, `http://`) transport; no native function is
  needed for that path at all. TLS (`wss://`, `https://`) uses a small
  native function, `client/shim.cc`, compiled against GNU APL's own
  internal headers (`Native_interface.hh` and friends) and loaded at
  runtime with dyadic `⎕FX` -- the documented mechanism GNU APL's own
  shipped `lib_file_io.so` uses for exactly this. The same native
  function also supplies SHA-1 and CSPRNG bytes (both needed only for the
  RFC 6455 WebSocket handshake and per-frame masking) and DNS resolution
  (`⎕FIO`'s own `connect()` takes an address that is already resolved to
  a 32-bit integer; GNU APL has no `getaddrinfo` of its own). No HTTP,
  JSON, WebSocket framing, or Convex sync-protocol logic lives in the
  native function.
- GNU APL has no threads (there is no way to call a function through a
  runtime-computed pointer, which a thread's entry point would need), so
  Live's WebSocket reader is not a background worker. The whole adapter
  process is the one worker: `client/tests/conformance/adapter.apl`'s
  command loop does one non-blocking read of the next NDJSON command and
  one non-blocking poll of the Live connection per pass, so a subscribed
  query's update is written out promptly without a second thread ever
  touching the connection concurrently.
- `client/tests/conformance/adapter.apl` implements NDJSON adapter
  protocol v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode
  (`⎕FIO[41]`/`[42]`, read/write, work identically on a plain fd or an
  accepted socket fd), with real `subscribe`/`unsubscribe`/
  `debugDisconnect` handlers backed by `client/convexlive.apl` --
  `debugDisconnect` is its one adapter-only command, acknowledged only
  after the old connection is retired and the next reconnect is
  scheduled.
- GNU APL's CLI has no way to run a script from a bare positional
  filename argument, only via `-f file`; `/usr/local/bin/convex-example`
  and `/usr/local/bin/convex-adapter` are therefore tiny `#!/bin/sh`
  launchers that run `apl -s -f <script> -- "$@"`, the same shape
  `unicon -o`'s own generated launcher uses for this project's Icon
  client.

## Limitations

- `client/tests/selftest.apl` (the offline, no-network Docker `test` stage)
  covers HTTP-side behaviour only. It does not include a local mock
  WebSocket fixture server exercising Live's edge cases deterministically
  and offline -- fragmentation/control-frame interleaving under an
  adversarial peer, five reconnects with an explicit backoff-reset
  assertion, a stopped-reader queue bound, and so on -- the way some other
  languages in this project do for their own `test` target. Every one of
  those scenarios this client actually implements is instead exercised
  against a real backend by the shared conformance pilot's `client/live/*`
  cases (`reconnect-five-times` genuinely reconnects five times over real
  TLS; `query-error-recovery` genuinely recovers from a real
  `FunctionError`) and, for the bugs a real run alone surfaced, by hand --
  real evidence, but not the fully offline, adversarial local coverage
  AGENTS.md's Live acceptance section asks for.
- Bearer-token authentication (`setAuth`) is accepted by the adapter,
  threaded into the HTTP `Authorization` header, and exercised by the
  shared conformance pilot's `client/http/bearer-token-lifecycle` case
  against the approved local backend.
- The native function is deliberately narrow: TCP connect/send/recv/close
  for TLS, SHA-1, CSPRNG bytes, and DNS resolution only. No HTTP, JSON,
  WebSocket framing, or Convex sync-protocol behaviour lives in C++.
- `⎕FIO[40]` (`select`) reliably raised `DOMAIN ERROR` in this build even
  when its argument's shape and nesting exactly matched `Quad_FIO.cc`'s
  own documented expectations (checked directly with `⍴`/`≡`/`⊃` before
  it ever reached `select()`). Both the HTTP transport and the Live
  WebSocket reader work around this with a non-blocking `fcntl` +
  `⎕FIO[37]`/`[41]` `recv()`/`read()` poll loop instead, which does not
  have the same problem.
- A GNU APL function header cannot destructure a parenthesized left
  argument into two formal names, e.g. `Z←(A B) Fn C` -- it silently
  produces a `DEFN ERROR` at definition time and the whole body then
  falls through to top-level immediate execution the moment the function
  is called, rather than ever running as a function, with no compile-time
  warning that anything is wrong. Found only once Live was driven against
  a real backend end to end (`WsBuildFrame`'s original header); the fix
  is a single left-argument name, destructured inside the body instead.
- The sync protocol's very first `Transition` on a fresh connection must
  be matched against `startVersion.ts` `"AAAAAAAAAAA="` (timestamp zero),
  not an empty string -- confirmed against a real backend after an empty
  initial `LVREMOTETS` made every first `Transition` fail validation
  silently (no error surfaced to the operator; the subscription just
  never delivered).
- The most serious landmine here: `client/shim.cc`'s `handle_of()` parsed
  a TLS handle argument with `atoi()` over its raw bytes, assuming ASCII
  decimal text -- correct for what `CONVEXTLS[1]` (connect) *returns*
  ("K:1"), wrong for what it later *receives*, since `client/convex.apl`'s
  `ConnConnect` immediately `⍎`-evaluates that text into a genuine APL
  numeric scalar before storing it. A real integer cell's raw codepoint
  *is* its numeric value (handle 1 arrives as the SOH control character,
  codepoint 1, not the ASCII digit `'1'`, codepoint 49), so `atoi()` over
  that byte silently parsed every non-zero handle as 0. This was
  completely invisible through every check so far, local and hosted,
  hand-run and shared-conformance, because only one TLS connection was
  ever open at a time (Live and HTTP never ran concurrently until this
  work) -- handle 0 was always correct by coincidence. It surfaced only
  once Live's own persistent connection held slot 0 open while a
  concurrent HTTP call's connection (correctly assigned slot 1 by
  `client/shim.cc`'s own bookkeeping) got silently misrouted onto slot 0
  instead: the HTTP request bytes went out on Live's socket, and the
  reply never came, reported as `TransportError: connection closed
  before headers completed`. Reproduced deterministically against the
  dedicated hosted target (not against the local backend, since that
  target is plain HTTP and never touches this native function at all) --
  a targeted native-level trace pinned it to the exact `SSL_write` call
  before the fix went in. Fixed by reading the argument cell's numeric
  value directly, the same way `maxBytes`/`timeoutMs` already are, rather
  than assuming text.
- A second landmine, found chasing a real OOM kill on the same dedicated
  hosted target once the handle bug above was fixed: the conformance
  adapter's own command loop looped straight back to the top of its
  read/tick cycle without ever reaching its idle branch's sleep, the
  moment any Live command had been issued -- an unthrottled busy-spin,
  tens of thousands of `LiveServiceTick` passes per second, each a
  handful of small APL allocations that add up under that much churn. A
  cgroup memory trace against the real target showed it plainly: flat
  around 22 MiB through every HTTP test and the first Live test, then
  climbing continuously (not one spike) past the shared 128 MiB budget
  within about two seconds of Live going active, killing the adapter
  mid-conformance-run with no application-level error at all (the
  harness only ever saw "adapter TCP connection closed"). Fixed by
  falling through to the loop's existing one-tick-per-pass sleep
  regardless of whether Live was active.
- GNU APL's own script-exit path (`)OFF`, required to leave the
  interpreter cleanly -- omitting it drops the process into an
  interactive `^D`/end-of-input prompt loop instead) appends one
  unsuppressible bare blank line to stdout after a script's last real
  line of output, on top of the already-present per-`)COPY` `DUMPED
  <mtime>` banner. Both `examples/basics/entrypoint.sh` and
  `client/tests/conformance/entrypoint.sh` filter it at the shell
  boundary (holding the most recently read line back by one step so a
  genuine trailing empty line is dropped instead of printed), since
  neither is suppressible from inside the language.
