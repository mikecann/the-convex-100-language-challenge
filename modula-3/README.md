# Convex from Modula-3

A from-scratch Convex client written in CM3 (Critical Mass Modula-3), built
directly on Modula-3's own standard-library TCP/IP sockets and one narrow
OpenSSL `EXTERNAL`-procedure boundary for TLS -- no delegated JavaScript,
Node, or other Convex client underneath it anywhere.

This is an educational demonstration for the 100 Convex Clients project, not
an official Convex SDK and not a package meant for publication.

- Selection tier: `ranked`
- Implementation status: `working`
- Earned capabilities: `http`, `live` -- see `_shared/results/` for the
  evidence and "Docker verification" below for the exact commands.

This is roster entry 52, replacing `oz`. Oz reached a real socket and
completed an HTTP round trip natively, but its TLS path required rebuilding
Mozart 2's own unmaintained 2016-era AST-dump code generator, which crashed
on the same file 208 consecutive times -- a genuine, reproducible
memory-safety bug in vendored tooling, not bad luck. See `INFEASIBLE.md` for
the full account. Modula-3 needs none of that: a real, long-stable
standard-library TCP/IP socket interface (the `tcp` package: `TCP.i3`/
`IP.i3`, DEC SRC/Olivetti heritage) for the plain transport, and genuine C
interop through `EXTERNAL` procedures for TLS -- one narrow, stable
procedure boundary to OpenSSL, not a code generator or a vendored FFI
toolchain.

## Start here

`examples/basics/main.m3` is the canonical example: it reads a room's
counter over Convex's documented HTTP API, opens a Live subscription over
`/api/sync`, increments the counter once, and proves the Live subscription
reported the same change without polling again. It produces exactly the
shared project's universal happy-path transcript, byte for byte:

```
current count: 0
live initial count: 0
mutation applied: true
mutation count: 1
live updated count: 1
verified count: 0 -> 1
```

## What works

