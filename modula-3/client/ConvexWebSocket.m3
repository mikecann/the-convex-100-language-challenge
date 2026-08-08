MODULE ConvexWebSocket;

IMPORT Text, Word, TextWr, Wr, ConvexTransport, ConvexWire, ConvexBase64, ConvexSha1, ConvexRandom;

CONST
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  MaxHandshakeBytes = 32768;

PROCEDURE Handshake(t: ConvexTransport.T; host: TEXT; path: TEXT; deadline: LONGREAL): TEXT
  RAISES {Error} =
  VAR
    key: TEXT;
    req: TEXT;
    hb: ConvexWire.HeaderBlock;
    accept, expected: TEXT;
  BEGIN
    TRY
      key := ConvexBase64.Encode(ConvexRandom.Bytes(16));
    EXCEPT
    | ConvexRandom.Error => RAISE Error("could not generate a WebSocket key");
    END;

    req := "GET " & path & " HTTP/1.1\r\n";
    req := req & "Host: " & host & "\r\n";
    req := req & "Upgrade: websocket\r\n";
    req := req & "Connection: Upgrade\r\n";
    req := req & "Sec-WebSocket-Key: " & key & "\r\n";
    req := req & "Sec-WebSocket-Version: 13\r\n";
    req := req & "Convex-Client: modula-3-0.1.0\r\n\r\n";

    TRY
      ConvexTransport.Write(t, req);
      hb := ConvexWire.ReadHeaderBlock(t, deadline, MaxHandshakeBytes);
    EXCEPT
    | ConvexTransport.Error(msg) => RAISE Error("handshake transport failure: " & msg);
    | ConvexWire.Error(msg) => RAISE Error("handshake failed: " & msg);
    END;

    IF ConvexWire.Find(hb.statusLine, "101", 0) < 0 THEN
      RAISE Error("handshake did not return 101: " & hb.statusLine);
    END;

    accept := ConvexWire.HeaderValue(hb.headerText, "sec-websocket-accept");
    IF accept = NIL THEN RAISE Error("handshake response omitted Sec-WebSocket-Accept"); END;

    expected := ConvexBase64.Encode(ConvexSha1.Digest(key & GUID));
    IF NOT Text.Equal(accept, expected) THEN
      RAISE Error("Sec-WebSocket-Accept mismatch");
    END;

    RETURN hb.leftover;
  END Handshake;

PROCEDURE PutU16BE(wr: Wr.T; n: INTEGER) =
  BEGIN
    Wr.PutChar(wr, VAL(Word.And(Word.RightShift(n, 8), 16_FF), CHAR));
    Wr.PutChar(wr, VAL(Word.And(n, 16_FF), CHAR));
  END PutU16BE;

PROCEDURE PutU64BE(wr: Wr.T; n: INTEGER) =
  BEGIN
    FOR shift := 56 TO 0 BY -8 DO
      Wr.PutChar(wr, VAL(Word.And(Word.RightShift(n, shift), 16_FF), CHAR));
    END;
  END PutU64BE;

PROCEDURE BuildFrame(opcode: INTEGER; payload: TEXT): TEXT =
  VAR
    len := Text.Length(payload);
    out := TextWr.New();
    mask: TEXT;
  BEGIN
    TRY
      mask := ConvexRandom.Bytes(4);
    EXCEPT
    | ConvexRandom.Error => mask := "\000\000\000\000"; (* extremely unlikely; never leaves masking off *)
    END;

    Wr.PutChar(out, VAL(Word.Or(16_80, opcode), CHAR)); (* FIN=1, RSV=0 *)

    IF len < 126 THEN
      Wr.PutChar(out, VAL(Word.Or(16_80, len), CHAR));
    ELSIF len < 65536 THEN
      Wr.PutChar(out, VAL(Word.Or(16_80, 126), CHAR));
      PutU16BE(out, len);
    ELSE
      Wr.PutChar(out, VAL(Word.Or(16_80, 127), CHAR));
      PutU64BE(out, len);
    END;

    Wr.PutText(out, mask);
    FOR i := 0 TO len - 1 DO
      VAR mb := ORD(Text.GetChar(mask, i MOD 4));
          pb := ORD(Text.GetChar(payload, i));
      BEGIN
        Wr.PutChar(out, VAL(Word.Xor(mb, pb), CHAR));
      END;
    END;

    RETURN TextWr.ToText(out);
  END BuildFrame;

PROCEDURE TryParseFrame(buf: TEXT): ParseResult RAISES {Error} =
  VAR n := Text.Length(buf); result: ParseResult;
  BEGIN
    result.ok := FALSE;
    IF n < 2 THEN RETURN result; END;

    VAR
      byte0 := ORD(Text.GetChar(buf, 0));
      byte1 := ORD(Text.GetChar(buf, 1));
      fin := Word.And(byte0, 16_80) # 0;
      opcode := Word.And(byte0, 16_0F);
      masked := Word.And(byte1, 16_80) # 0;
      lenField := Word.And(byte1, 16_7F);
      pos := 2;
      payloadLen: INTEGER;
    BEGIN
      IF masked THEN RAISE Error("server sent a masked frame"); END;

      IF lenField = 126 THEN
        IF n < pos + 2 THEN RETURN result; END;
        payloadLen := Word.Or(
          Word.LeftShift(ORD(Text.GetChar(buf, pos)), 8), ORD(Text.GetChar(buf, pos + 1)));
        pos := pos + 2;
      ELSIF lenField = 127 THEN
        IF n < pos + 8 THEN RETURN result; END;
        payloadLen := 0;
        FOR k := 0 TO 7 DO
          payloadLen := Word.Or(Word.LeftShift(payloadLen, 8), ORD(Text.GetChar(buf, pos + k)));
        END;
        pos := pos + 8;
      ELSE
        payloadLen := lenField;
      END;

      IF n < pos + payloadLen THEN RETURN result; END;

      result.ok := TRUE;
      result.consumed := pos + payloadLen;
      result.frame.fin := fin;
      result.frame.opcode := opcode;
      result.frame.payload := Text.Sub(buf, pos, payloadLen);
      RETURN result;
    END;
  END TryParseFrame;

BEGIN
END ConvexWebSocket.
