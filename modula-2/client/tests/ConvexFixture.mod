IMPLEMENTATION MODULE ConvexFixture;

FROM SYSTEM IMPORT ADDRESS;
FROM CShim IMPORT
  ShimListen, ShimAccept, ShimPlainWrap, ShimRead, ShimWrite, ShimFd,
  ShimCloseConn, ShimCloseFd, ShimPoll2, ShimMonotonicMs, ShimSha1;
FROM ConvexBase64 IMPORT Encode;

CONST
  NilAddress = ADDRESS(0);
  HandshakeGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

PROCEDURE TextLength (VAR s: ARRAY OF CHAR) : INTEGER;
VAR i, cap: INTEGER;
BEGIN
  cap := INTEGER(HIGH(s));
  i := 0;
  WHILE (i <= cap) AND (s[i] <> 0C) DO INC(i) END;
  RETURN i;
END TextLength;

VAR
  listenFd: INTEGER;
  conn: ADDRESS;
  connFd: INTEGER;

PROCEDURE AppendBuf (text: ARRAY OF CHAR; VAR out: ARRAY OF CHAR; VAR outLength: INTEGER);
VAR n, j: INTEGER;
BEGIN
  n := TextLength(text);
  FOR j := 0 TO n - 1 DO out[outLength] := text[j]; INC(outLength) END;
END AppendBuf;

PROCEDURE XorByte (a, b: CARDINAL) : CARDINAL;
BEGIN
  RETURN CARDINAL(BITSET(a) / BITSET(b));
END XorByte;

PROCEDURE Listen (bindAddress: ARRAY OF CHAR; port: INTEGER) : BOOLEAN;
BEGIN
  listenFd := ShimListen(bindAddress, port);
  RETURN listenFd >= 0;
END Listen;

PROCEDURE StopListening;
BEGIN
  IF listenFd >= 0 THEN ShimCloseFd(listenFd) END;
  listenFd := -1;
END StopListening;

PROCEDURE WriteAllBounded (VAR data: ARRAY OF CHAR; length: INTEGER; deadlineMs: LONGINT) : BOOLEAN;
VAR sent, n, ready1, ready2: INTEGER; remaining: LONGINT;
BEGIN
  sent := 0;
  WHILE sent < length DO
    remaining := deadlineMs - ShimMonotonicMs();
    IF remaining <= 0 THEN RETURN FALSE END;
    n := ShimWrite(conn, data, length);
    IF n = -2 THEN RETURN FALSE
    ELSIF n = -1 THEN
      IF ShimPoll2(connFd, -1, VAL(INTEGER, remaining), ready1, ready2) < 0 THEN RETURN FALSE END;
    ELSE
      INC(sent, n);
      IF sent < length THEN RETURN FALSE END;
    END;
  END;
  RETURN TRUE;
END WriteAllBounded;

PROCEDURE Accept (timeoutMs: INTEGER) : BOOLEAN;
VAR
  fd: INTEGER;
  deadline, remaining: LONGINT;
  request: ARRAY [0..8191] OF CHAR;
  requestLength: INTEGER;
  headerEnd, n, ready1, ready2, i, lineStart, lineEnd, valueStart: INTEGER;
  keySource: ARRAY [0..127] OF CHAR;
  digest: ARRAY [0..19] OF CHAR;
  accept: ARRAY [0..31] OF CHAR;
  response: ARRAY [0..511] OF CHAR;
  responseLength: INTEGER;
  chunk: ARRAY [0..1023] OF CHAR;