| Piece | Status |
| --- | --- |
| CM3 toolchain bootstrap + TCP/TLS gate | Proven in Docker (`toolchain-check`) |
| `client/ConvexJson.{i3,m3}` (JSON codec) | Compiled and exercised by every layer above it |
| `client/ConvexTransport.{i3,m3}` / `client/TlsShim.i3` + `client/shim.c` (TCP/TLS) | Real TLS 1.2+ handshake, cert + hostname verification, proven against the hosted deployment |
| `client/ConvexHttp.{i3,m3}` (HTTP/1.1 framing, query/mutation/action) | Full HTTP conformance verified |
| `client/ConvexWebSocket.{i3,m3}` (RFC 6455 framing, masking, handshake) | Unit-tested (`WebsocketTest.m3`): masking, every length encoding, the RFC 6455 worked `Sec-WebSocket-Accept` example, masked-frame rejection |
| `client/ConvexLive.{i3,m3}` (`/api/sync` state machine, reconnect, backoff) | Unit-tested against a scripted fixture (`LiveTest.m3`/`WsFixture.m3`): fragmentation reassembly, an interleaved Ping/Pong, UTF-8 validated once after reassembly, a rejected wrong `Sec-WebSocket-Accept`; full Live conformance (five real reconnects, backoff reset, query-error recovery) verified end to end |
| `examples/basics/main.m3` | Verified against both deployment profiles via `./run verify-example`/`verify-all` |
| NDJSON conformance adapter (`client/tests/conformance/Adapter.m3`) | Full shared conformance verified, both deployment profiles |
| `example-runtime` / `runtime` Docker stages | Built, pruned, policy-checked, and verified |

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m3 -->
```modula3
(* Convex from Modula-3: the shared counter journey.

   Reads a room's counter over Convex's documented HTTP API, starts a
   Live subscription, increments the counter once, and proves that the
   Live subscription reported the same change without polling. This is
   an educational demonstration of a hand-written, from-scratch Convex
   client (see ../../README.md), not an official Convex SDK.

   Run it with:
     CONVEX_URL=https://<deployment>.convex.cloud ./main <room> *)
MODULE main EXPORTS Main;

IMPORT IO, Text, Fmt, Env, Params, Process, Stdio,
       ConvexJson, ConvexHttp, ConvexLive, ConvexRandom;

PROCEDURE Fail(msg: TEXT) =
  BEGIN
    IO.Put("Modula-3 example failed: " & msg & "\n", Stdio.stderr);
    Process.Exit(1);
  END Fail;

(* Decodes the demo counter's "count" field into an idiomatic INTEGER.
   Convex JSON numbers may arrive in an integral decimal form such as
   "0" or "0.0"; both are accepted, but a fractional, non-finite, or
   out-of-range value fails loudly instead of being silently truncated
   -- exactly the regression AGENTS.md calls out, since a mocked
   integer-only fixture would never exercise this path. *)
PROCEDURE DecodeCount(value: ConvexJson.T; context: TEXT): INTEGER =
  VAR countField: ConvexJson.T; raw: LONGREAL;
  BEGIN
    IF value = NIL OR value.kind # ConvexJson.Kind.Obj THEN
      Fail(context & ": expected a JSON object");
    END;
    countField := ConvexJson.ObjectGet(value, "count");
    IF countField = NIL THEN Fail(context & ": missing \"count\""); END;
    TRY
      raw := ConvexJson.NumOf(countField);
    EXCEPT
    | ConvexJson.Error => Fail(context & ": \"count\" was not a JSON number"); raw := 0.0d0;
    END;
    (* Reject non-finite, fractional, and out-of-range values: a
       mathematically integral value comfortably within INTEGER's range
       is the only shape this example accepts. *)
    IF raw # raw THEN Fail(context & ": \"count\" was NaN"); END; (* NaN never equals itself *)
    IF ABS(raw) > 1.0d15 THEN Fail(context & ": \"count\" was out of range"); END;
    IF raw # FLOAT(ROUND(raw), LONGREAL) THEN Fail(context & ": \"count\" was not a whole number"); END;
    RETURN ROUND(raw);
  END DecodeCount;

VAR
  (* -- configuration: the deployment URL is required. The room comes
     from the verifier's first command-line argument (so repeated runs
     never collide), an EXAMPLE_ROOM environment variable for a
     convenient hand run, or a literal fallback so this still does
     something either way. -- *)
  deploymentUrl := Env.Get("CONVEX_URL");
  room: TEXT;
  queryArgs, mutationArgs: ConvexJson.T;
  queryResult: ConvexHttp.CallResult;
  currentCount, liveInitialCount, mutationCount, liveUpdatedCount: INTEGER;
  live: ConvexLive.T;
  runId: TEXT;
  gotInitial, gotUpdated: BOOLEAN;
BEGIN
  IF deploymentUrl = NIL OR Text.Equal(deploymentUrl, "") THEN
    Fail("CONVEX_URL is required");
  END;

  room := NIL;
  IF Params.Count >= 2 THEN room := Params.Get(1); END;
  IF room = NIL OR Text.Equal(room, "") THEN room := Env.Get("EXAMPLE_ROOM"); END;
  IF room = NIL OR Text.Equal(room, "") THEN room := "modula-3-example"; END;

  queryArgs := ConvexJson.NewObject();
  ConvexJson.ObjectSet(queryArgs, "room", ConvexJson.NewString(room));

  (* -- the HTTP query: reads the room's current counter through
     Convex's documented POST /api/query envelope, before anything
     reactive is involved, so the Live subscription below has a known
     value to agree with. -- *)
  queryResult := ConvexHttp.Call("query", "demo:state", queryArgs, deploymentUrl, "");
  IF queryResult.kind # ConvexHttp.ResultKind.Result THEN
    Fail("query: " & queryResult.errMessage);
  END;
  currentCount := DecodeCount(queryResult.value, "current query");
  IO.Put("current count: " & Fmt.Int(currentCount) & "\n");

  (* -- client creation: opens the WebSocket handshake to /api/sync and
     sends the Connect message. No query has been added yet. -- *)
  live := ConvexLive.New(deploymentUrl);

  (* -- starting Live before the mutation: subscribing first is what
     makes the update received below an observation of a real change,
     rather than a race against one that already happened. -- *)
  ConvexLive.Add(live, "counter", "demo:state", queryArgs);
  IF NOT ConvexLive.IsConnected(live) THEN
    Fail("sync connect: " & ConvexLive.LastCloseReason(live));
  END;

  (* -- the initial Live value: the same state the HTTP query above
     already read, delivered this time as the subscription's first
     Transition. -- *)
  gotInitial := FALSE;
  FOR attempt := 1 TO 100 DO
    IF gotInitial THEN EXIT; END;
    VAR batch := ConvexLive.Poll(live, 200);
    BEGIN
      FOR i := 0 TO batch.count - 1 DO
        IF Text.Equal(batch.events[i].subscriptionId, "counter") THEN
          IF batch.events[i].kind = ConvexLive.EventKind.Error THEN
            Fail("initial Live value: " & batch.events[i].errMessage);
          END;
          liveInitialCount := DecodeCount(batch.events[i].value, "initial Live value");
          gotInitial := TRUE;
        END;
      END;
    END;
  END;
  IF NOT gotInitial THEN Fail("initial Live value: timed out waiting for a Transition"); END;
  IF liveInitialCount # currentCount THEN
    Fail("the initial Live count disagreed with HTTP");
  END;
  IO.Put("live initial count: " & Fmt.Int(liveInitialCount) & "\n");

  (* -- the mutation and its idempotency key: runId lets Convex
     recognize a retried request and return the previous result
     instead of incrementing twice. A fresh random key means this run
     really applies its increment rather than replaying an old one. -- *)
  TRY
    runId := ConvexRandom.HexBytes(16);
  EXCEPT
  | ConvexRandom.Error => Fail("could not generate an idempotency key"); runId := "";
  END;
  mutationArgs := ConvexJson.NewObject();
  ConvexJson.ObjectSet(mutationArgs, "room", ConvexJson.NewString(room));
  ConvexJson.ObjectSet(mutationArgs, "language", ConvexJson.NewString("modula-3"));
  ConvexJson.ObjectSet(mutationArgs, "runId", ConvexJson.NewString(runId));

  VAR mutationResult := ConvexHttp.Call("mutation", "demo:increment", mutationArgs, deploymentUrl, "");
  BEGIN
    IF mutationResult.kind # ConvexHttp.ResultKind.Result THEN
      Fail("mutation: " & mutationResult.errMessage);
    END;
    VAR appliedField := ConvexJson.ObjectGet(mutationResult.value, "applied");
        applied := FALSE;
    BEGIN
      IF appliedField # NIL THEN
        TRY applied := ConvexJson.BoolOf(appliedField); EXCEPT | ConvexJson.Error => applied := FALSE; END;
      END;
      IF NOT applied THEN Fail("the mutation was not applied"); END;
    END;
    mutationCount := DecodeCount(ConvexJson.ObjectGet(mutationResult.value, "state"), "mutation");
  END;
  IF mutationCount # currentCount + 1 THEN
    Fail("the mutation returned an unexpected count");
  END;
  IO.Put("mutation applied: true\n");
  IO.Put("mutation count: " & Fmt.Int(mutationCount) & "\n");

  (* -- the resulting Live update: received over the same subscription,
     without polling HTTP again. -- *)
  gotUpdated := FALSE;
  FOR attempt := 1 TO 100 DO
    IF gotUpdated THEN EXIT; END;
    VAR batch := ConvexLive.Poll(live, 200);
    BEGIN
      FOR i := 0 TO batch.count - 1 DO
        IF Text.Equal(batch.events[i].subscriptionId, "counter") THEN
          IF batch.events[i].kind = ConvexLive.EventKind.Error THEN
            Fail("updated Live value: " & batch.events[i].errMessage);
          END;
          liveUpdatedCount := DecodeCount(batch.events[i].value, "updated Live value");
          gotUpdated := TRUE;
        END;
      END;
    END;
  END;
  IF NOT gotUpdated THEN Fail("updated Live value: timed out waiting for a Transition"); END;
  IF liveUpdatedCount # currentCount + 1 THEN
    Fail("the updated Live count disagreed with the mutation");
  END;
  IO.Put("live updated count: " & Fmt.Int(liveUpdatedCount) & "\n");

  (* Every operation above agreed before this proof line is printed. *)
  IO.Put("verified count: " & Fmt.Int(currentCount) & " -> " & Fmt.Int(liveUpdatedCount) & "\n");

  (* -- cleanup: close the Live connection cleanly before exiting. -- *)
  ConvexLive.Close(live);
END main.
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test modula-3
```

