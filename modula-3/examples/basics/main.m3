(* Convex from Modula-3: the shared counter journey.

   Reads a room's counter over Convex's documented HTTP API, starts a
   Live subscription, increments the counter once, and proves that the
   Live subscription reported the same change without polling. This is
   an educational demonstration of a hand-written, from-scratch Convex
   client (see ../../README.md), not an official Convex SDK.

   Run it with:
     CONVEX_URL=https://<deployment>.convex.cloud ./main <room> *)
MODULE main EXPORTS Main;

IMPORT IO, Text, Fmt, Env, Params, Process, Stdio,
       ConvexJson, ConvexHttp, ConvexLive, ConvexRandom;

PROCEDURE Fail(msg: TEXT) =
  BEGIN
    IO.Put("Modula-3 example failed: " & msg & "\n", Stdio.stderr);
    Process.Exit(1);
  END Fail;

(* Decodes the demo counter's "count" field into an idiomatic INTEGER.
   Convex JSON numbers may arrive in an integral decimal form such as
   "0" or "0.0"; both are accepted, but a fractional, non-finite, or
   out-of-range value fails loudly instead of being silently truncated
   -- exactly the regression AGENTS.md calls out, since a mocked
   integer-only fixture would never exercise this path. *)
PROCEDURE DecodeCount(value: ConvexJson.T; context: TEXT): INTEGER =
  VAR countField: ConvexJson.T; raw: LONGREAL;
  BEGIN
    IF value = NIL OR value.kind # ConvexJson.Kind.Obj THEN
      Fail(context & ": expected a JSON object");
    END;
    countField := ConvexJson.ObjectGet(value, "count");
    IF countField = NIL THEN Fail(context & ": missing \"count\""); END;
    TRY
      raw := ConvexJson.NumOf(countField);
    EXCEPT
    | ConvexJson.Error => Fail(context & ": \"count\" was not a JSON number"); raw := 0.0d0;
    END;
    (* Reject non-finite, fractional, and out-of-range values: a
       mathematically integral value comfortably within INTEGER's range
       is the only shape this example accepts. *)
    IF raw # raw THEN Fail(context & ": \"count\" was NaN"); END; (* NaN never equals itself *)
    IF ABS(raw) > 1.0d15 THEN Fail(context & ": \"count\" was out of range"); END;
    IF raw # FLOAT(ROUND(raw), LONGREAL) THEN Fail(context & ": \"count\" was not a whole number"); END;
    RETURN ROUND(raw);
  END DecodeCount;

VAR
  (* -- configuration: the deployment URL is required. The room comes
     from the verifier's first command-line argument (so repeated runs
     never collide), an EXAMPLE_ROOM environment variable for a
     convenient hand run, or a literal fallback so this still does
     something either way. -- *)
  deploymentUrl := Env.Get("CONVEX_URL");
  room: TEXT;
  queryArgs, mutationArgs: ConvexJson.T;
  queryResult: ConvexHttp.CallResult;
  currentCount, liveInitialCount, mutationCount, liveUpdatedCount: INTEGER;
  live: ConvexLive.T;
  runId: TEXT;
  gotInitial, gotUpdated: BOOLEAN;
