>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Convex from COBOL: the shared counter journey, 0 -> 1.
*>
*> The program queries a room's counter over HTTP, subscribes to the
*> same query over Live, increments it once, and proves that Live
*> delivered the new value. It prints the verification line only after
*> every operation agrees.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CONVEX-EXAMPLE.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".

01 WS-URL                   PIC X(1024).
01 WS-URL-LEN               BINARY-LONG.
01 WS-ROOM                  PIC X(256).
01 WS-ROOM-LEN              BINARY-LONG.
01 WS-CLIENTV               PIC X(64) VALUE "cobol-0.1.0".
01 WS-CLIENTV-LEN           BINARY-LONG VALUE 11.

01 WS-PATH                  PIC X(256).
01 WS-PATH-LEN              BINARY-LONG.
01 WS-ARGS                  PIC X(8192).
01 WS-ARGS-LEN              BINARY-LONG.
01 WS-ROOM-JSON             PIC X(1024).
01 WS-ROOM-JSON-LEN         BINARY-LONG.
01 WS-RUNID-JSON            PIC X(128).
01 WS-RUNID-JSON-LEN        BINARY-LONG.

01 WS-RUNID-RAW             PIC X(16).
01 WS-RUNID-HEX             PIC X(32).
01 WS-RUNID-HEX-LEN         BINARY-LONG.

01 WS-SUBIX                 BINARY-LONG.
01 WS-STATUS                BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-OP                    BINARY-LONG.
01 WS-TIMEOUT               BINARY-LONG VALUE 200.
01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-SIXTEEN               BINARY-LONG VALUE 16.

*> Every call this example makes into the client (query, subscribe,
*> mutate, and each Live pump) has already returned by the time this
*> program parses CVX-R-VALUE on its own behalf, so reusing slot 1
*> (WS-SLOT-HTTP in convex.cbl) here cannot collide with anything the
*> client itself still has in flight.
01 WS-SLOT                  BINARY-LONG VALUE 1.
01 WS-NODE                  BINARY-LONG.
01 WS-CHILD                 BINARY-LONG.
01 WS-KEY                   PIC X(64).
01 WS-KEY-LEN               BINARY-LONG.
01 WS-BOOLVAL               BINARY-DOUBLE.