Bootstraps CM3 from source (the pinned `d5.12.0` release, verified by commit
and checksum), compiles the whole client library (`cm3 -build` against a
`library("Convex")` target -- the whole-client compilation gate), then
compiles and runs `WebsocketTest.m3` (pure framing logic, no network) and
`LiveTest.m3` against `WsFixture.m3` (a scripted, one-shot loopback
WebSocket server) for fragmentation reassembly, an interleaved Ping/Pong,
UTF-8 validated once after reassembly, and a rejected wrong
`Sec-WebSocket-Accept`. It then compiles the canonical example and the
conformance adapter, runs a stdio-mode smoke test of the adapter's
`hello`/unrecognized-op/`close` handling, and stages the runtime images'
`ldd` library closure.

```sh
./run verify-example modula-3   # the canonical example against the local backend
./run verify modula-3           # + shared black-box conformance, local backend
./run verify-hosted modula-3    # the same, against the hosted drift target
./run verify-all modula-3       # both deployment profiles from one built image
```

build the `example-runtime` and `runtime` Docker stages -- a minimal,
non-root, read-only, all-capabilities-dropped image for each, staging only
CM3's own runtime closure (`libm3`/`libm3core`/`libm3tcp`, not
apt-installable since CM3 is not packaged for the base image, found and
copied via `ldd`) and the one compiled binary each stage needs -- and run
the example and the shared conformance controller against it.
`./run verify-all modula-3` is the evidence in
`_shared/results/local/modula-3-pilot-result.json` and
`_shared/results/hosted/modula-3-pilot-result.json`: every required HTTP and
Live test passing on both deployment profiles from the same built image,
`dirty: false`, at the exact commit this README was updated alongside. Only
the shared result evaluator computes the `http`/`live` capability badges
from that evidence; this README does not round up ahead of it.

