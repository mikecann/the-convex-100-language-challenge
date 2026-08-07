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
