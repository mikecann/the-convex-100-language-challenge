(* ConvexHttp - implementation. See ConvexHttp.i3. *)
MODULE ConvexHttp;

IMPORT Text, Time, Fmt, ConvexJson, ConvexTransport, ConvexUrl, ConvexWire;

CONST
  MaxHeaderBytes = 65536;
  MaxBodyBytes = 8388608; (* 8 MiB, comfortably above any Convex response *)
  ClientTag = "modula-3-0.1.0";

PROCEDURE TransportResult(msg: TEXT): CallResult =
  BEGIN
    RETURN CallResult{
      kind := ResultKind.TransportError, value := NIL,
      errName := "TransportError", errMessage := msg,
      errData := NIL, logLines := ConvexJson.NewArray()};
  END TransportResult;

PROCEDURE ProtocolResult(msg: TEXT): CallResult =
  BEGIN
    RETURN CallResult{
      kind := ResultKind.ProtocolError, value := NIL,
      errName := "ProtocolError", errMessage := msg,
      errData := NIL, logLines := ConvexJson.NewArray()};
  END ProtocolResult;

(* One bounded read, translating a ConvexTransport timeout into "no new
   bytes yet" as long as the deadline has not actually passed (so a
   caller's own loop keeps re-checking the real deadline). Returns NIL
   to mean "nothing new, try again"; "" to mean "peer closed". *)
PROCEDURE ReadSome(t: ConvexTransport.T; deadline: LONGREAL): TEXT RAISES {ConvexWire.Error} =
  VAR remainMs: INTEGER;
  BEGIN
    remainMs := ROUND((deadline - Time.Now()) * 1000.0d0);
    IF remainMs <= 0 THEN RAISE ConvexWire.Error("timed out reading response body"); END;
    IF remainMs > 2000 THEN remainMs := 2000; END;
    TRY
      RETURN ConvexTransport.Read(t, 65536, remainMs);
    EXCEPT
    | ConvexTransport.Error(msg) =>
        IF ConvexWire.Find(msg, "timeout:", 0) = 0 THEN RETURN NIL; END;
        RAISE ConvexWire.Error(msg);
    END;
  END ReadSome;

(* Read a Content-Length-declared or chunked or close-terminated body,
   given whatever bytes already arrived past the header block. *)
PROCEDURE ReadBody(t: ConvexTransport.T; leftover: TEXT; contentLength: INTEGER;
                    chunked: BOOLEAN; deadline: LONGREAL): TEXT RAISES {ConvexWire.Error} =
  VAR body := leftover; chunk: TEXT;
  BEGIN
    IF chunked THEN RETURN ReadChunked(t, leftover, deadline); END;

    IF contentLength >= 0 THEN
      WHILE Text.Length(body) < contentLength DO
        chunk := ReadSome(t, deadline);
        IF chunk # NIL THEN
          IF Text.Equal(chunk, "") THEN EXIT; (* peer closed early; return what we have *) END;
          body := body & chunk;
          IF Text.Length(body) > MaxBodyBytes THEN RAISE ConvexWire.Error("response body exceeded budget"); END;
        END;
      END;
      IF Text.Length(body) > contentLength THEN RETURN Text.Sub(body, 0, contentLength); END;
      RETURN body;
    END;

    (* neither Content-Length nor chunked: read until the peer closes *)
    LOOP
      chunk := ReadSome(t, deadline);
      IF chunk # NIL THEN
        IF Text.Equal(chunk, "") THEN RETURN body; END;
        body := body & chunk;
        IF Text.Length(body) > MaxBodyBytes THEN RAISE ConvexWire.Error("response body exceeded budget"); END;
      END;
    END;
  END ReadBody;

PROCEDURE ReadChunked(t: ConvexTransport.T; leftover: TEXT; deadline: LONGREAL): TEXT
  RAISES {ConvexWire.Error} =
  VAR pending := leftover; body := "";

  PROCEDURE Need(count: INTEGER) RAISES {ConvexWire.Error} =
    VAR chunk: TEXT;
    BEGIN
      WHILE Text.Length(pending) < count DO
        chunk := ReadSome(t, deadline);
        IF chunk # NIL THEN
          IF Text.Equal(chunk, "") THEN RAISE ConvexWire.Error("connection closed mid-chunk"); END;
          pending := pending & chunk;
        END;
        IF Text.Length(pending) + Text.Length(body) > MaxBodyBytes THEN
          RAISE ConvexWire.Error("response body exceeded budget");
        END;
      END;
    END Need;

  PROCEDURE NeedLine(): TEXT RAISES {ConvexWire.Error} =
    VAR at: INTEGER; chunk: TEXT;
    BEGIN
      LOOP
        at := ConvexWire.Find(pending, "\r\n", 0);
        IF at >= 0 THEN
          VAR line := Text.Sub(pending, 0, at);
          BEGIN
            pending := Text.Sub(pending, at + 2, LAST(CARDINAL));
            RETURN line;
          END;
        END;
        chunk := ReadSome(t, deadline);
        IF chunk # NIL THEN
          IF Text.Equal(chunk, "") THEN RAISE ConvexWire.Error("connection closed mid-chunk-header"); END;
          pending := pending & chunk;
        END;
      END;
    END NeedLine;

  VAR sizeLine: TEXT; size: INTEGER;
  BEGIN
    LOOP
      sizeLine := NeedLine();
      size := HexToInt(sizeLine);
      IF size = 0 THEN RETURN body; END;
      Need(size + 2);
      body := body & Text.Sub(pending, 0, size);
      pending := Text.Sub(pending, size + 2, LAST(CARDINAL)); (* skip trailing CRLF *)
    END;
  END ReadChunked;

