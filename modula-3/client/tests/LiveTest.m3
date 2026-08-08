(* LiveTest - drives a real ConvexLive.T over loopback TCP against
   WsFixture, proving the behaviour that only shows up once frames
   travel through a real socket and ConvexLive's own DrainFrames loop:
   fragmentation reassembly, a Ping answered correctly while a message
   is only half-reassembled, UTF-8 validated once after reassembly
   (not per fragment), and a wrong Sec-WebSocket-Accept being rejected
   before any application data is trusted. Each scenario is a fresh
   process against a fresh WsFixture process (see the Dockerfile),
   matching WsFixture's one-shot, one-connection design. *)
MODULE LiveTest EXPORTS Main;

IMPORT IO, Text, Time, Params, Process, ConvexJson, ConvexLive;

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

(* A crashed test binary (e.g. from indexing a field a RECORD kind
   promises is only meaningful for the other kind) is a much worse
   failure report than a clear mismatch message, so every assertion
   below checks "kind" before touching a kind-specific field and
   describes whatever it actually got instead. *)
PROCEDURE DescribeEvent(e: ConvexLive.Event): TEXT =
  BEGIN
    IF e.kind = ConvexLive.EventKind.Error THEN
      RETURN "Error(" & e.errName & ": " & e.errMessage & ")";
    ELSE
      RETURN "Update";
    END;
  END DescribeEvent;

PROCEDURE Contains(haystack: TEXT; needle: TEXT): BOOLEAN =
  VAR hn := Text.Length(haystack); nn := Text.Length(needle);
  BEGIN
    IF nn = 0 THEN RETURN TRUE; END;
    IF nn > hn THEN RETURN FALSE; END;
    FOR i := 0 TO hn - nn DO
      VAR ok := TRUE;
      BEGIN
        FOR j := 0 TO nn - 1 DO
          IF Text.GetChar(haystack, i + j) # Text.GetChar(needle, j) THEN ok := FALSE; EXIT; END;
        END;
        IF ok THEN RETURN TRUE; END;
      END;
    END;
    RETURN FALSE;
  END Contains;

(* Collect events by calling Poll repeatedly until either "want" events
   have arrived or "deadlineSeconds" (wall-clock, from Time.Now()) has
   elapsed -- a fixture reply can legitimately take more than one Poll
   call to fully arrive (e.g. the Ping/Pong round trip in the middle of
   a fragmented message), so a single Poll call is not enough. *)
PROCEDURE Collect(live: ConvexLive.T; want: INTEGER; deadlineSeconds: LONGREAL): REF ARRAY OF ConvexLive.Event =
  VAR out := NEW(REF ARRAY OF ConvexLive.Event, want); got := 0;
      deadline := Time.Now() + deadlineSeconds;
  BEGIN
    (* Every slot starts as a recognizable sentinel, not a zero-valued
       Event (whose "kind" would default to Update with a NIL value) --
       a caller that ends up indexing a slot Poll never filled in time
       must see an obviously-fake failure, not crash dereferencing NIL
       or silently read as a false Update. *)
    FOR i := 0 TO want - 1 DO
      out[i] := ConvexLive.Event{
        kind := ConvexLive.EventKind.Error, subscriptionId := NIL, value := NIL, logLines := NIL,
        errName := "TestTimeout", errMessage := "Collect's deadline passed before this event arrived", errData := NIL};
    END;
    WHILE got < want AND Time.Now() < deadline DO
      VAR batch := ConvexLive.Poll(live, 2000);
      BEGIN
        FOR i := 0 TO batch.count - 1 DO
          IF got < want THEN out[got] := batch.events[i]; INC(got); END;
        END;
      END;
    END;
    IF got < want THEN
      IO.Put("FAIL: only " & Text.FromChar(VAL(got + ORD('0'), CHAR)) &
             " of the expected " & Text.FromChar(VAL(want + ORD('0'), CHAR)) & " events arrived\n");
      INC(failures);
    END;
    RETURN out;
  END Collect;

PROCEDURE RunHappy(url: TEXT) =
  VAR live := ConvexLive.New(url);
      events: REF ARRAY OF ConvexLive.Event;
  BEGIN
    ConvexLive.Add(live, "sub1", "test:path", ConvexJson.NewObject());
    Check(ConvexLive.IsConnected(live), "the handshake against a correctly-accepting fixture succeeds");

    events := Collect(live, 3, 15.0d0);

    IF events[0].kind = ConvexLive.EventKind.Update THEN
      Check(TRUE, "event 1 is an Update (one complete frame)");
      Check(ConvexJson.NumOf(events[0].value) = 42.0d0, "event 1's value is the complete-frame Transition's 42");
    ELSE
      Check(FALSE, "event 1 is an Update (one complete frame) -- got " & DescribeEvent(events[0]));
    END;

    IF events[1].kind = ConvexLive.EventKind.Update THEN
      Check(TRUE, "event 2 is an Update (fragmented message, Ping interleaved mid-fragmentation)");
      Check(ConvexJson.NumOf(events[1].value) = 43.0d0,
            "event 2's value survived fragmentation reassembly with an interleaved Ping/Pong");
    ELSE
      Check(FALSE, "event 2 is an Update (fragmented message, Ping interleaved mid-fragmentation) -- got "
                   & DescribeEvent(events[1]));
    END;

    IF events[2].kind = ConvexLive.EventKind.Update THEN
      Check(TRUE, "event 3 is an Update (fragmented message split mid-UTF-8-codepoint)");
      Check(Text.Equal(ConvexJson.StrOf(events[2].value), "h\303\251llo"),
            "event 3's value reassembled the codepoint split across the frame boundary correctly");
    ELSE
      Check(FALSE, "event 3 is an Update (fragmented message split mid-UTF-8-codepoint) -- got "
                   & DescribeEvent(events[2]));
    END;

    ConvexLive.Close(live);
  END RunHappy;

PROCEDURE RunWrongAccept(url: TEXT) =
  VAR live := ConvexLive.New(url);
      batch: ConvexLive.EventBatch;
  BEGIN
    ConvexLive.Add(live, "sub1", "test:path", ConvexJson.NewObject());
    Check(NOT ConvexLive.IsConnected(live), "a wrong Sec-WebSocket-Accept must not leave the client connected");
    Check(ConvexLive.ConnectionCount(live) = 1, "the failed handshake still counts as one connection attempt");

    batch := ConvexLive.Poll(live, 100);
    Check(batch.count = 1, "the handshake failure is delivered as exactly one pending event, not silently dropped");
    IF batch.count >= 1 AND batch.events[0].kind = ConvexLive.EventKind.Error THEN
      Check(TRUE, "the event reports failure");
      Check(Text.Equal(batch.events[0].errName, "ProtocolError"),
            "a Sec-WebSocket-Accept mismatch is a ProtocolError, not a TransportError");
      Check(Contains(batch.events[0].errMessage, "Accept"),
            "the error message names what actually failed (Sec-WebSocket-Accept)");
    ELSIF batch.count >= 1 THEN
      Check(FALSE, "the event reports failure -- got " & DescribeEvent(batch.events[0]));
    END;

    ConvexLive.Close(live);
  END RunWrongAccept;

PROCEDURE RunInvalidUtf8(url: TEXT) =
  VAR live := ConvexLive.New(url);
      events: REF ARRAY OF ConvexLive.Event;
  BEGIN
    ConvexLive.Add(live, "sub1", "test:path", ConvexJson.NewObject());
    Check(ConvexLive.IsConnected(live), "the handshake itself succeeds; only the later message is invalid -- lastCloseReason="
                                          & ConvexLive.LastCloseReason(live));

    events := Collect(live, 1, 15.0d0);
    IF events[0].kind = ConvexLive.EventKind.Error THEN
      Check(TRUE, "a fragmented message that is not valid UTF-8 once reassembled is reported as a failure");
      Check(Text.Equal(events[0].errName, "ProtocolError"), "invalid UTF-8 after reassembly is a ProtocolError");
      Check(Contains(events[0].errMessage, "UTF-8"),
            "the error message names what actually failed (not valid UTF-8), proving this was" &
            " caught after reassembly and not misreported as something else");
    ELSE
      Check(FALSE, "a fragmented message that is not valid UTF-8 once reassembled is reported as a failure -- got "
                   & DescribeEvent(events[0]));
    END;

    ConvexLive.Close(live);
  END RunInvalidUtf8;

VAR
  scenario := Params.Get(1);
  url := "ws://127.0.0.1:" & Params.Get(2) & "/api/sync";
BEGIN
  IF Text.Equal(scenario, "happy") THEN
    RunHappy(url);
  ELSIF Text.Equal(scenario, "wrongaccept") THEN
    RunWrongAccept(url);
  ELSIF Text.Equal(scenario, "invalidutf8") THEN
    RunInvalidUtf8(url);
  ELSE
    IO.Put("LiveTest: unknown scenario " & scenario & "\n");
    Process.Exit(1);
  END;

  IF failures = 0 THEN
    IO.Put("PASS LiveTest " & scenario & "\n");
    Process.Exit(0);
  ELSE
    IO.Put("LiveTest " & scenario & ": failures present\n");
    Process.Exit(1);
  END;
END LiveTest.
