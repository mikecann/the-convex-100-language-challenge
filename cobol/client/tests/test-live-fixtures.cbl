>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Live reconnect, recovery, and barrier tests against a scripted
*> Convex sync peer.
*>
*> The peer completes a real RFC 6455 handshake, reads the client's
*> Connect and ModifyQuerySet frames, and replies with a Transition.
*> It serves several sequential sessions, answering session N with
*> count N, so five forced reconnects produce five distinct values and
*> a suppressed rehydration is distinguishable from a real update.
*>
*> The peer counts how many sessions saw the client resend its Add and
*> reports that as its exit status, which is how the query-set rebuild
*> is proven rather than assumed.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. TEST-LIVE-FIXTURES.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".

01 WS-FAILURES              BINARY-LONG VALUE 0.
01 WS-CHECKS                BINARY-LONG VALUE 0.
01 WS-NAME                  PIC X(72).

01 WS-PORT                  BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-ST                    BINARY-LONG.
01 WS-EXIT                  BINARY-LONG.
01 WS-SUBIX                 BINARY-LONG.
01 WS-MODE                  BINARY-LONG.
01 WS-SESSIONS              BINARY-LONG.

01 WS-URL                   PIC X(1024).
01 WS-URL-LEN               BINARY-LONG.
01 WS-PORTTEXT              PIC X(16).
*> `MOVE` from a BINARY-LONG straight to an alphanumeric field pads
*> with leading zeros, not spaces, so `FUNCTION TRIM` cannot remove
*> them; a numeric-edited intermediate (leading zeros suppressed to
*> spaces by the `Z`s) is what makes TRIM produce the bare port digits.
01 WS-PORT-EDIT              PIC ZZZZ9.
01 WS-CLIENTV               PIC X(64) VALUE "cobol-test".
01 WS-CLIENTV-LEN           BINARY-LONG VALUE 10.
01 WS-PATH                  PIC X(256) VALUE "demo:state".
01 WS-PATH-LEN              BINARY-LONG VALUE 10.
01 WS-ARGS                  PIC X(8192) VALUE '{"room":"r"}'.
01 WS-ARGS-LEN              BINARY-LONG VALUE 12.

01 WS-PUMP-MS               BINARY-LONG VALUE 25.
01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-WAIT-MS               BINARY-LONG VALUE 6000.

01 WS-SLOT                  BINARY-LONG VALUE 4.
01 WS-NODE                  BINARY-LONG.
01 WS-CHILD                 BINARY-LONG.
01 WS-KEY                   PIC X(64).
01 WS-KEY-LEN               BINARY-LONG.
01 WS-NUM                   BINARY-DOUBLE.
01 WS-GOT-DELIVERY          BINARY-LONG.

01 WS-GEN                   BINARY-LONG.
01 WS-PREV-GEN              BINARY-LONG.
01 WS-CYCLE                 BINARY-LONG.
01 WS-I                     BINARY-LONG.

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    CALL "cvx-util-init"

    PERFORM TEST-FIVE-RECONNECT-CYCLES
    PERFORM TEST-QUERY-FAILED-RECOVERY
    PERFORM TEST-STALE-RELAY-REJECTED

    DISPLAY "test-live-fixtures: " WS-CHECKS " checks, "
        WS-FAILURES " failures" UPON SYSERR
    IF WS-FAILURES > 0
        MOVE 1 TO RETURN-CODE
    END-IF
    STOP RUN.

CHECK-TRUE.
    ADD 1 TO WS-CHECKS.

FAIL-CASE.
    ADD 1 TO WS-FAILURES
    DISPLAY "FAIL " FUNCTION TRIM(WS-NAME) UPON SYSERR.

