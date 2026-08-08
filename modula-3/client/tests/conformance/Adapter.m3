(* Adapter - the NDJSON adapter protocol v1 conformance executable for
   the shared controller (see AGENTS.md's "Conformance executable"
   section and _shared/schemas/adapter.schema.json). Test
   infrastructure, not public client code: it wraps client/ConvexHttp
   and client/ConvexLive and speaks the shared harness's line-oriented
   protocol either over stdin/stdout, or over a single TCP connection
   when ADAPTER_LISTEN names a "host:port" to listen on. Reserves
   stdout (or the accepted controller socket) strictly for protocol
   events; every diagnostic goes to stderr.

   This process is single-threaded, so the main loop below interleaves
   pumping ConvexLive (its own module comment explains why "one worker
   owns the socket" needs no locking when there is only ever one
   thread calling it in the first place) with reading at most one
   controller command per pass. Both are given short per-pass budgets
   so neither one starves the other: a slow controller does not delay
   a subscription's next Poll for long, and a quiet Live connection
   does not delay noticing the next command for long either. *)
MODULE Adapter EXPORTS Main;

IMPORT IO, Text, Time, Thread, Env, Process,
       IP, TCP, Rd, Wr, Stdio,
       ConvexJson, ConvexHttp, ConvexLive;

CONST
  ClientTag = "modula-3-0.1.0";
  RuntimeTag = "CM3 d5.12.0";
  QueueMaxCount = 8;
  QueueMaxBytes = 4194304; (* 4 MiB -- comfortably inside the shared 128 MiB
                               adapter limit even under a stopped reader with
                               near-maximum messages; see AGENTS.md. *)
  LivePollMs = 100;
  ReadSliceMs = 200;

TYPE
  QueueEntry = RECORD text: TEXT; droppable: BOOLEAN; END;

  State = REF RECORD
    deploymentUrl: TEXT;
    live: ConvexLive.T := NIL; (* created lazily on the first "subscribe" *)
    token: TEXT := "";
    useTcp: BOOLEAN;
    conn: TCP.T := NIL; (* valid iff useTcp *)
    listener: TCP.Connector := NIL;
    readBuf: TEXT := "";
    queue: REF ARRAY OF QueueEntry;
    queueLen: INTEGER := 0;
    queueBytes: INTEGER := 0;
    done: BOOLEAN := FALSE;
  END;

(* -- transport: stdin/stdout, or one accepted TCP peer used for both
      directions ------------------------------------------------------ *)

PROCEDURE ParsePort(s: TEXT): IP.Port =
  VAR n := 0;
  BEGIN
    FOR i := 0 TO Text.Length(s) - 1 DO n := n * 10 + (ORD(Text.GetChar(s, i)) - ORD('0')); END;
    RETURN n;
  END ParsePort;

(* "listenSpec" is "host:port"; this adapter only ever needs to bind
   the wildcard address (the shared harness always connects from the
   same container), so only the port half is used. *)
PROCEDURE PortOf(listenSpec: TEXT): IP.Port =
  VAR colon := -1;
  BEGIN
    FOR i := 0 TO Text.Length(listenSpec) - 1 DO
      IF Text.GetChar(listenSpec, i) = ':' THEN colon := i; END;
    END;
    IF colon < 0 THEN RETURN ParsePort(listenSpec); END;
    RETURN ParsePort(Text.Sub(listenSpec, colon + 1, LAST(CARDINAL)));
  END PortOf;

PROCEDURE OpenTransport(st: State; listenSpec: TEXT): BOOLEAN =
  BEGIN
    IF listenSpec = NIL OR Text.Equal(listenSpec, "") THEN
      st.useTcp := FALSE;
      RETURN TRUE;
    END;
    st.useTcp := TRUE;
    TRY
      st.listener := TCP.NewConnector(IP.Endpoint{addr := IP.NullAddress, port := PortOf(listenSpec)});
      st.conn := TCP.Accept(st.listener);
    EXCEPT
    | IP.Error(ec) => IO.Put("adapter: listen/accept failed on " & listenSpec & "\n"); RETURN FALSE;
    | Thread.Alerted => IO.Put("adapter: listen/accept alerted\n"); RETURN FALSE;
    END;
    RETURN TRUE;
  END OpenTransport;

(* Reads one chunk of the transport, waiting at most "timeoutSeconds".
   Sets "closed" on a clean peer close; any other failure (including a
   plain timeout) is folded into "no new bytes this pass" so the main
   loop's own deadline logic is the single place that decides when to
   give up, matching ConvexTransport.Read's own timeout-vs-failure
   split for the real client. *)
