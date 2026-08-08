(* WebsocketTest - language-local coverage for ConvexWebSocket.m3's pure
   framing logic: no network, no fixture peer. Everything that touches a
   real socket (the handshake itself, fragmentation reassembly across
   real reads, interleaved control frames, and once-after-reassembly
   UTF-8 validation, all of which live in ConvexLive rather than here)
   is covered instead by LiveTest against WsFixture. *)
MODULE WebsocketTest EXPORTS Main;

IMPORT IO, Text, Word, Process, ConvexWebSocket;

VAR failures: INTEGER := 0;

PROCEDURE Check(cond: BOOLEAN; msg: TEXT) =
  BEGIN
    IF cond THEN
      IO.Put("PASS: " & msg & "\n");
    ELSE
      IO.Put("FAIL: " & msg & "\n");
      INC(failures);
    END;
  END Check;

(* Reverse BuildFrame's masking so a test can recover the original
   payload bytes and confirm the mask actually changed them on the
   wire, rather than merely trusting BuildFrame's own idea of what it
   sent. *)
PROCEDURE UnmaskPayload(mask: ARRAY [0..3] OF CHAR; payload: TEXT): TEXT =
  VAR n := Text.Length(payload); out: ARRAY [0..4095] OF CHAR;
  BEGIN
    FOR i := 0 TO n - 1 DO
      out[i] := VAL(Word.Xor(ORD(mask[i MOD 4]), ORD(Text.GetChar(payload, i))), CHAR);
    END;
    RETURN Text.FromChars(SUBARRAY(out, 0, n));
  END UnmaskPayload;

PROCEDURE TestSecWebSocketAccept() =
  BEGIN
    (* RFC 6455 section 1.3's own worked example. *)
    Check(Text.Equal(
            ConvexWebSocket.ComputeAccept("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
          "ComputeAccept matches the RFC 6455 worked example");
  END TestSecWebSocketAccept;

PROCEDURE TestMasking() =
  VAR frame := ConvexWebSocket.BuildFrame(ConvexWebSocket.OpText, "hello");
      byte0 := ORD(Text.GetChar(frame, 0));
      byte1 := ORD(Text.GetChar(frame, 1));
      mask: ARRAY [0..3] OF CHAR;
      recovered: TEXT;
  BEGIN
    Check(Word.And(byte0, 16_80) # 0, "BuildFrame sets FIN");
    Check(Word.And(byte0, 16_0F) = ConvexWebSocket.OpText, "BuildFrame keeps the requested opcode");
    Check(Word.And(byte1, 16_80) # 0, "BuildFrame sets the MASK bit -- clients must always mask");
    Check(Word.And(byte1, 16_7F) = 5, "unmasked 7-bit length field is the payload length");

    FOR i := 0 TO 3 DO mask[i] := Text.GetChar(frame, 2 + i); END;
    recovered := UnmaskPayload(mask, Text.Sub(frame, 6, 5));
    Check(Text.Equal(recovered, "hello"), "unmasking BuildFrame's output recovers the original payload");
    (* A masked frame is not just the payload sitting in the clear: at
       least one byte must actually have changed, or the "mask" proved
       nothing. *)
    Check(NOT Text.Equal(Text.Sub(frame, 6, 5), "hello"),
          "the masked bytes on the wire differ from the plaintext payload");
  END TestMasking;

PROCEDURE TestParseShortLength() =
  VAR frame := ConvexWebSocket.BuildFrame(ConvexWebSocket.OpBinary, "abc");
      (* BuildFrame always masks; TryParseFrame is the receive-side
         parser and expects unmasked server frames (RFC 6455 section
         5.1), so exercise it against a hand-built unmasked frame
         instead of BuildFrame's own (client-side) output. *)
      unmasked := Text.FromChars(ARRAY OF CHAR{VAL(16_80 + ConvexWebSocket.OpBinary, CHAR), VAL(3, CHAR), 'a', 'b', 'c'});
      pr: ConvexWebSocket.ParseResult;
  BEGIN
    pr := ConvexWebSocket.TryParseFrame(unmasked);
    Check(pr.ok, "a complete short frame parses");
    Check(pr.consumed = 5, "a complete short frame consumes exactly header+payload");
    Check(pr.frame.fin, "FIN bit round-trips");
    Check(pr.frame.opcode = ConvexWebSocket.OpBinary, "opcode round-trips");
    Check(Text.Equal(pr.frame.payload, "abc"), "short-length payload round-trips");
  END TestParseShortLength;

PROCEDURE TestParseExtended16() =
  VAR payload: ARRAY [0..199] OF CHAR;
      buf: ARRAY [0..203] OF CHAR;
      pr: ConvexWebSocket.ParseResult;
  BEGIN
    FOR i := 0 TO 199 DO payload[i] := 'x'; END;
    buf[0] := VAL(16_80 + ConvexWebSocket.OpText, CHAR);
    buf[1] := VAL(126, CHAR); (* 16-bit extended length follows *)
    buf[2] := VAL(0, CHAR);
    buf[3] := VAL(200, CHAR);
    FOR i := 0 TO 199 DO buf[4 + i] := payload[i]; END;
    pr := ConvexWebSocket.TryParseFrame(Text.FromChars(buf));
    Check(pr.ok, "a 16-bit extended-length frame parses");
    Check(pr.consumed = 204, "a 16-bit extended-length frame consumes header+payload");
    Check(Text.Length(pr.frame.payload) = 200, "16-bit extended length decodes to the right payload size");
  END TestParseExtended16;

PROCEDURE TestParseNeedsMoreBytes() =
  VAR pr: ConvexWebSocket.ParseResult;
  BEGIN
    pr := ConvexWebSocket.TryParseFrame(Text.FromChars(ARRAY OF CHAR{VAL(16_80 + ConvexWebSocket.OpText, CHAR), VAL(5, CHAR), 'h', 'e'}));
    Check(NOT pr.ok, "a truncated frame (header claims 5 bytes, only 2 present) reports not-yet-ok");
  END TestParseNeedsMoreBytes;

PROCEDURE TestRejectsMaskedServerFrame() =
  VAR raised := FALSE;
  BEGIN
    TRY
      EVAL ConvexWebSocket.TryParseFrame(
             Text.FromChars(ARRAY OF CHAR{
               VAL(16_80 + ConvexWebSocket.OpText, CHAR),
               VAL(16_80 + 3, CHAR), (* MASK bit set: never legal from a server *)
               '0', '0', '0', '0', 'a', 'b', 'c'}));
    EXCEPT
    | ConvexWebSocket.Error => raised := TRUE;
    END;
    Check(raised, "a masked frame claiming to be from the server is rejected (RFC 6455 5.1)");
  END TestRejectsMaskedServerFrame;

BEGIN
  TestSecWebSocketAccept();
  TestMasking();
  TestParseShortLength();
  TestParseExtended16();
  TestParseNeedsMoreBytes();
  TestRejectsMaskedServerFrame();
  IF failures = 0 THEN
    IO.Put("PASS WebsocketTest\n");
    Process.Exit(0);
  ELSE
    IO.Put("WebsocketTest: " & Text.FromChar(VAL(failures + ORD('0'), CHAR)) & " failure(s)\n");
    Process.Exit(1);
  END;
END WebsocketTest.