PROCEDURE HexToInt(s: TEXT): INTEGER =
  VAR n := 0; c: CHAR;
  BEGIN
    FOR i := 0 TO Text.Length(s) - 1 DO
      c := Text.GetChar(s, i);
      IF c >= '0' AND c <= '9' THEN n := n * 16 + (ORD(c) - ORD('0'));
      ELSIF c >= 'a' AND c <= 'f' THEN n := n * 16 + (ORD(c) - ORD('a') + 10);
      ELSIF c >= 'A' AND c <= 'F' THEN n := n * 16 + (ORD(c) - ORD('A') + 10);
      ELSE EXIT; (* chunk extensions after ';' are ignored *)
      END;
    END;
    RETURN n;
  END HexToInt;

(* Turn a decoded top-level JSON response object into a CallResult per
   Convex's own envelope: {"status":"success","value":...} or
   {"status":"error","errorMessage":...,"errorData":...}, both possibly
   carrying "logLines". *)
PROCEDURE Classify(statusCode: INTEGER; rawBody: TEXT): CallResult =
  VAR top: ConvexJson.T; status, msgVal: ConvexJson.T; logs: ConvexJson.T;
  BEGIN
    IF statusCode = 200 OR statusCode = 560 THEN
      TRY
        top := ConvexJson.Decode(rawBody);
      EXCEPT
      | ConvexJson.Error(m) => RETURN ProtocolResult("HTTP response body was not valid JSON: " & m);
      END;
      IF top.kind # ConvexJson.Kind.Obj THEN
        RETURN ProtocolResult("HTTP response body was not a JSON object");
      END;
      status := ConvexJson.ObjectGet(top, "status");
      IF status = NIL THEN RETURN ProtocolResult("HTTP response omitted status"); END;

      logs := ConvexJson.ObjectGet(top, "logLines");
      IF logs = NIL THEN logs := ConvexJson.NewArray(); END;

      TRY
        IF Text.Equal(ConvexJson.StrOf(status), "success") AND statusCode = 200 THEN
          VAR value := ConvexJson.ObjectGet(top, "value");
          BEGIN
            IF value = NIL THEN RETURN ProtocolResult("HTTP success response omitted value"); END;
            RETURN CallResult{
              kind := ResultKind.Result, value := value,
              errName := NIL, errMessage := NIL, errData := NIL, logLines := logs};
          END;
        END;

        IF Text.Equal(ConvexJson.StrOf(status), "error") OR statusCode = 560 THEN
          VAR message := "Convex function failed"; dataValue: ConvexJson.T := NIL;
          BEGIN
            msgVal := ConvexJson.ObjectGet(top, "errorMessage");
            IF msgVal = NIL THEN msgVal := ConvexJson.ObjectGet(top, "message"); END;
            IF msgVal # NIL THEN message := ConvexJson.StrOf(msgVal); END;
            dataValue := ConvexJson.ObjectGet(top, "errorData");
            RETURN CallResult{
              kind := ResultKind.FunctionError, value := NIL,
              errName := "FunctionError", errMessage := message,
              errData := dataValue, logLines := logs};
          END;
        END;
      EXCEPT
      | ConvexJson.Error(m) => RETURN ProtocolResult("malformed Convex response envelope: " & m);
      END;

      RETURN ProtocolResult("HTTP response had unknown status");
    END;

    VAR detail := "no Convex error envelope"; message: TEXT;
    BEGIN
      TRY
        top := ConvexJson.Decode(rawBody);
        IF top.kind = ConvexJson.Kind.Obj THEN
          msgVal := ConvexJson.ObjectGet(top, "errorMessage");
          IF msgVal = NIL THEN msgVal := ConvexJson.ObjectGet(top, "message"); END;
          IF msgVal # NIL THEN detail := ConvexJson.StrOf(msgVal); END;
        END;
      EXCEPT
      | ConvexJson.Error => (* leave detail as the default *)
      END;
      message := "HTTP " & Fmt.Int(statusCode) & " from Convex: " & detail;

      IF statusCode = 500 OR statusCode = 502 OR statusCode = 503 OR statusCode = 504
         OR statusCode = 408 OR statusCode = 429 THEN
        RETURN CallResult{
          kind := ResultKind.TransportError, value := NIL,
          errName := "TransportError", errMessage := message,
          errData := NIL, logLines := ConvexJson.NewArray()};
      END;
      RETURN CallResult{
        kind := ResultKind.ProtocolError, value := NIL,
        errName := "ProtocolError", errMessage := message,
        errData := NIL, logLines := ConvexJson.NewArray()};
    END;
  END Classify;

