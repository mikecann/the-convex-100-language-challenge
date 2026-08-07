IMPLEMENTATION MODULE ConvexSync;

FROM CShim IMPORT ShimMonotonicMs, ShimPoll2;
FROM ConvexWS IMPORT Open, SendText, Receive, Close, IsOpen, Fd, MaxMessage;
FROM ConvexHTTP IMPORT Post, MaxBody;
FROM ConvexBase64 IMPORT Decode;
FROM ConvexJSON IMPORT Member, DecodeString, AppendQuoted, ArrayBegin, ArrayNext,
  StringArrayValid, ParseNonNegativeInt;

(* gm2's ISO Strings.Length crashes when called on an array whose declared
   capacity is roughly 2 MiB or more (confirmed empirically: it is fine on
   a 1 MiB array and segfaults on a 2 MiB one, with no application code on
   the stack between the call and the crash). Several buffers in this
   client are exactly that large, so every module scans for the NUL
   terminator itself instead of trusting Strings.Length. *)
PROCEDURE TextLength (VAR s: ARRAY OF CHAR) : INTEGER;
VAR i, cap: INTEGER;
BEGIN
  cap := INTEGER(HIGH(s));
  i := 0;
  WHILE (i <= cap) AND (s[i] <> 0C) DO INC(i) END;
  RETURN i;
END TextLength;

CONST
  MaxArgs = 8192;
  MaxPath = 256;
  MaxMessageOut = 16640; (* MaxArgs + protocol envelope headroom *)
  MaxEvents = 32;
  InitialTimestamp = "AAAAAAAAAAA=";

