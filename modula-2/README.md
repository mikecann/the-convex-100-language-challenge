# Convex from Modula-2

This is a small native Modula-2 client for Convex HTTP functions and reactive Live queries, built with GNU Modula-2 (gm2), the GCC front end for the language.

It is an educational, unofficial experiment. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.mod`](examples/basics/main.mod). It queries a fresh counter over HTTP, opens a Live subscription before mutating anything, applies one idempotent mutation, and checks that the HTTP query, the mutation result, and the Live subscription all agree on the same `0 -> 1` journey.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, log lines, and structured errors | Implemented; language-local Docker tests pass, shared conformance pending |
| Live initial values, external updates, and `QueryFailed` followed by recovery | Implemented; proved against a loopback fixture in `client/tests/TestLive.mod`, shared conformance pending |
| Five forced reconnects with Add resend, rehydration suppression, and `connectionCount`/backoff bookkeeping | Implemented; proved against `client/tests/FixtureServer.mod`, shared conformance pending |
| WebSocket mutations, actions, Live authentication, optimistic updates | Not implemented |
| `TransitionChunk` assembly | Not implemented; treated as protocol drift and reconnects |
| Production SDK compatibility | Not claimed |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.mod -->
```modula2
(* Convex from Modula-2: the canonical "shared counter" walkthrough.
 *
 * This program is the single source of truth for the code shown in the
 * README and on the project website; ./run sync-examples projects this
 * exact file there, comments and all.
 *
 * It demonstrates, over a real Convex deployment:
 *   - configuring the client from the deployment URL,
 *   - an HTTP query,
 *   - opening a Live subscription and reading its initial value,
 *   - an idempotent HTTP mutation,
 *   - the Live update that the mutation produces,
 *   - and orderly shutdown.
 *)
MODULE Basics;

FROM ConvexJSON IMPORT Member, IsIntegralNumber, AppendQuoted;
IMPORT ConvexSync;
FROM Environment IMPORT GetEnvironment;
FROM Args IMPORT GetArg;
FROM STextIO IMPORT WriteString, WriteLn;
FROM CShim IMPORT ShimExit;

CONST
  MaxJson = 65536;

VAR
  url: ARRAY [0..511] OF CHAR;
  room: ARRAY [0..255] OF CHAR;
  args, value, logs, errorName, errorMessage, errorData: ARRAY [0..MaxJson - 1] OF CHAR;
  hasErrorData, ok: BOOLEAN;
  transportError: ARRAY [0..255] OF CHAR;
  handle, count: INTEGER;

(* AppendLit appends a NUL terminated literal to a NUL terminated buffer;
   Modula-2 has no string concatenation operator. *)
PROCEDURE AppendLit (text: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR base, extra, i: INTEGER;
BEGIN
  base := 0;
  WHILE destination[base] <> 0C DO INC(base) END;
  extra := 0;
  WHILE text[extra] <> 0C DO INC(extra) END;
  FOR i := 0 TO extra - 1 DO destination[base + i] := text[i] END;
  destination[base + extra] := 0C;
END AppendLit;

(* Fail prints a diagnostic to stderr-equivalent stdout note and exits non
   zero: the example must fail loudly on any unexpected value, not just
   when a call errors outright. *)
PROCEDURE Fail (message: ARRAY OF CHAR);
BEGIN
  WriteString("basics: "); WriteString(message); WriteLn;
  ShimExit(1);
END Fail;

(* DecodeCount extracts the "count" member of a Convex demo:state style
   JSON object and decodes it as an ordinary integer. Convex may encode a
   whole number in JSON's integral-float form (0.0, 1.0); this only
   accepts values that are mathematically integral, matching AGENTS.md's
   requirement that example decoding reject genuinely fractional values
   rather than silently truncating them. *)
PROCEDURE DecodeCount (VAR json: ARRAY OF CHAR; VAR result: INTEGER) : BOOLEAN;
VAR
  raw: ARRAY [0..63] OF CHAR;
  found, negative: BOOLEAN;
  i, cap: INTEGER;
BEGIN
  IF NOT Member(json, "count", raw, found) OR NOT found THEN RETURN FALSE END;
  IF NOT IsIntegralNumber(raw) THEN RETURN FALSE END;
  i := 0;
  cap := 0;
  WHILE raw[cap] <> 0C DO INC(cap) END;
  negative := FALSE;
  IF (cap > 0) AND (raw[0] = '-') THEN negative := TRUE; i := 1 END;
  result := 0;
  WHILE (i < cap) AND (raw[i] >= '0') AND (raw[i] <= '9') DO
    result := result * 10 + (INTEGER(ORD(raw[i])) - INTEGER(ORD('0')));
    INC(i);
  END;
  IF negative THEN result := -result END;
  RETURN TRUE;
END DecodeCount;

PROCEDURE AwaitLiveCount (targetHandle: INTEGER; VAR result: INTEGER);
VAR
  eventKind, eventHandle: INTEGER;
  eventValue, eventLogs, eventErrorName, eventErrorMessage, eventErrorData: ARRAY [0..MaxJson - 1] OF CHAR;
  eventHasErrorData: BOOLEAN;
  waited: INTEGER;
BEGIN
  waited := 0;
  LOOP
    ConvexSync.Pump(200, eventKind, eventHandle, eventValue, eventLogs,
                     eventErrorName, eventErrorMessage, eventErrorData, eventHasErrorData);
    IF (eventKind <> 0) AND (eventHandle = targetHandle) THEN
      IF eventKind = 2 THEN Fail("Live subscription failed unexpectedly") END;
      IF NOT DecodeCount(eventValue, result) THEN Fail("Live value was not a demo:state object") END;
      RETURN;
    END;
    INC(waited);
    IF waited > 150 THEN Fail("timed out waiting for a Live update") END;
  END;
END AwaitLiveCount;

(* CheckMutationResult validates demo:increment's {"applied":true,"state":
   {..., "count":1, ...}} shape without assuming field order. *)
