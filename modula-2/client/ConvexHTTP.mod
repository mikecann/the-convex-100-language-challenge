IMPLEMENTATION MODULE ConvexHTTP;

FROM SYSTEM IMPORT ADDRESS;
FROM CShim IMPORT
  ShimTcpConnect, ShimTlsWrap, ShimPlainWrap, ShimRead, ShimWrite, ShimFd,
  ShimPending, ShimCloseConn, ShimPoll2, ShimMonotonicMs, ShimLastError;
FROM ConvexURL IMPORT Parse;

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
  ChunkCap = 65536;

(* Post is never reentrant (this client is single threaded), so its large
   working buffers are static module storage rather than stack allocated;
   gm2's default thread stack is not generous enough for a multi-megabyte
   local array plus nested nesting procedure frames. *)
VAR
  GlobalRequest: ARRAY [0..4095] OF CHAR;
  GlobalRaw: ARRAY [0..MaxBody] OF CHAR;
  GlobalChunk: ARRAY [0..ChunkCap - 1] OF CHAR;

PROCEDURE CopyError (text: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR
  i, n: INTEGER;
BEGIN
  n := INTEGER(TextLength(text));
  IF n > INTEGER(HIGH(destination)) THEN n := INTEGER(HIGH(destination)) END;
  FOR i := 0 TO n - 1 DO destination[i] := text[i] END;
  destination[n] := 0C;
END CopyError;

PROCEDURE ShimError (VAR destination: ARRAY OF CHAR);
VAR
  buf: ARRAY [0..511] OF CHAR;
  n: INTEGER;
BEGIN
  n := ShimLastError(buf, 511);
  IF n > 511 THEN n := 511 END;
  buf[n] := 0C;
  CopyError(buf, destination);
END ShimError;

(* WriteAllBounded writes the whole buffer, resuming after short and
   would-block writes, until either every byte is sent or deadlineMs (an
   absolute ShimMonotonicMs value) passes. *)
PROCEDURE WriteAllBounded (conn: ADDRESS; VAR data: ARRAY OF CHAR; length: INTEGER;
                           deadlineMs: LONGINT; VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
VAR
  sent, n, ready1, ready2, fd, chunkLength, i: INTEGER;
  remaining: LONGINT;
BEGIN
  sent := 0;
  fd := ShimFd(conn);
  WHILE sent < length DO
    remaining := deadlineMs - ShimMonotonicMs();
    IF remaining <= 0 THEN
      ok := FALSE;
      CopyError("write deadline exceeded", errorText);
      RETURN;
    END;
    chunkLength := length - sent;
    IF chunkLength > ChunkCap THEN chunkLength := ChunkCap END;
    FOR i := 0 TO chunkLength - 1 DO
      GlobalChunk[i] := data[sent + i];
    END;
    n := ShimWrite(conn, GlobalChunk, chunkLength);
    IF n = -2 THEN
      ok := FALSE;
      ShimError(errorText);
      RETURN;
    ELSIF n = -1 THEN
      IF ShimPoll2(fd, -1, VAL(INTEGER, remaining), ready1, ready2) < 0 THEN
        ok := FALSE;
        ShimError(errorText);
        RETURN;
      END;
    ELSE
      INC(sent, n);
    END;
  END;
  ok := TRUE;
END WriteAllBounded;

(* HeaderLineHasPrefix performs a case-insensitive comparison of the first
   INTEGER(TextLength(prefix)) characters of raw[lineStart..lineEnd) to
   prefix (which must already be lower case). *)
PROCEDURE HeaderLineHasPrefix (VAR raw: ARRAY OF CHAR; lineStart, lineEnd: INTEGER;
                                prefix: ARRAY OF CHAR) : BOOLEAN;
VAR
  prefixLength, i: INTEGER;
  a: CHAR;
BEGIN
  prefixLength := INTEGER(TextLength(prefix));
  IF lineEnd - lineStart < prefixLength THEN RETURN FALSE END;
  FOR i := 0 TO prefixLength - 1 DO
    a := raw[lineStart + i];
    IF (a >= 'A') AND (a <= 'Z') THEN a := CHR(ORD(a) + 32) END;
    IF a <> prefix[i] THEN RETURN FALSE END;
  END;
  RETURN TRUE;
END HeaderLineHasPrefix;

(* FindHeaderEnd looks for the blank line ("\r\n\r\n") ending the HTTP
   header block within raw[0..rawLength). Returns the index of the first
   CR of that sequence, or -1 if it has not arrived yet. *)
PROCEDURE FindHeaderEnd (VAR raw: ARRAY OF CHAR; rawLength: INTEGER) : INTEGER;
VAR
  i: INTEGER;
BEGIN
  IF rawLength < 4 THEN RETURN -1 END;
  FOR i := 0 TO rawLength - 4 DO
    IF (raw[i] = CHR(13)) AND (raw[i+1] = CHR(10)) AND (raw[i+2] = CHR(13)) AND (raw[i+3] = CHR(10)) THEN
      RETURN i;
    END;
  END;
  RETURN -1;
END FindHeaderEnd;

(* ParseHeaders walks the header block raw[0..headerEnd) looking for
   Content-Length and Transfer-Encoding. *)
PROCEDURE ParseHeaders (VAR raw: ARRAY OF CHAR; headerEnd: INTEGER;
                         VAR haveContentLength: BOOLEAN; VAR contentLength: INTEGER;
                         VAR chunked: BOOLEAN);
VAR
  lineStart, lineEnd, valueStart, i: INTEGER;
  parsedOk: BOOLEAN;
BEGIN
  haveContentLength := FALSE;
  chunked := FALSE;
  contentLength := 0;
  lineStart := 0;
  WHILE lineStart < headerEnd DO
    lineEnd := lineStart;
    WHILE (lineEnd < headerEnd) AND (raw[lineEnd] <> CHR(13)) DO INC(lineEnd) END;
    IF HeaderLineHasPrefix(raw, lineStart, lineEnd, "content-length:") THEN
      valueStart := lineStart + 15;
      WHILE (valueStart < lineEnd) AND (raw[valueStart] = ' ') DO INC(valueStart) END;
      parsedOk := valueStart < lineEnd;
      contentLength := 0;
      FOR i := valueStart TO lineEnd - 1 DO
        IF (raw[i] < '0') OR (raw[i] > '9') THEN
          parsedOk := FALSE;
        ELSE
          contentLength := contentLength * 10 + (INTEGER(ORD(raw[i])) - INTEGER(ORD('0')));
        END;
      END;
      IF parsedOk THEN haveContentLength := TRUE END;
    END;
    IF HeaderLineHasPrefix(raw, lineStart, lineEnd, "transfer-encoding:") THEN
      chunked := TRUE;
    END;
    lineStart := lineEnd + 2;
  END;
END ParseHeaders;

(* Post implements one request/response cycle. See ConvexHTTP.def. *)
PROCEDURE Post (url: ARRAY OF CHAR; VAR payload: ARRAY OF CHAR; token: ARRAY OF CHAR;
                 timeoutMs: INTEGER;
                 VAR body: ARRAY OF CHAR; VAR ok: BOOLEAN; VAR errorText: ARRAY OF CHAR);
VAR
  secure: BOOLEAN;
  host: ARRAY [0..255] OF CHAR;
  path: ARRAY [0..1023] OF CHAR;
  port: INTEGER;
  fd: INTEGER;
  conn: ADDRESS;
  requestLength: INTEGER;
  payloadLength, tokenLength: INTEGER;
  deadline, remaining: LONGINT;
  rawLength: INTEGER;
  headerEnd, bodyStart, contentLength, targetLength: INTEGER;
  haveContentLength, chunked: BOOLEAN;
  n, ready1, ready2, i, readCap: INTEGER;

  (* Modula-2 string literals have no backslash escapes ("\r\n" is four
     literal characters, not CR LF), so every header line ends with an
     explicit call to AppendCRLF rather than an embedded escape. *)
  PROCEDURE AppendLiteral (text: ARRAY OF CHAR);
  VAR n2, i2: INTEGER;
  BEGIN
    n2 := INTEGER(TextLength(text));
    FOR i2 := 0 TO n2 - 1 DO
      GlobalRequest[requestLength] := text[i2];
      INC(requestLength);
    END;
  END AppendLiteral;

  PROCEDURE AppendCRLF;
  BEGIN
    GlobalRequest[requestLength] := CHR(13);
    GlobalRequest[requestLength + 1] := CHR(10);
    INC(requestLength, 2);
  END AppendCRLF;

  PROCEDURE AppendInt (value: INTEGER);
  VAR digits: ARRAY [0..15] OF CHAR; count, v: INTEGER;
  BEGIN
    IF value = 0 THEN
      GlobalRequest[requestLength] := '0';
      INC(requestLength);
      RETURN;
    END;
    count := 0;
    v := value;
    WHILE v > 0 DO
      digits[count] := CHR(ORD('0') + CARDINAL(v MOD 10));
      v := v DIV 10;
      INC(count);
    END;
    WHILE count > 0 DO
      DEC(count);
      GlobalRequest[requestLength] := digits[count];
      INC(requestLength);
    END;
  END AppendInt;

BEGIN
  body[0] := 0C;
  ok := FALSE;
  errorText[0] := 0C;
  deadline := ShimMonotonicMs() + VAL(LONGINT, timeoutMs);

  IF NOT Parse(url, secure, host, port, path) THEN
    CopyError("invalid Convex deployment URL", errorText);
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

  payloadLength := INTEGER(TextLength(payload));
  tokenLength := INTEGER(TextLength(token));

  requestLength := 0;
  AppendLiteral("POST ");
  AppendLiteral(path);
  AppendLiteral(" HTTP/1.1"); AppendCRLF;
  AppendLiteral("Host: "); AppendLiteral(host); AppendCRLF;
  AppendLiteral("Content-Type: application/json"); AppendCRLF;
  AppendLiteral("Connection: close"); AppendCRLF;
  AppendLiteral("Content-Length: ");
  AppendInt(payloadLength);
  AppendCRLF;
  IF tokenLength > 0 THEN
    AppendLiteral("Authorization: Bearer ");
    AppendLiteral(token);
    AppendCRLF;
  END;
  AppendCRLF;

  (* payload can be near MaxBody and must never be copied into GlobalRequest
     (a value-parameter ARRAY OF CHAR copy of a multi-megabyte buffer is
     what originally crashed this module against example.com), so the
     header block and payload are written as two separate bounded writes. *)
  WriteAllBounded(conn, GlobalRequest, requestLength, deadline, ok, errorText);
  IF NOT ok THEN
    ShimCloseConn(conn);
    RETURN;
  END;
  WriteAllBounded(conn, payload, payloadLength, deadline, ok, errorText);
  IF NOT ok THEN
    ShimCloseConn(conn);
    RETURN;
  END;

  rawLength := 0;
  headerEnd := -1;
  haveContentLength := FALSE;
  chunked := FALSE;
  contentLength := 0;

  LOOP
    remaining := deadline - ShimMonotonicMs();
    IF remaining <= 0 THEN
      ShimCloseConn(conn);
      CopyError("response timed out", errorText);
      RETURN;
    END;
    IF ShimPending(conn) = 0 THEN
      n := ShimPoll2(ShimFd(conn), -1, VAL(INTEGER, remaining), ready1, ready2);
      IF n < 0 THEN
        ShimCloseConn(conn);
        ShimError(errorText);
        RETURN;
      END;
    END;
    IF rawLength >= MaxBody THEN
      ShimCloseConn(conn);
      CopyError("response exceeded the 2 MiB cap", errorText);
      RETURN;
    END;
    readCap := MaxBody - rawLength;
    IF readCap > ChunkCap THEN readCap := ChunkCap END;
    n := ShimRead(conn, GlobalChunk, readCap);
    IF n = -2 THEN
      ShimCloseConn(conn);
      ShimError(errorText);
      RETURN;
    ELSIF n = -1 THEN
      (* spurious wakeup; poll again *)
    ELSIF n = 0 THEN
      EXIT; (* peer closed the connection *)
    ELSE
      FOR i := 0 TO n - 1 DO
        GlobalRaw[rawLength + i] := GlobalChunk[i];
      END;
      INC(rawLength, n);
      IF headerEnd < 0 THEN
        headerEnd := FindHeaderEnd(GlobalRaw, rawLength);
        IF headerEnd >= 0 THEN
          bodyStart := headerEnd + 4;
          ParseHeaders(GlobalRaw, headerEnd, haveContentLength, contentLength, chunked);
          IF chunked THEN
            ShimCloseConn(conn);
            CopyError("chunked transfer encoding is not supported", errorText);
            RETURN;
          END;
        END;
      END;
      IF (headerEnd >= 0) AND haveContentLength THEN
        targetLength := bodyStart + contentLength;
        IF targetLength > MaxBody THEN
          ShimCloseConn(conn);
          CopyError("response exceeded the 2 MiB cap", errorText);
          RETURN;
        END;
        IF rawLength >= targetLength THEN EXIT END;
      END;
    END;
  END;

  ShimCloseConn(conn);

  IF headerEnd < 0 THEN
    CopyError("connection closed before headers completed", errorText);
    RETURN;
  END;
  IF haveContentLength AND (rawLength < bodyStart + contentLength) THEN
    CopyError("connection closed before the declared body was received", errorText);
    RETURN;
  END;

  IF haveContentLength THEN
    n := contentLength;
  ELSE
    n := rawLength - bodyStart;
  END;
  IF n > INTEGER(HIGH(body)) THEN
    CopyError("response body exceeded the caller's buffer", errorText);
    RETURN;
  END;
  FOR i := 0 TO n - 1 DO
    body[i] := GlobalRaw[bodyStart + i];
  END;
  body[n] := 0C;
  ok := TRUE;
END Post;

END ConvexHTTP.