(* Call() and Pump() work with buffers that can approach MaxBody/MaxMessage
   (a few megabytes); gm2 copies a large ARRAY OF CHAR value parameter onto
   the stack (see ConvexHTTP.mod's note), and even without that, several
   such arrays as PROCEDURE locals risk the default thread stack, so they
   are static module storage instead. Neither Call nor Pump is reentrant
   (this client is single threaded). *)
VAR
  PumpMsgText: ARRAY [0..MaxMessage - 1] OF CHAR;
  CallPayload: ARRAY [0..MaxBody - 1] OF CHAR;
  CallBody: ARRAY [0..MaxBody - 1] OF CHAR;
  CallValueRaw, CallLogsRaw, CallMsgRaw, CallDataRaw: ARRAY [0..MaxBody - 1] OF CHAR;

TYPE
  Subscription = RECORD
    occupied: BOOLEAN;
    active: BOOLEAN;
    addPending: BOOLEAN;
    removePending: BOOLEAN;
    rehydrating: BOOLEAN;
    hasLastValue: BOOLEAN;
    valueTooLargeToCompare: BOOLEAN;
    queryId: INTEGER;
    path: ARRAY [0..MaxPath - 1] OF CHAR;
    args: ARRAY [0..MaxArgs - 1] OF CHAR;
    lastValue: ARRAY [0..MaxValue - 1] OF CHAR;
  END;

  PendingEvent = RECORD
    kind: INTEGER; (* 1 updated, 2 failed *)
    handle: INTEGER;
    value: ARRAY [0..MaxValue - 1] OF CHAR;
    logs: ARRAY [0..MaxValue - 1] OF CHAR;
    errorName: ARRAY [0..31] OF CHAR; (* "FunctionError" / "ProtocolError" / "TransportError" *)
    errorMessage: ARRAY [0..MaxValue - 1] OF CHAR;
    errorData: ARRAY [0..MaxValue - 1] OF CHAR;
    hasErrorData: BOOLEAN;
  END;

VAR
  deploymentUrl: ARRAY [0..511] OF CHAR;
  authToken: ARRAY [0..2047] OF CHAR;
  sessionId: ARRAY [0..63] OF CHAR;

  subs: ARRAY [0..MaxSubscriptions - 1] OF Subscription;
  nextQueryId: INTEGER;

  connected: BOOLEAN;
  querySetVersion: INTEGER;
  remoteQuerySet: INTEGER;
  remoteIdentity: INTEGER;
  remoteTimestamp: ARRAY [0..15] OF CHAR;
  maxObservedTs: ARRAY [0..15] OF CHAR;
  connectionCount: INTEGER;
  lastCloseReasonText: ARRAY [0..63] OF CHAR;
  reconnectAt: LONGINT;
  backoffMs: INTEGER;

  events: ARRAY [0..MaxEvents - 1] OF PendingEvent;
  eventHead, eventCount: INTEGER;

(* ---------- small text helpers ---------- *)

PROCEDURE CopyText (source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := INTEGER(TextLength(source));
  IF n > INTEGER(HIGH(destination)) THEN n := INTEGER(HIGH(destination)) END;
  FOR i := 0 TO n - 1 DO destination[i] := source[i] END;
  destination[n] := 0C;
END CopyText;

(* CopyLargeText is CopyText with source passed VAR instead of by value,
   used only where source may be one of the module's MaxBody-sized (2
   MiB) buffers -- CallValueRaw, CallLogsRaw, CallDataRaw below. A plain
   (value) ARRAY OF CHAR parameter is passed by gm2 copying every byte
   into the callee's own stack frame; this is exactly the hazard
   ConvexHTTP.mod's Post already documents ("a value-parameter ARRAY OF
   CHAR copy of a multi-megabyte buffer is what originally crashed this
   module") and already avoids for its own payload parameter. CopyText
   itself was the one place that lesson was not applied, and it crashed
   the same way, in module initialization, before any output:
   _M2_Basics_init -> ConvexSync.Call -> CopyText(CallValueRaw, value)
   blew the thread's stack copying 2 MiB of by-value parameter. This
   can't just change CopyText's own source parameter to VAR, because
   gm2 rejects binding a VAR formal to a string-literal actual (most of
   CopyText's call sites pass literals like CopyText("...", reason)), so
   the two large-buffer-safe call sites get this sibling instead. source
   is never written here, so nothing behavioral differs from CopyText,
   only how the argument arrives. *)
PROCEDURE CopyLargeText (VAR source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := INTEGER(TextLength(source));
  IF n > INTEGER(HIGH(destination)) THEN n := INTEGER(HIGH(destination)) END;
  FOR i := 0 TO n - 1 DO destination[i] := source[i] END;
  destination[n] := 0C;
END CopyLargeText;

PROCEDURE TextEqual (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR) : BOOLEAN;
VAR la, lb, i: INTEGER;
BEGIN
  la := INTEGER(TextLength(a));
  lb := INTEGER(TextLength(b));
  IF la <> lb THEN RETURN FALSE END;
  FOR i := 0 TO la - 1 DO
    IF a[i] <> b[i] THEN RETURN FALSE END;
  END;
  RETURN TRUE;
END TextEqual;

(* ---------- session id and timestamp comparison ---------- *)

PROCEDURE HexDigit (value: INTEGER) : CHAR;
BEGIN
  IF value < 10 THEN RETURN CHR(ORD('0') + CARDINAL(value)) END;
  RETURN CHR(ORD('a') + CARDINAL(value - 10));
END HexDigit;

PROCEDURE NewSessionId;
VAR
  clock: LONGINT;
  hex: ARRAY [0..15] OF CHAR;
  i: INTEGER;
  v: LONGINT;
BEGIN
  clock := ShimMonotonicMs();
  FOR i := 15 TO 0 BY -1 DO
    v := clock MOD 16;
    hex[i] := HexDigit(VAL(INTEGER, v));
    clock := clock DIV 16;
  END;
  (* "00000000-0000-4000-8000-" is exactly 24 characters (indices 0..23,
     ending in its own trailing '-'), so the 12 trailing hex digits that
     complete the UUID's fifth group belong at indices 24..35, not
     21..32. The old 21..32 range instead overwrote three characters of
     the prefix itself -- "8000-"'s last "00-" -- deleting the fourth/
     fifth group's separating hyphen and truncating the fourth group to
     a single digit, with no hyphen ever reinstated before the tacked-on
     hex digits. The server correctly rejected the result as invalid:
     {"type":"FatalError","error":"Received Invalid JSON on websocket:
     invalid group count: expected 5, found 4"} -- every single Live
     connection attempt sent a 4-group, 33-character non-UUID as its
     sessionId and was fatally rejected before ever receiving a
     Transition. *)
  CopyText("00000000-0000-4000-8000-", sessionId);
  FOR i := 4 TO 15 DO
    sessionId[24 + (i - 4)] := hex[i];
  END;
  sessionId[36] := 0C;
END NewSessionId;

(* TimestampGreater decodes two base64 sync-protocol timestamps (each an
   8 byte little-endian counter) and compares their magnitude without ever
   materialising them as a 64 bit integer type this dialect may not have. *)
PROCEDURE TimestampGreater (VAR left: ARRAY OF CHAR; VAR right: ARRAY OF CHAR) : BOOLEAN;
VAR
  leftBytes, rightBytes: ARRAY [0..7] OF CHAR;
  leftLen, rightLen, i: INTEGER;
  leftOk, rightOk: BOOLEAN;
BEGIN
  leftOk := Decode(left, leftBytes, leftLen) AND (leftLen = 8);
  rightOk := Decode(right, rightBytes, rightLen) AND (rightLen = 8);
  IF NOT leftOk OR NOT rightOk THEN RETURN FALSE END;
  FOR i := 7 TO 0 BY -1 DO
    IF ORD(leftBytes[i]) > ORD(rightBytes[i]) THEN RETURN TRUE END;
    IF ORD(leftBytes[i]) < ORD(rightBytes[i]) THEN RETURN FALSE END;
  END;
  RETURN FALSE;
END TimestampGreater;

(* ---------- subscription table ---------- *)

PROCEDURE FindSlot (queryId: INTEGER) : INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND (subs[i].queryId = queryId) THEN RETURN i END;
  END;
  RETURN -1;
END FindSlot;

PROCEDURE FreeSlot () : INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF NOT subs[i].occupied THEN RETURN i END;
  END;
  RETURN -1;
END FreeSlot;

PROCEDURE ActiveCount () : INTEGER;
VAR i, count: INTEGER;
BEGIN
  count := 0;
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].active AND NOT subs[i].removePending THEN INC(count) END;
  END;
  RETURN count;
END ActiveCount;

(* ---------- pending event queue ---------- *)

PROCEDURE DiscardEventsFor (handle: INTEGER);
VAR i, w: INTEGER;
BEGIN
  w := 0;
  FOR i := 0 TO eventCount - 1 DO
    IF events[(eventHead + i) MOD MaxEvents].handle <> handle THEN
      events[(eventHead + w) MOD MaxEvents] := events[(eventHead + i) MOD MaxEvents];
      INC(w);
    END;
  END;
  eventCount := w;
END DiscardEventsFor;

PROCEDURE EnqueueEvent (VAR event: PendingEvent);
BEGIN
  IF eventCount >= MaxEvents THEN
    eventHead := (eventHead + 1) MOD MaxEvents;
    DEC(eventCount);
  END;
  events[(eventHead + eventCount) MOD MaxEvents] := event;
  INC(eventCount);
END EnqueueEvent;

(* ---------- outgoing message builders ---------- *)

(* Every message builder below appends through these two shared, top level
   helpers rather than a nested procedure closing over its caller's
   buffer: this gm2 build corrupts its own symbol table ("front end
   poisoned this symbol" / "gcc symbol which is no longer in scope") when a
   procedure with a nested procedure calls another procedure that also has
   one, so nesting is avoided everywhere a message is assembled. *)
PROCEDURE AppendBuf (text: ARRAY OF CHAR; VAR out: ARRAY OF CHAR; VAR outLength: INTEGER);
VAR n, j: INTEGER;
BEGIN
  n := INTEGER(TextLength(text));
  FOR j := 0 TO n - 1 DO out[outLength] := text[j]; INC(outLength) END;
END AppendBuf;

PROCEDURE AppendIntBuf (value: INTEGER; VAR out: ARRAY OF CHAR; VAR outLength: INTEGER);
VAR digits: ARRAY [0..15] OF CHAR; digitCount, v: INTEGER;
BEGIN
  IF value = 0 THEN AppendBuf("0", out, outLength); RETURN END;
  digitCount := 0;
  v := value;
  WHILE v > 0 DO
    digits[digitCount] := CHR(ORD('0') + CARDINAL(v MOD 10));
    v := v DIV 10;
    INC(digitCount);
  END;
  WHILE digitCount > 0 DO
    DEC(digitCount);
    out[outLength] := digits[digitCount];
    INC(outLength);
  END;
END AppendIntBuf;

PROCEDURE BuildConnectMessage (VAR out: ARRAY OF CHAR);
VAR outLength: INTEGER;
BEGIN
  outLength := 0;
  AppendBuf('{"type":"Connect","sessionId":"', out, outLength);
  AppendBuf(sessionId, out, outLength);
  AppendBuf('","connectionCount":', out, outLength);
  AppendIntBuf(connectionCount, out, outLength);
  AppendBuf(',"lastCloseReason":', out, outLength);
  out[outLength] := 0C;
  IF NOT AppendQuoted(lastCloseReasonText, out) THEN AppendBuf('""', out, outLength) END;
  outLength := INTEGER(TextLength(out));
  IF INTEGER(TextLength(maxObservedTs)) > 0 THEN
    AppendBuf(',"maxObservedTimestamp":', out, outLength);
    out[outLength] := 0C;
    IF NOT AppendQuoted(maxObservedTs, out) THEN AppendBuf('""', out, outLength) END;
    outLength := INTEGER(TextLength(out));
  END;
  AppendBuf(',"clientTs":0}', out, outLength);
  out[outLength] := 0C;
END BuildConnectMessage;

PROCEDURE AppendAddModification (slot: INTEGER; VAR out: ARRAY OF CHAR; VAR outLength: INTEGER);
VAR i: INTEGER;
BEGIN
  AppendBuf('{"type":"Add","queryId":', out, outLength);
  AppendIntBuf(subs[slot].queryId, out, outLength);
  AppendBuf(',"udfPath":', out, outLength);
  out[outLength] := 0C;
  IF NOT AppendQuoted(subs[slot].path, out) THEN AppendBuf('""', out, outLength) END;
  outLength := INTEGER(TextLength(out));
  AppendBuf(',"args":[', out, outLength);
  FOR i := 0 TO INTEGER(TextLength(subs[slot].args)) - 1 DO
    out[outLength] := subs[slot].args[i];
    INC(outLength);
  END;
  AppendBuf(']}', out, outLength);
END AppendAddModification;

(* BuildSnapshotAdds emits a ModifyQuerySet covering every currently active
   subscription; used right after a fresh Connect so a new connection
   rehydrates every Live query it owns. *)
PROCEDURE BuildSnapshotAdds (VAR out: ARRAY OF CHAR; VAR count: INTEGER);
VAR
  outLength, i: INTEGER;
  first: BOOLEAN;
BEGIN
  outLength := 0;
  count := 0;
  first := TRUE;
  AppendBuf('{"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,"modifications":[', out, outLength);
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].active AND NOT subs[i].removePending THEN
      IF NOT first THEN AppendBuf(',', out, outLength) END;
      first := FALSE;
      AppendAddModification(i, out, outLength);
      INC(count);
      subs[i].rehydrating := subs[i].hasLastValue;
      (* Without this, every one of these subscriptions would still read
         as addPending on the next Pump() and get sent a second, redundant
         individual Add afterwards - corrupting the query set (a real
         Convex backend rejects Adding a queryId that is already active)
         and, in this client's own loopback tests, confusing which wire
         queryId a later Transition belongs to. *)
      subs[i].addPending := FALSE;
    END;
  END;
  AppendBuf(']}', out, outLength);
  out[outLength] := 0C;
END BuildSnapshotAdds;

PROCEDURE BuildSingleModification (slot: INTEGER; removing: BOOLEAN;
                                    VAR out: ARRAY OF CHAR; VAR outLength: INTEGER;
                                    baseVersion, newVersion: INTEGER);
BEGIN
  outLength := 0;
  AppendBuf('{"type":"ModifyQuerySet","baseVersion":', out, outLength);
  AppendIntBuf(baseVersion, out, outLength);
  AppendBuf(',"newVersion":', out, outLength);
  AppendIntBuf(newVersion, out, outLength);
  AppendBuf(',"modifications":[', out, outLength);
  IF removing THEN
    AppendBuf('{"type":"Remove","queryId":', out, outLength);
    AppendIntBuf(subs[slot].queryId, out, outLength);
    AppendBuf('}', out, outLength);
  ELSE
    AppendAddModification(slot, out, outLength);
  END;
  AppendBuf(']}', out, outLength);
  out[outLength] := 0C;
END BuildSingleModification;

(* ---------- connecting ---------- *)

PROCEDURE RetireConnection (reason: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  connected := FALSE;
  INC(connectionCount);
  CopyText(reason, lastCloseReasonText);
  querySetVersion := 0;
  remoteQuerySet := 0;
  remoteIdentity := 0;
  CopyText(InitialTimestamp, remoteTimestamp);
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].active AND NOT subs[i].removePending THEN
      subs[i].addPending := TRUE;
      subs[i].rehydrating := subs[i].hasLastValue;
    END;
  END;
END RetireConnection;

PROCEDURE ConnectNow;
VAR
  ok: BOOLEAN;
  errorText: ARRAY [0..255] OF CHAR;
  connectMsg: ARRAY [0..511] OF CHAR;
  snapshot: ARRAY [0..MaxMessageOut - 1] OF CHAR;
  addCount: INTEGER;
  deadline: LONGINT;
  syncUrl: ARRAY [0..767] OF CHAR;
BEGIN
  (* ConvexURL.Parse defaults a URL's path to "/" whenever the URL itself
     has no path component -- which deploymentUrl never does, since it is
     always exactly the bare CONVEX_URL (e.g. "http://backend:3210" or
     "https://foo.convex.cloud"). Opening deploymentUrl directly therefore
     always requested "/" (the deployment's plain-text health page, "This
     Convex deployment is running...") instead of the sync endpoint, and
     Open correctly refused to treat that 200 OK as a WebSocket upgrade
     ("WebSocket handshake was rejected or forged") -- so this never
     connected at all, on either the self-hosted or the hosted backend.
     The Live protocol lives at /api/sync specifically, so it must be
     appended here before calling Open, the same way every HTTP call in
     this file explicitly appends "/api/query" etc. to endpoint. *)
  CopyText(deploymentUrl, syncUrl);
  AppendLit("/api/sync", syncUrl);
  Open(syncUrl, "0.1.0", 8000, ok, errorText);
  IF NOT ok THEN
    RetireConnection(errorText);
    reconnectAt := ShimMonotonicMs() + VAL(LONGINT, backoffMs);
    backoffMs := backoffMs * 2;
    IF backoffMs > 15000 THEN backoffMs := 15000 END;
    RETURN;
  END;
  BuildConnectMessage(connectMsg);
  deadline := ShimMonotonicMs() + 5000;
  SendText(connectMsg, INTEGER(TextLength(connectMsg)), deadline, ok, errorText);
  IF NOT ok THEN
    Close();
    RetireConnection(errorText);
    reconnectAt := ShimMonotonicMs() + VAL(LONGINT, backoffMs);
    backoffMs := backoffMs * 2;
    IF backoffMs > 15000 THEN backoffMs := 15000 END;
    RETURN;
  END;
  BuildSnapshotAdds(snapshot, addCount);
  IF addCount > 0 THEN
    deadline := ShimMonotonicMs() + 5000;
    SendText(snapshot, INTEGER(TextLength(snapshot)), deadline, ok, errorText);
    IF NOT ok THEN
      Close();
      RetireConnection(errorText);
      reconnectAt := ShimMonotonicMs() + VAL(LONGINT, backoffMs);
      backoffMs := backoffMs * 2;
      IF backoffMs > 15000 THEN backoffMs := 15000 END;
      RETURN;
    END;
  END;
  connected := TRUE;
  querySetVersion := 0;
  IF addCount > 0 THEN querySetVersion := 1 END;
  backoffMs := 100;
END ConnectNow;

(* ---------- incoming Transition handling ---------- *)

PROCEDURE ParseStateVersion (VAR obj: ARRAY OF CHAR; VAR querySet, identity: INTEGER;
                             VAR ts: ARRAY OF CHAR; VAR ok: BOOLEAN);
VAR
  raw: ARRAY [0..MaxValue - 1] OF CHAR;
  found, decoded: BOOLEAN;
BEGIN
  ok := FALSE;
  ts[0] := 0C;
  IF NOT Member(obj, "querySet", raw, found) OR NOT found THEN RETURN END;
  IF NOT ParseNonNegativeInt(raw, querySet) THEN RETURN END;
  IF NOT Member(obj, "identity", raw, found) OR NOT found THEN RETURN END;
  IF NOT ParseNonNegativeInt(raw, identity) THEN RETURN END;
  IF NOT Member(obj, "ts", raw, found) OR NOT found THEN RETURN END;
  IF NOT DecodeString(raw, ts) THEN RETURN END;
  ok := TRUE;
END ParseStateVersion;

(* HandleTransition validates and applies one Transition message, enqueuing
   at most one event per modification (bounded by the shared event queue).
   Returns FALSE (with reason) on any structural or state mismatch, which
   the caller treats as a ProtocolError and a forced reconnect. *)
PROCEDURE HandleTransition (VAR message: ARRAY OF CHAR; VAR ok: BOOLEAN; VAR reason: ARRAY OF CHAR);
VAR
  startObj, endObj, modifications, kindRaw, kind: ARRAY [0..MaxValue - 1] OF CHAR;
  found, decoded, elementOk: BOOLEAN;
  startQuerySet, startIdentity, endQuerySet, endIdentity: INTEGER;
  startTs, endTs: ARRAY [0..15] OF CHAR;
  cursor: INTEGER;
  element: ARRAY [0..MaxValue - 1] OF CHAR;
  queryIdRaw: ARRAY [0..63] OF CHAR;
  queryId, slot: INTEGER;
  logsRaw: ARRAY [0..MaxValue - 1] OF CHAR;
  hasLogs: BOOLEAN;
  event: PendingEvent;
  valueRaw: ARRAY [0..MaxValue - 1] OF CHAR;
  errRaw: ARRAY [0..MaxValue - 1] OF CHAR;
  errText: ARRAY [0..MaxValue - 1] OF CHAR;
  errDataRaw: ARRAY [0..MaxValue - 1] OF CHAR;
  hasErrData: BOOLEAN;
  unchanged: BOOLEAN;
BEGIN
  ok := FALSE;
  IF NOT Member(message, "startVersion", startObj, found) OR NOT found THEN
    CopyText("Transition omitted startVersion", reason); RETURN;
  END;
  IF NOT Member(message, "endVersion", endObj, found) OR NOT found THEN
    CopyText("Transition omitted endVersion", reason); RETURN;
  END;
  IF NOT Member(message, "modifications", modifications, found) OR NOT found THEN
    CopyText("Transition omitted modifications", reason); RETURN;
  END;
  ParseStateVersion(startObj, startQuerySet, startIdentity, startTs, decoded);
  IF NOT decoded THEN CopyText("Transition startVersion was invalid", reason); RETURN END;
  ParseStateVersion(endObj, endQuerySet, endIdentity, endTs, decoded);
  IF NOT decoded THEN CopyText("Transition endVersion was invalid", reason); RETURN END;

  IF (startQuerySet <> remoteQuerySet) OR (startIdentity <> remoteIdentity) OR NOT TextEqual(startTs, remoteTimestamp) THEN
    CopyText("Transition startVersion did not match local state", reason);
    RETURN;
  END;

  IF NOT ArrayBegin(modifications, cursor) THEN
    CopyText("Transition modifications were malformed", reason); RETURN;
  END;
  LOOP
    IF NOT ArrayNext(modifications, cursor, element) THEN EXIT END;
    IF NOT Member(element, "type", kindRaw, found) OR NOT found THEN
      CopyText("Transition modification omitted type", reason); RETURN;
    END;
    IF NOT DecodeString(kindRaw, kind) THEN
      CopyText("Transition modification type was invalid", reason); RETURN;
    END;
    IF NOT Member(element, "queryId", queryIdRaw, found) OR NOT found THEN
      CopyText("Transition modification omitted queryId", reason); RETURN;
    END;
    IF NOT ParseNonNegativeInt(queryIdRaw, queryId) THEN
      CopyText("Transition modification queryId was invalid", reason); RETURN;
    END;
    logsRaw[0] := 0C;
    hasLogs := Member(element, "logLines", logsRaw, found) AND found;
    IF hasLogs AND NOT StringArrayValid(logsRaw) THEN
      CopyText("Transition logLines was not an array of strings", reason); RETURN;
    END;

    slot := FindSlot(queryId);

    IF TextEqual(kind, "QueryRemoved") THEN
      IF slot >= 0 THEN subs[slot].hasLastValue := FALSE END;
    ELSIF TextEqual(kind, "QueryUpdated") THEN
      IF NOT Member(element, "value", valueRaw, found) OR NOT found THEN
        CopyText("QueryUpdated omitted value", reason); RETURN;
      END;
      IF (slot >= 0) AND subs[slot].active AND NOT subs[slot].removePending THEN
        unchanged := subs[slot].rehydrating AND subs[slot].hasLastValue
          AND NOT subs[slot].valueTooLargeToCompare AND TextEqual(subs[slot].lastValue, valueRaw);
        IF INTEGER(TextLength(valueRaw)) > INTEGER(HIGH(subs[slot].lastValue)) THEN
          subs[slot].valueTooLargeToCompare := TRUE;
        ELSE
          subs[slot].valueTooLargeToCompare := FALSE;
          CopyText(valueRaw, subs[slot].lastValue);
        END;
        subs[slot].hasLastValue := TRUE;
        subs[slot].rehydrating := FALSE;
        IF NOT unchanged THEN
          event.kind := 1;
          event.handle := queryId;
          CopyText(valueRaw, event.value);
          IF hasLogs THEN CopyText(logsRaw, event.logs) ELSE CopyText("[]", event.logs) END;
          event.hasErrorData := FALSE;
          EnqueueEvent(event);
        END;
      END;
    ELSIF TextEqual(kind, "QueryFailed") THEN
      IF NOT Member(element, "errorMessage", errRaw, found) OR NOT found THEN
        CopyText("QueryFailed omitted errorMessage", reason); RETURN;
      END;
      IF NOT DecodeString(errRaw, errText) THEN CopyText(errRaw, errText) END;
      hasErrData := Member(element, "errorData", errDataRaw, found) AND found;
      IF (slot >= 0) AND subs[slot].active AND NOT subs[slot].removePending THEN
        subs[slot].hasLastValue := FALSE;
        subs[slot].rehydrating := FALSE;
        event.kind := 2;
        event.handle := queryId;
        CopyText("FunctionError", event.errorName);
        CopyText(errText, event.errorMessage);
        event.hasErrorData := hasErrData;
        IF hasErrData THEN CopyText(errDataRaw, event.errorData) END;
        IF hasLogs THEN CopyText(logsRaw, event.logs) ELSE CopyText("[]", event.logs) END;
        EnqueueEvent(event);
      END;
    ELSE
      CopyText("unknown Transition modification type", reason);
      RETURN;
    END;
  END;

  remoteQuerySet := endQuerySet;
  remoteIdentity := endIdentity;
  CopyText(endTs, remoteTimestamp);
  IF INTEGER(TextLength(maxObservedTs)) = 0 THEN
    CopyText(endTs, maxObservedTs);
  ELSIF TimestampGreater(endTs, maxObservedTs) THEN
    CopyText(endTs, maxObservedTs);
  END;
  ok := TRUE;
END HandleTransition;

(* PublishErrorToAll reports a connection-level failure (ProtocolError or
   TransportError) to every active subscription without disturbing
   hasLastValue/lastValue: the failure is about the transport, not a
   server verdict on the query, and a reconnect is about to try again
   immediately. Clearing the cached value here would defeat rehydration
   suppression on every single reconnect, redelivering a value the caller
   already has. *)
PROCEDURE PublishErrorToAll (name: ARRAY OF CHAR; message: ARRAY OF CHAR);
VAR i: INTEGER; event: PendingEvent;
BEGIN
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].active AND NOT subs[i].removePending THEN
      event.kind := 2;
      event.handle := subs[i].queryId;
      CopyText(name, event.errorName);
      CopyText(message, event.errorMessage);
      event.hasErrorData := FALSE;
      CopyText("[]", event.logs);
      EnqueueEvent(event);
    END;
  END;
END PublishErrorToAll;

PROCEDURE CompleteDisconnectedRemoves;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].removePending THEN
      subs[i].occupied := FALSE;
    END;
  END;
END CompleteDisconnectedRemoves;

PROCEDURE ScheduleReconnect;
BEGIN
  reconnectAt := ShimMonotonicMs() + VAL(LONGINT, backoffMs);
  backoffMs := backoffMs * 2;
  IF backoffMs > 15000 THEN backoffMs := 15000 END;
END ScheduleReconnect;

PROCEDURE DisconnectDueToFailure (reason: ARRAY OF CHAR; errName: ARRAY OF CHAR);
BEGIN
  IF INTEGER(TextLength(errName)) > 0 THEN
    PublishErrorToAll(errName, reason);
  END;
  Close();
  RetireConnection(reason);
  CompleteDisconnectedRemoves();
  ScheduleReconnect();
END DisconnectDueToFailure;

PROCEDURE FindPendingCommand (VAR slot: INTEGER; VAR removing: BOOLEAN) : BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].removePending THEN
      slot := i; removing := TRUE; RETURN TRUE;
    END;
  END;
  FOR i := 0 TO MaxSubscriptions - 1 DO
    IF subs[i].occupied AND subs[i].active AND subs[i].addPending AND NOT subs[i].removePending THEN
      slot := i; removing := FALSE; RETURN TRUE;
    END;
  END;
  RETURN FALSE;
END FindPendingCommand;

PROCEDURE SendPendingCommand (slot: INTEGER; removing: BOOLEAN);
VAR
  msg: ARRAY [0..MaxMessageOut - 1] OF CHAR;
  msgLength: INTEGER;
  ok: BOOLEAN;
  errorText: ARRAY [0..255] OF CHAR;
  deadline: LONGINT;
BEGIN
  BuildSingleModification(slot, removing, msg, msgLength, querySetVersion, querySetVersion + 1);
  deadline := ShimMonotonicMs() + 5000;
  SendText(msg, msgLength, deadline, ok, errorText);
  IF NOT ok THEN
    DisconnectDueToFailure(errorText, "");
    RETURN;
  END;
  INC(querySetVersion);
  IF removing THEN
    subs[slot].occupied := FALSE;
  ELSE
    subs[slot].addPending := FALSE;
  END;
END SendPendingCommand;

PROCEDURE DispatchServerMessage (VAR message: ARRAY OF CHAR);
VAR
  typeRaw, typeName: ARRAY [0..63] OF CHAR;
  found, decoded, ok: BOOLEAN;
  reason: ARRAY [0..255] OF CHAR;
BEGIN
  IF NOT Member(message, "type", typeRaw, found) OR NOT found THEN
    DisconnectDueToFailure("server message omitted type", "ProtocolError");
    RETURN;
  END;
  IF NOT DecodeString(typeRaw, typeName) THEN
    DisconnectDueToFailure("server message type was invalid", "ProtocolError");
    RETURN;
  END;
  IF TextEqual(typeName, "Transition") THEN
    HandleTransition(message, ok, reason);
    IF NOT ok THEN DisconnectDueToFailure(reason, "ProtocolError") END;
  ELSIF TextEqual(typeName, "Ping") THEN
    (* nothing to do *)
  ELSIF TextEqual(typeName, "MutationResponse") OR TextEqual(typeName, "ActionResponse") THEN
    (* WebSocket mutations/actions are not sent by this client; ignore *)
  ELSE
    CopyText("unknown server message type", reason);
    DisconnectDueToFailure(reason, "ProtocolError");
  END;
END DispatchServerMessage;

(* ---------- Pump: the sole owner of the WebSocket connection ---------- *)

PROCEDURE DrainOneEvent (VAR eventKind, handle: INTEGER;
                         VAR value, logs, errorName, errorMessage, errorData: ARRAY OF CHAR;
                         VAR hasErrorData: BOOLEAN) : BOOLEAN;
VAR event: PendingEvent;
BEGIN
  IF eventCount = 0 THEN RETURN FALSE END;
  event := events[eventHead];
  eventHead := (eventHead + 1) MOD MaxEvents;
  DEC(eventCount);
  handle := event.handle;
  IF event.kind = 1 THEN
    eventKind := 1;
    CopyText(event.value, value);
    CopyText(event.logs, logs);
    hasErrorData := FALSE;
  ELSE
    eventKind := 2;
    CopyText(event.errorName, errorName);
    CopyText(event.errorMessage, errorMessage);
    hasErrorData := event.hasErrorData;
    IF hasErrorData THEN CopyText(event.errorData, errorData) END;
    CopyText(event.logs, logs);
  END;
  RETURN TRUE;
END DrainOneEvent;

PROCEDURE Pump (timeoutMs: INTEGER;
                 VAR eventKind: INTEGER; VAR handle: INTEGER;
                 VAR value: ARRAY OF CHAR; VAR logs: ARRAY OF CHAR;
                 VAR errorName: ARRAY OF CHAR; VAR errorMessage: ARRAY OF CHAR;
                 VAR errorData: ARRAY OF CHAR; VAR hasErrorData: BOOLEAN);
VAR
  slot: INTEGER;
  removing: BOOLEAN;
  msgLength, status, pollResult, ready1, ready2: INTEGER;
  errorText: ARRAY [0..255] OF CHAR;
  now, waitMs: LONGINT;
BEGIN
  eventKind := 0; handle := 0;
  value[0] := 0C; logs[0] := 0C;
  errorName[0] := 0C; errorMessage[0] := 0C; errorData[0] := 0C;
  hasErrorData := FALSE;

  IF DrainOneEvent(eventKind, handle, value, logs, errorName, errorMessage, errorData, hasErrorData) THEN
    RETURN;
  END;

  IF connected THEN
    IF FindPendingCommand(slot, removing) THEN
      SendPendingCommand(slot, removing);
      RETURN;
    END;
    Receive(timeoutMs, PumpMsgText, msgLength, status, errorText);
    IF status = 1 THEN
      DispatchServerMessage(PumpMsgText);
    ELSIF status = 2 THEN
      DisconnectDueToFailure("peer closed the connection", "TransportError");
    ELSIF status = -1 THEN
      DisconnectDueToFailure(errorText, "TransportError");
    END;
    IF DrainOneEvent(eventKind, handle, value, logs, errorName, errorMessage, errorData, hasErrorData) THEN
      RETURN;
    END;
  ELSE
    IF ActiveCount() = 0 THEN
      pollResult := ShimPoll2(-1, -1, timeoutMs, ready1, ready2);
      RETURN;
    END;
    now := ShimMonotonicMs();
    IF now >= reconnectAt THEN
      ConnectNow();
      RETURN;
    END;
    waitMs := reconnectAt - now;
    IF waitMs > VAL(LONGINT, timeoutMs) THEN waitMs := VAL(LONGINT, timeoutMs) END;
    pollResult := ShimPoll2(-1, -1, VAL(INTEGER, waitMs), ready1, ready2);
  END;
END Pump;

(* ---------- public API ---------- *)

PROCEDURE Init (url: ARRAY OF CHAR; token: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  CopyText(url, deploymentUrl);
  CopyText(token, authToken);
  NewSessionId;
  nextQueryId := 0;
  FOR i := 0 TO MaxSubscriptions - 1 DO subs[i].occupied := FALSE END;
  connected := FALSE;
  querySetVersion := 0;
  remoteQuerySet := 0;
  remoteIdentity := 0;
  CopyText(InitialTimestamp, remoteTimestamp);
  maxObservedTs[0] := 0C;
  connectionCount := 0;
  CopyText("InitialConnect", lastCloseReasonText);
  reconnectAt := 0;
  backoffMs := 100;
  eventHead := 0; eventCount := 0;
END Init;

PROCEDURE SetAuth (token: ARRAY OF CHAR);
BEGIN
  CopyText(token, authToken);
END SetAuth;

PROCEDURE AppendLit (extra: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR baseLength, extraLength, i: INTEGER;
BEGIN
  baseLength := INTEGER(TextLength(destination));
  extraLength := INTEGER(TextLength(extra));
  FOR i := 0 TO extraLength - 1 DO destination[baseLength + i] := extra[i] END;
  destination[baseLength + extraLength] := 0C;
END AppendLit;

PROCEDURE Call (operation: ARRAY OF CHAR; path: ARRAY OF CHAR; VAR args: ARRAY OF CHAR;
                 VAR value: ARRAY OF CHAR; VAR logs: ARRAY OF CHAR;
                 VAR errorName: ARRAY OF CHAR; VAR errorMessage: ARRAY OF CHAR;
                 VAR errorData: ARRAY OF CHAR; VAR hasErrorData: BOOLEAN;
                 VAR ok: BOOLEAN; VAR transportError: ARRAY OF CHAR);
VAR
  endpoint: ARRAY [0..767] OF CHAR;
  payloadLength, i: INTEGER;
  httpOk: BOOLEAN;
  statusRaw, statusText: ARRAY [0..63] OF CHAR;
  found: BOOLEAN;
BEGIN
  value[0] := 0C; logs[0] := 0C; errorName[0] := 0C; errorMessage[0] := 0C; errorData[0] := 0C;
  hasErrorData := FALSE; ok := FALSE; transportError[0] := 0C;

  CopyText(deploymentUrl, endpoint);
  IF TextEqual(operation, "query") THEN
    AppendLit("/api/query", endpoint);
  ELSIF TextEqual(operation, "mutation") THEN
    AppendLit("/api/mutation", endpoint);
  ELSE
    AppendLit("/api/action", endpoint);
  END;

  CopyText('{"path":', CallPayload);
  IF NOT AppendQuoted(path, CallPayload) THEN
    CopyText("function path was too long", transportError);
    RETURN;
  END;
  AppendLit(',"args":', CallPayload);
  payloadLength := INTEGER(TextLength(CallPayload));
  FOR i := 0 TO INTEGER(TextLength(args)) - 1 DO
    CallPayload[payloadLength] := args[i];
    INC(payloadLength);
  END;
  CallPayload[payloadLength] := 0C;
  AppendLit(',"format":"json"}', CallPayload);

  Post(endpoint, CallPayload, authToken, 15000, CallBody, httpOk, transportError);
  IF NOT httpOk THEN RETURN END;

  IF NOT Member(CallBody, "status", statusRaw, found) OR NOT found THEN
    CopyText("HTTP response was not valid Convex JSON", transportError);
    RETURN;
  END;
  IF NOT DecodeString(statusRaw, statusText) THEN
    CopyText("HTTP response status was invalid", transportError);
    RETURN;
  END;

  IF Member(CallBody, "logLines", CallLogsRaw, found) AND found THEN
    IF NOT StringArrayValid(CallLogsRaw) THEN
      CopyText("HTTP logLines was not an array of strings", transportError);
      RETURN;
    END;
    CopyLargeText(CallLogsRaw, logs);
  ELSE
    CopyText("[]", logs);
  END;

  IF TextEqual(statusText, "success") THEN
    IF NOT Member(CallBody, "value", CallValueRaw, found) OR NOT found THEN
      CopyText("successful Convex response omitted value", transportError);
      RETURN;
    END;
    CopyLargeText(CallValueRaw, value);
    ok := TRUE;
    RETURN;
  END;

  IF TextEqual(statusText, "error") THEN
    IF Member(CallBody, "errorMessage", CallMsgRaw, found) AND found THEN
      IF NOT DecodeString(CallMsgRaw, errorMessage) THEN
        CopyText("HTTP errorMessage was not a JSON string", transportError);
        RETURN;
      END;
    ELSE
      CopyText("Convex function failed", errorMessage);
    END;
    hasErrorData := Member(CallBody, "errorData", CallDataRaw, found) AND found;
    IF hasErrorData THEN CopyLargeText(CallDataRaw, errorData) END;
    CopyText("FunctionError", errorName);
    ok := TRUE;
    RETURN;
  END;

  CopyText("HTTP response had an unknown Convex status", transportError);
END Call;

PROCEDURE Subscribe (path: ARRAY OF CHAR; VAR args: ARRAY OF CHAR;
                       VAR handle: INTEGER; VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
VAR slot: INTEGER;
BEGIN
  handle := -1;
  ok := FALSE;
  errorText[0] := 0C;
  IF INTEGER(TextLength(args)) >= MaxArgs THEN
    CopyText("Live arguments were too large", errorText);
    RETURN;
  END;
  slot := FreeSlot();
  IF slot < 0 THEN
    CopyText("Live subscription limit reached", errorText);
    RETURN;
  END;
  subs[slot].occupied := TRUE;
  subs[slot].active := TRUE;
  subs[slot].addPending := TRUE;
  subs[slot].removePending := FALSE;
  subs[slot].rehydrating := FALSE;
  subs[slot].hasLastValue := FALSE;
  subs[slot].valueTooLargeToCompare := FALSE;
  subs[slot].queryId := nextQueryId;
  INC(nextQueryId);
  CopyText(path, subs[slot].path);
  CopyText(args, subs[slot].args);
  handle := subs[slot].queryId;
  ok := TRUE;
END Subscribe;

PROCEDURE Unsubscribe (handle: INTEGER);
VAR slot: INTEGER;
BEGIN
  slot := FindSlot(handle);
  IF slot < 0 THEN RETURN END;
  DiscardEventsFor(handle);
  IF NOT connected THEN
    subs[slot].occupied := FALSE;
    RETURN;
  END;
  subs[slot].active := FALSE;
  subs[slot].removePending := TRUE;
END Unsubscribe;

PROCEDURE DebugDisconnect (VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
BEGIN
  errorText[0] := 0C;
  IF NOT connected THEN
    ok := FALSE;
    CopyText("Live WebSocket is not connected", errorText);
    RETURN;
  END;
  Close();
  RetireConnection("DebugDisconnect");
  CompleteDisconnectedRemoves();
  reconnectAt := ShimMonotonicMs();
  backoffMs := 100;
  ok := TRUE;
END DebugDisconnect;

PROCEDURE ConnectionCount () : INTEGER;
BEGIN
  RETURN connectionCount;
END ConnectionCount;

PROCEDURE LastCloseReason (VAR text: ARRAY OF CHAR);
BEGIN
  CopyText(lastCloseReasonText, text);
END LastCloseReason;

PROCEDURE MaxObservedTimestamp (VAR text: ARRAY OF CHAR);
BEGIN
  CopyText(maxObservedTs, text);
END MaxObservedTimestamp;

PROCEDURE IsConnected () : BOOLEAN;
BEGIN
  RETURN connected;
END IsConnected;

END ConvexSync.