PROCEDURE ReadChunk(st: State; timeoutSeconds: LONGREAL; VAR (*out*) closed: BOOLEAN): TEXT =
  VAR buf: REF ARRAY OF CHAR := NEW(REF ARRAY OF CHAR, 65536); n: CARDINAL;
  BEGIN
    closed := FALSE;
    TRY
      n := st.conn.get(buf^, timeoutSeconds);
    EXCEPT
    | Thread.Alerted => RETURN "";
    ELSE RETURN "";
    END;
    IF n = 0 THEN closed := TRUE; RETURN ""; END;
    RETURN Text.FromChars(SUBARRAY(buf^, 0, n));
  END ReadChunk;

(* Returns ["ok", line], ["timeout", NIL], or ["eof", NIL]. *)
PROCEDURE ReadCommand(st: State; budgetSeconds: LONGREAL; VAR (*out*) outcome: TEXT): TEXT =
  VAR deadline := Time.Now() + budgetSeconds; closed: BOOLEAN;
  BEGIN
    IF NOT st.useTcp THEN
      TRY
        outcome := "ok";
        RETURN Rd.GetLine(Stdio.stdin);
      EXCEPT
      | Rd.EndOfFile => outcome := "eof"; RETURN NIL;
      | Rd.Failure => outcome := "eof"; RETURN NIL;
      | Thread.Alerted => outcome := "eof"; RETURN NIL;
      END;
    END;

    LOOP
      VAR nl := FindChar(st.readBuf, '\n');
      BEGIN
        IF nl >= 0 THEN
          VAR line := Text.Sub(st.readBuf, 0, nl);
          BEGIN
            IF Text.Length(line) > 0 AND Text.GetChar(line, Text.Length(line) - 1) = '\r' THEN
              line := Text.Sub(line, 0, Text.Length(line) - 1);
            END;
            st.readBuf := Text.Sub(st.readBuf, nl + 1, LAST(CARDINAL));
            outcome := "ok";
            RETURN line;
          END;
        END;
      END;
      VAR remaining := deadline - Time.Now();
      BEGIN
        IF remaining <= 0.0d0 THEN outcome := "timeout"; RETURN NIL; END;
        VAR sliceSeconds := remaining;
        BEGIN
          IF sliceSeconds > FLOAT(ReadSliceMs, LONGREAL) / 1000.0d0 THEN
            sliceSeconds := FLOAT(ReadSliceMs, LONGREAL) / 1000.0d0;
          END;
          VAR chunk := ReadChunk(st, sliceSeconds, closed);
          BEGIN
            IF closed THEN outcome := "eof"; RETURN NIL; END;
            st.readBuf := st.readBuf & chunk;
          END;
        END;
      END;
    END;
  END ReadCommand;

PROCEDURE FindChar(s: TEXT; c: CHAR): INTEGER =
  BEGIN
    FOR i := 0 TO Text.Length(s) - 1 DO
      IF Text.GetChar(s, i) = c THEN RETURN i; END;
    END;
    RETURN -1;
  END FindChar;

PROCEDURE WriteLineRaw(st: State; line: TEXT) =
  VAR data := line & "\n"; n := Text.Length(data); buf: REF ARRAY OF CHAR;
  BEGIN
    IF NOT st.useTcp THEN
      TRY
        Wr.PutText(Stdio.stdout, data);
        Wr.Flush(Stdio.stdout);
      EXCEPT
      | Wr.Failure => st.done := TRUE;
      | Thread.Alerted => st.done := TRUE;
      END;
      RETURN;
    END;
    buf := NEW(REF ARRAY OF CHAR, n);
    Text.SetChars(buf^, data);
    TRY
      st.conn.put(buf^);
    EXCEPT
    | Thread.Alerted => st.done := TRUE;
    ELSE st.done := TRUE;
    END;
  END WriteLineRaw;

(* -- the bounded output queue: 8 slots, a 4 MiB byte budget. Subscription
      events are droppable (oldest-first); hello/result/error/ack/closed
      responses are not, and if the budget cannot be freed without
      dropping one of those, the adapter fails loudly rather than
      growing without bound. -------------------------------------------- *)

PROCEDURE Charge(text: TEXT): INTEGER = BEGIN RETURN Text.Length(text) + 64; END Charge;

