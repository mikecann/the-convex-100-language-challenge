>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Socket-level WebSocket framing tests against a hostile peer.
*>
*> Every case here is preloaded into a socketpair and read through the
*> real cvx-ws-poll, so nothing depends on timing. That includes the
*> resumability case: a partial frame is made available, the poll is
*> allowed to time out, the remainder is pushed, and the next poll must
*> return the complete message. If the parser restarted at a guessed
*> frame boundary instead of preserving state, that case fails.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. TEST-WS-FIXTURES.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

01 WS-FAILURES              BINARY-LONG VALUE 0.
01 WS-CHECKS                BINARY-LONG VALUE 0.
01 WS-NAME                  PIC X(72).

01 WS-PEER                  BINARY-LONG.
01 WS-HANDLE                BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-ST                    BINARY-LONG.
01 WS-OPCODE                BINARY-LONG.

01 WS-FRAME                 PIC X(65536).
01 WS-FRAME-LEN             BINARY-LONG.
01 WS-MSG                   PIC X(2097152).
01 WS-MSG-LEN               BINARY-LONG.
01 WS-DRAIN                 PIC X(4096).
01 WS-DRAIN-LEN             BINARY-LONG.

01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-POLL-MS               BINARY-LONG VALUE 150.

01 WS-I                     BINARY-LONG.
01 WS-N                     BINARY-LONG.
01 WS-PAYLOAD               PIC X(4096).
01 WS-PAYLOAD-LEN           BINARY-LONG.
01 WS-PART                  BINARY-LONG.
01 WS-B1                    BINARY-LONG.
01 WS-B2                    BINARY-LONG.

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    CALL "cvx-util-init"

    PERFORM TEST-SINGLE-TEXT-FRAME
    PERFORM TEST-FRAGMENTED-MESSAGE
    PERFORM TEST-PING-IS-PONGED
    PERFORM TEST-PONG-IS-IGNORED
    PERFORM TEST-VALID-CLOSE
    PERFORM TEST-INVALID-CLOSE-CODE
    PERFORM TEST-SHORT-CLOSE-PAYLOAD
    PERFORM TEST-MASKED-SERVER-FRAME
    PERFORM TEST-RESERVED-BITS
    PERFORM TEST-BINARY-FRAME
    PERFORM TEST-ORPHAN-CONTINUATION
    PERFORM TEST-NON-MINIMAL-LENGTH
    PERFORM TEST-OVERSIZED-DECLARED-LENGTH
    PERFORM TEST-OVERLONG-CONTROL-FRAME
    PERFORM TEST-FRAGMENTED-CONTROL-FRAME
    PERFORM TEST-DRIBBLED-FRAME-RESUMES
    PERFORM TEST-STALLED-FRAME-PRESERVES-STATE

    DISPLAY "test-ws-fixtures: " WS-CHECKS " checks, "
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
*> Fixture plumbing. Parser state is module wide, so every case starts
*> from a fresh pair and an explicit reset.
*> ------------------------------------------------------------------
START-CASE.
    CALL "cvx-ws-reset"
    CALL "cvx_fixture_pair" USING
        BY REFERENCE WS-PEER
        BY REFERENCE WS-HANDLE
        RETURNING WS-RC
    MOVE 0 TO WS-FRAME-LEN.

END-CASE.
    CALL "cvx_fixture_close_peer" USING BY VALUE WS-PEER
        RETURNING WS-RC
    CALL "cvx_net_close" USING BY VALUE WS-HANDLE RETURNING WS-RC.

PUSH-FRAME.
    CALL "cvx_fixture_push" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-FRAME
        BY VALUE WS-FRAME-LEN
        RETURNING WS-RC.

POLL-ONCE.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + WS-POLL-MS
    CALL "cvx-ws-poll" USING WS-HANDLE WS-DEADLINE WS-OPCODE
        WS-MSG WS-MSG-LEN WS-ST.

*> Append one byte, expressed as its numeric value.
APPEND-BYTE.
    ADD 1 TO WS-FRAME-LEN
    MOVE FUNCTION CHAR(WS-N + 1) TO WS-FRAME(WS-FRAME-LEN:1).

*> Append an unmasked server frame with a small payload.
APPEND-SMALL-FRAME.
    MOVE WS-B1 TO WS-N
    PERFORM APPEND-BYTE
    MOVE WS-PAYLOAD-LEN TO WS-N
    PERFORM APPEND-BYTE
    IF WS-PAYLOAD-LEN > 0
        MOVE WS-PAYLOAD(1:WS-PAYLOAD-LEN)
            TO WS-FRAME(WS-FRAME-LEN + 1:WS-PAYLOAD-LEN)
        ADD WS-PAYLOAD-LEN TO WS-FRAME-LEN
    END-IF.