BEGIN
  deadline := ShimMonotonicMs() + VAL(LONGINT, timeoutMs);
  fd := ShimAccept(listenFd, timeoutMs);
  IF fd < 0 THEN RETURN FALSE END;
  conn := ShimPlainWrap(fd);
  connFd := fd;

  requestLength := 0;
  headerEnd := -1;
  LOOP
    remaining := deadline - ShimMonotonicMs();
    IF remaining <= 0 THEN RETURN FALSE END;
    IF ShimPoll2(connFd, -1, VAL(INTEGER, remaining), ready1, ready2) <= 0 THEN RETURN FALSE END;
    n := ShimRead(conn, chunk, 1024);
    IF n <= 0 THEN RETURN FALSE END;
    FOR i := 0 TO n - 1 DO request[requestLength + i] := chunk[i] END;
    INC(requestLength, n);
    request[requestLength] := 0C;
    i := 0;
    WHILE i <= requestLength - 4 DO
      IF (request[i] = CHR(13)) AND (request[i+1] = CHR(10)) AND (request[i+2] = CHR(13)) AND (request[i+3] = CHR(10)) THEN
        headerEnd := i; i := requestLength;
      ELSE INC(i) END;
    END;
    IF headerEnd >= 0 THEN EXIT END;
  END;

  keySource[0] := 0C;
  lineStart := 0;
  WHILE lineStart < headerEnd DO
    lineEnd := lineStart;
    WHILE (lineEnd < headerEnd) AND (request[lineEnd] <> CHR(13)) DO INC(lineEnd) END;
    (* "Sec-WebSocket-Key:" is exactly 18 characters; matched exactly so it
       is never confused with "Sec-WebSocket-Version:" or similar, which
       the real client also sends. Case sensitive is fine here: this
       fixture only ever talks to this project's own ConvexWS client,
       which always sends canonical header casing. *)
    IF (lineEnd - lineStart > 18)
       AND (request[lineStart] = 'S') AND (request[lineStart+1] = 'e') AND (request[lineStart+2] = 'c')
       AND (request[lineStart+3] = '-') AND (request[lineStart+4] = 'W') AND (request[lineStart+5] = 'e')
       AND (request[lineStart+6] = 'b') AND (request[lineStart+7] = 'S') AND (request[lineStart+8] = 'o')
       AND (request[lineStart+9] = 'c') AND (request[lineStart+10] = 'k') AND (request[lineStart+11] = 'e')
       AND (request[lineStart+12] = 't') AND (request[lineStart+13] = '-') AND (request[lineStart+14] = 'K')
       AND (request[lineStart+15] = 'e') AND (request[lineStart+16] = 'y') AND (request[lineStart+17] = ':') THEN
      valueStart := lineStart + 18;
      WHILE (valueStart < lineEnd) AND (request[valueStart] = ' ') DO INC(valueStart) END;
      FOR i := 0 TO lineEnd - valueStart - 1 DO keySource[i] := request[valueStart + i] END;
      keySource[lineEnd - valueStart] := 0C;
    END;
    lineStart := lineEnd + 2;
  END;
  IF keySource[0] = 0C THEN RETURN FALSE END;

  (* AppendBuf tracks the combined length in i as it writes but, unlike
     AppendQuoted/AppendText elsewhere in this client, never NUL-terminates
     the destination itself. Calling TextLength(keySource) here instead of
     using i directly used to scan past the just-appended GUID into
     whatever uninitialised stack memory followed it looking for a stray
     zero byte, so ShimSha1 hashed a garbage-length, nondeterministic
     input: the resulting Sec-WebSocket-Accept the fixture sent almost
     always still happened to satisfy the client (when that stray zero
     byte landed immediately after the GUID by chance) but occasionally
     did not, and only then as a function of whatever this call's stack
     frame happened to contain - explaining a failure that reproduced far
     more readily on a fast native machine (a different, more thoroughly
     reused stack) than under bruce's slower emulation. Terminating
     explicitly and passing the tracked length directly removes the
     uninitialised read entirely. *)
  i := TextLength(keySource);
  AppendBuf(HandshakeGuid, keySource, i);
  keySource[i] := 0C;
  ShimSha1(keySource, i, digest);
  Encode(digest, 20, accept);

  responseLength := 0;
  AppendBuf("HTTP/1.1 101 Switching Protocols", response, responseLength);
  response[responseLength] := CHR(13); response[responseLength+1] := CHR(10); INC(responseLength, 2);
  AppendBuf("Upgrade: websocket", response, responseLength);
  response[responseLength] := CHR(13); response[responseLength+1] := CHR(10); INC(responseLength, 2);
  AppendBuf("Connection: Upgrade", response, responseLength);
  response[responseLength] := CHR(13); response[responseLength+1] := CHR(10); INC(responseLength, 2);
  AppendBuf("Sec-WebSocket-Accept: ", response, responseLength);
  AppendBuf(accept, response, responseLength);
  response[responseLength] := CHR(13); response[responseLength+1] := CHR(10); INC(responseLength, 2);
  response[responseLength] := CHR(13); response[responseLength+1] := CHR(10); INC(responseLength, 2);

  RETURN WriteAllBounded(response, responseLength, deadline);
END Accept;