PROCEDURE DropOldest(st: State): BOOLEAN =
  VAR i := 0;
  BEGIN
    WHILE i < st.queueLen DO
      IF st.queue[i].droppable THEN
        DEC(st.queueBytes, Charge(st.queue[i].text));
        FOR k := i TO st.queueLen - 2 DO st.queue[k] := st.queue[k + 1]; END;
        DEC(st.queueLen);
        RETURN TRUE;
      END;
      INC(i);
    END;
    RETURN FALSE;
  END DropOldest;

PROCEDURE Emit(st: State; text: TEXT; droppable: BOOLEAN) =
  VAR charge := Charge(text);
  BEGIN
    WHILE (st.queueBytes + charge > QueueMaxBytes OR st.queueLen >= QueueMaxCount) AND DropOldest(st) DO
    END;
    IF st.queueBytes + charge > QueueMaxBytes OR st.queueLen >= QueueMaxCount THEN
      IF NOT droppable THEN
        IO.Put("adapter: output budget exhausted by undroppable responses\n");
        st.done := TRUE;
      END;
      RETURN;
    END;
    st.queue[st.queueLen] := QueueEntry{text := text, droppable := droppable};
    INC(st.queueLen);
    INC(st.queueBytes, charge);
  END Emit;

PROCEDURE Flush(st: State) =
  BEGIN
    FOR i := 0 TO st.queueLen - 1 DO WriteLineRaw(st, st.queue[i].text); END;
    st.queueLen := 0;
    st.queueBytes := 0;
  END Flush;

(* -- event construction: an absent "id"/"subscriptionId" is simply never
      ObjectSet, so ConvexJson.Encode never emits it -- matching the
      shared schema's "omit, never null" rule for optional fields. ----- *)

PROCEDURE SetIdIfAny(o: ConvexJson.T; id: TEXT) =
  BEGIN
    IF id # NIL AND NOT Text.Equal(id, "") THEN ConvexJson.ObjectSet(o, "id", ConvexJson.NewString(id)); END;
  END SetIdIfAny;

PROCEDURE ErrorObject(name: TEXT; message: TEXT; data: ConvexJson.T): ConvexJson.T =
  VAR o := ConvexJson.NewObject();
  BEGIN
    ConvexJson.ObjectSet(o, "name", ConvexJson.NewString(name));
    ConvexJson.ObjectSet(o, "message", ConvexJson.NewString(message));
    (* "data" is legitimately absent much of the time (ConvexHttp.CallResult
       and ConvexLive.Event both document it as "may be NIL"), and unlike an
       optional top-level field this one is not omitted -- the schema's
       "error" object always carries a "data" key, JSON null when there is
       none. A Modula-3 NIL here is not "skip this field": ConvexJson.T's
       own NIL means "no value at all," and encoding one directly would
       dereference it. ConvexJson.NewNull() is the actual JSON null. *)
    IF data = NIL THEN data := ConvexJson.NewNull(); END;
    ConvexJson.ObjectSet(o, "data", data);
    RETURN o;
  END ErrorObject;

PROCEDURE ReadyEvent(id: TEXT): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    ConvexJson.ObjectSet(o, "protocolVersion", ConvexJson.NewInt(1));
    SetIdIfAny(o, id);
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("ready"));
    ConvexJson.ObjectSet(o, "language", ConvexJson.NewString("modula-3"));
    ConvexJson.ObjectSet(o, "implementation", ConvexJson.NewString("native-" & ClientTag));
    ConvexJson.ObjectSet(o, "runtime", ConvexJson.NewString(RuntimeTag));
    RETURN ConvexJson.Encode(o);
  END ReadyEvent;

PROCEDURE ResultEvent(id: TEXT; value: ConvexJson.T; logs: ConvexJson.T): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    SetIdIfAny(o, id);
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("result"));
    ConvexJson.ObjectSet(o, "value", value);
    ConvexJson.ObjectSet(o, "logs", logs);
    RETURN ConvexJson.Encode(o);
  END ResultEvent;

PROCEDURE ErrorEvent(id: TEXT; name: TEXT; message: TEXT; data: ConvexJson.T): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    SetIdIfAny(o, id);
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("error"));
    ConvexJson.ObjectSet(o, "error", ErrorObject(name, message, data));
    RETURN ConvexJson.Encode(o);
  END ErrorEvent;

PROCEDURE AckEvent(id: TEXT): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    SetIdIfAny(o, id);
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("ack"));
    RETURN ConvexJson.Encode(o);
  END AckEvent;

PROCEDURE ClosedEvent(id: TEXT): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    SetIdIfAny(o, id);
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("closed"));
    RETURN ConvexJson.Encode(o);
  END ClosedEvent;