*> ------------------------------------------------------------------
*> Well formed frames
*> ------------------------------------------------------------------
TEST-SINGLE-TEXT-FRAME.
    MOVE "single text frame is delivered" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE '{"type":"Ping"}' TO WS-PAYLOAD
    MOVE 15 TO WS-PAYLOAD-LEN
    MOVE 129 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-OK OR WS-MSG-LEN NOT = 15
        PERFORM FAIL-CASE
    ELSE
        IF WS-MSG(1:15) NOT = '{"type":"Ping"}'
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM END-CASE.

*> Three fragments must reassemble into one message, and the message
*> must not surface until the final frame arrives.
TEST-FRAGMENTED-MESSAGE.
    MOVE "fragmented message reassembles in order" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    *> text, not final
    MOVE "abc" TO WS-PAYLOAD
    MOVE 3 TO WS-PAYLOAD-LEN
    MOVE 1 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    *> continuation, not final
    MOVE "de" TO WS-PAYLOAD
    MOVE 2 TO WS-PAYLOAD-LEN
    MOVE 0 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    *> continuation, final
    MOVE "f" TO WS-PAYLOAD
    MOVE 1 TO WS-PAYLOAD-LEN
    MOVE 128 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-OK OR WS-MSG-LEN NOT = 6
        PERFORM FAIL-CASE
    ELSE
        IF WS-MSG(1:6) NOT = "abcdef"
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM END-CASE.

*> A ping must be answered with a pong carrying the same payload, and
*> must not be mistaken for an application message.
TEST-PING-IS-PONGED.
    MOVE "ping is answered with a masked pong" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE "hi" TO WS-PAYLOAD
    MOVE 2 TO WS-PAYLOAD-LEN
    MOVE 137 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    *> No application message: the poll runs out of work and times out.
    IF WS-ST NOT = CVX-TIMEOUT
        PERFORM FAIL-CASE
    END-IF
    CALL "cvx_fixture_drain" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-DRAIN
        BY VALUE 4096
        BY REFERENCE WS-DRAIN-LEN
        RETURNING WS-RC
    PERFORM CHECK-TRUE
    MOVE "pong is a masked client frame with opcode 10" TO WS-NAME
    IF WS-DRAIN-LEN < 8
        PERFORM FAIL-CASE
    ELSE
        COMPUTE WS-B1 = FUNCTION ORD(WS-DRAIN(1:1)) - 1
        COMPUTE WS-B2 = FUNCTION ORD(WS-DRAIN(2:1)) - 1
        *> 0x8A final pong, and the mask bit must be set.
        IF WS-B1 NOT = 138 OR WS-B2 < 128
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM END-CASE.

TEST-PONG-IS-IGNORED.
    MOVE "unsolicited pong is ignored" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE 0 TO WS-PAYLOAD-LEN
    MOVE 138 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-TIMEOUT
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

*> ------------------------------------------------------------------
*> Close frames
*> ------------------------------------------------------------------
TEST-VALID-CLOSE.
    MOVE "close with code 1000 ends the stream" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE FUNCTION CHAR(4) TO WS-PAYLOAD(1:1)
    MOVE FUNCTION CHAR(233) TO WS-PAYLOAD(2:1)
    MOVE 2 TO WS-PAYLOAD-LEN
    MOVE 136 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-EOF
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-INVALID-CLOSE-CODE.
    MOVE "close with a reserved code is a protocol error" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    *> 999 is below the lowest legal close code.
    MOVE FUNCTION CHAR(4) TO WS-PAYLOAD(1:1)
    MOVE FUNCTION CHAR(232) TO WS-PAYLOAD(2:1)
    MOVE 2 TO WS-PAYLOAD-LEN
    MOVE 136 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-SHORT-CLOSE-PAYLOAD.
    MOVE "one byte close payload is a protocol error" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE FUNCTION CHAR(4) TO WS-PAYLOAD(1:1)
    MOVE 1 TO WS-PAYLOAD-LEN
    MOVE 136 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

*> ------------------------------------------------------------------
*> Malformed frames
*> ------------------------------------------------------------------
TEST-MASKED-SERVER-FRAME.
    MOVE "masked server frame is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE 129 TO WS-N
    PERFORM APPEND-BYTE
    *> Mask bit set on a server frame is illegal.
    MOVE 130 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 6
        MOVE 65 TO WS-N
        PERFORM APPEND-BYTE
    END-PERFORM
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-RESERVED-BITS.
    MOVE "reserved bits set is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    *> 0xC1: final, RSV1 set, text.
    MOVE 193 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 1 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 65 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-BINARY-FRAME.
    MOVE "binary frame is profile drift" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE "ab" TO WS-PAYLOAD
    MOVE 2 TO WS-PAYLOAD-LEN
    MOVE 130 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-ORPHAN-CONTINUATION.
    MOVE "continuation without a start is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE "ab" TO WS-PAYLOAD
    MOVE 2 TO WS-PAYLOAD-LEN
    MOVE 128 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