## The TLS boundary

`client/TlsShim.i3` + `client/shim.c` is the only native code in this
client: a narrow OpenSSL binding reached through CM3's `EXTERNAL` procedure
mechanism, layered over the file descriptor Modula-3's own standard-library
`TCP.i3` already opened. It performs a real TLS 1.2+ handshake with
certificate AND hostname verification (`SSL_set1_host` plus
`X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS`), retrying `SSL_connect` across
`WANT_READ`/`WANT_WRITE` via `poll(2)` rather than assuming a blocking
socket (CM3's own runtime leaves sockets non-blocking so it can multiplex
Modula-3 threads over a handful of OS threads). Every failure path funnels
through one `fail_closing` helper so a failed handshake never leaks the
underlying file descriptor -- an earlier version of `shim.c` returned `NULL`
from several places without releasing it, and enough failed handshakes in a
row could have starved `SSL_CTX_set_default_verify_paths` itself of the fds
it needs to open the CA directory.

`Dockerfile`'s `toolchain-check` stage proves both halves against the real
approved hosted deployment during the build itself: a real TCP connection
through Modula-3's own standard library, and a real, certificate-and-
hostname-verified TLS handshake through the shim, plus a negative control
(`wrong.host.badssl.com`) proving hostname verification is not a no-op.