PROCEDURE SubscriptionValueEvent(subId: TEXT; value: ConvexJson.T; logs: ConvexJson.T): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("subscription"));
    ConvexJson.ObjectSet(o, "subscriptionId", ConvexJson.NewString(subId));
    ConvexJson.ObjectSet(o, "value", value);
    ConvexJson.ObjectSet(o, "logs", logs);
    RETURN ConvexJson.Encode(o);
  END SubscriptionValueEvent;

PROCEDURE SubscriptionErrorEvent(subId: TEXT; name: TEXT; message: TEXT; data: ConvexJson.T; logs: ConvexJson.T): TEXT =
  VAR o := ConvexJson.NewObject();
  BEGIN
    ConvexJson.ObjectSet(o, "type", ConvexJson.NewString("subscription"));
    ConvexJson.ObjectSet(o, "subscriptionId", ConvexJson.NewString(subId));
    ConvexJson.ObjectSet(o, "error", ErrorObject(name, message, data));
    ConvexJson.ObjectSet(o, "logs", logs);
    RETURN ConvexJson.Encode(o);
  END SubscriptionErrorEvent;

(* -- pumping ConvexLive: forward every event Poll returns as a
      (droppable) subscription event. ConvexLive itself already
      suppresses an unchanged rehydration (see its own lastSignature
      tracking), so unlike a poll-and-diff design this adapter does not
      need a second layer of "have I already published this revision"
      bookkeeping. ---------------------------------------------------- *)

PROCEDURE PumpLive(st: State) =
  VAR batch: ConvexLive.EventBatch;
  BEGIN
    IF st.live = NIL THEN RETURN; END;
    batch := ConvexLive.Poll(st.live, LivePollMs);
    FOR i := 0 TO batch.count - 1 DO
      VAR e := batch.events[i];
      BEGIN
        IF e.kind = ConvexLive.EventKind.Update THEN
          Emit(st, SubscriptionValueEvent(e.subscriptionId, e.value, e.logLines), TRUE);
        ELSE
          Emit(st, SubscriptionErrorEvent(e.subscriptionId, e.errName, e.errMessage, e.errData, e.logLines), TRUE);
        END;
      END;
    END;
  END PumpLive;

(* -- command parsing helpers: NIL on absence or a kind mismatch, so
      every dispatch procedure below can validate with one comparison
      against NIL. ------------------------------------------------------ *)

PROCEDURE GetStr(o: ConvexJson.T; key: TEXT): TEXT =
  VAR v := ConvexJson.ObjectGet(o, key);
  BEGIN
    IF v = NIL THEN RETURN NIL; END;
    TRY RETURN ConvexJson.StrOf(v); EXCEPT | ConvexJson.Error => RETURN NIL; END;
  END GetStr;

PROCEDURE GetObj(o: ConvexJson.T; key: TEXT): ConvexJson.T =
  VAR v := ConvexJson.ObjectGet(o, key);
  BEGIN
    IF v = NIL OR v.kind # ConvexJson.Kind.Obj THEN RETURN NIL; END;
    RETURN v;
  END GetObj;

(* -- dispatch -------------------------------------------------------- *)

PROCEDURE ProtocolMismatch(st: State; id: TEXT) =
  BEGIN
    Emit(st, ErrorEvent(id, "ProtocolError", "command does not match adapter protocol v1", NIL), FALSE);
  END ProtocolMismatch;

PROCEDURE DispatchCall(st: State; id: TEXT; op: TEXT; root: ConvexJson.T) =
  VAR path := GetStr(root, "path"); args := GetObj(root, "args"); result: ConvexHttp.CallResult;
  BEGIN
    IF path = NIL OR args = NIL THEN ProtocolMismatch(st, id); RETURN; END;
    result := ConvexHttp.Call(op, path, args, st.deploymentUrl, st.token);
    IF result.kind = ConvexHttp.ResultKind.Result THEN
      Emit(st, ResultEvent(id, result.value, result.logLines), FALSE);
    ELSE
      Emit(st, ErrorEvent(id, result.errName, result.errMessage, result.errData), FALSE);
    END;
  END DispatchCall;

PROCEDURE EnsureLive(st: State) =
  BEGIN
    IF st.live = NIL THEN st.live := ConvexLive.New(st.deploymentUrl); END;
  END EnsureLive;

PROCEDURE DispatchSubscribe(st: State; id: TEXT; root: ConvexJson.T) =
  VAR subId := GetStr(root, "subscriptionId"); path := GetStr(root, "path"); args := GetObj(root, "args");
  BEGIN
    IF subId = NIL OR path = NIL OR args = NIL THEN ProtocolMismatch(st, id); RETURN; END;
    EnsureLive(st);
    ConvexLive.Add(st.live, subId, path, args);
    Emit(st, AckEvent(id), FALSE);
  END DispatchSubscribe;