PROCEDURE CheckMutationResult (VAR result: ARRAY OF CHAR);
VAR
  appliedRaw, stateRaw: ARRAY [0..MaxJson - 1] OF CHAR;
  found: BOOLEAN;
  stateCount: INTEGER;
BEGIN
  IF NOT Member(result, "applied", appliedRaw, found) OR NOT found THEN
    Fail("unexpected mutation result");
  END;
  IF NOT ((appliedRaw[0] = 't') AND (appliedRaw[1] = 'r') AND (appliedRaw[2] = 'u') AND (appliedRaw[3] = 'e') AND (appliedRaw[4] = 0C)) THEN
    Fail("unexpected mutation result");
  END;
  IF NOT Member(result, "state", stateRaw, found) OR NOT found THEN
    Fail("unexpected mutation result");
  END;
  IF NOT DecodeCount(stateRaw, stateCount) OR (stateCount <> 1) THEN
    Fail("unexpected mutation result");
  END;
END CheckMutationResult;

BEGIN
  (* Configure this client from the verifier-selected deployment. The
     dedicated public demo functions need no authentication token. *)
  IF NOT GetEnvironment("CONVEX_URL", url) THEN
    Fail("CONVEX_URL is required");
  END;
  ConvexSync.Init(url, "");

  (* Accept the verifier's unique room ID as argv[1], with a friendly
     default for anyone running the image by hand. *)
  IF NOT GetArg(room, 1) THEN
    room := "modula-2-basic-example";
  END;

  (* Query the counter over HTTP before opening the Live subscription, so
     the printed transcript always starts from a known value. *)
  args[0] := 0C;
  AppendLit('{"room":', args);
  IF NOT AppendQuoted(room, args) THEN Fail("room id was too long") END;
  AppendLit('}', args);
  ConvexSync.Call("query", "demo:state", args, value, logs,
                  errorName, errorMessage, errorData, hasErrorData, ok, transportError);
  IF NOT ok THEN Fail(transportError) END;
  IF errorName[0] <> 0C THEN Fail("unexpected initial HTTP value") END;
  IF NOT DecodeCount(value, count) OR (count <> 0) THEN Fail("unexpected initial HTTP value") END;
  WriteString("current count: 0"); WriteLn;

  (* Start the Live subscription before the mutation, so the mutation
     cannot race past it. *)
  ConvexSync.Subscribe("demo:state", args, handle, ok, transportError);
  IF NOT ok THEN Fail(transportError) END;
  AwaitLiveCount(handle, count);
  IF count <> 0 THEN Fail("unexpected initial Live value") END;
  WriteString("live initial count: 0"); WriteLn;

  (* The room-specific idempotency key makes a retry of this example safe:
     this mutation increments the counter at most once. *)
  args[0] := 0C;
  AppendLit('{"room":', args);
  IF NOT AppendQuoted(room, args) THEN Fail("room id was too long") END;
  AppendLit(',"language":"Modula-2","runId":"', args);
  AppendLit(room, args);
  AppendLit('-once"}', args);
  ConvexSync.Call("mutation", "demo:increment", args, value, logs,
                  errorName, errorMessage, errorData, hasErrorData, ok, transportError);
  IF NOT ok THEN Fail(transportError) END;
  IF errorName[0] <> 0C THEN Fail("unexpected mutation result") END;
  CheckMutationResult(value);
  WriteString("mutation applied: true"); WriteLn;
  WriteString("mutation count: 1"); WriteLn;

  (* Wait for the server Transition carrying the same updated counter. *)
  AwaitLiveCount(handle, count);
  IF count <> 1 THEN Fail("unexpected updated Live value") END;
  WriteString("live updated count: 1"); WriteLn;

  (* Unsubscribe before the process exits so the server sees an orderly
     close rather than a dropped connection. *)
  ConvexSync.Unsubscribe(handle);

  (* Stdout is deliberately this exact six line happy-path transcript. *)
  WriteString("verified count: 0 -> 1"); WriteLn;
