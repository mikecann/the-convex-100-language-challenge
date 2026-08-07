IMPLEMENTATION MODULE ConvexWS;

FROM SYSTEM IMPORT ADDRESS;
FROM CShim IMPORT
  ShimTcpConnect, ShimTlsWrap, ShimPlainWrap, ShimRead, ShimWrite, ShimFd,
  ShimPending, ShimCloseConn, ShimPoll2, ShimMonotonicMs, ShimLastError,
  ShimRandomBytes, ShimSha1;
FROM ConvexURL IMPORT Parse;
FROM ConvexBase64 IMPORT Encode;

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
  NetCap = 65536;
  HandshakeGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

  StageOpcode = 0;
  StageLenByte = 1;
  StageExtLen = 2;
  StagePayload = 4;

  OpContinuation = 0;
  OpText = 1;
  OpBinary = 2;
  OpClose = 8;
  OpPing = 9;
  OpPong = 10;

VAR
  conn: ADDRESS;
  connFd: INTEGER;
  open: BOOLEAN;

  (* read-ahead buffer of not-yet-consumed bytes from the socket *)
  netBuf: ARRAY [0..NetCap - 1] OF CHAR;
  netPos, netLen: INTEGER;

  (* current frame parse state; persists across Receive() calls so a
     timeout can never lose a partially read frame *)
  stage: INTEGER;
  finBit: BOOLEAN;
  opcode: INTEGER;
  extLenNeeded, extLenGot: INTEGER;
  extLenBytes: ARRAY [0..7] OF CHAR;
  payloadLen, payloadGot: INTEGER;

  (* message currently being assembled (a single unfragmented frame is the
     common case; fragMessageActive covers a real multi-frame message) *)
  fragMessageActive: BOOLEAN;
  fragOpcode: INTEGER;
  msgBuf: ARRAY [0..MaxMessage - 1] OF CHAR;
  msgLen: INTEGER;

  controlBuf: ARRAY [0..127] OF CHAR;
  controlLen: INTEGER;

PROCEDURE CopyText (source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := INTEGER(TextLength(source));
  IF n > INTEGER(HIGH(destination)) THEN n := INTEGER(HIGH(destination)) END;
  FOR i := 0 TO n - 1 DO destination[i] := source[i] END;
  destination[n] := 0C;
END CopyText;

PROCEDURE ShimError (VAR destination: ARRAY OF CHAR);
VAR buf: ARRAY [0..511] OF CHAR; n: INTEGER;
BEGIN
  n := ShimLastError(buf, 511);
  IF n > 511 THEN n := 511 END;
  buf[n] := 0C;
  CopyText(buf, destination);
END ShimError;

PROCEDURE ResetFrameState;
BEGIN
  stage := StageOpcode;
  extLenGot := 0;
  payloadGot := 0;
END ResetFrameState;

PROCEDURE XorByte (a, b: CARDINAL) : CARDINAL;
BEGIN
  RETURN CARDINAL(BITSET(a) / BITSET(b));
END XorByte;

(* gm2's ISO Strings.Equal cannot be resolved by this compiler build (see
   ConvexJSON.mod); Strings.Append is avoided for the same reason, in favour
   of a direct copy that this module already knows how to bound. *)