PROCEDURE DispatchUnsubscribe(st: State; id: TEXT; root: ConvexJson.T) =
  VAR subId := GetStr(root, "subscriptionId");
  BEGIN
    IF subId = NIL THEN ProtocolMismatch(st, id); RETURN; END;
    IF st.live # NIL THEN ConvexLive.Remove(st.live, subId); END;
    Emit(st, AckEvent(id), FALSE);
  END DispatchUnsubscribe;

PROCEDURE DispatchSetAuth(st: State; id: TEXT; root: ConvexJson.T) =
  VAR token := GetStr(root, "token");
  BEGIN
    IF token = NIL THEN ProtocolMismatch(st, id); RETURN; END;
    (* HTTP-only: this client's ConvexLive has no Authenticate message
       support yet (see manifest.yaml's limitations), so setAuth only
       affects the bearer token DispatchCall attaches to query/
       mutation/action HTTP requests from here on. *)
    st.token := token;
    Emit(st, AckEvent(id), FALSE);
  END DispatchSetAuth;

PROCEDURE Dispatch(st: State; line: TEXT) =
  VAR parsed: ConvexJson.T; id, op: TEXT;
  BEGIN
    TRY
      parsed := ConvexJson.Decode(line);
    EXCEPT
    | ConvexJson.Error => ProtocolMismatch(st, ""); RETURN;
    END;
    IF parsed.kind # ConvexJson.Kind.Obj THEN ProtocolMismatch(st, ""); RETURN; END;

    id := GetStr(parsed, "id");
    IF id = NIL THEN id := ""; END;
    op := GetStr(parsed, "op");
    IF op = NIL THEN ProtocolMismatch(st, id); RETURN; END;

    IF Text.Equal(op, "hello") THEN
      Emit(st, ReadyEvent(id), FALSE);
    ELSIF Text.Equal(op, "query") OR Text.Equal(op, "mutation") OR Text.Equal(op, "action") THEN
      DispatchCall(st, id, op, parsed);
    ELSIF Text.Equal(op, "subscribe") THEN
      DispatchSubscribe(st, id, parsed);
    ELSIF Text.Equal(op, "unsubscribe") THEN
      DispatchUnsubscribe(st, id, parsed);
    ELSIF Text.Equal(op, "setAuth") THEN
      DispatchSetAuth(st, id, parsed);
    ELSIF Text.Equal(op, "debugDisconnect") THEN
      IF st.live # NIL THEN ConvexLive.DebugDisconnect(st.live); END;
      Emit(st, AckEvent(id), FALSE);
    ELSIF Text.Equal(op, "close") THEN
      IF st.live # NIL THEN ConvexLive.Close(st.live); END;
      Emit(st, ClosedEvent(id), FALSE);
      st.done := TRUE;
    ELSE
      ProtocolMismatch(st, id);
    END;
  END Dispatch;

(* -- entry point ------------------------------------------------------- *)

VAR
  st: State;
  deploymentUrl := Env.Get("CONVEX_URL");
  listenSpec := Env.Get("ADAPTER_LISTEN");
  outcome: TEXT;
  line: TEXT;
BEGIN
  IF deploymentUrl = NIL OR Text.Equal(deploymentUrl, "") THEN
    IO.Put("adapter: CONVEX_URL is required\n");
    Process.Exit(1);
  END;

  st := NEW(State, deploymentUrl := deploymentUrl, queue := NEW(REF ARRAY OF QueueEntry, QueueMaxCount));
  IF NOT OpenTransport(st, listenSpec) THEN Process.Exit(1); END;

  WHILE NOT st.done DO
    PumpLive(st);
    line := ReadCommand(st, FLOAT(ReadSliceMs, LONGREAL) / 1000.0d0, outcome);
    IF Text.Equal(outcome, "ok") THEN
      Dispatch(st, line);
    ELSIF Text.Equal(outcome, "eof") THEN
      st.done := TRUE;
    END;
    (* outcome = "timeout": nothing arrived this pass; loop back to
       PumpLive rather than blocking further here. *)
    Flush(st);
  END;

  IF st.live # NIL THEN ConvexLive.Close(st.live); END;
  IF st.useTcp THEN
    IF st.conn # NIL THEN TCP.Close(st.conn); END;
    IF st.listener # NIL THEN TCP.CloseConnector(st.listener); END;
  END;
END Adapter.
