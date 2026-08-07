(* ConvexAdapter is the NDJSON adapter protocol v1 executable described in
   AGENTS.md: test infrastructure, not public client code. It speaks the
   shared controller's line protocol (one JSON command per input line, one
   JSON event per output line) and translates every command into a call
   against the real Modula-2 client (ConvexSync / ConvexWS / ConvexHTTP).
   It reserves stdout for protocol events; every diagnostic goes to
   stderr. It supports both stdin/stdout and, when ADAPTER_LISTEN is set,
   a single accepted TCP connection carrying the same NDJSON stream. *)

MODULE ConvexAdapter;

FROM SYSTEM IMPORT ADDRESS;
FROM CShim IMPORT
  ShimPlainWrap, ShimRead, ShimWrite, ShimFd, ShimPending, ShimCloseConn,
  ShimPoll2, ShimListen, ShimAccept, ShimCloseFd, ShimMonotonicMs,
  ShimLastError, ShimSetNonBlocking, ShimExit;
FROM ConvexJSON IMPORT Member, DecodeString, AppendQuoted, ParseNonNegativeInt;
FROM ConvexHTTP IMPORT MaxBody;
FROM ConvexWS IMPORT MaxMessage;
IMPORT ConvexSync;
FROM Environment IMPORT GetEnvironment;

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
  NilAddress = ADDRESS(0);
  CmdBufCap = 1048576; (* 1 MiB: generous for this adapter's own test commands *)
  MaxAdapterSubs = ConvexSync.MaxSubscriptions;
  RuntimeVersion = "GNU Modula-2 14.2.0";
  Implementation = "native";
  Language = "modula-2";

VAR
  readConn, writeConn: ADDRESS;
  readFd, writeFd, listenFd: INTEGER;
  usingTcp: BOOLEAN;

  (* inputAccum holds not-yet-processed bytes read from the command
     stream; cmdBuf holds exactly one extracted, NUL terminated command
     line while ProcessCommand and its handlers parse it. *)
  inputAccum: ARRAY [0..CmdBufCap - 1] OF CHAR;
  inputAccumLen: INTEGER;
  cmdBuf: ARRAY [0..CmdBufCap - 1] OF CHAR;

  outBuf: ARRAY [0..MaxMessage + 65536] OF CHAR;

  (* subscriptionId (adapter/protocol level) <-> ConvexSync handle mapping *)
  subIds: ARRAY [0..MaxAdapterSubs - 1] OF ARRAY [0..127] OF CHAR;
  subHandles: ARRAY [0..MaxAdapterSubs - 1] OF INTEGER;
  subOccupied: ARRAY [0..MaxAdapterSubs - 1] OF BOOLEAN;

  closing: BOOLEAN;
  exitCode: INTEGER;

  callValue, callLogs, callErrorMessage, callErrorData: ARRAY [0..MaxBody - 1] OF CHAR;
  liveValue, liveLogs, liveErrorName, liveErrorMessage, liveErrorData: ARRAY [0..ConvexSync.MaxValue - 1] OF CHAR;

(* ---------- tiny text helpers ---------- *)

PROCEDURE CopyText (source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := INTEGER(TextLength(source));
  IF n > INTEGER(HIGH(destination)) THEN n := INTEGER(HIGH(destination)) END;
  FOR i := 0 TO n - 1 DO destination[i] := source[i] END;
  destination[n] := 0C;
END CopyText;

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

PROCEDURE AppendBuf (text: ARRAY OF CHAR; VAR out: ARRAY OF CHAR; VAR outLength: INTEGER);
VAR n, j: INTEGER;
BEGIN
  n := INTEGER(TextLength(text));
  FOR j := 0 TO n - 1 DO out[outLength] := text[j]; INC(outLength) END;
END AppendBuf;

PROCEDURE AppendRaw (VAR source: ARRAY OF CHAR; VAR out: ARRAY OF CHAR; VAR outLength: INTEGER);
VAR n, j: INTEGER;
BEGIN
  n := INTEGER(TextLength(source));
  FOR j := 0 TO n - 1 DO out[outLength] := source[j]; INC(outLength) END;
END AppendRaw;

(* WriteStderrVar takes its text by VAR: gm2 copies a non-VAR ARRAY OF CHAR
   parameter onto the stack (see ConvexHTTP.mod's note on this), so any
   caller passing a large buffer (such as the megabyte-scale cmdBuf) must
   go through this entry point rather than the small-literal-friendly
   WriteStderr below. *)
PROCEDURE WriteStderrVar (VAR text: ARRAY OF CHAR);
VAR conn: ADDRESS; n: INTEGER; nl: ARRAY [0..0] OF CHAR;
BEGIN
  conn := ShimPlainWrap(2);
  n := ShimWrite(conn, text, INTEGER(TextLength(text)));
  nl[0] := CHR(10);
  n := ShimWrite(conn, nl, 1);
  (* stderr is diagnostics only; a failed write here is not fatal *)
END WriteStderrVar;

PROCEDURE WriteStderr (text: ARRAY OF CHAR);
BEGIN
  WriteStderrVar(text);
END WriteStderr;

(* ---------- bounded output ---------- *)

(* WriteLineBounded writes length bytes of out followed by a newline,
   resuming after short writes, and gives up after a fixed absolute
   deadline so a stalled or hostile controller can never hang the adapter
   forever (see AGENTS.md's bounded-write requirement). *)
PROCEDURE WriteLineBounded (VAR out: ARRAY OF CHAR; length: INTEGER) : BOOLEAN;
VAR
  sent, n, ready1, ready2: INTEGER;
  deadline, remaining: LONGINT;
  nl: ARRAY [0..0] OF CHAR;
BEGIN
  deadline := ShimMonotonicMs() + 3000;
  sent := 0;
  WHILE sent < length DO
    remaining := deadline - ShimMonotonicMs();
    IF remaining <= 0 THEN RETURN FALSE END;
    n := ShimWrite(writeConn, out, length); (* CShim writes from out[0]; caller ensures out[0] is next unsent byte *)
    IF n = -2 THEN RETURN FALSE
    ELSIF n = -1 THEN
      IF ShimPoll2(writeFd, -1, VAL(INTEGER, remaining), ready1, ready2) < 0 THEN RETURN FALSE END;
    ELSE
      INC(sent, n);
      IF sent < length THEN RETURN FALSE END; (* a genuine short write here would resend from out[0]; treat as fatal *)
    END;
  END;
  nl[0] := CHR(10);
  sent := 0;
  WHILE sent < 1 DO
    remaining := deadline - ShimMonotonicMs();
    IF remaining <= 0 THEN RETURN FALSE END;
    n := ShimWrite(writeConn, nl, 1);
    IF n = -2 THEN RETURN FALSE
    ELSIF n = -1 THEN
      IF ShimPoll2(writeFd, -1, VAL(INTEGER, remaining), ready1, ready2) < 0 THEN RETURN FALSE END;
    ELSE
      sent := n;
    END;
  END;
  RETURN TRUE;
END WriteLineBounded;

PROCEDURE EmitReady (id: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"id":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(id, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"implementation":"', outBuf, n);
  AppendBuf(Implementation, outBuf, n);
  AppendBuf('","language":"', outBuf, n);
  AppendBuf(Language, outBuf, n);
  AppendBuf('","protocolVersion":1,"runtime":"', outBuf, n);
  AppendBuf(RuntimeVersion, outBuf, n);
  AppendBuf('","type":"ready"}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitReady;

PROCEDURE EmitAck (id: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"id":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(id, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"type":"ack"}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitAck;

PROCEDURE EmitClosed (id: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"id":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(id, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"type":"closed"}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN exitCode := 1 END;
END EmitClosed;

PROCEDURE EmitErrorForId (id: ARRAY OF CHAR; name: ARRAY OF CHAR; message: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"error":{"message":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(message, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"name":"', outBuf, n);
  AppendBuf(name, outBuf, n);
  AppendBuf('"},"id":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(id, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"type":"error"}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitErrorForId;

PROCEDURE EmitFunctionErrorForId (id: ARRAY OF CHAR; name: ARRAY OF CHAR; VAR message: ARRAY OF CHAR;
                                  hasData: BOOLEAN; VAR data: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"error":{', outBuf, n);
  IF hasData THEN
    AppendBuf('"data":', outBuf, n);
    AppendRaw(data, outBuf, n);
    AppendBuf(',', outBuf, n);
  END;
  AppendBuf('"message":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(message, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"name":"', outBuf, n);
  AppendBuf(name, outBuf, n);
  AppendBuf('"},"id":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(id, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"type":"error"}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitFunctionErrorForId;

PROCEDURE EmitResult (id: ARRAY OF CHAR; VAR value: ARRAY OF CHAR; VAR logs: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"id":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(id, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"logs":', outBuf, n);
  AppendRaw(logs, outBuf, n);
  AppendBuf(',"type":"result","value":', outBuf, n);
  AppendRaw(value, outBuf, n);
  AppendBuf('}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitResult;

PROCEDURE EmitSubscriptionValue (subId: ARRAY OF CHAR; VAR value: ARRAY OF CHAR; VAR logs: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"logs":', outBuf, n);
  AppendRaw(logs, outBuf, n);
  AppendBuf(',"subscriptionId":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(subId, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"type":"subscription","value":', outBuf, n);
  AppendRaw(value, outBuf, n);
  AppendBuf('}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitSubscriptionValue;

PROCEDURE EmitSubscriptionError (subId: ARRAY OF CHAR; name: ARRAY OF CHAR; VAR message: ARRAY OF CHAR;
                                 hasData: BOOLEAN; VAR data: ARRAY OF CHAR; VAR logs: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := 0;
  AppendBuf('{"error":{', outBuf, n);
  IF hasData THEN
    AppendBuf('"data":', outBuf, n);
    AppendRaw(data, outBuf, n);
    AppendBuf(',', outBuf, n);
  END;
  AppendBuf('"message":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(message, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"name":"', outBuf, n);
  AppendBuf(name, outBuf, n);
  AppendBuf('"},"logs":', outBuf, n);
  AppendRaw(logs, outBuf, n);
  AppendBuf(',"subscriptionId":', outBuf, n);
  outBuf[n] := 0C;
  IF NOT AppendQuoted(subId, outBuf) THEN END;
  n := INTEGER(TextLength(outBuf));
  AppendBuf(',"type":"subscription"}', outBuf, n);
  IF NOT WriteLineBounded(outBuf, n) THEN closing := TRUE; exitCode := 1 END;
END EmitSubscriptionError;

(* ---------- subscription id <-> handle table ---------- *)

PROCEDURE FindSubBySubId (VAR subId: ARRAY OF CHAR) : INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxAdapterSubs - 1 DO
    IF subOccupied[i] AND TextEqual(subIds[i], subId) THEN RETURN i END;
  END;
  RETURN -1;
END FindSubBySubId;

PROCEDURE FindSubByHandle (handle: INTEGER) : INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxAdapterSubs - 1 DO
    IF subOccupied[i] AND (subHandles[i] = handle) THEN RETURN i END;
  END;
  RETURN -1;
END FindSubByHandle;

(* ---------- command dispatch ---------- *)

VAR
  cmdIdRaw, cmdId: ARRAY [0..511] OF CHAR;
  cmdOpRaw, cmdOp: ARRAY [0..63] OF CHAR;
  cmdPathRaw, cmdPath: ARRAY [0..511] OF CHAR;
  cmdSubIdRaw, cmdSubId: ARRAY [0..255] OF CHAR;
  cmdTokenRaw, cmdToken: ARRAY [0..2047] OF CHAR;
  cmdArgs: ARRAY [0..MaxBody - 1] OF CHAR;

PROCEDURE HandleCall;
VAR
  found, ok, hasErrorData: BOOLEAN;
  errorName: ARRAY [0..63] OF CHAR;
  transportError: ARRAY [0..255] OF CHAR;
BEGIN
  IF NOT Member(cmdBuf, "path", cmdPathRaw, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "command omitted path");
    RETURN;
  END;
  IF NOT DecodeString(cmdPathRaw, cmdPath) THEN
    EmitErrorForId(cmdId, "ProtocolError", "command path was invalid");
    RETURN;
  END;
  IF NOT Member(cmdBuf, "args", cmdArgs, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "command omitted args");
    RETURN;
  END;
  ConvexSync.Call(cmdOp, cmdPath, cmdArgs, callValue, callLogs,
                  errorName, callErrorMessage, callErrorData, hasErrorData,
                  ok, transportError);
  IF NOT ok THEN
    EmitErrorForId(cmdId, "TransportError", transportError);
    RETURN;
  END;
  IF INTEGER(TextLength(errorName)) > 0 THEN
    EmitFunctionErrorForId(cmdId, errorName, callErrorMessage, hasErrorData, callErrorData);
  ELSE
    EmitResult(cmdId, callValue, callLogs);
  END;
END HandleCall;

PROCEDURE HandleSubscribe;
VAR
  found, ok: BOOLEAN;
  handle, slot: INTEGER;
  errorText: ARRAY [0..255] OF CHAR;
BEGIN
  IF NOT Member(cmdBuf, "subscriptionId", cmdSubIdRaw, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "subscribe omitted subscriptionId");
    RETURN;
  END;
  IF NOT DecodeString(cmdSubIdRaw, cmdSubId) THEN
    EmitErrorForId(cmdId, "ProtocolError", "subscriptionId was invalid");
    RETURN;
  END;
  IF NOT Member(cmdBuf, "path", cmdPathRaw, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "subscribe omitted path");
    RETURN;
  END;
  IF NOT DecodeString(cmdPathRaw, cmdPath) THEN
    EmitErrorForId(cmdId, "ProtocolError", "subscribe path was invalid");
    RETURN;
  END;
  IF NOT Member(cmdBuf, "args", cmdArgs, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "subscribe omitted args");
    RETURN;
  END;

  slot := FindSubBySubId(cmdSubId);
  IF slot >= 0 THEN
    (* Same-ID replacement: invalidate the old relay before the new ack,
       per this project's ordering rule. *)
    ConvexSync.Unsubscribe(subHandles[slot]);
    subOccupied[slot] := FALSE;
  END;

  ConvexSync.Subscribe(cmdPath, cmdArgs, handle, ok, errorText);
  IF NOT ok THEN
    EmitErrorForId(cmdId, "ProtocolError", errorText);
    RETURN;
  END;

  slot := -1;
  FOR i := 0 TO MaxAdapterSubs - 1 DO
    IF (slot < 0) AND NOT subOccupied[i] THEN slot := i END;
  END;
  IF slot < 0 THEN
    ConvexSync.Unsubscribe(handle);
    EmitErrorForId(cmdId, "ProtocolError", "adapter subscription table is full");
    RETURN;
  END;
  subOccupied[slot] := TRUE;
  subHandles[slot] := handle;
  CopyText(cmdSubId, subIds[slot]);
  EmitAck(cmdId);
END HandleSubscribe;

PROCEDURE HandleUnsubscribe;
VAR found: BOOLEAN; slot: INTEGER;
BEGIN
  IF NOT Member(cmdBuf, "subscriptionId", cmdSubIdRaw, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "unsubscribe omitted subscriptionId");
    RETURN;
  END;
  IF NOT DecodeString(cmdSubIdRaw, cmdSubId) THEN
    EmitErrorForId(cmdId, "ProtocolError", "subscriptionId was invalid");
    RETURN;
  END;
  slot := FindSubBySubId(cmdSubId);
  IF slot >= 0 THEN
    ConvexSync.Unsubscribe(subHandles[slot]);
    subOccupied[slot] := FALSE;
  END;
  EmitAck(cmdId);
END HandleUnsubscribe;

PROCEDURE HandleSetAuth;
VAR found: BOOLEAN;
BEGIN
  IF NOT Member(cmdBuf, "token", cmdTokenRaw, found) OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "setAuth omitted token");
    RETURN;
  END;
  IF NOT DecodeString(cmdTokenRaw, cmdToken) THEN
    EmitErrorForId(cmdId, "ProtocolError", "token was invalid");
    RETURN;
  END;
  ConvexSync.SetAuth(cmdToken);
  EmitAck(cmdId);
END HandleSetAuth;

PROCEDURE HandleDebugDisconnect;
VAR ok: BOOLEAN; errorText: ARRAY [0..255] OF CHAR;
BEGIN
  ConvexSync.DebugDisconnect(ok, errorText);
  IF ok THEN EmitAck(cmdId) ELSE EmitErrorForId(cmdId, "TransportError", errorText) END;
END HandleDebugDisconnect;

PROCEDURE ProcessCommand;
VAR found, docOk: BOOLEAN;
BEGIN
  cmdId[0] := 0C;
  docOk := Member(cmdBuf, "id", cmdIdRaw, found);
  IF docOk AND found THEN
    IF NOT DecodeString(cmdIdRaw, cmdId) THEN CopyText("", cmdId) END;
  END;
  docOk := Member(cmdBuf, "op", cmdOpRaw, found);
  IF NOT docOk OR NOT found THEN
    EmitErrorForId(cmdId, "ProtocolError", "command omitted op");
    RETURN;
  END;
  IF NOT DecodeString(cmdOpRaw, cmdOp) THEN
    EmitErrorForId(cmdId, "ProtocolError", "command op was invalid");
    RETURN;
  END;

  IF TextEqual(cmdOp, "hello") THEN
    EmitReady(cmdId);
  ELSIF TextEqual(cmdOp, "setAuth") THEN
    HandleSetAuth;
  ELSIF TextEqual(cmdOp, "query") OR TextEqual(cmdOp, "mutation") OR TextEqual(cmdOp, "action") THEN
    HandleCall;
  ELSIF TextEqual(cmdOp, "subscribe") THEN
    HandleSubscribe;
  ELSIF TextEqual(cmdOp, "unsubscribe") THEN
    HandleUnsubscribe;
  ELSIF TextEqual(cmdOp, "debugDisconnect") THEN
    HandleDebugDisconnect;
  ELSIF TextEqual(cmdOp, "close") THEN
    EmitClosed(cmdId);
    closing := TRUE;
  ELSE
    EmitErrorForId(cmdId, "ProtocolError", "unknown op");
  END;
END ProcessCommand;

(* ---------- input reading ---------- *)

VAR inputChunk: ARRAY [0..65535] OF CHAR;

(* PumpInput performs one non-blocking attempt to read more bytes from the
   command stream into inputAccum. Returns FALSE if the stream is closed
   or errored (the caller then treats the adapter as done). *)
PROCEDURE PumpInput () : BOOLEAN;
VAR n, ready1, ready2, i, cap: INTEGER;
BEGIN
  IF ShimPending(readConn) = 0 THEN
    IF ShimPoll2(readFd, -1, 0, ready1, ready2) <= 0 THEN RETURN TRUE END;
  END;
  IF inputAccumLen >= CmdBufCap - 1 THEN
    WriteStderr("command line exceeded the adapter's input cap");
    RETURN FALSE;
  END;
  cap := CmdBufCap - 1 - inputAccumLen;
  IF cap > 65536 THEN cap := 65536 END;
  n := ShimRead(readConn, inputChunk, cap);
  IF n = -2 THEN RETURN FALSE
  ELSIF n = 0 THEN RETURN FALSE
  ELSIF n > 0 THEN
    FOR i := 0 TO n - 1 DO inputAccum[inputAccumLen + i] := inputChunk[i] END;
    INC(inputAccumLen, n);
  END;
  RETURN TRUE;
END PumpInput;

(* ExtractLine pulls one newline terminated line (a trailing CR is
   stripped) out of the front of inputAccum into cmdBuf, compacting the
   remainder forward. Returns FALSE when no complete line is buffered. *)
PROCEDURE ExtractLine () : BOOLEAN;
VAR i, lineLen, rest, j: INTEGER;
BEGIN
  i := 0;
  WHILE (i < inputAccumLen) AND (inputAccum[i] <> CHR(10)) DO INC(i) END;
  IF i >= inputAccumLen THEN RETURN FALSE END;
  lineLen := i;
  IF (lineLen > 0) AND (inputAccum[lineLen - 1] = CHR(13)) THEN DEC(lineLen) END;
  FOR j := 0 TO lineLen - 1 DO cmdBuf[j] := inputAccum[j] END;
  cmdBuf[lineLen] := 0C;
  rest := inputAccumLen - (i + 1);
  FOR j := 0 TO rest - 1 DO inputAccum[j] := inputAccum[i + 1 + j] END;
  inputAccumLen := rest;
  RETURN TRUE;
END ExtractLine;

(* ---------- Live event delivery ---------- *)

PROCEDURE PumpLive;
VAR
  eventKind, handle, slot: INTEGER;
  hasErrorData: BOOLEAN;
BEGIN
  ConvexSync.Pump(20, eventKind, handle, liveValue, liveLogs, liveErrorName, liveErrorMessage, liveErrorData, hasErrorData);
  IF eventKind = 0 THEN RETURN END;
  slot := FindSubByHandle(handle);
  IF slot < 0 THEN RETURN END; (* already unsubscribed locally; drop *)
  IF eventKind = 1 THEN
    EmitSubscriptionValue(subIds[slot], liveValue, liveLogs);
  ELSE
    EmitSubscriptionError(subIds[slot], liveErrorName, liveErrorMessage, hasErrorData, liveErrorData, liveLogs);
  END;
END PumpLive;

(* ---------- program body ---------- *)

VAR
  listenAddress: ARRAY [0..63] OF CHAR;
  haveListen: BOOLEAN;
  deploymentUrl, authToken: ARRAY [0..511] OF CHAR;
  haveUrl: BOOLEAN;
  i: INTEGER;

BEGIN
  closing := FALSE;
  exitCode := 0;
  inputAccumLen := 0;
  FOR i := 0 TO MaxAdapterSubs - 1 DO subOccupied[i] := FALSE END;

  haveListen := GetEnvironment("ADAPTER_LISTEN", listenAddress);
  IF haveListen THEN
    usingTcp := TRUE;
    listenFd := ShimListen("0.0.0.0", 8080);
    IF listenFd < 0 THEN
      WriteStderr("failed to listen on 0.0.0.0:8080");
      ShimExit(1);
    END;
    readFd := ShimAccept(listenFd, 30000);
    IF readFd < 0 THEN
      WriteStderr("timed out waiting for the controller to connect");
      ShimExit(1);
    END;
    writeFd := readFd;
    readConn := ShimPlainWrap(readFd);
    writeConn := readConn;
  ELSE
    usingTcp := FALSE;
    readFd := 0;
    writeFd := 1;
    readConn := ShimPlainWrap(0);
    writeConn := ShimPlainWrap(1);
  END;

  haveUrl := GetEnvironment("CONVEX_URL", deploymentUrl);
  IF NOT haveUrl THEN
    CopyText("http://127.0.0.1:9", deploymentUrl);
  END;
  authToken[0] := 0C;
  ConvexSync.Init(deploymentUrl, authToken);

  WHILE NOT closing DO
    WHILE (NOT closing) AND ExtractLine() DO
      ProcessCommand;
    END;
    IF NOT closing THEN
      IF NOT PumpInput() THEN
        WriteStderr("command stream closed unexpectedly");
        closing := TRUE;
        exitCode := 1;
      END;
    END;
    IF NOT closing THEN PumpLive END;
  END;

  ShimCloseConn(readConn);
  IF usingTcp THEN
    ShimCloseFd(listenFd);
  ELSE
    ShimCloseConn(writeConn);
  END;
  ShimExit(exitCode);
END ConvexAdapter.