*> ------------------------------------------------------------------
*> Harness
*> ------------------------------------------------------------------
SPAWN-LIVE-PEER.
    CALL "cvx_fixture_spawn_live" USING
        BY VALUE WS-SESSIONS
        BY VALUE WS-MODE
        BY REFERENCE WS-PORT
        RETURNING WS-RC
    MOVE WS-PORT TO WS-PORT-EDIT
    MOVE WS-PORT-EDIT TO WS-PORTTEXT
    MOVE SPACES TO WS-URL
    MOVE 1 TO WS-URL-LEN
    STRING
        "http://127.0.0.1:" DELIMITED SIZE
        FUNCTION TRIM(WS-PORTTEXT) DELIMITED SIZE
        INTO WS-URL WITH POINTER WS-URL-LEN
    END-STRING
    SUBTRACT 1 FROM WS-URL-LEN
    CALL "cvx-client-init" USING WS-URL WS-URL-LEN WS-CLIENTV
        WS-CLIENTV-LEN CVX-ERROR WS-ST.

*> Drive the single owner until a delivery for the subscription shows
*> up or the wait budget runs out.
WAIT-DELIVERY.
    MOVE 0 TO WS-GOT-DELIVERY
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + WS-WAIT-MS
    PERFORM UNTIL 1 = 2
        CALL "cvx-live-next" USING WS-SUBIX CVX-RESULT CVX-ERROR
            WS-ST
        IF WS-ST = CVX-OK
            MOVE 1 TO WS-GOT-DELIVERY
            EXIT PERFORM
        END-IF
        CALL "cvx-live-pump" USING WS-PUMP-MS WS-ST
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        IF WS-NOW > WS-DEADLINE
            EXIT PERFORM
        END-IF
    END-PERFORM.

*> Pump without consuming, so a delivery can be left queued.
PUMP-A-WHILE.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + 1500
    PERFORM UNTIL 1 = 2
        CALL "cvx-live-pump" USING WS-PUMP-MS WS-ST
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        IF WS-NOW > WS-DEADLINE
            EXIT PERFORM
        END-IF
    END-PERFORM.

DECODE-DELIVERED-COUNT.
    MOVE -1 TO WS-NUM
    CALL "cvx-json-parse" USING WS-SLOT CVX-R-VALUE CVX-R-VALUE-LEN
        WS-ST
    IF WS-ST NOT = CVX-OK
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "count" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    IF WS-CHILD = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-int" USING WS-SLOT WS-CHILD WS-NUM WS-ST.

TEARDOWN.
    CALL "cvx-live-close" USING WS-ST
    CALL "cvx_fixture_kill" RETURNING WS-RC.

*> ------------------------------------------------------------------
*> Five real reconnect cycles.
*>
*> Each cycle forces a disconnect, then requires a genuinely new value
*> on the rebuilt connection. The generation must advance every cycle,
*> which is the barrier the adapter relies on to discard anything left
*> over from a retired socket.
*> ------------------------------------------------------------------
TEST-FIVE-RECONNECT-CYCLES.
    MOVE 6 TO WS-SESSIONS
    MOVE 0 TO WS-MODE
    PERFORM SPAWN-LIVE-PEER

    CALL "cvx-live-subscribe" USING WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN WS-SUBIX CVX-ERROR WS-ST
    MOVE "subscribe is accepted" TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
        PERFORM TEARDOWN
        EXIT PARAGRAPH
    END-IF

    MOVE "initial Live value arrives" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM WAIT-DELIVERY
    IF WS-GOT-DELIVERY = 0
        PERFORM FAIL-CASE
        PERFORM TEARDOWN
        EXIT PARAGRAPH
    END-IF
    PERFORM DECODE-DELIVERED-COUNT
    IF WS-NUM NOT = 0
        PERFORM FAIL-CASE
    END-IF

    CALL "cvx-live-generation" USING WS-PREV-GEN

    PERFORM VARYING WS-CYCLE FROM 1 BY 1 UNTIL WS-CYCLE > 5
        CALL "cvx-live-debug-disconnect" USING WS-GEN CVX-ERROR WS-ST
        MOVE "debugDisconnect is acknowledged" TO WS-NAME
        PERFORM CHECK-TRUE
        IF WS-ST NOT = CVX-OK
            PERFORM FAIL-CASE
            EXIT PERFORM
        END-IF

        *> The acknowledgement must carry a strictly newer generation.
        MOVE "generation advances on every reconnect" TO WS-NAME
        PERFORM CHECK-TRUE
        IF WS-GEN <= WS-PREV-GEN
            PERFORM FAIL-CASE
        END-IF
        MOVE WS-GEN TO WS-PREV-GEN

        MOVE "rebuilt connection delivers the next value" TO WS-NAME
        PERFORM CHECK-TRUE
        PERFORM WAIT-DELIVERY
        IF WS-GOT-DELIVERY = 0
            PERFORM FAIL-CASE
            EXIT PERFORM
        END-IF
        PERFORM DECODE-DELIVERED-COUNT
        IF WS-NUM NOT = WS-CYCLE
            PERFORM FAIL-CASE
        END-IF
    END-PERFORM

    CALL "cvx-live-close" USING WS-ST
    CALL "cvx_fixture_reap" USING BY REFERENCE WS-EXIT RETURNING WS-RC

    *> The peer counted the sessions in which the client resent its
    *> Add. All six connections must have rebuilt the query set.
    MOVE "every connection resent the active Add" TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-EXIT < 6
        PERFORM FAIL-CASE
    END-IF.

