(* WsFixture - a scripted, one-shot RFC 6455 WebSocket *server* used
   only by LiveTest, never shipped as part of the client or the
   conformance adapter. It speaks just enough of the protocol to drive
   ConvexLive through the scenarios language-local tests need to prove:
   fragmentation reassembly, a Ping interleaved mid-fragmentation
   (answered with an exact Pong), UTF-8 validated only after
   reassembly (both a valid codepoint split across the frame boundary
   and an invalid one), and a deliberately wrong Sec-WebSocket-Accept
   being rejected. Real WebSocket servers never behave this way on
   purpose; this one only exists to hold the wire still long enough to
   observe the client's reaction. *)
MODULE WsFixture EXPORTS Main;

IMPORT IP, TCP, Thread, Text, TextWr, Wr, Word, IO, Params, Process,
       ConvexWebSocket, ConvexWire;

(* Each scenario gets its own fixed port, passed as argv[2] (rather than
   reusing one port across the three sequential scenarios in the
   Dockerfile's test loop) so this never has to guess whether this CM3
   build's TCP.NewConnector sets SO_REUSEADDR: a listening socket from a
   just-closed connector should not still be settling by the time the
   next scenario tries to bind. *)
PROCEDURE ParsePort(s: TEXT): IP.Port =
  VAR n := 0;
  BEGIN
    FOR i := 0 TO Text.Length(s) - 1 DO
      n := n * 10 + (ORD(Text.GetChar(s, i)) - ORD('0'));
    END;
    RETURN n;
  END ParsePort;

PROCEDURE ReadSome(conn: TCP.T; maxBytes: INTEGER): TEXT =
  VAR buf: REF ARRAY OF CHAR := NEW(REF ARRAY OF CHAR, maxBytes); n: CARDINAL;
  BEGIN
    TRY
      n := conn.get(buf^, 10.0d0);
    EXCEPT
    | Thread.Alerted => IO.Put("fixture: read alerted\n"); Process.Exit(1); RETURN "";
    ELSE
      IO.Put("fixture: read failed\n"); Process.Exit(1); RETURN "";
    END;
    IF n = 0 THEN RETURN ""; END;
    RETURN Text.FromChars(SUBARRAY(buf^, 0, n));
  END ReadSome;

PROCEDURE ReadUntil(conn: TCP.T; needle: TEXT): TEXT =
  VAR whole := "";
  BEGIN
    LOOP
      IF ConvexWire.Find(whole, needle, 0) >= 0 THEN RETURN whole; END;
      VAR chunk := ReadSome(conn, 65536);
      BEGIN
        IF Text.Equal(chunk, "") THEN
          IO.Put("fixture: peer closed before " & needle & "\n");
          Process.Exit(1);
        END;
        whole := whole & chunk;
      END;
    END;
  END ReadUntil;

(* -- building raw, unmasked (server-to-client) frames ---------------- *)

PROCEDURE PutU16BE(wr: Wr.T; n: INTEGER) =
  BEGIN
    Wr.PutChar(wr, VAL(Word.And(Word.RightShift(n, 8), 16_FF), CHAR));
    Wr.PutChar(wr, VAL(Word.And(n, 16_FF), CHAR));
  END PutU16BE;

PROCEDURE BuildServerFrame(fin: BOOLEAN; opcode: INTEGER; payload: TEXT): TEXT =
  VAR len := Text.Length(payload); out := TextWr.New(); b0 := opcode;
  BEGIN
    IF fin THEN b0 := Word.Or(16_80, b0); END;
    Wr.PutChar(out, VAL(b0, CHAR));
    IF len < 126 THEN
      Wr.PutChar(out, VAL(len, CHAR));
    ELSE
      Wr.PutChar(out, VAL(126, CHAR));
      PutU16BE(out, len);
    END;
    Wr.PutText(out, payload);
    RETURN TextWr.ToText(out);
  END BuildServerFrame;

PROCEDURE WriteAll(conn: TCP.T; data: TEXT) =
  VAR n := Text.Length(data); buf: REF ARRAY OF CHAR := NEW(REF ARRAY OF CHAR, n);
  BEGIN
    Text.SetChars(buf^, data);
    TRY
      conn.put(buf^);
    EXCEPT
    | Thread.Alerted => IO.Put("fixture: write alerted\n"); Process.Exit(1);
    ELSE
      IO.Put("fixture: write failed\n"); Process.Exit(1);
    END;
  END WriteAll;

(* -- reading one client (masked) frame back, to check the Pong ------- *)

TYPE ClientFrame = RECORD opcode: INTEGER; payload: TEXT; END;

PROCEDURE ReadOneClientFrame(conn: TCP.T; VAR buf: TEXT): ClientFrame =
  VAR n, pos, payloadLen: INTEGER; byte0, byte1: INTEGER;
  BEGIN
    LOOP
      n := Text.Length(buf);
      IF n >= 2 THEN
        byte0 := ORD(Text.GetChar(buf, 0));
        byte1 := ORD(Text.GetChar(buf, 1));
        VAR
          opcode := Word.And(byte0, 16_0F);
          masked := Word.And(byte1, 16_80) # 0;
          lenField := Word.And(byte1, 16_7F);
        BEGIN
          IF NOT masked THEN
            IO.Put("fixture: client frame was not masked (RFC 6455 5.1 violation)\n");
            Process.Exit(1);
          END;
          pos := 2;
          IF lenField = 126 THEN
            IF n < pos + 2 THEN payloadLen := -1;
            ELSE
              payloadLen := Word.Or(Word.LeftShift(ORD(Text.GetChar(buf, pos)), 8), ORD(Text.GetChar(buf, pos + 1)));
              pos := pos + 2;
            END;
          ELSE
            payloadLen := lenField;
          END;
          IF payloadLen >= 0 AND n >= pos + 4 + payloadLen THEN
            VAR mask: ARRAY [0..3] OF CHAR; payload: ARRAY [0..4095] OF CHAR;
            BEGIN
              FOR i := 0 TO 3 DO mask[i] := Text.GetChar(buf, pos + i); END;
              FOR i := 0 TO payloadLen - 1 DO
                payload[i] := VAL(Word.Xor(ORD(mask[i MOD 4]), ORD(Text.GetChar(buf, pos + 4 + i))), CHAR);
              END;
              buf := Text.Sub(buf, pos + 4 + payloadLen, LAST(CARDINAL));
              RETURN ClientFrame{opcode := opcode, payload := Text.FromChars(SUBARRAY(payload, 0, payloadLen))};
            END;
          END;
        END;
      END;
      VAR chunk := ReadSome(conn, 65536);
      BEGIN
        IF Text.Equal(chunk, "") THEN
          IO.Put("fixture: peer closed mid-frame\n");
          Process.Exit(1);
        END;
        buf := buf & chunk;
      END;
    END;
  END ReadOneClientFrame;

(* The client sends its own "Connect" and "ModifyQuerySet" (Add) sync-
   protocol messages as soon as the handshake completes (see
   ConvexLive.Connect), before this fixture ever looks at the wire in
   the other direction -- so the first frame(s) sitting in "buf" when a
   scenario expects a Pong are ordinary client text frames, not the
   Pong yet. Skip past those (this fixture never needs to understand
   their contents) rather than misreading one as the Pong. *)
PROCEDURE ReadUntilPong(conn: TCP.T; VAR buf: TEXT): ClientFrame =
  VAR frame: ClientFrame; skips := 0;
  BEGIN
    LOOP
      frame := ReadOneClientFrame(conn, buf);
      IF frame.opcode = ConvexWebSocket.OpPong THEN RETURN frame; END;
      INC(skips);
      IF skips > 10 THEN
        IO.Put("fixture: FAIL never saw a Pong (skipped " & Text.FromChar(VAL(skips + ORD('0'), CHAR))
               & " other client frame(s) first)\n");
        Process.Exit(1);
      END;
    END;
  END ReadUntilPong;

(* Linux sends an RST instead of a clean FIN when a socket is close(2)d
   while bytes the peer sent are still sitting unread in its receive
   buffer -- and every scenario's client writes at least a "Connect"
   sync-protocol message right after the handshake, which this fixture
   never has a reason to read otherwise. Without draining that first,
   the RST would race the client's own next write or read and surface
   as a spurious TransportError that has nothing to do with what the
   scenario actually means to test. Best-effort and tolerant of any
   failure: by the time this runs, the scripted scenario is already
   over and there is nothing left to assert. *)
PROCEDURE DrainBestEffort(conn: TCP.T) =
  VAR buf: REF ARRAY OF CHAR := NEW(REF ARRAY OF CHAR, 65536); n: CARDINAL;
  BEGIN
    TRY
      LOOP
        n := conn.get(buf^, 0.3d0);
        IF n = 0 THEN EXIT; END;
      END;
    EXCEPT
    | Thread.Alerted =>
    ELSE
    END;
  END DrainBestEffort;

(* -- the HTTP Upgrade handshake, shared by every scenario ------------- *)

PROCEDURE DoHandshake(conn: TCP.T; wrongAccept: BOOLEAN): TEXT =
  VAR req := ReadUntil(conn, "\r\n\r\n");
      hb: ConvexWire.HeaderBlock;
      key, accept: TEXT;
      resp := TextWr.New();
  BEGIN
    VAR blankAt := ConvexWire.Find(req, "\r\n\r\n", 0);
        headerText := Text.Sub(req, 0, blankAt + 2);
    BEGIN
      key := ConvexWire.HeaderValue(headerText, "sec-websocket-key");
    END;
    IF wrongAccept THEN
      accept := "not-the-right-accept-value=";
    ELSE
      accept := ConvexWebSocket.ComputeAccept(key);
    END;
    Wr.PutText(resp, "HTTP/1.1 101 Switching Protocols\r\n");
    Wr.PutText(resp, "Upgrade: websocket\r\n");
    Wr.PutText(resp, "Connection: Upgrade\r\n");
    Wr.PutText(resp, "Sec-WebSocket-Accept: " & accept & "\r\n\r\n");
    WriteAll(conn, TextWr.ToText(resp));
    RETURN key;
  END DoHandshake;

(* -- scenarios ---------------------------------------------------------

   "happy": one complete Transition frame, then a fragmented Transition
   (2 frames) with a Ping interleaved between them (the client must
   answer with an exact Pong before the fixture sends the closing
   fragment), then a fragmented Transition whose JSON string value
   splits a two-byte UTF-8 codepoint exactly across the frame
   boundary, then Close.

   "wrongaccept": the handshake response's Sec-WebSocket-Accept does
   not match the client's key.

   "invalidutf8": a fragmented message whose reassembled bytes are not
   valid UTF-8 (an overlong two-byte encoding of NUL, C0 80), split so
   neither fragment alone reveals that on its own.
   ---------------------------------------------------------------- *)

PROCEDURE RunHappy(conn: TCP.T) =
  VAR clientBuf := "";
  BEGIN
    EVAL DoHandshake(conn, FALSE);

    (* One complete message: queryId 0 (the test's only Add) updates to 42. *)
    WriteAll(conn, BuildServerFrame(TRUE, ConvexWebSocket.OpText,
      "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}," &
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"}," &
      "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":42,\"logLines\":[]}]}"));

    (* A fragmented message (2 data frames) with a Ping interleaved
       between them. The split point ("foo" | "bar") is arbitrary --
       what matters is that it lands mid-message, not on a JSON token
       boundary. *)
    VAR whole := "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"}," &
                 "\"endVersion\":{\"querySet\":2,\"identity\":0,\"ts\":\"AgAAAAAAAAA=\"}," &
                 "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":43,\"logLines\":[]}]}";
        splitAt := 20;
    BEGIN
      WriteAll(conn, BuildServerFrame(FALSE, ConvexWebSocket.OpText, Text.Sub(whole, 0, splitAt)));
      WriteAll(conn, BuildServerFrame(TRUE, ConvexWebSocket.OpPing, "pingpayload"));
      VAR pong := ReadUntilPong(conn, clientBuf);
      BEGIN
        IF pong.opcode # ConvexWebSocket.OpPong OR NOT Text.Equal(pong.payload, "pingpayload") THEN
          IO.Put("fixture: FAIL expected an exact Pong(\"pingpayload\") interleaved mid-fragmentation, got opcode "
                 & Text.FromChar(VAL(pong.opcode + ORD('0'), CHAR)) & " payload " & pong.payload & "\n");
          Process.Exit(1);
        END;
        IO.Put("fixture: got the expected interleaved Pong\n");
      END;
      WriteAll(conn, BuildServerFrame(TRUE, ConvexWebSocket.OpContinuation, Text.Sub(whole, splitAt, LAST(CARDINAL))));
    END;

    (* A fragmented message whose JSON string value is "h" + U+00E9
       ("e" with an acute accent, UTF-8 C3 A9) + "llo", split so the
       first fragment ends right after the 0xC3 leading byte and the
       second fragment starts with the 0xA9 continuation byte -- valid
       UTF-8 only once both fragments are joined. *)
    VAR utf8Value := Text.FromChars(ARRAY OF CHAR{'h', VAL(16_C3, CHAR), VAL(16_A9, CHAR), 'l', 'l', 'o'});
        prefix := "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":2,\"identity\":0,\"ts\":\"AgAAAAAAAAA=\"}," &
                  "\"endVersion\":{\"querySet\":3,\"identity\":0,\"ts\":\"AwAAAAAAAAA=\"}," &
                  "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":\"";
        suffix := "\",\"logLines\":[]}]}";
        frag1 := prefix & Text.Sub(utf8Value, 0, 2); (* ends right after 0xC3 *)
        frag2 := Text.Sub(utf8Value, 2, LAST(CARDINAL)) & suffix;
    BEGIN
      WriteAll(conn, BuildServerFrame(FALSE, ConvexWebSocket.OpText, frag1));
      WriteAll(conn, BuildServerFrame(TRUE, ConvexWebSocket.OpContinuation, frag2));
    END;

    WriteAll(conn, BuildServerFrame(TRUE, ConvexWebSocket.OpClose, ""));
    IO.Put("fixture: happy scenario complete\n");
  END RunHappy;

PROCEDURE RunWrongAccept(conn: TCP.T) =
  BEGIN
    EVAL DoHandshake(conn, TRUE);
    IO.Put("fixture: wrongaccept scenario sent a deliberately wrong Sec-WebSocket-Accept\n");
  END RunWrongAccept;

PROCEDURE RunInvalidUtf8(conn: TCP.T) =
  BEGIN
    EVAL DoHandshake(conn, FALSE);
    (* C0 80 is an overlong two-byte encoding of NUL: never valid
       UTF-8, but neither single byte looks obviously wrong on its
       own, and the split lands between them so no individual
       fragment's bytes reveal the violation before reassembly. *)
    WriteAll(conn, BuildServerFrame(FALSE, ConvexWebSocket.OpText, Text.FromChar(VAL(16_C0, CHAR))));
    WriteAll(conn, BuildServerFrame(TRUE, ConvexWebSocket.OpContinuation, Text.FromChar(VAL(16_80, CHAR))));
    IO.Put("fixture: invalidutf8 scenario complete\n");
  END RunInvalidUtf8;

VAR
  scenario := Params.Get(1);
  port := ParsePort(Params.Get(2));
  connector := TCP.NewConnector(IP.Endpoint{addr := IP.NullAddress, port := port});
  conn: TCP.T;
BEGIN
  IO.Put("fixture: listening on 127.0.0.1:" & Params.Get(2) & ", scenario " & scenario & "\n");
  conn := TCP.Accept(connector);
  IF Text.Equal(scenario, "happy") THEN
    RunHappy(conn);
  ELSIF Text.Equal(scenario, "wrongaccept") THEN
    RunWrongAccept(conn);
  ELSIF Text.Equal(scenario, "invalidutf8") THEN
    RunInvalidUtf8(conn);
  ELSE
    IO.Put("fixture: unknown scenario " & scenario & "\n");
    Process.Exit(1);
  END;
  DrainBestEffort(conn);
  TCP.Close(conn);
  TCP.CloseConnector(connector);
END WsFixture.
