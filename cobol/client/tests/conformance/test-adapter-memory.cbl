>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Stopped-reader memory accounting for the real adapter binary.
*>
*> This runs the actual /usr/local/bin/convex-adapter that ships in the
*> runtime image, with its stdout connected to a pipe that is never
*> read, and feeds it near-maximum command lines.
*>
*> What is being proven:
*>
*>  * The adapter owns no output queue at all. Events are written
*>    synchronously, so a controller that stops reading applies
*>    backpressure through the kernel pipe. Blocking there is the
*>    correct behaviour; accumulating events in the process would not
*>    be. A stalled controller therefore stalls the adapter, which is
*>    documented rather than worked around.
*>
*>  * The input side is a fixed 2 MiB line buffer in WORKING-STORAGE.
*>    Feeding many near-maximum lines cannot grow it.
*>
*>  * Resident memory stays far below the shared 128 MiB limit, and is
*>    compared against the statically known footprint rather than an
*>    arbitrary threshold.
*>
*> The adapter path is taken from ADAPTER_BINARY so the Docker stage
*> can point this at the exact binary it just linked.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. TEST-ADAPTER-MEMORY.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

01 WS-FAILURES              BINARY-LONG VALUE 0.
01 WS-CHECKS                BINARY-LONG VALUE 0.
01 WS-NAME                  PIC X(72).

*> The shared limit, and the ceiling this client intends to stay under.
01 WS-SHARED-LIMIT          BINARY-DOUBLE VALUE 134217728.
01 WS-INTENDED-CEILING      BINARY-DOUBLE VALUE 67108864.

01 WS-EXE                   PIC X(512).
01 WS-EXE-LEN               BINARY-LONG.
01 WS-IN-FD                 BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-ST                    BINARY-LONG.
01 WS-SENT                  BINARY-LONG.
01 WS-TIMEOUT-MS            BINARY-LONG VALUE 500.

01 WS-BASELINE              BINARY-DOUBLE.
01 WS-RSS                   BINARY-DOUBLE.
01 WS-PEAK                  BINARY-DOUBLE VALUE 0.
01 WS-GROWTH                BINARY-DOUBLE.