*> ------------------------------------------------------------------
*> A QueryFailed must surface as a structured error and must not
*> strand the subscription: a later valid value on the same connection
*> has to arrive normally.
*> ------------------------------------------------------------------
TEST-QUERY-FAILED-RECOVERY.
    MOVE 2 TO WS-SESSIONS
    MOVE 1 TO WS-MODE
    PERFORM SPAWN-LIVE-PEER

    CALL "cvx-live-subscribe" USING WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN WS-SUBIX CVX-ERROR WS-ST

    MOVE "QueryFailed surfaces as an error delivery" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM WAIT-DELIVERY
    IF WS-GOT-DELIVERY = 0 OR CVX-R-IS-ERROR NOT = 1
        PERFORM FAIL-CASE
        PERFORM TEARDOWN
        EXIT PARAGRAPH
    END-IF

    MOVE "QueryFailed keeps its structured errorData" TO WS-NAME
    PERFORM CHECK-TRUE
    IF CVX-E-DATA-LEN = 0
        PERFORM FAIL-CASE
    ELSE
        IF CVX-E-NAME(1:13) NOT = "FunctionError"
            PERFORM FAIL-CASE
        END-IF
    END-IF

    MOVE "subscription recovers with a later valid value" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM WAIT-DELIVERY
    IF WS-GOT-DELIVERY = 0 OR CVX-R-IS-ERROR NOT = 0
        PERFORM FAIL-CASE
    ELSE
        PERFORM DECODE-DELIVERED-COUNT
        IF WS-NUM NOT = 1
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM TEARDOWN.

*> ------------------------------------------------------------------
*> Anything still queued from a retired connection belongs to the old
*> generation and must never be readable after the disconnect is
*> acknowledged.
*> ------------------------------------------------------------------
TEST-STALE-RELAY-REJECTED.
    MOVE 3 TO WS-SESSIONS
    MOVE 0 TO WS-MODE
    PERFORM SPAWN-LIVE-PEER

    CALL "cvx-live-subscribe" USING WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN WS-SUBIX CVX-ERROR WS-ST

    *> Let the first connection deliver, but deliberately do not read
    *> the delivery: it stays queued.
    PERFORM PUMP-A-WHILE

    CALL "cvx-live-debug-disconnect" USING WS-GEN CVX-ERROR WS-ST
    MOVE "disconnect acknowledged with a queued delivery pending"
        TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
        PERFORM TEARDOWN
        EXIT PARAGRAPH
    END-IF

    *> The queued value came from the socket that was just retired, so
    *> it must be gone rather than crossing the acknowledgement.
    MOVE "stale delivery does not cross the disconnect barrier"
        TO WS-NAME
    PERFORM CHECK-TRUE
    CALL "cvx-live-next" USING WS-SUBIX CVX-RESULT CVX-ERROR WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    *> The rebuilt connection still works afterwards.
    MOVE "subscription still delivers after the barrier" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM WAIT-DELIVERY
    IF WS-GOT-DELIVERY = 0
        PERFORM FAIL-CASE
    END-IF
    PERFORM TEARDOWN.

END PROGRAM TEST-LIVE-FIXTURES.