## RFC 6455 WebSocket framing

`client/ConvexWebSocket.{i3,m3}` implements the HTTP Upgrade handshake with
a verified `Sec-WebSocket-Accept` (`ComputeAccept`, tested directly against
RFC 6455 section 1.3's own worked example), masked outbound frames (this
client never needs to fragment an outgoing message -- every sync-protocol
message it sends fits in one frame), and a receive-side parser
(`TryParseFrame`) that rejects any masked frame claiming to be from the
server, per RFC 6455 section 5.1. It deliberately knows nothing about
fragmentation reassembly, interleaved control frames, or UTF-8 validation:
those are `ConvexLive.m3`'s job, since only the caller watching a whole
logical message come together knows when it is actually complete.

`client/tests/WebsocketTest.m3` proves the pure framing logic with no
network at all. `client/tests/LiveTest.m3`, against
`client/tests/WsFixture.m3` (a scripted, one-shot loopback WebSocket
server), proves the properties that only show up once frames travel
through a real socket and `ConvexLive.DrainFrames`'s own loop: a message
split across two frames reassembles correctly with a Ping answered by an
exact Pong in between, a valid two-byte UTF-8 codepoint split exactly
across the frame boundary decodes correctly (proving validation happens
once, after reassembly, not per fragment), a genuinely invalid reassembled
byte sequence is rejected as a `ProtocolError`, and a deliberately wrong
`Sec-WebSocket-Accept` is rejected before any application data is trusted.
Building `WsFixture.m3` surfaced one real Linux behavior worth recording: a
socket that is `close(2)`d while the peer's own already-sent bytes are
still sitting unread in its receive buffer gets an RST instead of a clean
FIN, which raced the client's own next write and surfaced as a spurious
`TransportError` unrelated to what a scenario actually meant to test --
fixed with a best-effort drain immediately before every scenario's close.

## `/api/sync` Live

`client/ConvexLive.{i3,m3}` implements the pinned
`convex-rs-0.10.4-unversioned-sync` protocol as a single-threaded state
machine: `New`, `Add`/`Remove`, `Poll`, `DebugDisconnect`, and `Close` are
its whole public surface, and every one of them reads and mutates the same
`T` in place with no internal locking or worker thread -- "one worker owns
the socket" is satisfied by convention (callers must not call two of these
procedures on the same `T` concurrently from different threads) the same
way a single-threaded event loop always satisfies it. It implements:

- Automatic reconnection with exponential backoff (100ms base, capped at
  15s), reset to the base the moment a handshake succeeds -- a healthy
  connection never inherits a stale, grown delay from an earlier run of
  failures.
- Resubscribing the whole active query set on every reconnect, and
  suppressing exactly one unchanged rehydration per subscription via a
  `lastSignature` comparison: a reconnect's replayed `Add` naturally
  reproduces whatever value the subscription already had, and delivering
  that as if it were a new update would be wrong. Any later Transition --
  changed or not -- delivers normally again.
- `connectionCount`, `lastCloseReason`, and the running maximum
  `maxObservedTimestamp` across every connection, all carried into the
  next `Connect`.
- The adapter-only `DebugDisconnect` hook: retires the current connection
  and arms the reconnect timer synchronously, so the caller can acknowledge
  immediately after it returns.
- A bounded pending-event queue (256 events): once full, `Poll` simply
  stops reading further frames off the socket until the caller drains what
  is already queued, a natural backpressure design rather than an
  unbounded buffer or a forced reconnect.

`./run verify`'s shared conformance run is what proves the properties a
synthetic fixture cannot: five real reconnects against a real deployment
with backoff actually resetting after a good handshake, and a stopped
reader staying comfortably inside the shared 128 MiB adapter memory limit
(the conformance adapter's own bounded 8-slot/4 MiB output queue is what
bounds that, not `ConvexLive`'s in-process event queue -- see the next
section).