BEGIN
  IF deploymentUrl = NIL OR Text.Equal(deploymentUrl, "") THEN
    Fail("CONVEX_URL is required");
  END;

  room := NIL;
  IF Params.Count >= 2 THEN room := Params.Get(1); END;
  IF room = NIL OR Text.Equal(room, "") THEN room := Env.Get("EXAMPLE_ROOM"); END;
  IF room = NIL OR Text.Equal(room, "") THEN room := "modula-3-example"; END;

  queryArgs := ConvexJson.NewObject();
  ConvexJson.ObjectSet(queryArgs, "room", ConvexJson.NewString(room));

  (* -- the HTTP query: reads the room's current counter through
     Convex's documented POST /api/query envelope, before anything
     reactive is involved, so the Live subscription below has a known
     value to agree with. -- *)
  queryResult := ConvexHttp.Call("query", "demo:state", queryArgs, deploymentUrl, "");
  IF queryResult.kind # ConvexHttp.ResultKind.Result THEN
    Fail("query: " & queryResult.errMessage);
  END;
  currentCount := DecodeCount(queryResult.value, "current query");
  IO.Put("current count: " & Fmt.Int(currentCount) & "\n");

  (* -- client creation: opens the WebSocket handshake to /api/sync and
     sends the Connect message. No query has been added yet. -- *)
  live := ConvexLive.New(deploymentUrl);

  (* -- starting Live before the mutation: subscribing first is what
     makes the update received below an observation of a real change,
     rather than a race against one that already happened. -- *)
  ConvexLive.Add(live, "counter", "demo:state", queryArgs);
  IF NOT ConvexLive.IsConnected(live) THEN
    Fail("sync connect: " & ConvexLive.LastCloseReason(live));
  END;

  (* -- the initial Live value: the same state the HTTP query above
     already read, delivered this time as the subscription's first
     Transition. -- *)
  gotInitial := FALSE;
  FOR attempt := 1 TO 100 DO
    IF gotInitial THEN EXIT; END;
    VAR batch := ConvexLive.Poll(live, 200);
    BEGIN
      FOR i := 0 TO batch.count - 1 DO
        IF Text.Equal(batch.events[i].subscriptionId, "counter") THEN
          IF batch.events[i].kind = ConvexLive.EventKind.Error THEN
            Fail("initial Live value: " & batch.events[i].errMessage);
          END;
          liveInitialCount := DecodeCount(batch.events[i].value, "initial Live value");
          gotInitial := TRUE;
        END;
      END;
    END;
  END;
  IF NOT gotInitial THEN Fail("initial Live value: timed out waiting for a Transition"); END;
  IF liveInitialCount # currentCount THEN
    Fail("the initial Live count disagreed with HTTP");
  END;
  IO.Put("live initial count: " & Fmt.Int(liveInitialCount) & "\n");

  (* -- the mutation and its idempotency key: runId lets Convex
     recognize a retried request and return the previous result
     instead of incrementing twice. A fresh random key means this run
     really applies its increment rather than replaying an old one. -- *)
  TRY
    runId := ConvexRandom.HexBytes(16);
  EXCEPT
  | ConvexRandom.Error => Fail("could not generate an idempotency key"); runId := "";
  END;
  mutationArgs := ConvexJson.NewObject();
  ConvexJson.ObjectSet(mutationArgs, "room", ConvexJson.NewString(room));
  ConvexJson.ObjectSet(mutationArgs, "language", ConvexJson.NewString("modula-3"));
  ConvexJson.ObjectSet(mutationArgs, "runId", ConvexJson.NewString(runId));

  VAR mutationResult := ConvexHttp.Call("mutation", "demo:increment", mutationArgs, deploymentUrl, "");
  BEGIN
    IF mutationResult.kind # ConvexHttp.ResultKind.Result THEN
      Fail("mutation: " & mutationResult.errMessage);
    END;
    VAR appliedField := ConvexJson.ObjectGet(mutationResult.value, "applied");
        applied := FALSE;
    BEGIN
      IF appliedField # NIL THEN
        TRY applied := ConvexJson.BoolOf(appliedField); EXCEPT | ConvexJson.Error => applied := FALSE; END;
      END;
      IF NOT applied THEN Fail("the mutation was not applied"); END;
    END;
    mutationCount := DecodeCount(ConvexJson.ObjectGet(mutationResult.value, "state"), "mutation");
  END;
  IF mutationCount # currentCount + 1 THEN
    Fail("the mutation returned an unexpected count");
  END;
  IO.Put("mutation applied: true\n");
  IO.Put("mutation count: " & Fmt.Int(mutationCount) & "\n");

  (* -- the resulting Live update: received over the same subscription,
     without polling HTTP again. -- *)
  gotUpdated := FALSE;
  FOR attempt := 1 TO 100 DO
    IF gotUpdated THEN EXIT; END;
    VAR batch := ConvexLive.Poll(live, 200);
    BEGIN
      FOR i := 0 TO batch.count - 1 DO
        IF Text.Equal(batch.events[i].subscriptionId, "counter") THEN
          IF batch.events[i].kind = ConvexLive.EventKind.Error THEN
            Fail("updated Live value: " & batch.events[i].errMessage);
          END;
          liveUpdatedCount := DecodeCount(batch.events[i].value, "updated Live value");
          gotUpdated := TRUE;
        END;
      END;
    END;
  END;
  IF NOT gotUpdated THEN Fail("updated Live value: timed out waiting for a Transition"); END;
  IF liveUpdatedCount # currentCount + 1 THEN
    Fail("the updated Live count disagreed with the mutation");
  END;
  IO.Put("live updated count: " & Fmt.Int(liveUpdatedCount) & "\n");

  (* Every operation above agreed before this proof line is printed. *)
  IO.Put("verified count: " & Fmt.Int(currentCount) & " -> " & Fmt.Int(liveUpdatedCount) & "\n");

  (* -- cleanup: close the Live connection cleanly before exiting. -- *)
  ConvexLive.Close(live);
END main.