PROCEDURE ReceiveText (timeoutMs: INTEGER; VAR text: ARRAY OF CHAR) : BOOLEAN;
VAR
  deadline, remaining: LONGINT;
  byte0, byte1, opcode: INTEGER;
  masked: BOOLEAN;
  payloadLen: INTEGER;
  extBytes: ARRAY [0..7] OF CHAR;
  maskKey: ARRAY [0..3] OF CHAR;
  i, n, ready1, ready2: INTEGER;
  b: ARRAY [0..0] OF CHAR;

  PROCEDURE ReadByte (VAR out: CHAR) : BOOLEAN;
  VAR got, r1, r2, m: INTEGER; rem: LONGINT;
  BEGIN
    rem := deadline - ShimMonotonicMs();
    IF rem <= 0 THEN RETURN FALSE END;
    IF ShimPoll2(connFd, -1, VAL(INTEGER, rem), r1, r2) <= 0 THEN RETURN FALSE END;
    got := ShimRead(conn, b, 1);
    IF got <> 1 THEN RETURN FALSE END;
    out := b[0];
    RETURN TRUE;
  END ReadByte;

VAR ch: CHAR;
BEGIN
  deadline := ShimMonotonicMs() + VAL(LONGINT, timeoutMs);
  LOOP
    IF NOT ReadByte(ch) THEN RETURN FALSE END;
    opcode := INTEGER(CARDINAL(ORD(ch)) MOD 16);
    IF NOT ReadByte(ch) THEN RETURN FALSE END;
    masked := (CARDINAL(ORD(ch)) DIV 128) MOD 2 = 1;
    payloadLen := INTEGER(CARDINAL(ORD(ch)) MOD 128);
    IF payloadLen = 126 THEN
      IF NOT ReadByte(ch) THEN RETURN FALSE END; extBytes[0] := ch;
      IF NOT ReadByte(ch) THEN RETURN FALSE END; extBytes[1] := ch;
      payloadLen := INTEGER(CARDINAL(ORD(extBytes[0])) * 256 + CARDINAL(ORD(extBytes[1])));
    ELSIF payloadLen = 127 THEN
      FOR i := 0 TO 7 DO
        IF NOT ReadByte(ch) THEN RETURN FALSE END;
        extBytes[i] := ch;
      END;
      payloadLen := INTEGER(CARDINAL(ORD(extBytes[6])) * 256 + CARDINAL(ORD(extBytes[7])));
    END;
    IF masked THEN
      FOR i := 0 TO 3 DO
        IF NOT ReadByte(ch) THEN RETURN FALSE END;
        maskKey[i] := ch;
      END;
    END;
    IF payloadLen > MaxFrame THEN RETURN FALSE END;
    FOR i := 0 TO payloadLen - 1 DO
      IF NOT ReadByte(ch) THEN RETURN FALSE END;
      IF masked THEN
        text[i] := CHR(XorByte(ORD(ch), ORD(maskKey[i MOD 4])));
      ELSE
        text[i] := ch;
      END;
    END;
    text[payloadLen] := 0C;
    IF opcode = 1 THEN
      RETURN TRUE;
    ELSIF opcode = 8 THEN
      RETURN FALSE;
    END;
    (* ping/pong/continuation: ignore and read the next frame *)
  END;
END ReceiveText;

PROCEDURE SendText (VAR text: ARRAY OF CHAR; length: INTEGER) : BOOLEAN;
VAR
  frame: ARRAY [0..MaxFrame + 9] OF CHAR;
  frameLength, i: INTEGER;
BEGIN
  frame[0] := CHR(129); (* FIN=1, opcode=1 *)
  IF length <= 125 THEN
    frame[1] := CHR(length);
    frameLength := 2;
  ELSE
    frame[1] := CHR(126);
    frame[2] := CHR((length DIV 256) MOD 256);
    frame[3] := CHR(length MOD 256);
    frameLength := 4;
  END;
  FOR i := 0 TO length - 1 DO frame[frameLength + i] := text[i] END;
  INC(frameLength, length);
  RETURN WriteAllBounded(frame, frameLength, ShimMonotonicMs() + 3000);
END SendText;

PROCEDURE CloseAbruptly;
BEGIN
  IF conn <> NilAddress THEN
    ShimCloseConn(conn);
    conn := NilAddress;
  END;
END CloseAbruptly;

BEGIN
  listenFd := -1;
  conn := NilAddress;
  connFd := -1;
END ConvexFixture.