01 WS-CURRENT               BINARY-DOUBLE.
01 WS-INITIAL               BINARY-DOUBLE.
01 WS-MUTCOUNT              BINARY-DOUBLE.
01 WS-UPDATED               BINARY-DOUBLE.
01 WS-EXPECTED              BINARY-DOUBLE.
01 WS-NUM                   BINARY-DOUBLE.
01 WS-NUMTEXT               PIC -(18)9.
01 WS-FROMTEXT              PIC -(18)9.
01 WS-TOTEXT                PIC -(18)9.
01 WS-STAGE                 PIC X(64).

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    *> ---------------------------------------------------------------
    *> Configuration comes from the container, never from a literal.
    *> The verifier passes a unique room as the first argument so
    *> concurrent runs cannot collide on one counter.
    *> ---------------------------------------------------------------
    MOVE SPACES TO WS-URL
    ACCEPT WS-URL FROM ENVIRONMENT "CONVEX_URL"
    COMPUTE WS-URL-LEN = FUNCTION LENGTH(FUNCTION TRIM(WS-URL))
    IF WS-URL = SPACES
        MOVE "CONVEX_URL is required" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    MOVE SPACES TO WS-ROOM
    DISPLAY 1 UPON ARGUMENT-NUMBER
    ACCEPT WS-ROOM FROM ARGUMENT-VALUE
        ON EXCEPTION MOVE "cobol-example" TO WS-ROOM
    END-ACCEPT
    IF WS-ROOM = SPACES
        MOVE "cobol-example" TO WS-ROOM
    END-IF
    COMPUTE WS-ROOM-LEN = FUNCTION LENGTH(FUNCTION TRIM(WS-ROOM))

    *> Create one client for the deployment. It owns both the HTTP
    *> endpoint and, later, the Live WebSocket.
    CALL "cvx-client-init" USING WS-URL WS-URL-LEN WS-CLIENTV
        WS-CLIENTV-LEN CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "client configuration" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    *> The room name is JSON encoded once and reused as the argument
    *> object for both the query and the subscription.
    CALL "cvx-json-esc-string" USING WS-ROOM WS-ROOM-LEN
        WS-ROOM-JSON WS-ROOM-JSON-LEN
    MOVE SPACES TO WS-ARGS
    MOVE 1 TO WS-ARGS-LEN
    STRING
        '{"room":' DELIMITED SIZE
        WS-ROOM-JSON(1:WS-ROOM-JSON-LEN) DELIMITED SIZE
        '}' DELIMITED SIZE
        INTO WS-ARGS
        WITH POINTER WS-ARGS-LEN
    END-STRING
    SUBTRACT 1 FROM WS-ARGS-LEN

    *> ---------------------------------------------------------------
    *> Read the current counter over Convex's HTTP query endpoint.
    *> ---------------------------------------------------------------
    MOVE "demo:state" TO WS-PATH
    MOVE 10 TO WS-PATH-LEN
    MOVE 1 TO WS-OP
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "initial query" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    PERFORM DECODE-COUNT
    MOVE WS-NUM TO WS-CURRENT
    MOVE WS-CURRENT TO WS-NUMTEXT
    DISPLAY "current count: " FUNCTION TRIM(WS-NUMTEXT)

    *> ---------------------------------------------------------------
    *> Subscribe before mutating. Starting Live first is what
    *> guarantees the increment cannot slip past unobserved.
    *> ---------------------------------------------------------------
    CALL "cvx-live-subscribe" USING WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN WS-SUBIX CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "subscribe" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    *> The first Live delivery hydrates the same value the query just
    *> returned, which is how the two views are shown to agree.
    MOVE "initial Live value" TO WS-STAGE
    PERFORM WAIT-FOR-DELIVERY
    PERFORM DECODE-COUNT
    MOVE WS-NUM TO WS-INITIAL
    IF WS-INITIAL NOT = WS-CURRENT
        MOVE "initial Live value disagreed with HTTP" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    MOVE WS-INITIAL TO WS-NUMTEXT
    DISPLAY "live initial count: " FUNCTION TRIM(WS-NUMTEXT)

    *> ---------------------------------------------------------------
    *> Increment once. runId is the mutation's idempotency key: a
    *> retry with the same value returns the first result instead of
    *> counting twice, which is why it is generated per run rather
    *> than per attempt.
    *> ---------------------------------------------------------------
    CALL "cvx_random_bytes" USING
        BY REFERENCE WS-RUNID-RAW
        BY VALUE WS-SIXTEEN
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE "could not generate a run identifier" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-hex-encode" USING WS-RUNID-RAW WS-SIXTEEN
        WS-RUNID-HEX WS-RUNID-HEX-LEN
    CALL "cvx-json-esc-string" USING WS-RUNID-HEX WS-RUNID-HEX-LEN
        WS-RUNID-JSON WS-RUNID-JSON-LEN
    MOVE SPACES TO WS-ARGS
    MOVE 1 TO WS-ARGS-LEN
    STRING
        '{"room":' DELIMITED SIZE
        WS-ROOM-JSON(1:WS-ROOM-JSON-LEN) DELIMITED SIZE
        ',"language":"COBOL","runId":' DELIMITED SIZE
        WS-RUNID-JSON(1:WS-RUNID-JSON-LEN) DELIMITED SIZE
        '}' DELIMITED SIZE
        INTO WS-ARGS
        WITH POINTER WS-ARGS-LEN
    END-STRING
    SUBTRACT 1 FROM WS-ARGS-LEN

    MOVE "demo:increment" TO WS-PATH
    MOVE 14 TO WS-PATH-LEN
    MOVE 2 TO WS-OP
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "mutation" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    *> The mutation reports whether it applied and echoes the new
    *> state. Both are checked before anything is printed.
    CALL "cvx-json-parse" USING WS-SLOT CVX-R-VALUE CVX-R-VALUE-LEN
        WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "mutation result was not JSON" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "applied" TO WS-KEY
    MOVE 7 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-bool" USING WS-SLOT WS-CHILD WS-BOOLVAL WS-STATUS
    IF WS-STATUS NOT = CVX-OK OR WS-BOOLVAL NOT = 1
        MOVE "mutation was not applied" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    MOVE "state" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    PERFORM DECODE-COUNT-AT-NODE
    MOVE WS-NUM TO WS-MUTCOUNT
    COMPUTE WS-EXPECTED = WS-CURRENT + 1
    IF WS-MUTCOUNT NOT = WS-EXPECTED
        MOVE "mutation returned an unexpected count" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    DISPLAY "mutation applied: true"
    MOVE WS-MUTCOUNT TO WS-NUMTEXT
    DISPLAY "mutation count: " FUNCTION TRIM(WS-NUMTEXT)

    *> ---------------------------------------------------------------
    *> Receive the increment through Live rather than polling HTTP.
    *> ---------------------------------------------------------------
    MOVE "updated Live value" TO WS-STAGE
    PERFORM WAIT-FOR-DELIVERY
    PERFORM DECODE-COUNT
    MOVE WS-NUM TO WS-UPDATED
    IF WS-UPDATED NOT = WS-EXPECTED
        MOVE "updated Live value disagreed with the mutation"
            TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    MOVE WS-UPDATED TO WS-NUMTEXT
    DISPLAY "live updated count: " FUNCTION TRIM(WS-NUMTEXT)

    *> Remove the subscription and hang up the socket politely.
    CALL "cvx-live-unsubscribe" USING WS-SUBIX CVX-ERROR WS-STATUS
    CALL "cvx-live-close" USING WS-STATUS

    *> Printed last, and only because HTTP, the mutation, and both
    *> Live deliveries agreed on the same journey.
    MOVE WS-CURRENT TO WS-FROMTEXT
    MOVE WS-UPDATED TO WS-TOTEXT
    DISPLAY "verified count: " FUNCTION TRIM(WS-FROMTEXT)
        " -> " FUNCTION TRIM(WS-TOTEXT)
    STOP RUN.

