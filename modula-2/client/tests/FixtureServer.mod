(* FixtureServer is a standalone, test-only executable: it runs the server
   side of one Convex /api/sync WebSocket session on 127.0.0.1, scripted
   just enough to exercise this client's Live acceptance behaviour end to
   end (see AGENTS.md). It is not part of the public client; the Docker
   test stage runs it as a background process alongside TestLive, the
   same two-process pattern this project's other compiled clients use for
   deterministic Live tests, because proving a real reconnect needs two
   independently scheduled peers, not two threads pretending to be one.
 *
 * Script: accept connection 1, read Connect, read one ModifyQuerySet
 * carrying both subscriptions' Add (room "x" and a demo:requiresNonzero
 * style room "y" that is expected to fail), send a Transition with x's
 * count 0, send a QueryFailed for y, send a QueryUpdated with x's count
 * 1 (the "external update"), then close the connection abruptly (no
 * close frame) to force a client reconnect; accept connection 2, expect
 * one ModifyQuerySet resending both Adds, send a fresh Transition with
 * x's count still 1 (unchanged - this must not surface as a new event),
 * then a QueryUpdated with y's count 2 (recovered), then stop. *)
MODULE FixtureServer;

FROM ConvexFixture IMPORT Listen, Accept, ReceiveText, SendText, CloseAbruptly, StopListening;
FROM ConvexJSON IMPORT Member, ArrayBegin, ArrayNext, ParseNonNegativeInt;
FROM CShim IMPORT ShimExit;
FROM STextIO IMPORT WriteString, WriteLn;

VAR
  msg: ARRAY [0..8191] OF CHAR;
  out: ARRAY [0..8191] OF CHAR;
  outLen: INTEGER;
  typeRaw: ARRAY [0..63] OF CHAR;
  found: BOOLEAN;
  queryIdX, queryIdY: INTEGER;

PROCEDURE Log (text: ARRAY OF CHAR);
BEGIN
  WriteString("fixture: "); WriteString(text); WriteLn;
END Log;

PROCEDURE Die (text: ARRAY OF CHAR);
BEGIN
  Log(text);
  ShimExit(1);
END Die;

(* ReadBothAddQueryIds reads one ModifyQuerySet message and returns the
   queryId of each of its two Add modifications, in wire order. This
   fixture's script always subscribes room x before room y, and
   ConvexSync always flushes every pending Add it already knows about
   into one ModifyQuerySet (see ConvexSync.mod's BuildSnapshotAdds), so
   both the very first message and the post-reconnect resend carry
   exactly two Add modifications in that order. *)
PROCEDURE ReadBothAddQueryIds (VAR firstId, secondId: INTEGER);
VAR
  modsText, element, idRaw: ARRAY [0..2047] OF CHAR;
  found2: BOOLEAN;
  cursor, count, parsed: INTEGER;
BEGIN
  IF NOT ReceiveText(10000, msg) THEN Die("did not receive the resent ModifyQuerySet") END;
  IF NOT Member(msg, "modifications", modsText, found2) OR NOT found2 THEN
    Die("ModifyQuerySet omitted modifications");
  END;
  IF NOT ArrayBegin(modsText, cursor) THEN Die("modifications was not an array") END;
  count := 0;
  WHILE ArrayNext(modsText, cursor, element) DO
    IF NOT Member(element, "queryId", idRaw, found2) OR NOT found2 OR NOT ParseNonNegativeInt(idRaw, parsed) THEN
      Die("Add modification omitted a valid queryId");
    END;
    IF count = 0 THEN firstId := parsed ELSE secondId := parsed END;
    INC(count);
  END;
  IF count <> 2 THEN Die("expected exactly two Add modifications") END;
END ReadBothAddQueryIds;

PROCEDURE BuildTransition (queryId, startQuerySet, endQuerySet: INTEGER; count: INTEGER; failed: BOOLEAN);
VAR digits: ARRAY [0..15] OF CHAR; dc, v: INTEGER;

  PROCEDURE Lit (text: ARRAY OF CHAR);
  VAR n, j: INTEGER;
  BEGIN
    n := 0;
    WHILE text[n] <> 0C DO INC(n) END;
    FOR j := 0 TO n - 1 DO out[outLen] := text[j]; INC(outLen) END;
  END Lit;

  PROCEDURE Int (value: INTEGER);
  BEGIN
    IF value = 0 THEN Lit("0"); RETURN END;
    dc := 0; v := value;
    WHILE v > 0 DO digits[dc] := CHR(ORD('0') + CARDINAL(v MOD 10)); v := v DIV 10; INC(dc) END;
    WHILE dc > 0 DO DEC(dc); out[outLen] := digits[dc]; INC(outLen) END;
  END Int;

BEGIN
  outLen := 0;
  Lit('{"type":"Transition","startVersion":{"identity":0,"querySet":');
  Int(startQuerySet);
  Lit(',"ts":"AAAAAAAAAAA="},"endVersion":{"identity":0,"querySet":');
  Int(endQuerySet);
  Lit(',"ts":"AAAAAAAAAAA="},"modifications":[{"queryId":');
  Int(queryId);
  IF failed THEN
    Lit(',"type":"QueryFailed","errorMessage":"room is empty","errorData":{"code":"ROOM_EMPTY"},"logLines":[]');
  ELSE
    Lit(',"type":"QueryUpdated","value":{"count":');
    Int(count);
    Lit('},"logLines":[]');
  END;
  Lit('}]}');
  out[outLen] := 0C;
END BuildTransition;

BEGIN
  IF NOT Listen("127.0.0.1", 19191) THEN Die("listen failed") END;
  Log("listening on 127.0.0.1:19191");

  IF NOT Accept(20000) THEN Die("accept 1 failed") END;
  Log("accepted connection 1");

  IF NOT ReceiveText(10000, msg) THEN Die("did not receive Connect") END;
  IF NOT Member(msg, "type", typeRaw, found) THEN Die("Connect had no type") END;

  ReadBothAddQueryIds(queryIdX, queryIdY);
  Log("received Add for room x and room y");

  BuildTransition(queryIdX, 0, 1, 0, FALSE);
  IF NOT SendText(out, outLen) THEN Die("send initial Transition failed") END;
  Log("sent initial value 0");

  BuildTransition(queryIdY, 1, 2, 0, TRUE);
  IF NOT SendText(out, outLen) THEN Die("send QueryFailed failed") END;
  Log("sent QueryFailed for room y");

  BuildTransition(queryIdX, 2, 3, 1, FALSE);
  IF NOT SendText(out, outLen) THEN Die("send external update failed") END;
  Log("sent external update (count 1)");

  CloseAbruptly;
  Log("closed connection 1 abruptly");

  IF NOT Accept(20000) THEN Die("accept 2 failed") END;
  Log("accepted connection 2 (reconnect)");

  IF NOT ReceiveText(10000, msg) THEN Die("did not receive Connect on reconnect") END;

  ReadBothAddQueryIds(queryIdX, queryIdY);
  Log("client resent both Adds after reconnect");

  BuildTransition(queryIdX, 0, 1, 1, FALSE);
  IF NOT SendText(out, outLen) THEN Die("send post-reconnect value failed") END;
  Log("sent post-reconnect value (count 1, unchanged)");

  BuildTransition(queryIdY, 1, 2, 2, FALSE);
  IF NOT SendText(out, outLen) THEN Die("send recovered room y value failed") END;
  Log("sent recovered room y value (count 2)");

  StopListening;
  Log("done");
END FixtureServer.