## The conformance adapter

`client/tests/conformance/Adapter.m3` is test infrastructure, not public
client code (see AGENTS.md's "Conformance executable" section): it wraps
`ConvexHttp` and `ConvexLive` and speaks the shared harness's NDJSON
protocol v1, either over stdin/stdout or over one accepted TCP connection
when `ADAPTER_LISTEN` names a listen address. It is single threaded, so its
main loop interleaves pumping `ConvexLive.Poll` with reading one controller
command at a time, in short (100-200ms) slices each way so neither one
starves the other.

Its own output is a bounded queue: 8 slots, a 4 MiB byte budget,
subscription events droppable oldest-first, and `hello`/`result`/`error`/
`ack`/`closed` responses never dropped -- comfortably inside the shared
128 MiB adapter memory limit even under a stopped reader with near-maximum
messages. `setAuth` only affects the bearer token `query`/`mutation`/
`action` calls attach from then on; `ConvexLive` has no Live-authentication
(`Authenticate` message) support yet, so a subscription made after
`setAuth` still runs unauthenticated -- documented here rather than
silently assumed.

## Known limitations

- Live authentication (the `Authenticate` sync-protocol message) is not
  implemented; `setAuth` affects only HTTP `query`/`mutation`/`action`
  calls.
- `TransitionChunk` (an unrecognized, chunked Transition modification) is
  reported as a `ProtocolError` and the connection reconnects, rather than
  being reassembled.
- `ConvexLive`'s in-process pending-event queue is bounded by count (256
  events) rather than by a separate byte budget; the conformance adapter's
  own queue (8 slots, 4 MiB) is what actually bounds memory toward a slow
  or stopped consumer, per the shared 128 MiB limit.
- `ConvexTransport.Connect` has no connect-level timeout of its own
  (Modula-3's `TCP.Connect` exposes none); a connect that hangs at the TCP
  level rather than failing or refusing is not separately bounded beyond
  each caller's own overall operation deadline.

## Build recipe (proven)

`Dockerfile`'s `toolchain` stage bootstraps CM3 from source: each CM3
release publishes a "boot" tarball of the compiler's own sources already
translated to C by an earlier CM3, which any C++ compiler can build into a
working bootstrap `cm3`. `scripts/concierge.py install --prefix /opt/cm3
core tcp` then uses that bootstrap compiler to self-host -- rebuild `cm3`
itself, plus exactly the `core` (front end, back end, `m3core`/`libm3`
support libraries) and `tcp` (the stdlib TCP/IP interfaces this client's
plain transport uses) package set from real Modula-3 source. This is
deliberately narrower than the "headless" default package set: that
superset also pulls in `m3tk-misc`, an unrelated CM3 IDE-toolkit package
whose 2016-era `qsort` C declaration conflicts with GCC 13's `<stdlib.h>` --
a broken build surface this headless network client never needs.

CM3's own `m3makefile`/`cm3 -build` model is a flat, non-package build: a
directory's `m3makefile` lists the interfaces and implementations to
compile (and, for `TlsShim`, the one C source to compile alongside them)
and either `program("name")` or `library("name")` to say what to link.
Every test, the conformance adapter, and the canonical example each get
their own build directory with the full client source copied in flat
alongside that one program's own `Main`-exporting module, mirroring how
`Dockerfile`'s `toolchain-check` stage already proved the pattern for the
build-time gate program.

The runtime images stage CM3's own `libm3`/`libm3core`/`libm3tcp` shared
libraries (found via `ldd`, since CM3 is not apt-installable on the runtime
base image) alongside OpenSSL, the glibc DNS resolver modules, CA
certificates, and the handful of POSIX text tools the shared policy and
example verifier require -- the same `ldd`-closure-into-a-pruned-image
pattern this project's other from-source native clients use.