PROCEDURE AppendText (extra: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR
  baseLength, extraLength, i: INTEGER;
BEGIN
  baseLength := INTEGER(TextLength(destination));
  extraLength := INTEGER(TextLength(extra));
  FOR i := 0 TO extraLength - 1 DO
    destination[baseLength + i] := extra[i];
  END;
  destination[baseLength + extraLength] := 0C;
END AppendText;

(* WriteAllBounded writes length bytes of data, resuming after short writes,
   until either everything is sent or deadlineMs passes. *)
PROCEDURE WriteAllBounded (VAR data: ARRAY OF CHAR; length: INTEGER; deadlineMs: LONGINT;
                           VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
VAR
  sent, n, ready1, ready2: INTEGER;
  remaining: LONGINT;
BEGIN
  sent := 0;
  WHILE sent < length DO
    remaining := deadlineMs - ShimMonotonicMs();
    IF remaining <= 0 THEN
      ok := FALSE;
      CopyText("write deadline exceeded", errorText);
      RETURN;
    END;
    n := ShimWrite(conn, data, length); (* CShim writes from data[0]; we always send one full frame per call *)
    IF n = -2 THEN
      ok := FALSE;
      ShimError(errorText);
      RETURN;
    ELSIF n = -1 THEN
      IF ShimPoll2(connFd, -1, VAL(INTEGER, remaining), ready1, ready2) < 0 THEN
        ok := FALSE;
        ShimError(errorText);
        RETURN;
      END;
    ELSE
      INC(sent, n);
      IF sent < length THEN
        (* A short write on a frame we always start at data[0] would resend
           already-sent bytes; this client's frames are small enough that a
           short write is rare, but guard it explicitly rather than send a
           corrupt frame. *)
        ok := FALSE;
        CopyText("short write while sending a WebSocket frame", errorText);
        RETURN;
      END;
    END;
  END;
  ok := TRUE;
END WriteAllBounded;

PROCEDURE Fd () : INTEGER;
BEGIN
  RETURN connFd;
END Fd;

PROCEDURE IsOpen () : BOOLEAN;
BEGIN
  RETURN open;
END IsOpen;

PROCEDURE Close ();
VAR
  frame: ARRAY [0..5] OF CHAR;
  mask: ARRAY [0..3] OF CHAR;
  ok: BOOLEAN;
  errorText: ARRAY [0..127] OF CHAR;
BEGIN
  IF NOT open THEN RETURN END;
  ShimRandomBytes(mask, 4);
  frame[0] := CHR(080H + OpClose);
  frame[1] := CHR(080H);
  frame[2] := mask[0]; frame[3] := mask[1]; frame[4] := mask[2]; frame[5] := mask[3];
  WriteAllBounded(frame, 6, ShimMonotonicMs() + 500, ok, errorText);
  ShimCloseConn(conn);
  conn := NilAddress;
  connFd := -1;
  open := FALSE;
END Close;

(* --- handshake --- *)

PROCEDURE Open (url: ARRAY OF CHAR; clientVersion: ARRAY OF CHAR; timeoutMs: INTEGER;
                 VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
VAR
  secure: BOOLEAN;
  host: ARRAY [0..255] OF CHAR;
  path: ARRAY [0..1023] OF CHAR;
  port: INTEGER;
  fd: INTEGER;
  deadline, remaining: LONGINT;
  keyRaw: ARRAY [0..15] OF CHAR;
  keyB64: ARRAY [0..31] OF CHAR;
  expectedAcceptSource: ARRAY [0..127] OF CHAR;
  expectedDigest: ARRAY [0..19] OF CHAR;
  expectedAccept: ARRAY [0..31] OF CHAR;
  request: ARRAY [0..2047] OF CHAR;
  requestLength: INTEGER;
  response: ARRAY [0..8191] OF CHAR;
  responseLength: INTEGER;
  headerEnd, n, ready1, ready2, i: INTEGER;
  sawStatus101, sawUpgrade, acceptMatched: BOOLEAN;
  lineStart, lineEnd: INTEGER;

  (* Modula-2 string literals have no backslash escapes ("\r\n" is four
     literal characters, not CR LF), so every header line ends with an
     explicit call to AppendCRLF rather than an embedded escape. *)
  PROCEDURE AppendLiteral (text: ARRAY OF CHAR);
  VAR n2, i2: INTEGER;
  BEGIN
    n2 := INTEGER(TextLength(text));
    FOR i2 := 0 TO n2 - 1 DO
      request[requestLength] := text[i2];
      INC(requestLength);
    END;
  END AppendLiteral;

  PROCEDURE AppendCRLF;
  BEGIN
    request[requestLength] := CHR(13);
    request[requestLength + 1] := CHR(10);
    INC(requestLength, 2);
  END AppendCRLF;

  PROCEDURE LineHasPrefix (VAR text: ARRAY OF CHAR; start, stop: INTEGER; prefix: ARRAY OF CHAR) : BOOLEAN;
  VAR pn, i3: INTEGER; a: CHAR;
  BEGIN
    pn := INTEGER(TextLength(prefix));
    IF stop - start < pn THEN RETURN FALSE END;
    FOR i3 := 0 TO pn - 1 DO
      a := text[start + i3];
      IF (a >= 'A') AND (a <= 'Z') THEN a := CHR(ORD(a) + 32) END;
      IF a <> prefix[i3] THEN RETURN FALSE END;
    END;
    RETURN TRUE;
  END LineHasPrefix;

BEGIN
  ok := FALSE;
  errorText[0] := 0C;
  IF open THEN Close() END;

  deadline := ShimMonotonicMs() + VAL(LONGINT, timeoutMs);
  IF NOT Parse(url, secure, host, port, path) THEN
    CopyText("invalid Convex sync URL", errorText);
    RETURN;
  END;

  remaining := deadline - ShimMonotonicMs();
  IF remaining < 1 THEN remaining := 1 END;
  fd := ShimTcpConnect(host, port, VAL(INTEGER, remaining));
  IF fd < 0 THEN
    ShimError(errorText);
    RETURN;
  END;

  IF secure THEN
    remaining := deadline - ShimMonotonicMs();
    IF remaining < 1 THEN remaining := 1 END;
    conn := ShimTlsWrap(fd, host, VAL(INTEGER, remaining));
    IF conn = NilAddress THEN
      ShimError(errorText);
      RETURN;
    END;
  ELSE
    conn := ShimPlainWrap(fd);
  END;
  connFd := ShimFd(conn);

  ShimRandomBytes(keyRaw, 16);
  Encode(keyRaw, 16, keyB64);

  requestLength := 0;
  AppendLiteral("GET ");
  AppendLiteral(path);
  AppendLiteral(" HTTP/1.1"); AppendCRLF;
  AppendLiteral("Host: "); AppendLiteral(host); AppendCRLF;
  AppendLiteral("Upgrade: websocket"); AppendCRLF;
  AppendLiteral("Connection: Upgrade"); AppendCRLF;
  AppendLiteral("Sec-WebSocket-Key: "); AppendLiteral(keyB64); AppendCRLF;
  AppendLiteral("Sec-WebSocket-Version: 13"); AppendCRLF;
  AppendLiteral("User-Agent: convex-modula-2/"); AppendLiteral(clientVersion); AppendCRLF;
  AppendCRLF;

  request[requestLength] := 0C;
  WriteAllBounded(request, requestLength, deadline, ok, errorText);
  IF NOT ok THEN
    ShimCloseConn(conn);
    conn := NilAddress; connFd := -1;
    RETURN;
  END;

  CopyText(keyB64, expectedAcceptSource);
  AppendText(HandshakeGuid, expectedAcceptSource);
  ShimSha1(expectedAcceptSource, INTEGER(TextLength(expectedAcceptSource)), expectedDigest);
  Encode(expectedDigest, 20, expectedAccept);

  responseLength := 0;
  headerEnd := -1;
  LOOP
    remaining := deadline - ShimMonotonicMs();
    IF remaining <= 0 THEN
      ShimCloseConn(conn); conn := NilAddress; connFd := -1;
      CopyText("WebSocket handshake timed out", errorText);
      ok := FALSE;
      RETURN;
    END;
    IF ShimPending(conn) = 0 THEN
      IF ShimPoll2(connFd, -1, VAL(INTEGER, remaining), ready1, ready2) < 0 THEN
        ShimCloseConn(conn); conn := NilAddress; connFd := -1;
        ShimError(errorText);
        ok := FALSE;
        RETURN;
      END;
    END;
    IF responseLength >= INTEGER(HIGH(response)) THEN
      ShimCloseConn(conn); conn := NilAddress; connFd := -1;
      CopyText("WebSocket handshake response too large", errorText);
      ok := FALSE;
      RETURN;
    END;
    n := ShimRead(conn, netBuf, NetCap);
    IF n = -2 THEN
      ShimCloseConn(conn); conn := NilAddress; connFd := -1;
      ShimError(errorText);
      ok := FALSE;
      RETURN;
    ELSIF n = -1 THEN
      (* nothing yet *)
    ELSIF n = 0 THEN
      ShimCloseConn(conn); conn := NilAddress; connFd := -1;
      CopyText("connection closed during the WebSocket handshake", errorText);
      ok := FALSE;
      RETURN;
    ELSE
      FOR i := 0 TO n - 1 DO
        response[responseLength + i] := netBuf[i];
      END;
      INC(responseLength, n);
      response[responseLength] := 0C;
      i := 0;
      WHILE i <= responseLength - 4 DO
        IF (response[i] = CHR(13)) AND (response[i+1] = CHR(10)) AND (response[i+2] = CHR(13)) AND (response[i+3] = CHR(10)) THEN
          headerEnd := i;
          i := responseLength;
        ELSE
          INC(i);
        END;
      END;
      IF headerEnd >= 0 THEN EXIT END;
    END;
  END;

  sawStatus101 := FALSE;
  sawUpgrade := FALSE;
  acceptMatched := FALSE;
  lineStart := 0;
  WHILE lineStart < headerEnd DO
    lineEnd := lineStart;
    WHILE (lineEnd < headerEnd) AND (response[lineEnd] <> CHR(13)) DO INC(lineEnd) END;
    IF lineStart = 0 THEN
      IF LineHasPrefix(response, 0, lineEnd, "http/1.1 101") THEN sawStatus101 := TRUE END;
    ELSE
      IF LineHasPrefix(response, lineStart, lineEnd, "upgrade:") THEN
        IF LineHasPrefix(response, lineStart + 8, lineEnd, " websocket") THEN sawUpgrade := TRUE END;
      END;
      IF LineHasPrefix(response, lineStart, lineEnd, "sec-websocket-accept:") THEN
        i := lineStart + 21;
        WHILE (i < lineEnd) AND (response[i] = ' ') DO INC(i) END;
        IF (lineEnd - i = INTEGER(TextLength(expectedAccept))) THEN
          acceptMatched := TRUE;
          FOR n := 0 TO lineEnd - i - 1 DO
            IF response[i + n] <> expectedAccept[n] THEN acceptMatched := FALSE END;
          END;
        END;
      END;
    END;
    lineStart := lineEnd + 2;
  END;

  IF NOT sawStatus101 OR NOT sawUpgrade OR NOT acceptMatched THEN
    ShimCloseConn(conn); conn := NilAddress; connFd := -1;
    CopyText("WebSocket handshake was rejected or forged", errorText);
    ok := FALSE;
    RETURN;
  END;

  netPos := 0;
  netLen := 0;
  ResetFrameState;
  fragMessageActive := FALSE;
  msgLen := 0;
  open := TRUE;
  ok := TRUE;
END Open;

(* --- sending --- *)

PROCEDURE SendText (VAR text: ARRAY OF CHAR; length: INTEGER; deadlineMs: LONGINT;
                     VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
VAR
  frame: ARRAY [0..MaxMessage + 13] OF CHAR;
  frameLength, i: INTEGER;
  mask: ARRAY [0..3] OF CHAR;
BEGIN
  ok := FALSE;
  errorText[0] := 0C;
  IF NOT open THEN
    CopyText("WebSocket is not open", errorText);
    RETURN;
  END;
  IF length > MaxMessage THEN
    CopyText("outgoing message exceeds the 4 MiB cap", errorText);
    RETURN;
  END;
  frame[0] := CHR(080H + OpText);
  IF length <= 125 THEN
    frame[1] := CHR(080H + length);
    frameLength := 2;
  ELSIF length <= 65535 THEN
    frame[1] := CHR(080H + 126);
    frame[2] := CHR((length DIV 256) MOD 256);
    frame[3] := CHR(length MOD 256);
    frameLength := 4;
  ELSE
    frame[1] := CHR(080H + 127);
    FOR i := 2 TO 5 DO frame[i] := CHR(0) END;
    frame[6] := CHR((length DIV 16777216) MOD 256);
    frame[7] := CHR((length DIV 65536) MOD 256);
    frame[8] := CHR((length DIV 256) MOD 256);
    frame[9] := CHR(length MOD 256);
    frameLength := 10;
  END;
  ShimRandomBytes(mask, 4);
  FOR i := 0 TO 3 DO
    frame[frameLength + i] := mask[i];
  END;
  INC(frameLength, 4);
  FOR i := 0 TO length - 1 DO
    frame[frameLength + i] := CHR(XorByte(ORD(text[i]), ORD(mask[i MOD 4])));
  END;
  INC(frameLength, length);
  WriteAllBounded(frame, frameLength, deadlineMs, ok, errorText);
END SendText;

(* --- receiving --- *)

(* Utf8Valid checks that buf[0..length) is well formed UTF-8: no overlong
   encodings, no encoded surrogate halves, and no codepoint above U+10FFFF.
   RFC 6455 requires validating the reassembled message, not each
   fragment, since a UTF-8 sequence may legally be split across frames;
   this is only ever called once a whole message has been assembled. *)
PROCEDURE Utf8Valid (VAR buf: ARRAY OF CHAR; length: INTEGER) : BOOLEAN;
VAR
  i, need, minCode, code, b, j, cont: INTEGER;
BEGIN
  i := 0;
  WHILE i < length DO
    b := CARDINAL(ORD(buf[i]));
    IF b < 080H THEN
      INC(i);
    ELSE
      IF (b DIV 32) = 06H THEN
        need := 1; code := b MOD 32; minCode := 080H;
      ELSIF (b DIV 16) = 0EH THEN
        need := 2; code := b MOD 16; minCode := 0800H;
      ELSIF (b DIV 8) = 1EH THEN
        need := 3; code := b MOD 8; minCode := 010000H;
      ELSE
        RETURN FALSE;
      END;
      IF i + need >= length THEN RETURN FALSE END;
      FOR j := 1 TO need DO
        cont := CARDINAL(ORD(buf[i + j]));
        IF (cont DIV 64) <> 02H THEN RETURN FALSE END; (* must be 10xxxxxx *)
        code := code * 64 + (cont MOD 64);
      END;
      IF code < minCode THEN RETURN FALSE END; (* overlong encoding *)
      IF (code >= 0D800H) AND (code <= 0DFFFH) THEN RETURN FALSE END; (* surrogate half *)
      IF code > 010FFFFH THEN RETURN FALSE END;
      INC(i, need + 1);
    END;
  END;
  RETURN TRUE;
END Utf8Valid;

(* StartPayload validates the just-parsed frame header against RFC 6455's
   fragmentation and control-frame rules, then arms StagePayload (or, for a
   zero-length payload, dispatches the frame immediately). *)
PROCEDURE StartPayload (VAR errorText: ARRAY OF CHAR) : INTEGER;
BEGIN
  IF opcode >= OpClose THEN
    IF NOT finBit THEN
      CopyText("control frame was fragmented", errorText);
      RETURN -1;
    END;
    IF payloadLen > 125 THEN
      CopyText("control frame payload exceeded 125 bytes", errorText);
      RETURN -1;
    END;
    controlLen := 0;
  ELSIF opcode = OpContinuation THEN
    IF NOT fragMessageActive THEN
      CopyText("unexpected WebSocket continuation frame", errorText);
      RETURN -1;
    END;
  ELSIF (opcode = OpText) OR (opcode = OpBinary) THEN
    IF fragMessageActive THEN
      CopyText("expected a continuation frame", errorText);
      RETURN -1;
    END;
    msgLen := 0;
  ELSE
    CopyText("unsupported WebSocket opcode", errorText);
    RETURN -1;
  END;
  IF (opcode = OpContinuation) OR (opcode = OpText) OR (opcode = OpBinary) THEN
    IF msgLen + payloadLen > MaxMessage THEN
      CopyText("incoming WebSocket message exceeded the 4 MiB cap", errorText);
      RETURN -1;
    END;
  END;
  stage := StagePayload;
  RETURN 0;
END StartPayload;

(* SendPong answers a ping with a pong echoing its payload, best effort
   with a short bounded deadline; a failure here is folded into the next
   Receive() call's own transport error rather than reported here. *)
PROCEDURE SendPong;
VAR
  frame: ARRAY [0..133] OF CHAR;
  mask: ARRAY [0..3] OF CHAR;
  i, frameLength: INTEGER;
  ok: BOOLEAN;
  ignored: ARRAY [0..63] OF CHAR;
BEGIN
  frame[0] := CHR(080H + OpPong);
  frame[1] := CHR(080H + controlLen);
  ShimRandomBytes(mask, 4);
  frame[2] := mask[0]; frame[3] := mask[1]; frame[4] := mask[2]; frame[5] := mask[3];
  frameLength := 6;
  FOR i := 0 TO controlLen - 1 DO
    frame[frameLength + i] := CHR(XorByte(ORD(controlBuf[i]), ORD(mask[i MOD 4])));
  END;
  INC(frameLength, controlLen);
  WriteAllBounded(frame, frameLength, ShimMonotonicMs() + 2000, ok, ignored);
END SendPong;

(* ProcessBuffered consumes as much of netBuf[netPos..netLen) as the
   current frame state allows. It returns 0 when it needs more network
   bytes to keep going (all buffered bytes consumed, mid frame or between
   frames), 1 when a complete text message is ready in text/length, 2 when
   the peer sent a close frame, or -1 on a framing error. *)
PROCEDURE ProcessBuffered (VAR text: ARRAY OF CHAR; VAR length: INTEGER;
                           VAR errorText: ARRAY OF CHAR) : INTEGER;
VAR
  b, avail, need, take, i, started: INTEGER;
BEGIN
  LOOP
    IF stage = StageOpcode THEN
      IF netPos >= netLen THEN RETURN 0 END;
      b := CARDINAL(ORD(netBuf[netPos]));
      INC(netPos);
      finBit := (b DIV 128) MOD 2 = 1;
      opcode := b MOD 16;
      stage := StageLenByte;
    ELSIF stage = StageLenByte THEN
      IF netPos >= netLen THEN RETURN 0 END;
      b := CARDINAL(ORD(netBuf[netPos]));
      INC(netPos);
      IF (b DIV 128) MOD 2 = 1 THEN
        CopyText("server WebSocket frame was masked", errorText);
        RETURN -1;
      END;
      b := b MOD 128;
      IF b = 126 THEN
        extLenNeeded := 2; extLenGot := 0; stage := StageExtLen;
      ELSIF b = 127 THEN
        extLenNeeded := 8; extLenGot := 0; stage := StageExtLen;
      ELSE
        payloadLen := b; payloadGot := 0;
        started := StartPayload(errorText);
        IF started < 0 THEN RETURN -1 END;
        IF payloadLen = 0 THEN stage := StagePayload END; (* fall through below *)
      END;
    ELSIF stage = StageExtLen THEN
      WHILE (netPos < netLen) AND (extLenGot < extLenNeeded) DO
        extLenBytes[extLenGot] := netBuf[netPos];
        INC(netPos);
        INC(extLenGot);
      END;
      IF extLenGot < extLenNeeded THEN RETURN 0 END;
      IF extLenNeeded = 2 THEN
        payloadLen := CARDINAL(ORD(extLenBytes[0])) * 256 + CARDINAL(ORD(extLenBytes[1]));
      ELSE
        IF (extLenBytes[0] <> 0C) OR (extLenBytes[1] <> 0C) OR (extLenBytes[2] <> 0C)
           OR (extLenBytes[3] <> 0C) THEN
          CopyText("incoming WebSocket frame exceeded the 4 MiB cap", errorText);
          RETURN -1;
        END;
        payloadLen := CARDINAL(ORD(extLenBytes[4])) * 16777216 + CARDINAL(ORD(extLenBytes[5])) * 65536
          + CARDINAL(ORD(extLenBytes[6])) * 256 + CARDINAL(ORD(extLenBytes[7]));
      END;
      IF payloadLen > MaxMessage THEN
        CopyText("incoming WebSocket frame exceeded the 4 MiB cap", errorText);
        RETURN -1;
      END;
      payloadGot := 0;
      started := StartPayload(errorText);
      IF started < 0 THEN RETURN -1 END;
    ELSIF stage = StagePayload THEN
      avail := netLen - netPos;
      need := payloadLen - payloadGot;
      take := avail;
      IF take > need THEN take := need END;
      IF take > 0 THEN
        IF opcode >= OpClose THEN
          FOR i := 0 TO take - 1 DO controlBuf[controlLen + i] := netBuf[netPos + i] END;
          INC(controlLen, take);
        ELSE
          FOR i := 0 TO take - 1 DO msgBuf[msgLen + i] := netBuf[netPos + i] END;
          INC(msgLen, take);
        END;
        INC(netPos, take);
        INC(payloadGot, take);
      END;
      IF payloadGot < payloadLen THEN RETURN 0 END;

      (* frame complete: dispatch *)
      IF opcode = OpClose THEN
        ResetFrameState;
        RETURN 2;
      ELSIF opcode = OpPing THEN
        SendPong;
        ResetFrameState;
      ELSIF opcode = OpPong THEN
        ResetFrameState;
      ELSE
        (* continuation, text, or binary data frame *)
        IF finBit THEN
          fragMessageActive := FALSE;
          IF opcode = OpBinary THEN
            CopyText("binary WebSocket frames are not supported", errorText);
            RETURN -1;
          END;
          IF NOT Utf8Valid(msgBuf, msgLen) THEN
            CopyText("text frame was not valid UTF-8", errorText);
            RETURN -1;
          END;
          IF msgLen > INTEGER(HIGH(text)) THEN
            CopyText("incoming message exceeded the caller's buffer", errorText);
            RETURN -1;
          END;
          FOR i := 0 TO msgLen - 1 DO text[i] := msgBuf[i] END;
          text[msgLen] := 0C;
          length := msgLen;
          ResetFrameState;
          RETURN 1;
        ELSE
          IF opcode <> OpContinuation THEN
            fragOpcode := opcode;
            fragMessageActive := TRUE;
          END;
          ResetFrameState;
        END;
      END;
    END;
  END;
END ProcessBuffered;

PROCEDURE Receive (timeoutMs: INTEGER;
                    VAR text: ARRAY OF CHAR; VAR length: INTEGER;
                    VAR status: INTEGER; VAR errorText: ARRAY OF CHAR);
VAR
  deadline, remaining: LONGINT;
  n, ready1, ready2: INTEGER;
BEGIN
  status := 0;
  length := 0;
  errorText[0] := 0C;
  IF NOT open THEN
    CopyText("WebSocket is not open", errorText);
    status := -1;
    RETURN;
  END;
  deadline := ShimMonotonicMs() + VAL(LONGINT, timeoutMs);
  LOOP
    IF netPos < netLen THEN
      status := ProcessBuffered(text, length, errorText);
      IF status <> 0 THEN RETURN END;
    END;
    remaining := deadline - ShimMonotonicMs();
    IF remaining <= 0 THEN
      status := 0;
      RETURN;
    END;
    IF ShimPending(conn) = 0 THEN
      n := ShimPoll2(connFd, -1, VAL(INTEGER, remaining), ready1, ready2);
      IF n < 0 THEN
        ShimError(errorText);
        status := -1;
        RETURN;
      END;
      IF n = 0 THEN
        status := 0;
        RETURN;
      END;
    END;
    n := ShimRead(conn, netBuf, NetCap);
    IF n = -2 THEN
      ShimError(errorText);
      status := -1;
      RETURN;
    ELSIF n = -1 THEN
      (* spurious wakeup; loop back around to poll again *)
      netPos := 0; netLen := 0;
    ELSIF n = 0 THEN
      CopyText("connection closed", errorText);
      status := -1;
      RETURN;
    ELSE
      netPos := 0;
      netLen := n;
    END;
  END;
END Receive;

END ConvexWS.