END Basics.
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test modula-2
./run build modula-2
```

The `test` target installs gm2 14.2.0 from Debian trixie, compiles every module and program for real `linux/amd64`, runs the language-local unit and Live acceptance tests, and exercises the NDJSON adapter's hello/close lifecycle. The `build` target produces the non-root `runtime` (adapter) image; `example-runtime` is built the same way with a different Dockerfile target. Root owns `verify-example`, `verify`, and `verify-hosted` because those commands serialize the shared backend and evidence store.

## Protocol and runtime notes

The client implements Convex's HTTP envelopes and this repository's pinned `/api/sync` profile directly in Modula-2. The only foreign code is `client/cshim.c`, a small C shim (declared to gm2 through `client/CShim.def`'s `DEFINITION MODULE FOR "C"`) that supplies raw POSIX sockets, OpenSSL for TLS, `poll()`, a monotonic clock, CSPRNG bytes, and SHA-1 for the WebSocket handshake key. It contains no Convex, HTTP, JSON, or WebSocket framing logic; all of that is `client/ConvexBase64.mod`, `client/ConvexJSON.mod`, `client/ConvexURL.mod`, `client/ConvexHTTP.mod`, `client/ConvexWS.mod`, and `client/ConvexSync.mod`.

`ConvexSync` is a process-wide singleton with one worker: the process calling `Pump()` is the sole owner of the WebSocket socket, reconnect state, and query-set version, matching this repository's requirement that controller and subscription work never touch the socket concurrently. `Add`/`Remove` are queued and flushed the next time `Pump()` runs; a `debugDisconnect`-triggered reconnect resends every still-active `Add` in one `ModifyQuerySet` message and suppresses a rehydrated value that is byte-identical to what the subscription already had, so the observable sequence is initial value, disconnect, external mutation, updated value, never a spurious repeat of the old value. `QueryFailed` is delivered as a structured `FunctionError` without ending the subscription, and a later valid `Transition` recovers it normally. Timestamps are decoded from Convex's base64 little-endian 8-byte counters and compared by magnitude so `maxObservedTimestamp` only advances.

Three genuine correctness bugs were found and fixed using the loopback fixture in `client/tests/FixtureServer.mod` together with `client/tests/TestLive.mod`, rather than by inspection: a transport-level disconnect was clearing every subscription's cached "last value", which defeated rehydration suppression on every single reconnect; the reconnect snapshot never cleared its own `addPending` flag, causing a redundant duplicate `Add` for the same query on the very next `Pump()`; and every failure event was hardcoded to report `FunctionError` regardless of its real cause, so a `TransportError` or `ProtocolError` was always misreported. All three are fixed in `client/ConvexSync.mod` and are covered by the deterministic two-process Live acceptance test.

The conformance adapter under `client/tests/conformance/ConvexAdapter.mod` implements NDJSON adapter protocol v1 over both stdin/stdout and TCP (`ADAPTER_LISTEN`), reserves stdout for protocol events, sends diagnostics to stderr, and omits optional fields (`id`, `subscriptionId`, `logs`, `errorData`) rather than serializing them as `null` when absent. `debugDisconnect` is exposed only there, not in the educational client API, exactly as this project requires for proving real reconnects.

GNU Modula-2 14.2.0 (the version Debian trixie packages) has a few undocumented compiler limitations this client works around: indexing a `CONST` string literal can crash the front end with an internal error, so lookup tables such as the base64 alphabet and hex digits are module-level `VAR` arrays assigned once when the module starts; two procedures that each declare their own nested procedure can crash the front end when one calls the other, so `ConvexSync`'s four message builders share flat, top-level `AppendBuf`/`AppendIntBuf` helpers instead of nested ones; and the standard library's `Strings.Length` segfaults on arrays of roughly 2 MiB or larger (this client's buffers routinely are), so every module uses a small hand-written bounded scan for string length instead. Each workaround is commented at its call site in the source.

## Limitations

Live authentication, WebSocket mutations, WebSocket actions, optimistic updates, and journals are deferred; every query, mutation, and action goes over the HTTP API, and Live is read-only subscription delivery. `TransitionChunk` assembly is deferred: receiving one, or any other unrecognised server message type, is reported as a `ProtocolError` and reconnects every active subscription.

At most 16 Live subscriptions may be active at once (`client/ConvexSync.mod`'s fixed subscription table), with a 256-byte path and an 8192-byte argument and last-value cap per subscription. `Pump()` delivers from a bounded ring buffer of the newest 32 pending events; a slow or absent consumer causes the oldest queued event to be dropped rather than unbounded growth, but that overflow path is implemented without a dedicated language-local test yet. HTTP bodies are capped at 2 MiB and WebSocket messages at 4 MiB; chunked HTTP transfer-encoding is rejected as a transport error rather than decoded.

Values are exposed as raw JSON text rather than a richer Modula-2 value tree; the example and tests decode only the specific fields they need. The root-owned local and hosted evaluators have not yet run against this exact commit, so no capability badge is claimed in `manifest.yaml` even though the language-local Docker `test` gate, the loopback HTTP/TLS/WebSocket smoke tests exercised during development, and the two-process Live acceptance test all pass.