*> A short payload encoded with the 16 bit marker is non-minimal and
*> must be refused rather than silently accepted.
TEST-NON-MINIMAL-LENGTH.
    MOVE "non-minimal length encoding is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE 129 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 126 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 0 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 5 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 5
        MOVE 65 TO WS-N
        PERFORM APPEND-BYTE
    END-PERFORM
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

*> The header alone is pushed. The client must refuse the declared
*> size without waiting for, or reserving room for, the payload.
TEST-OVERSIZED-DECLARED-LENGTH.
    MOVE "oversized 64 bit length is refused from the header alone"
        TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE 129 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 127 TO WS-N
    PERFORM APPEND-BYTE
    *> 0x0000000100000000, four gigabytes.
    MOVE 0 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM APPEND-BYTE
    PERFORM APPEND-BYTE
    MOVE 1 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 0 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM APPEND-BYTE
    PERFORM APPEND-BYTE
    PERFORM APPEND-BYTE
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-OVERLONG-CONTROL-FRAME.
    MOVE "control frame over 125 bytes is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE 137 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 126 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 0 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 200 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

TEST-FRAGMENTED-CONTROL-FRAME.
    MOVE "fragmented control frame is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    *> 0x09 without the final bit.
    MOVE 9 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 2 TO WS-N
    PERFORM APPEND-BYTE
    MOVE 65 TO WS-N
    PERFORM APPEND-BYTE
    PERFORM APPEND-BYTE
    PERFORM PUSH-FRAME
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-ERR
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

*> ------------------------------------------------------------------
*> Resumability: the guarantee that a timeout mid frame never rewinds
*> the parser to a guessed boundary.
*> ------------------------------------------------------------------
TEST-DRIBBLED-FRAME-RESUMES.
    MOVE "frame split across two arrivals is reassembled" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE '{"type":"Ping"}' TO WS-PAYLOAD
    MOVE 15 TO WS-PAYLOAD-LEN
    MOVE 129 TO WS-B1
    PERFORM APPEND-SMALL-FRAME

    *> First arrival: header plus four payload bytes only.
    MOVE 6 TO WS-PART
    CALL "cvx_fixture_push" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-FRAME
        BY VALUE WS-PART
        RETURNING WS-RC
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-TIMEOUT
        PERFORM FAIL-CASE
    END-IF

    *> Second arrival: the rest. The buffered prefix must still be
    *> there, and the message must now complete intact.
    PERFORM CHECK-TRUE
    MOVE "buffered prefix survives the timeout" TO WS-NAME
    COMPUTE WS-N = WS-FRAME-LEN - WS-PART
    CALL "cvx_fixture_push" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-FRAME(WS-PART + 1:1)
        BY VALUE WS-N
        RETURNING WS-RC
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-OK OR WS-MSG-LEN NOT = 15
        PERFORM FAIL-CASE
    ELSE
        IF WS-MSG(1:15) NOT = '{"type":"Ping"}'
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM END-CASE.

*> A peer that stops one byte short must never produce a message, no
*> matter how many times the owner polls.
TEST-STALLED-FRAME-PRESERVES-STATE.
    MOVE "frame stalled one byte short never completes" TO WS-NAME
    PERFORM CHECK-TRUE
    PERFORM START-CASE
    MOVE '{"type":"Ping"}' TO WS-PAYLOAD
    MOVE 15 TO WS-PAYLOAD-LEN
    MOVE 129 TO WS-B1
    PERFORM APPEND-SMALL-FRAME
    COMPUTE WS-PART = WS-FRAME-LEN - 1
    CALL "cvx_fixture_push" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-FRAME
        BY VALUE WS-PART
        RETURNING WS-RC
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 3
        PERFORM POLL-ONCE
        IF WS-ST NOT = CVX-TIMEOUT
            PERFORM FAIL-CASE
            EXIT PERFORM
        END-IF
    END-PERFORM

    *> The final byte completes it, proving the earlier polls preserved
    *> rather than discarded the partial frame.
    PERFORM CHECK-TRUE
    MOVE "final byte completes the stalled frame" TO WS-NAME
    MOVE 1 TO WS-N
    CALL "cvx_fixture_push" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-FRAME(WS-FRAME-LEN:1)
        BY VALUE WS-N
        RETURNING WS-RC
    PERFORM POLL-ONCE
    IF WS-ST NOT = CVX-OK OR WS-MSG-LEN NOT = 15
        PERFORM FAIL-CASE
    END-IF
    PERFORM END-CASE.

END PROGRAM TEST-WS-FIXTURES.