*> Pump the Live owner until a delivery for this subscription arrives.
*> COBOL has no threads, so the caller drives the transport; the pump
*> is the only routine that touches the socket.
WAIT-FOR-DELIVERY.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + 20000
    PERFORM UNTIL 1 = 2
        CALL "cvx-live-next" USING WS-SUBIX CVX-RESULT CVX-ERROR
            WS-STATUS
        IF WS-STATUS = CVX-OK
            IF CVX-R-IS-ERROR = 1
                PERFORM FAIL-AND-STOP
            END-IF
            EXIT PERFORM
        END-IF
        CALL "cvx-live-pump" USING WS-TIMEOUT WS-STATUS
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        IF WS-NOW > WS-DEADLINE
            PERFORM FAIL-AND-STOP
        END-IF
    END-PERFORM.

*> Convex may encode a whole count as 0 or 0.0. cvx-json-int accepts
*> both and refuses anything genuinely fractional or out of range, so
*> a surprising value fails the example instead of being truncated.
DECODE-COUNT.
    CALL "cvx-json-parse" USING WS-SLOT CVX-R-VALUE CVX-R-VALUE-LEN
        WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE WS-NODE TO WS-CHILD
    PERFORM DECODE-COUNT-AT-NODE.

DECODE-COUNT-AT-NODE.
    MOVE "count" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-CHILD WS-KEY WS-KEY-LEN
        WS-NODE
    IF WS-NODE = 0
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-json-int" USING WS-SLOT WS-NODE WS-NUM WS-STATUS
    IF WS-STATUS NOT = CVX-OK OR WS-NUM < 0
        PERFORM FAIL-AND-STOP
    END-IF.

*> Diagnostics go to stderr. Stdout carries only the six verified
*> lines, because the shared verifier compares it byte for byte.
FAIL-AND-STOP.
    DISPLAY "COBOL example failed at " FUNCTION TRIM(WS-STAGE)
        UPON SYSERR
    IF CVX-E-MSG-LEN > 0
        DISPLAY "  " CVX-E-MSG(1:CVX-E-MSG-LEN) UPON SYSERR
    END-IF
    CALL "cvx-live-close" USING WS-STATUS
    MOVE 1 TO RETURN-CODE
    STOP RUN.

END PROGRAM CONVEX-EXAMPLE.
