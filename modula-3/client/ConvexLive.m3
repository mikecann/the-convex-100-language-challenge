(* ConvexLive - implementation. See ConvexLive.i3 for the design notes
   on why this is deliberately single-threaded. *)
MODULE ConvexLive;

IMPORT Text, Time, Thread, ConvexJson, ConvexUrl, ConvexTransport, ConvexWebSocket,
       ConvexUtf8, ConvexRandom, ConvexBase64;

CONST
  ZeroTs = "AAAAAAAAAAA="; (* base64 of 8 zero bytes: Convex's zero logical timestamp *)
  MaxFragmentBytes = 8388608; (* 8 MiB *)
  MaxPendingEvents = 256;
  PartialFrameDeadlineSeconds = 5.0d0;

TYPE
  SubEntry = RECORD
    active: BOOLEAN;
    subscriptionId: TEXT;
    queryId: INTEGER;
    path: TEXT;
    args: ConvexJson.T;
    lastSignature: TEXT;
  END;

REVEAL
  T = ROOT BRANDED "ConvexLive.T" OBJECT
        host: TEXT;
        path: TEXT;
        port: INTEGER;
        useTls: BOOLEAN;

        connected: BOOLEAN := FALSE;
        transport: ConvexTransport.T := NIL;

        connectionCount: INTEGER := 0;
        lastCloseReason: TEXT := "InitialConnect";
        reconnectAtMs: LONGREAL := -1.0d0;
        reconnectDelayMs: INTEGER := 100;

        nextQueryId: INTEGER := 0;
        querySet: INTEGER := 0;
        remoteQuerySet: INTEGER := 0;
        remoteIdentity: ConvexJson.T := NIL;
        remoteTs: TEXT := ZeroTs;
        maxObservedTs: TEXT := NIL;

        subs: REF ARRAY OF SubEntry;
        subCount: INTEGER := 0;

        recvBuffer: TEXT := "";
        fragOpcode: INTEGER := -1;
        fragBuffer: TEXT := "";
        partialFrameSinceMs: LONGREAL := -1.0d0;

        pending: REF ARRAY OF Event;
        pendingCount: INTEGER := 0;
      END;

PROCEDURE New(url: TEXT): T =
  VAR u := ConvexUrl.Parse(url, "/api/sync");
      live := NEW(T);
  BEGIN
    live.host := u.host;
    live.path := u.path;
    live.port := u.port;
    live.useTls := u.useTls;
    live.subs := NEW(REF ARRAY OF SubEntry, 8);
    live.pending := NEW(REF ARRAY OF Event, 16);
    RETURN live;
  END New;

(* -- small growable-array helpers, same doubling strategy as ConvexJson -- *)

PROCEDURE EnsureSubsCap(live: T) =
  VAR newSubs: REF ARRAY OF SubEntry;
  BEGIN
    IF live.subCount < NUMBER(live.subs^) THEN RETURN; END;
    newSubs := NEW(REF ARRAY OF SubEntry, NUMBER(live.subs^) * 2);
    FOR i := 0 TO live.subCount - 1 DO newSubs[i] := live.subs[i]; END;
    live.subs := newSubs;
  END EnsureSubsCap;

PROCEDURE FindSubBySubId(live: T; subscriptionId: TEXT): INTEGER =
  BEGIN
    FOR i := 0 TO live.subCount - 1 DO
      IF live.subs[i].active AND Text.Equal(live.subs[i].subscriptionId, subscriptionId) THEN RETURN i; END;
    END;
    RETURN -1;
  END FindSubBySubId;

PROCEDURE FindSubByQueryId(live: T; qid: INTEGER): INTEGER =
  BEGIN
    FOR i := 0 TO live.subCount - 1 DO
      IF live.subs[i].active AND live.subs[i].queryId = qid THEN RETURN i; END;
    END;
    RETURN -1;
  END FindSubByQueryId;

PROCEDURE EnsurePendingCap(live: T) =
  VAR newPending: REF ARRAY OF Event;
  BEGIN
    IF live.pendingCount < NUMBER(live.pending^) THEN RETURN; END;
    newPending := NEW(REF ARRAY OF Event, NUMBER(live.pending^) * 2);
    FOR i := 0 TO live.pendingCount - 1 DO newPending[i] := live.pending[i]; END;
    live.pending := newPending;
  END EnsurePendingCap;

PROCEDURE PushPending(live: T; ev: Event) =
  BEGIN
    EnsurePendingCap(live);
    live.pending[live.pendingCount] := ev;
    INC(live.pendingCount);
  END PushPending;

PROCEDURE StartsWith(s: TEXT; prefix: TEXT): BOOLEAN =
  VAR pn := Text.Length(prefix);
  BEGIN
    IF Text.Length(s) < pn THEN RETURN FALSE; END;
    RETURN Text.Equal(Text.Sub(s, 0, pn), prefix);
  END StartsWith;

(* -- connection lifecycle ------------------------------------------------ *)

PROCEDURE Retire(live: T; reason: TEXT) =
  VAR errName: TEXT;
  BEGIN
    IF live.connected THEN ConvexTransport.Close(live.transport); END;
    live.connected := FALSE;
    live.transport := NIL;
    live.lastCloseReason := reason;
    INC(live.connectionCount);
    live.recvBuffer := "";
    live.fragOpcode := -1;
    live.fragBuffer := "";
    live.partialFrameSinceMs := -1.0d0;

    IF live.subCount = 0 THEN live.reconnectAtMs := -1.0d0; RETURN; END;
    IF Text.Equal(reason, "client-closed") THEN live.reconnectAtMs := -1.0d0; RETURN; END;

    live.reconnectAtMs := Time.Now() + FLOAT(live.reconnectDelayMs, LONGREAL) / 1000.0d0;
    live.reconnectDelayMs := live.reconnectDelayMs * 2;
    IF live.reconnectDelayMs > 15000 THEN live.reconnectDelayMs := 15000; END;

    IF NOT Text.Equal(reason, "DebugDisconnect") THEN
      IF StartsWith(reason, "ProtocolError:") THEN errName := "ProtocolError"; ELSE errName := "TransportError"; END;
      FOR i := 0 TO live.subCount - 1 DO
        IF live.subs[i].active THEN
          PushPending(live, Event{
            kind := EventKind.Error, subscriptionId := live.subs[i].subscriptionId,
            value := NIL, logLines := ConvexJson.NewArray(),
            errName := errName, errMessage := reason, errData := NIL});
        END;
      END;
    END;
  END Retire;

PROCEDURE BuildAddMod(qid: INTEGER; path: TEXT; args: ConvexJson.T): ConvexJson.T =
  VAR m := ConvexJson.NewObject(); argsArr := ConvexJson.NewArray();
  BEGIN
    ConvexJson.ArrayAppend(argsArr, args);
    ConvexJson.ObjectSet(m, "type", ConvexJson.NewString("Add"));
    ConvexJson.ObjectSet(m, "queryId", ConvexJson.NewInt(qid));
    ConvexJson.ObjectSet(m, "udfPath", ConvexJson.NewString(path));
    ConvexJson.ObjectSet(m, "args", argsArr);
    RETURN m;
  END BuildAddMod;

PROCEDURE BuildRemoveMod(qid: INTEGER): ConvexJson.T =
  VAR m := ConvexJson.NewObject();
  BEGIN
    ConvexJson.ObjectSet(m, "type", ConvexJson.NewString("Remove"));
    ConvexJson.ObjectSet(m, "queryId", ConvexJson.NewInt(qid));
    RETURN m;
  END BuildRemoveMod;

PROCEDURE SendModifyQuerySet(live: T; mods: ConvexJson.T) =
  VAR msg := ConvexJson.NewObject(); base := live.querySet;
  BEGIN
    live.querySet := live.querySet + 1;
    ConvexJson.ObjectSet(msg, "type", ConvexJson.NewString("ModifyQuerySet"));
    ConvexJson.ObjectSet(msg, "baseVersion", ConvexJson.NewInt(base));
    ConvexJson.ObjectSet(msg, "newVersion", ConvexJson.NewInt(live.querySet));
    ConvexJson.ObjectSet(msg, "modifications", mods);
    TRY
      ConvexTransport.Write(live.transport, ConvexWebSocket.BuildFrame(ConvexWebSocket.OpText, ConvexJson.Encode(msg)));
    EXCEPT
    | ConvexTransport.Error(m) => Retire(live, "TransportError: " & m);
    END;
  END SendModifyQuerySet;

PROCEDURE Connect(live: T) =
  VAR leftover: TEXT; sessionId: TEXT; connectMsg: ConvexJson.T;
  BEGIN
    TRY
      live.transport := ConvexTransport.Connect(live.host, live.port, live.useTls);
    EXCEPT
    | ConvexTransport.Error(m) => Retire(live, "TransportError: connect failed: " & m); RETURN;
    END;

    TRY
      leftover := ConvexWebSocket.Handshake(live.transport, live.host, live.path, Time.Now() + 10.0d0);
    EXCEPT
    | ConvexWebSocket.Error(m) =>
        ConvexTransport.Close(live.transport);
        live.transport := NIL;
        Retire(live, "ProtocolError: " & m);
        RETURN;
    END;

    live.connected := TRUE;
    (* Disarm the reconnect timer now that a connection actually
       exists: MaybeReconnect's own live.connected guard makes this a
       belt-and-braces reset, not the only thing preventing a second,
       redundant Connect from firing on the next Poll. *)
    live.reconnectAtMs := -1.0d0;
    (* A successful handshake proves the network and the peer are
       healthy again, so the next unrelated failure should start
       backing off from the beginning, not from wherever a previous,
       unrelated outage's backoff had climbed to. *)
    live.reconnectDelayMs := 100;
    live.querySet := 0;
    live.remoteQuerySet := 0;
    (* Matches the reference sync profile: a fresh connection's identity
       version starts at 0 (an anonymous-identity version counter), not
       JSON null. *)
    live.remoteIdentity := ConvexJson.NewInt(0);
    live.remoteTs := ZeroTs;
    live.recvBuffer := leftover;
    live.fragOpcode := -1;
    live.fragBuffer := "";
    live.partialFrameSinceMs := -1.0d0;

    TRY
      sessionId := ConvexRandom.HexBytes(16);
    EXCEPT
    | ConvexRandom.Error => Retire(live, "TransportError: could not generate a session id"); RETURN;
    END;

    connectMsg := ConvexJson.NewObject();
    ConvexJson.ObjectSet(connectMsg, "type", ConvexJson.NewString("Connect"));
    ConvexJson.ObjectSet(connectMsg, "sessionId", ConvexJson.NewString(sessionId));
    ConvexJson.ObjectSet(connectMsg, "connectionCount", ConvexJson.NewInt(live.connectionCount));
    ConvexJson.ObjectSet(connectMsg, "lastCloseReason", ConvexJson.NewString(live.lastCloseReason));
    ConvexJson.ObjectSet(connectMsg, "clientTs", ConvexJson.NewInt(0));
    IF live.maxObservedTs # NIL THEN
      ConvexJson.ObjectSet(connectMsg, "maxObservedTimestamp", ConvexJson.NewString(live.maxObservedTs));
    END;

    TRY
      ConvexTransport.Write(live.transport, ConvexWebSocket.BuildFrame(ConvexWebSocket.OpText, ConvexJson.Encode(connectMsg)));
    EXCEPT
    | ConvexTransport.Error(m) => Retire(live, "TransportError: " & m); RETURN;
    END;

    IF live.subCount > 0 THEN
      VAR mods := ConvexJson.NewArray();
      BEGIN
        FOR i := 0 TO live.subCount - 1 DO
          IF live.subs[i].active THEN
            ConvexJson.ArrayAppend(mods, BuildAddMod(live.subs[i].queryId, live.subs[i].path, live.subs[i].args));
          END;
        END;
        IF ConvexJson.ArrayLen(mods) > 0 THEN SendModifyQuerySet(live, mods); END;
      END;
    END;
  END Connect;

PROCEDURE MaybeReconnect(live: T) =
  BEGIN
    (* live.connected is the primary guard: reconnectAtMs is only ever
       cleared to -1 by Retire when there is nothing left worth
       reconnecting for, never by a successful Connect, so without this
       check every Poll call after a successful reconnect would call
       Connect again -- opening a second, redundant WebSocket alongside
       the first (the first's ConvexTransport.T becomes unreachable
       without ever being closed: a real fd leak) and, if that second
       handshake happened to fail, crashing Retire on a NIL transport
       (live.connected still TRUE from the first connect, but
       live.transport just got closed and NIL'd by the second attempt's
       own failure path). *)
    IF live.connected THEN RETURN; END;
    IF live.reconnectAtMs < 0.0d0 THEN RETURN; END;
    IF Time.Now() < live.reconnectAtMs THEN RETURN; END;
    IF live.subCount = 0 THEN RETURN; END;
    Connect(live);
  END MaybeReconnect;

(* -- public subscription management --------------------------------------- *)

PROCEDURE Add(live: T; subscriptionId: TEXT; path: TEXT; args: ConvexJson.T) =
  VAR qid := live.nextQueryId; wasConnected := live.connected;
  BEGIN
    INC(live.nextQueryId);
    EnsureSubsCap(live);
    live.subs[live.subCount] := SubEntry{
      active := TRUE, subscriptionId := subscriptionId, queryId := qid,
      path := path, args := args, lastSignature := NIL};
    INC(live.subCount);

    IF NOT live.connected THEN Connect(live); END;

    IF wasConnected AND live.connected THEN
      VAR mods := ConvexJson.NewArray();
      BEGIN
        ConvexJson.ArrayAppend(mods, BuildAddMod(qid, path, args));
        SendModifyQuerySet(live, mods);
      END;
    END;
  END Add;

PROCEDURE Remove(live: T; subscriptionId: TEXT) =
  VAR idx := FindSubBySubId(live, subscriptionId); qid: INTEGER;
  BEGIN
    IF idx < 0 THEN RETURN; END;
    qid := live.subs[idx].queryId;
    (* Invalidate the relay before any acknowledgement the caller sends
       after this returns: mark inactive (excluded from every lookup
       and resend) rather than physically compacting the array, so
       indices used elsewhere in this same pass stay valid. *)
    live.subs[idx].active := FALSE;

    IF live.connected THEN
      VAR mods := ConvexJson.NewArray();
      BEGIN
        ConvexJson.ArrayAppend(mods, BuildRemoveMod(qid));
        SendModifyQuerySet(live, mods);
      END;
    END;
  END Remove;

PROCEDURE DebugDisconnect(live: T) =
  BEGIN
    Retire(live, "DebugDisconnect");
  END DebugDisconnect;

PROCEDURE Close(live: T) =
  BEGIN
    IF live.connected THEN ConvexTransport.Close(live.transport); live.connected := FALSE; live.transport := NIL; END;
    live.lastCloseReason := "client-closed";
    live.reconnectAtMs := -1.0d0;
  END Close;

PROCEDURE ConnectionCount(live: T): INTEGER = BEGIN RETURN live.connectionCount; END ConnectionCount;
PROCEDURE LastCloseReason(live: T): TEXT = BEGIN RETURN live.lastCloseReason; END LastCloseReason;
PROCEDURE IsConnected(live: T): BOOLEAN = BEGIN RETURN live.connected; END IsConnected;
PROCEDURE MaxObservedTimestamp(live: T): TEXT = BEGIN RETURN live.maxObservedTs; END MaxObservedTimestamp;

(* -- timestamp comparison -------------------------------------------------- *)

(* Convex's opaque logical-timestamp cursor decodes to 8 raw
   little-endian bytes; reconstructing them as an unsigned 64-bit
   magnitude (well within a signed INTEGER's range for any timestamp
   this client will observe) lets maxObservedTimestamp tracking use a
   plain numeric comparison instead of a byte-reversal-into-hex dance. *)
PROCEDURE TsValue(base64Ts: TEXT): INTEGER =
  VAR raw: TEXT; v := 0;
  BEGIN
    TRY
      raw := ConvexBase64.Decode(base64Ts);
    EXCEPT
    | ConvexBase64.Error => RETURN 0;
    END;
    FOR i := Text.Length(raw) - 1 TO 0 BY -1 DO
      v := v * 256 + ORD(Text.GetChar(raw, i));
    END;
    RETURN v;
  END TsValue;

PROCEDURE MaybeAdvanceMaxTs(live: T; ts: TEXT) =
  BEGIN
    IF live.maxObservedTs = NIL OR TsValue(ts) > TsValue(live.maxObservedTs) THEN
      live.maxObservedTs := ts;
    END;
  END MaybeAdvanceMaxTs;

(* -- message handling ------------------------------------------------------ *)

PROCEDURE LogsOf(m: ConvexJson.T): ConvexJson.T =
  VAR logs := ConvexJson.ObjectGet(m, "logLines");
  BEGIN
    IF logs = NIL THEN RETURN ConvexJson.NewArray(); END;
    RETURN logs;
  END LogsOf;

PROCEDURE ApplyOneModification(live: T; m: ConvexJson.T) =
  VAR qid: INTEGER; idx: INTEGER; mtype: TEXT;
  BEGIN
    TRY
      qid := ROUND(ConvexJson.NumOf(ConvexJson.ObjectGet(m, "queryId")));
      mtype := ConvexJson.StrOf(ConvexJson.ObjectGet(m, "type"));
    EXCEPT
    | ConvexJson.Error => Retire(live, "ProtocolError: malformed modification"); RETURN;
    END;

    idx := FindSubByQueryId(live, qid);
    IF idx < 0 THEN RETURN; (* unknown or already-removed query: ignore *) END;

    IF Text.Equal(mtype, "QueryRemoved") THEN
      RETURN;
    ELSIF Text.Equal(mtype, "QueryUpdated") THEN
      VAR value := ConvexJson.ObjectGet(m, "value"); logs := LogsOf(m);
          sig := "value" & ConvexJson.Encode(value) & "|logs" & ConvexJson.Encode(logs);
      BEGIN
        IF live.subs[idx].lastSignature # NIL AND Text.Equal(sig, live.subs[idx].lastSignature) THEN RETURN; END;
        live.subs[idx].lastSignature := sig;
        PushPending(live, Event{
          kind := EventKind.Update, subscriptionId := live.subs[idx].subscriptionId,
          value := value, logLines := logs, errName := NIL, errMessage := NIL, errData := NIL});
      END;
    ELSIF Text.Equal(mtype, "QueryFailed") THEN
      VAR
        msgVal := ConvexJson.ObjectGet(m, "errorMessage");
        errMessage := "";
        errData := ConvexJson.ObjectGet(m, "errorData");
        logs := LogsOf(m);
        dataText := "";
        sig: TEXT;
      BEGIN
        TRY
          IF msgVal # NIL THEN errMessage := ConvexJson.StrOf(msgVal); END;
        EXCEPT
        | ConvexJson.Error => (* leave errMessage empty *)
        END;
        IF errData # NIL THEN dataText := ConvexJson.Encode(errData); END;
        sig := "error" & errMessage & "|" & dataText & "|logs" & ConvexJson.Encode(logs);
        IF live.subs[idx].lastSignature # NIL AND Text.Equal(sig, live.subs[idx].lastSignature) THEN RETURN; END;
        live.subs[idx].lastSignature := sig;
        PushPending(live, Event{
          kind := EventKind.Error, subscriptionId := live.subs[idx].subscriptionId,
          value := NIL, logLines := logs, errName := "FunctionError",
          errMessage := errMessage, errData := errData});
      END;
    END;
    (* any other modification type: ignore, matching the sync profile's
       own forward-compatibility contract *)
  END ApplyOneModification;

PROCEDURE ApplyTransition(live: T; msg: ConvexJson.T) =
  VAR startV := ConvexJson.ObjectGet(msg, "startVersion");
      endV := ConvexJson.ObjectGet(msg, "endVersion");
  BEGIN
    IF startV = NIL OR endV = NIL THEN
      Retire(live, "ProtocolError: Transition omitted a version");
      RETURN;
    END;

    TRY
      VAR
        startQs := ROUND(ConvexJson.NumOf(ConvexJson.ObjectGet(startV, "querySet")));
        startIdentity := ConvexJson.ObjectGet(startV, "identity");
        startTs := ConvexJson.StrOf(ConvexJson.ObjectGet(startV, "ts"));
      BEGIN
        IF startQs # live.remoteQuerySet
           OR NOT Text.Equal(ConvexJson.Encode(startIdentity), ConvexJson.Encode(live.remoteIdentity))
           OR NOT Text.Equal(startTs, live.remoteTs) THEN
          Retire(live, "ProtocolError: transition start version mismatch");
          RETURN;
        END;
      END;

      VAR
        endQs := ROUND(ConvexJson.NumOf(ConvexJson.ObjectGet(endV, "querySet")));
        endIdentity := ConvexJson.ObjectGet(endV, "identity");
        endTs := ConvexJson.StrOf(ConvexJson.ObjectGet(endV, "ts"));
      BEGIN
        live.remoteQuerySet := endQs;
        live.remoteIdentity := endIdentity;
        live.remoteTs := endTs;
        MaybeAdvanceMaxTs(live, endTs);
      END;
    EXCEPT
    | ConvexJson.Error => Retire(live, "ProtocolError: malformed Transition version"); RETURN;
    END;

    VAR modsField := ConvexJson.ObjectGet(msg, "modifications");
    BEGIN
      IF modsField = NIL THEN RETURN; END;
      (* Only the last modification for a given queryId in one Transition
         matters, applied in first-seen order -- matches the reference
         sync profile's own coalescing contract. *)
      VAR
        n := ConvexJson.ArrayLen(modsField);
        seenQids := NEW(REF ARRAY OF INTEGER, n);
        seenCount := 0;
        lastForQid := NEW(REF ARRAY OF ConvexJson.T, n);
      BEGIN
        FOR i := 0 TO n - 1 DO
          VAR m := ConvexJson.ArrayGet(modsField, i);
              qid: INTEGER;
          BEGIN
            TRY
              qid := ROUND(ConvexJson.NumOf(ConvexJson.ObjectGet(m, "queryId")));
            EXCEPT
            | ConvexJson.Error => Retire(live, "ProtocolError: malformed modification"); RETURN;
            END;
            VAR foundAt := -1;
            BEGIN
              FOR k := 0 TO seenCount - 1 DO
                IF seenQids[k] = qid THEN foundAt := k; EXIT; END;
              END;
              IF foundAt < 0 THEN
                seenQids[seenCount] := qid;
                lastForQid[seenCount] := m;
                INC(seenCount);
              ELSE
                lastForQid[foundAt] := m;
              END;
            END;
          END;
        END;
        FOR k := 0 TO seenCount - 1 DO
          ApplyOneModification(live, lastForQid[k]);
          IF NOT live.connected THEN RETURN; (* Retire fired mid-loop *) END;
        END;
      END;
    END;
  END ApplyTransition;

PROCEDURE HandleMessage(live: T; payload: TEXT) =
  VAR msg: ConvexJson.T; typeVal: ConvexJson.T; msgType: TEXT;
  BEGIN
    TRY
      msg := ConvexJson.Decode(payload);
    EXCEPT
    | ConvexJson.Error => Retire(live, "ProtocolError: Live message was not valid JSON"); RETURN;
    END;
    IF msg.kind # ConvexJson.Kind.Obj THEN
      Retire(live, "ProtocolError: Live message was not a JSON object");
      RETURN;
    END;
    typeVal := ConvexJson.ObjectGet(msg, "type");
    IF typeVal = NIL THEN
      Retire(live, "ProtocolError: Live message omitted type");
      RETURN;
    END;
    TRY
      msgType := ConvexJson.StrOf(typeVal);
    EXCEPT
    | ConvexJson.Error => Retire(live, "ProtocolError: Live message type was not a string"); RETURN;
    END;

    IF Text.Equal(msgType, "Transition") THEN
      ApplyTransition(live, msg);
    ELSIF Text.Equal(msgType, "Ping") OR Text.Equal(msgType, "MutationResponse") OR Text.Equal(msgType, "ActionResponse") THEN
      (* no-op: this client issues mutations/actions over HTTP, not Live *)
    ELSIF Text.Equal(msgType, "TransitionChunk") THEN
      Retire(live, "ProtocolError: TransitionChunk is not implemented");
    ELSIF Text.Equal(msgType, "FatalError") THEN
      Retire(live, "ProtocolError: FatalError from server");
    ELSIF Text.Equal(msgType, "AuthError") THEN
      Retire(live, "ProtocolError: AuthError from server");
    ELSE
      Retire(live, "ProtocolError: unsupported Live message " & msgType);
    END;
  END HandleMessage;

PROCEDURE CompleteMessage(live: T; opcode: INTEGER; payload: TEXT) =
  BEGIN
    IF opcode # ConvexWebSocket.OpText THEN
      Retire(live, "ProtocolError: unsupported frame opcode");
      RETURN;
    END;
    IF NOT ConvexUtf8.IsValid(payload) THEN
      Retire(live, "ProtocolError: text message was not valid UTF-8");
      RETURN;
    END;
    HandleMessage(live, payload);
  END CompleteMessage;

(* -- frame draining --------------------------------------------------------- *)

PROCEDURE DrainFrames(live: T) =
  BEGIN
    WHILE live.pendingCount < MaxPendingEvents DO
      VAR pr: ConvexWebSocket.ParseResult;
      BEGIN
        TRY
          pr := ConvexWebSocket.TryParseFrame(live.recvBuffer);
        EXCEPT
        | ConvexWebSocket.Error(m) => Retire(live, "ProtocolError: " & m); RETURN;
        END;

        IF NOT pr.ok THEN
          IF Text.Length(live.recvBuffer) > 0 THEN
            IF live.partialFrameSinceMs < 0.0d0 THEN
              live.partialFrameSinceMs := Time.Now();
            ELSIF Time.Now() - live.partialFrameSinceMs > PartialFrameDeadlineSeconds THEN
              Retire(live, "ProtocolError: partial frame deadline exceeded");
            END;
          END;
          RETURN;
        END;

        live.partialFrameSinceMs := -1.0d0;
        live.recvBuffer := Text.Sub(live.recvBuffer, pr.consumed, LAST(CARDINAL));

        IF pr.frame.opcode = ConvexWebSocket.OpClose
           OR pr.frame.opcode = ConvexWebSocket.OpPing
           OR pr.frame.opcode = ConvexWebSocket.OpPong THEN
          IF NOT pr.frame.fin THEN
            Retire(live, "ProtocolError: fragmented control frame");
            RETURN;
          END;
          IF pr.frame.opcode = ConvexWebSocket.OpClose THEN
            Retire(live, "TransportError: peer closed");
            RETURN;
          ELSIF pr.frame.opcode = ConvexWebSocket.OpPing THEN
            TRY
              ConvexTransport.Write(live.transport, ConvexWebSocket.BuildFrame(ConvexWebSocket.OpPong, pr.frame.payload));
            EXCEPT
            | ConvexTransport.Error(m) => Retire(live, "TransportError: " & m); RETURN;
            END;
          END;
          (* Pong: nothing to do. *)
        ELSIF pr.frame.opcode = ConvexWebSocket.OpContinuation THEN
          IF live.fragOpcode < 0 THEN
            Retire(live, "ProtocolError: continuation frame without a fragmented message in progress");
            RETURN;
          END;
          live.fragBuffer := live.fragBuffer & pr.frame.payload;
          IF Text.Length(live.fragBuffer) > MaxFragmentBytes THEN
            Retire(live, "ProtocolError: fragmented message exceeded budget");
            RETURN;
          END;
          IF pr.frame.fin THEN
            VAR opcode := live.fragOpcode; buf := live.fragBuffer;
            BEGIN
              live.fragOpcode := -1;
              live.fragBuffer := "";
              CompleteMessage(live, opcode, buf);
              IF NOT live.connected THEN RETURN; END;
            END;
          END;
        ELSE
          IF pr.frame.opcode # ConvexWebSocket.OpText THEN
            Retire(live, "ProtocolError: unsupported frame opcode");
            RETURN;
          END;
          IF live.fragOpcode >= 0 THEN
            Retire(live, "ProtocolError: new data frame while a fragmented message is in progress");
            RETURN;
          END;
          IF pr.frame.fin THEN
            CompleteMessage(live, pr.frame.opcode, pr.frame.payload);
            IF NOT live.connected THEN RETURN; END;
          ELSE
            live.fragOpcode := pr.frame.opcode;
            live.fragBuffer := pr.frame.payload;
          END;
        END;
      END;
    END;
  END DrainFrames;

PROCEDURE BatchFromPending(live: T): EventBatch =
  VAR result: EventBatch;
  BEGIN
    result.count := live.pendingCount;
    IF result.count = 0 THEN
      result.events := NEW(REF ARRAY OF Event, 0);
    ELSE
      result.events := NEW(REF ARRAY OF Event, result.count);
      FOR i := 0 TO result.count - 1 DO result.events[i] := live.pending[i]; END;
    END;
    live.pendingCount := 0;
    RETURN result;
  END BatchFromPending;

PROCEDURE Poll(live: T; timeoutMs: INTEGER): EventBatch =
  VAR chunk: TEXT;
  BEGIN
    IF live.pendingCount > 0 THEN RETURN BatchFromPending(live); END;

    MaybeReconnect(live);
    IF NOT live.connected THEN
      (* Not just "nothing to read": there is nowhere to read from.
         Sleep out the caller's own timeoutMs (capped to whatever is
         left before the next reconnect attempt is due) instead of
         busy-spinning Time.Now() comparisons at full CPU until a
         reconnect becomes due -- Poll's contract is "block for up to
         timeoutMs", not "return instantly when disconnected". *)
      VAR sleepSeconds := FLOAT(timeoutMs, LONGREAL) / 1000.0d0;
      BEGIN
        IF live.reconnectAtMs >= 0.0d0 THEN
          VAR untilReconnect := live.reconnectAtMs - Time.Now();
          BEGIN
            IF untilReconnect >= 0.0d0 AND untilReconnect < sleepSeconds THEN sleepSeconds := untilReconnect; END;
          END;
        END;
        IF sleepSeconds > 0.0d0 THEN Thread.Pause(sleepSeconds); END;
      END;
      (* The sleep above may have been exactly long enough for the
         scheduled reconnect to become due; try it now so a caller
         polling with a generous timeout does not pay an extra round
         trip just to notice. *)
      MaybeReconnect(live);
      IF NOT live.connected THEN RETURN BatchFromPending(live); END;
    END;

    TRY
      chunk := ConvexTransport.Read(live.transport, 262144, timeoutMs);
    EXCEPT
    | ConvexTransport.Error(m) =>
        IF NOT StartsWith(m, "timeout:") THEN Retire(live, "TransportError: " & m); END;
        RETURN BatchFromPending(live);
    END;

    IF Text.Equal(chunk, "") THEN
      Retire(live, "TransportError: peer closed");
      RETURN BatchFromPending(live);
    END;

    live.recvBuffer := live.recvBuffer & chunk;
    DrainFrames(live);
    RETURN BatchFromPending(live);
  END Poll;

BEGIN
END ConvexLive.