PROCEDURE Call(op: TEXT; path: TEXT; args: ConvexJson.T; baseUrl: TEXT; token: TEXT): CallResult =
  VAR
    u := ConvexUrl.Parse(baseUrl, "/");
    bodyJson := ConvexJson.NewObject();
    body, req: TEXT;
    t: ConvexTransport.T := NIL;
    deadline := Time.Now() + 15.0d0;
    hb: ConvexWire.HeaderBlock;
    statusCode: INTEGER;
    contentLength: INTEGER;
    chunked: BOOLEAN;
    rawBody: TEXT;
  BEGIN
    ConvexJson.ObjectSet(bodyJson, "path", ConvexJson.NewString(path));
    ConvexJson.ObjectSet(bodyJson, "args", args);
    ConvexJson.ObjectSet(bodyJson, "format", ConvexJson.NewString("json"));
    body := ConvexJson.Encode(bodyJson);

    req := "POST /api/" & op & " HTTP/1.1\r\n";
    req := req & "Host: " & u.host & "\r\n";
    req := req & "Content-Type: application/json\r\n";
    req := req & "Accept: application/json\r\n";
    req := req & "Convex-Client: " & ClientTag & "\r\n";
    IF Text.Length(token) > 0 THEN req := req & "Authorization: Bearer " & token & "\r\n"; END;
    req := req & "Content-Length: " & Fmt.Int(Text.Length(body)) & "\r\n";
    req := req & "Connection: close\r\n\r\n";
    req := req & body;

    TRY
      t := ConvexTransport.Connect(u.host, u.port, u.useTls);
    EXCEPT
    | ConvexTransport.Error(msg) => RETURN TransportResult("connect failed: " & msg);
    END;

    TRY
      ConvexTransport.Write(t, req);
      hb := ConvexWire.ReadHeaderBlock(t, deadline, MaxHeaderBytes);

      statusCode := StatusCodeOf(hb.statusLine);
      IF statusCode < 0 THEN
        ConvexTransport.Close(t);
        RETURN ProtocolResult("HTTP response had no parseable status line");
      END;

      contentLength := -1;
      VAR clText := ConvexWire.HeaderValue(hb.headerText, "content-length");
      BEGIN
        IF clText # NIL THEN contentLength := ParseDigits(clText); END;
      END;
      chunked := FALSE;
      VAR teText := ConvexWire.HeaderValue(hb.headerText, "transfer-encoding");
      BEGIN
        IF teText # NIL AND Text.Equal(LowerText(teText), "chunked") THEN chunked := TRUE; END;
      END;

      rawBody := ReadBody(t, hb.leftover, contentLength, chunked, deadline);
      ConvexTransport.Close(t);
      RETURN Classify(statusCode, rawBody);
    EXCEPT
    | ConvexTransport.Error(msg) => ConvexTransport.Close(t); RETURN TransportResult(msg);
    | ConvexWire.Error(msg) => ConvexTransport.Close(t); RETURN TransportResult(msg);
    END;
  END Call;

PROCEDURE StatusCodeOf(statusLine: TEXT): INTEGER =
  VAR at := ConvexWire.Find(statusLine, "HTTP/", 0);
  BEGIN
    IF at < 0 THEN RETURN -1; END;
    VAR pos := at + 5;
    BEGIN
      WHILE pos < Text.Length(statusLine) AND Text.GetChar(statusLine, pos) # ' ' DO INC(pos); END;
      WHILE pos < Text.Length(statusLine) AND Text.GetChar(statusLine, pos) = ' ' DO INC(pos); END;
      VAR start := pos; n := 0;
      BEGIN
        WHILE pos < Text.Length(statusLine)
              AND Text.GetChar(statusLine, pos) >= '0' AND Text.GetChar(statusLine, pos) <= '9' DO
          INC(pos);
        END;
        IF pos = start THEN RETURN -1; END;
        FOR i := start TO pos - 1 DO n := n * 10 + (ORD(Text.GetChar(statusLine, i)) - ORD('0')); END;
        RETURN n;
      END;
    END;
  END StatusCodeOf;

PROCEDURE ParseDigits(s: TEXT): INTEGER =
  VAR n := 0;
  BEGIN
    FOR i := 0 TO Text.Length(s) - 1 DO
      VAR c := Text.GetChar(s, i);
      BEGIN
        IF c < '0' OR c > '9' THEN EXIT; END;
        n := n * 10 + (ORD(c) - ORD('0'));
      END;
    END;
    RETURN n;
  END ParseDigits;

PROCEDURE LowerText(s: TEXT): TEXT =
  VAR buf := NEW(REF ARRAY OF CHAR, Text.Length(s));
  BEGIN
    Text.SetChars(buf^, s);
    FOR i := 0 TO Text.Length(s) - 1 DO
      IF buf[i] >= 'A' AND buf[i] <= 'Z' THEN buf[i] := VAL(ORD(buf[i]) + 32, CHAR); END;
    END;
    RETURN Text.FromChars(buf^);
  END LowerText;

BEGIN
END ConvexHttp.