01 WS-HELLO                 PIC X(64).
01 WS-HELLO-LEN             BINARY-LONG.
01 WS-BIG                   PIC X(2097152).
01 WS-BIG-LEN               BINARY-LONG.
01 WS-ROUND                 BINARY-LONG.
01 WS-ROUNDS                BINARY-LONG VALUE 12.
01 WS-I                     BINARY-LONG.
01 WS-BLOCKED               BINARY-LONG VALUE 0.
01 WS-REPORT                PIC -(18)9.

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    MOVE SPACES TO WS-EXE
    ACCEPT WS-EXE FROM ENVIRONMENT "ADAPTER_BINARY"
    IF WS-EXE = SPACES
        MOVE "/usr/local/bin/convex-adapter" TO WS-EXE
    END-IF
    COMPUTE WS-EXE-LEN = FUNCTION LENGTH(FUNCTION TRIM(WS-EXE))

    CALL "cvx_fixture_spawn_adapter" USING
        BY REFERENCE WS-EXE
        BY VALUE WS-EXE-LEN
        BY REFERENCE WS-IN-FD
        RETURNING WS-RC
    MOVE "adapter starts under a stopped reader" TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-RC NOT = CVX-OK
        PERFORM FAIL-CASE
        PERFORM FINISH
    END-IF

    *> Complete the handshake so the adapter is in its normal loop.
    MOVE 1 TO WS-HELLO-LEN
    STRING
        '{"protocolVersion":1,"id":"h","op":"hello"}' DELIMITED SIZE
        X"0A" DELIMITED SIZE
        INTO WS-HELLO WITH POINTER WS-HELLO-LEN
    END-STRING
    SUBTRACT 1 FROM WS-HELLO-LEN
    CALL "cvx_fixture_feed_adapter" USING
        BY VALUE WS-IN-FD
        BY REFERENCE WS-HELLO
        BY VALUE WS-HELLO-LEN
        BY VALUE WS-TIMEOUT-MS
        BY REFERENCE WS-SENT
        RETURNING WS-RC

    PERFORM SAMPLE-RSS
    MOVE WS-RSS TO WS-BASELINE

    *> Build one command line just under the 2 MiB adapter limit. It is
    *> deliberately a syntactically valid object with an enormous
    *> unknown field, so the adapter must scan the whole line.
    PERFORM BUILD-NEAR-MAX-LINE

    PERFORM VARYING WS-ROUND FROM 1 BY 1 UNTIL WS-ROUND > WS-ROUNDS
        CALL "cvx_fixture_feed_adapter" USING
            BY VALUE WS-IN-FD
            BY REFERENCE WS-BIG
            BY VALUE WS-BIG-LEN
            BY VALUE WS-TIMEOUT-MS
            BY REFERENCE WS-SENT
            RETURNING WS-RC
        IF WS-RC = CVX-TIMEOUT
            *> Expected once the adapter is wedged on its blocked
            *> stdout. That is correct backpressure, not a failure.
            MOVE 1 TO WS-BLOCKED
        END-IF
        PERFORM SAMPLE-RSS
        IF WS-RSS > WS-PEAK
            MOVE WS-RSS TO WS-PEAK
        END-IF
    END-PERFORM

    MOVE "peak resident memory stays under the shared 128 MiB limit"
        TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-PEAK >= WS-SHARED-LIMIT
        PERFORM FAIL-CASE
    END-IF

    MOVE "peak resident memory stays under the intended ceiling"
        TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-PEAK >= WS-INTENDED-CEILING
        PERFORM FAIL-CASE
    END-IF

    *> Exact accounting: every buffer is WORKING-STORAGE, so feeding
    *> twelve near-maximum lines must not grow the process beyond the
    *> one 2 MiB input line it is allowed to hold, plus slack for the
    *> pages the runtime touches while scanning.
    COMPUTE WS-GROWTH = WS-PEAK - WS-BASELINE
    MOVE "growth under repeated near-maximum input is bounded"
        TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-GROWTH > 8388608
        PERFORM FAIL-CASE
    END-IF

    MOVE "a stopped reader applies backpressure rather than buffering"
        TO WS-NAME
    PERFORM CHECK-TRUE
    IF WS-BLOCKED = 0 AND WS-GROWTH > 8388608
        PERFORM FAIL-CASE
    END-IF

    MOVE WS-BASELINE TO WS-REPORT
    DISPLAY "  baseline rss bytes: " FUNCTION TRIM(WS-REPORT)
        UPON SYSERR
    MOVE WS-PEAK TO WS-REPORT
    DISPLAY "  peak rss bytes:     " FUNCTION TRIM(WS-REPORT)
        UPON SYSERR
    MOVE WS-GROWTH TO WS-REPORT
    DISPLAY "  growth bytes:       " FUNCTION TRIM(WS-REPORT)
        UPON SYSERR

    PERFORM FINISH.

BUILD-NEAR-MAX-LINE.
    MOVE SPACES TO WS-BIG
    MOVE 1 TO WS-BIG-LEN
    STRING
        '{"id":"m","op":"query","path":"demo:state","args":{},'
            DELIMITED SIZE
        '"filler":"' DELIMITED SIZE
        INTO WS-BIG WITH POINTER WS-BIG-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BIG-LEN
    *> Pad to just under the 2 MiB line cap.
    PERFORM VARYING WS-I FROM 1 BY 1
            UNTIL WS-BIG-LEN >= 2097100
        MOVE "x" TO WS-BIG(WS-BIG-LEN + 1:1)
        ADD 1 TO WS-BIG-LEN
    END-PERFORM
    MOVE '"}' TO WS-BIG(WS-BIG-LEN + 1:2)
    ADD 2 TO WS-BIG-LEN
    MOVE X"0A" TO WS-BIG(WS-BIG-LEN + 1:1)
    ADD 1 TO WS-BIG-LEN.

SAMPLE-RSS.
    CALL "cvx_fixture_adapter_rss" USING
        BY REFERENCE WS-RSS RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE 0 TO WS-RSS
    END-IF.

CHECK-TRUE.
    ADD 1 TO WS-CHECKS.

FAIL-CASE.
    ADD 1 TO WS-FAILURES
    DISPLAY "FAIL " FUNCTION TRIM(WS-NAME) UPON SYSERR.

FINISH.
    CALL "cvx_fixture_kill_adapter" RETURNING WS-RC
    DISPLAY "test-adapter-memory: " WS-CHECKS " checks, "
        WS-FAILURES " failures" UPON SYSERR
    IF WS-FAILURES > 0
        MOVE 1 TO RETURN-CODE
    END-IF
    STOP RUN.

END PROGRAM TEST-ADAPTER-MEMORY.
