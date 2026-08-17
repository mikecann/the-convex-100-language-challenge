# Modula-2

[Modula-2](https://people.inf.ethz.ch/wirth/projects.html) is Niklaus Wirth's late-1970s revision of Pascal, created to build the Lilith personal workstation's system software. It added separately compiled modules, explicit interfaces, coroutines, and low-level facilities suited to operating systems, tools, teaching, and industrial control software. Wirth later simplified its ideas into Oberon.

Today Modula-2 is a niche language rather than a mainstream application stack, but its [ISO standard](https://www.iso.org/standard/18583.html) remains current and [GNU Modula-2](https://gcc.gnu.org/onlinedocs/gm2/) is a documented GCC front end. This repository uses GNU Modula-2 14.2.0 to explore what a small, native Convex client looks like without a modern package ecosystem.

This is an educational, unofficial demonstration. It is not a production SDK and is not intended for package publication.

## Getting Started

Start with [`examples/basics/main.mod`](examples/basics/main.mod). It queries a fresh counter, opens a Live subscription before changing the counter, sends one idempotent mutation, and confirms the same `0 -> 1` result through both HTTP and Live.

From the repository root, Docker builds the exact canonical example and runs it against the project's approved test deployment:

```sh
./run verify-example modula-2
```

## Interesting Parts

### The interface is a separate file from the implementation

Modula-2 was Wirth's fix for a problem C headers only paper over: a module's public contract and its private body are two different files, compiled and checked separately. `ConvexJSON.def` is the entire public face of this client's JSON reader — its scanning logic lives only in `ConvexJSON.mod`, a file the interface never mentions.

```modula2
DEFINITION MODULE ConvexJSON;

(* Callers only ever see this; the byte-scanning implementation lives
   in ConvexJSON.mod, a file this interface never exposes. *)
PROCEDURE Member (VAR doc: ARRAY OF CHAR; key: ARRAY OF CHAR;
                   VAR value: ARRAY OF CHAR; VAR found: BOOLEAN) : BOOLEAN;
(* ...six more procedures, then nothing else... *)

END ConvexJSON.
```

Nothing outside this file can reach `ConvexJSON.mod`'s internals, even by accident — the compiler enforces the boundary, not a convention.

### There's no + for strings

Modula-2 has no string type and no concatenation operator: `ARRAY OF CHAR` is just a fixed, NUL-terminated block of memory, so a JSON argument object gets built one appended fragment at a time. It reads a little like Forth pushing pieces onto a buffer instead of a stack.

```modula2
args[0] := 0C;
AppendLit('{"room":', args);
IF NOT AppendQuoted(room, args) THEN Fail("room id was too long") END;
AppendLit('}', args);
(* TypeScript: `{"room":${JSON.stringify(room)}}` *)
```

By the time `Call` sees `args`, it is already plain JSON text — there was never a string builder hiding the work.

### Success and failure are separate out-parameters

Modula-2 has no exceptions. Every way a Convex call can end — a clean result, a structured `FunctionError`, or a transport failure — comes back through its own `VAR` parameter, all present in the signature at once rather than caught later.

```modula2
PROCEDURE Call (operation: ARRAY OF CHAR; path: ARRAY OF CHAR; VAR args: ARRAY OF CHAR;
                 VAR value: ARRAY OF CHAR; VAR logs: ARRAY OF CHAR;
                 VAR errorName: ARRAY OF CHAR; VAR errorMessage: ARRAY OF CHAR;
                 VAR errorData: ARRAY OF CHAR; VAR hasErrorData: BOOLEAN;
                 VAR ok: BOOLEAN; VAR transportError: ARRAY OF CHAR);
(* TypeScript: one try/catch around `await client.query(...)` covers all three *)
```

Reading a result means checking `ok`, then `errorName`, in that fixed order — nothing is hidden, but nothing is optional either.

### Live delivers one event per Pump call

React's `useQuery` starts and stops a subscription with the component and rerenders you automatically. This client hands that job to the caller instead: `Subscribe` only registers intent, and `Pump` is the single place that ever touches the WebSocket, handing back at most one queued update per call.

```modula2
ConvexSync.Subscribe("demo:state", args, handle, ok, transportError);
REPEAT
  (* Pump owns the socket; it returns at most one Live event per call. *)
  ConvexSync.Pump(200, eventKind, eventHandle, value, logs,
                  errorName, errorMessage, errorData, hasErrorData);
UNTIL (eventKind <> 0) AND (eventHandle = handle);
(* TypeScript: useQuery(api.demo.state, { room }) owns this loop for you *)
```

Reconnects, backoff, and duplicate-value suppression all happen inside that same one function — proved against a loopback fixture in the test suite.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, log lines, and structured errors | Implemented; verified by shared conformance on both profiles |
| Live initial values, external updates, and `QueryFailed` followed by recovery | Implemented; proved against a loopback fixture in [`client/tests/TestLive.mod`](client/tests/TestLive.mod), and verified by shared conformance on both profiles |
| Five forced reconnects with subscription resend, unchanged-value suppression, and connection/backoff bookkeeping | Implemented; proved against [`client/tests/FixtureServer.mod`](client/tests/FixtureServer.mod), and verified by shared conformance on both profiles |
| WebSocket mutations, actions, Live authentication, optimistic updates, and journals | Not implemented |
| `TransitionChunk` assembly | Not implemented; treated as a protocol error, followed by reconnecting active subscriptions |
| Production SDK compatibility | Not claimed |

## Example

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

## Implementation Notes

The public client is split along boundaries that suit Modula-2's module system. Each `.def` file is the small public interface, while its `.mod` partner hides the implementation. `ConvexJSON` scans fixed character arrays without building a dynamic value tree. `ConvexHTTP` implements HTTP/1.1 framing, `ConvexWS` implements WebSocket framing, and `ConvexSync` adds the Convex request shapes and Live subscription behaviour.

This is classified as a native client because the Convex-specific work is written in Modula-2. The small [`client/cshim.c`](client/cshim.c) layer provides only general operating-system facilities that GNU Modula-2 does not conveniently expose here: raw sockets, OpenSSL TLS, polling, a monotonic clock, secure random bytes, and SHA-1 for the WebSocket handshake. It does not understand Convex, HTTP, JSON, or WebSocket frames.

Live uses one process-wide connection. `Subscribe` records work, and the next `Pump` sends it or reads an available server message. A fixed table allows 16 active subscriptions. Pending delivery is a 32-event ring buffer; if a caller stops pumping and fills it, the oldest event is discarded instead of allowing memory to grow without a bound. Reconnects resend active subscriptions and suppress a repeated initial value when its JSON bytes match the last value already delivered.

GNU Modula-2 14.2.0 also shaped some otherwise odd-looking code. The implementation keeps lookup tables in initialized variables because indexing a constant string can crash this compiler, uses top-level helpers instead of certain combinations of nested procedures, and replaces the standard `Strings.Length` for multi-megabyte arrays with bounded scans. These are compiler workarounds documented beside the affected code, not general Modula-2 rules.

## Known Issues

1. Live is read-only. Queries, mutations, and actions use HTTP; Live authentication, WebSocket mutations and actions, optimistic updates, and journals are deferred.
2. Values remain raw JSON text. Callers use `ConvexJSON` to extract the fields they need rather than receiving a richer Modula-2 value tree.
3. `TransitionChunk` is not assembled. An unrecognised server message becomes a protocol error and causes active subscriptions to reconnect.
4. The client caps HTTP bodies at 2 MiB and WebSocket messages at 4 MiB, and it rejects chunked HTTP transfer encoding.
5. Live allows 16 subscriptions, with 8 KiB argument and last-value buffers per subscription. The 32-event overflow behaviour is implemented but does not yet have a dedicated language-local saturation test.
6. The test adapter has not been pressure-tested with a stopped reader against the shared 128 MiB process limit.
