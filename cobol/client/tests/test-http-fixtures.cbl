>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Socket-level HTTP tests against a hostile peer.
*>
*> Two fixture shapes are used, and the choice is deliberate:
*>
*>  * A socketpair preloaded with exact bytes drives the real response
*>    reader through cvx-http-read-into. Nothing is timed, so every
*>    framing case is perfectly reproducible.
*>
*>  * A forked loopback peer is used only where timing is the subject
*>    (dribbling, stalling) and for the end-to-end status classification
*>    cases, which exercise connect, write, read, and envelope decoding
*>    through the public client entry.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. TEST-HTTP-FIXTURES.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".

01 WS-FAILURES              BINARY-LONG VALUE 0.
01 WS-CHECKS                BINARY-LONG VALUE 0.
01 WS-NAME                  PIC X(72).

01 WS-PEER                  BINARY-LONG.
01 WS-HANDLE                BINARY-LONG.
01 WS-PORT                  BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-ST                    BINARY-LONG.
01 WS-CODE                  BINARY-LONG.
01 WS-EXIT                  BINARY-LONG.

01 WS-BLOB                  PIC X(262144).
01 WS-BLOB-LEN              BINARY-LONG.
01 WS-OUT                   PIC X(2097152).
01 WS-OUT-LEN               BINARY-LONG.
01 WS-DRAIN                 PIC X(65536).
01 WS-DRAIN-LEN             BINARY-LONG.

01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-SHORT-MS              BINARY-LONG VALUE 400.
01 WS-LONG-MS               BINARY-LONG VALUE 8000.

01 WS-URL                   PIC X(1024).
01 WS-URL-LEN               BINARY-LONG.
01 WS-CLIENTV               PIC X(64) VALUE "cobol-test".
01 WS-CLIENTV-LEN           BINARY-LONG VALUE 10.
01 WS-PATH                  PIC X(256) VALUE "demo:state".
01 WS-PATH-LEN              BINARY-LONG VALUE 10.
01 WS-ARGS                  PIC X(8192) VALUE "{}".
01 WS-ARGS-LEN              BINARY-LONG VALUE 2.
01 WS-OP                    BINARY-LONG VALUE 1.
01 WS-PORTTEXT              PIC X(16).
*> `MOVE` from a BINARY-LONG straight to an alphanumeric field pads
*> with leading zeros, not spaces, so `FUNCTION TRIM` cannot remove
*> them; a numeric-edited intermediate (leading zeros suppressed to
*> spaces by the `Z`s) is what makes TRIM produce the bare port digits.
01 WS-PORT-EDIT              PIC ZZZZ9.
*> Same reason as WS-PORT-EDIT: WS-CODE is a fixed-width HTTP status
*> code (200, 400, ...), and the fixture status lines below need it
*> written without leading zeros.
01 WS-CODE-EDIT              PIC ZZ9.

01 WS-I                     BINARY-LONG.
01 WS-BIG-LEN               BINARY-LONG.
01 WS-ZERO                  BINARY-LONG VALUE 0.
01 WS-MODE                  BINARY-LONG.
01 WS-PREFIX                BINARY-LONG.
01 WS-DELAY                 BINARY-LONG.

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    CALL "cvx-util-init"

    PERFORM TEST-CONTENT-LENGTH-BODY
    PERFORM TEST-CHUNKED-BODY
    PERFORM TEST-CHUNKED-OVERSIZED
    PERFORM TEST-DECLARED-LENGTH-OVERSIZED
    PERFORM TEST-CONFLICTING-FRAMING
    PERFORM TEST-TRUNCATED-BODY
    PERFORM TEST-BAD-STATUS-LINE
    PERFORM TEST-HEADER-FLOOD
    PERFORM TEST-STATUS-CLASSIFICATION
    PERFORM TEST-DRIBBLED-RESPONSE
    PERFORM TEST-STALLED-RESPONSE

    DISPLAY "test-http-fixtures: " WS-CHECKS " checks, "
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
*> Fixture helpers
*> ------------------------------------------------------------------
OPEN-PAIR.
    CALL "cvx_fixture_pair" USING
        BY REFERENCE WS-PEER
        BY REFERENCE WS-HANDLE
        RETURNING WS-RC.

PUSH-BLOB.
    CALL "cvx_fixture_push" USING
        BY VALUE WS-PEER
        BY REFERENCE WS-BLOB
        BY VALUE WS-BLOB-LEN
        RETURNING WS-RC.

*> Half close so the reader observes a clean end of stream.
END-PEER.
    CALL "cvx_fixture_shutdown" USING
        BY VALUE WS-PEER RETURNING WS-RC.

CLOSE-PAIR.
    CALL "cvx_fixture_close_peer" USING
        BY VALUE WS-PEER RETURNING WS-RC
    CALL "cvx_net_close" USING BY VALUE WS-HANDLE RETURNING WS-RC.

READ-RESPONSE.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + WS-SHORT-MS
    CALL "cvx-http-read-into" USING WS-HANDLE WS-DEADLINE WS-CODE
        WS-OUT WS-OUT-LEN WS-ST.

*> ------------------------------------------------------------------
*> Well formed framing
*> ------------------------------------------------------------------
TEST-CONTENT-LENGTH-BODY.
    MOVE "Content-Length body is read exactly" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        "Content-Type: application/json" X"0D0A" DELIMITED SIZE
        "Content-Length: 26" X"0D0A" X"0D0A" DELIMITED SIZE
        '{"status":"success","value":1}' DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM READ-RESPONSE
    IF WS-ST NOT = CVX-OK OR WS-CODE NOT = 200 OR WS-OUT-LEN NOT = 26
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

TEST-CHUNKED-BODY.
    MOVE "chunked body is reassembled" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        "Transfer-Encoding: chunked" X"0D0A" X"0D0A" DELIMITED SIZE
        "5" X"0D0A" "{" QUOTE "a" QUOTE ":" X"0D0A" DELIMITED SIZE
        "2" X"0D0A" "1}" X"0D0A" DELIMITED SIZE
        "0" X"0D0A" X"0D0A" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM READ-RESPONSE
    IF WS-ST NOT = CVX-OK OR WS-OUT-LEN NOT = 7
        PERFORM FAIL-CASE
    ELSE
        IF WS-OUT(1:7) NOT = '{"a":1}'
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM CLOSE-PAIR.

*> ------------------------------------------------------------------
*> Declared sizes must be refused while they are still numbers
*> ------------------------------------------------------------------
TEST-CHUNKED-OVERSIZED.
    MOVE "oversized chunk size is refused before the chunk" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    *> 0x7FFFFFF is far beyond the 2 MiB body cap. The reader must
    *> reject on the size line, without waiting for the payload it
    *> describes, so only a few bytes ever arrive.
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        "Transfer-Encoding: chunked" X"0D0A" X"0D0A" DELIMITED SIZE
        "7FFFFFF" X"0D0A" "abc" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM READ-RESPONSE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

TEST-DECLARED-LENGTH-OVERSIZED.
    MOVE "oversized Content-Length is refused before the body"
        TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        "Content-Length: 999999999" X"0D0A" X"0D0A" DELIMITED SIZE
        "abc" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM READ-RESPONSE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

*> Accepting both framing headers is the classic smuggling ambiguity.
TEST-CONFLICTING-FRAMING.
    MOVE "Content-Length with chunked is refused" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        "Content-Length: 3" X"0D0A" DELIMITED SIZE
        "Transfer-Encoding: chunked" X"0D0A" X"0D0A" DELIMITED SIZE
        "abc" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM READ-RESPONSE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

*> A peer that promises more than it sends and then hangs up must not
*> yield a short body that looks successful.
TEST-TRUNCATED-BODY.
    MOVE "truncated body followed by EOF is refused" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        "Content-Length: 100" X"0D0A" X"0D0A" DELIMITED SIZE
        "only-ten-b" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM END-PEER
    PERFORM READ-RESPONSE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

TEST-BAD-STATUS-LINE.
    MOVE "non-HTTP status line is refused" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "NOT-HTTP 200 OK" X"0D0A" X"0D0A" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM END-PEER
    PERFORM READ-RESPONSE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

*> More headers than the cap allows must be rejected rather than
*> letting a peer grow the header table without bound.
TEST-HEADER-FLOOD.
    MOVE "header flood is refused" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    STRING
        "HTTP/1.1 200 OK" X"0D0A" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 80
        STRING
            "X-Filler: 0123456789" X"0D0A" DELIMITED SIZE
            INTO WS-BLOB WITH POINTER WS-BLOB-LEN
        END-STRING
    END-PERFORM
    STRING
        X"0D0A" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN
    PERFORM OPEN-PAIR
    PERFORM PUSH-BLOB
    PERFORM END-PEER
    PERFORM READ-RESPONSE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF
    PERFORM CLOSE-PAIR.

*> ------------------------------------------------------------------
*> End-to-end status classification through the public client entry.
*> The Convex envelope, not the HTTP code, decides success or failure,
*> so a 560 carrying a success envelope and a 200 carrying an error
*> envelope both have to be classified by what is inside.
*> ------------------------------------------------------------------
TEST-STATUS-CLASSIFICATION.
    MOVE "200 with an error envelope is a function error" TO WS-NAME
    MOVE 200 TO WS-CODE
    PERFORM BUILD-ERROR-ENVELOPE
    PERFORM RUN-AGAINST-PEER
    PERFORM CHECK-TRUE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    ELSE
        IF CVX-E-NAME(1:13) NOT = "FunctionError"
            PERFORM FAIL-CASE
        END-IF
    END-IF

    MOVE "560 with an error envelope is a function error" TO WS-NAME
    MOVE 560 TO WS-CODE
    PERFORM BUILD-ERROR-ENVELOPE
    PERFORM RUN-AGAINST-PEER
    PERFORM CHECK-TRUE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    ELSE
        IF CVX-E-NAME(1:13) NOT = "FunctionError"
            PERFORM FAIL-CASE
        END-IF
    END-IF
    PERFORM CHECK-TRUE
    MOVE "560 error carries its structured errorData" TO WS-NAME
    IF CVX-E-DATA-LEN = 0
        PERFORM FAIL-CASE
    END-IF

    MOVE "500 without an envelope is a protocol error" TO WS-NAME
    MOVE 500 TO WS-CODE
    PERFORM BUILD-PLAIN-BODY
    PERFORM RUN-AGAINST-PEER
    PERFORM CHECK-TRUE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    ELSE
        IF CVX-E-NAME(1:13) NOT = "TransportErro"
                AND CVX-E-NAME(1:13) NOT = "ProtocolError"
            PERFORM FAIL-CASE
        END-IF
    END-IF

    MOVE "400 without an envelope is not a success" TO WS-NAME
    MOVE 400 TO WS-CODE
    PERFORM BUILD-PLAIN-BODY
    PERFORM RUN-AGAINST-PEER
    PERFORM CHECK-TRUE
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "200 with a success envelope yields the value" TO WS-NAME
    MOVE 200 TO WS-CODE
    PERFORM BUILD-SUCCESS-ENVELOPE
    PERFORM RUN-AGAINST-PEER
    PERFORM CHECK-TRUE
    IF WS-ST NOT = CVX-OK OR CVX-R-VALUE-LEN = 0
        PERFORM FAIL-CASE
    END-IF.

BUILD-ERROR-ENVELOPE.
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    MOVE WS-CODE TO WS-CODE-EDIT
    MOVE WS-CODE-EDIT TO WS-PORTTEXT
    STRING
        "HTTP/1.1 " DELIMITED SIZE
        FUNCTION TRIM(WS-PORTTEXT) DELIMITED SIZE
        " X" X"0D0A" DELIMITED SIZE
        *> The declared length must match the body below exactly:
        *> `{"status":"error","errorMessage":"room is empty","errorData":
        *> {"code":"ROOM_EMPTY"},"logLines":[]}` is 97 bytes, not 96. A
        *> short count truncates the JSON the counted-body reader hands
        *> to the parser, which is exactly why this envelope never
        *> decoded successfully.
        "Content-Length: 97" X"0D0A" DELIMITED SIZE
        "Connection: close" X"0D0A" X"0D0A" DELIMITED SIZE
        '{"status":"error","errorMessage":"room is empty",'
            DELIMITED SIZE
        '"errorData":{"code":"ROOM_EMPTY"},"logLines":[]}'
            DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN.

BUILD-SUCCESS-ENVELOPE.
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    MOVE WS-CODE TO WS-CODE-EDIT
    MOVE WS-CODE-EDIT TO WS-PORTTEXT
    STRING
        "HTTP/1.1 " DELIMITED SIZE
        FUNCTION TRIM(WS-PORTTEXT) DELIMITED SIZE
        " OK" X"0D0A" DELIMITED SIZE
        *> `{"status":"success","value":{"count":0},"logLines":[]}` is
        *> 54 bytes, not 45; see the comment in BUILD-ERROR-ENVELOPE.
        "Content-Length: 54" X"0D0A" DELIMITED SIZE
        "Connection: close" X"0D0A" X"0D0A" DELIMITED SIZE
        '{"status":"success","value":{"count":0},"logLines":[]}'
            DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN.

BUILD-PLAIN-BODY.
    MOVE SPACES TO WS-BLOB
    MOVE 1 TO WS-BLOB-LEN
    MOVE WS-CODE TO WS-CODE-EDIT
    MOVE WS-CODE-EDIT TO WS-PORTTEXT
    STRING
        "HTTP/1.1 " DELIMITED SIZE
        FUNCTION TRIM(WS-PORTTEXT) DELIMITED SIZE
        " X" X"0D0A" DELIMITED SIZE
        "Content-Type: text/plain" X"0D0A" DELIMITED SIZE
        "Content-Length: 13" X"0D0A" DELIMITED SIZE
        "Connection: close" X"0D0A" X"0D0A" DELIMITED SIZE
        "gateway error" DELIMITED SIZE
        INTO WS-BLOB WITH POINTER WS-BLOB-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BLOB-LEN.

*> Spawn a scripted peer, point a real client at it, and make one call.
RUN-AGAINST-PEER.
    MOVE 0 TO WS-MODE
    MOVE 0 TO WS-PREFIX
    MOVE 0 TO WS-DELAY
    PERFORM SPAWN-PEER
    PERFORM POINT-CLIENT-AT-PEER
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-ST
    CALL "cvx_fixture_reap" USING BY REFERENCE WS-EXIT
        RETURNING WS-RC.

SPAWN-PEER.
    CALL "cvx_fixture_spawn" USING
        BY REFERENCE WS-BLOB
        BY VALUE WS-BLOB-LEN
        BY VALUE WS-MODE
        BY VALUE WS-PREFIX
        BY VALUE WS-DELAY
        BY REFERENCE WS-PORT
        RETURNING WS-RC.

POINT-CLIENT-AT-PEER.
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

*> ------------------------------------------------------------------
*> Timing cases
*> ------------------------------------------------------------------

*> A response that never arrives in one piece must still be read. This
*> is the reassembly guarantee, exercised through the real socket.
TEST-DRIBBLED-RESPONSE.
    MOVE "response dribbled one byte at a time still parses"
        TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE 200 TO WS-CODE
    PERFORM BUILD-SUCCESS-ENVELOPE
    MOVE 1 TO WS-MODE
    MOVE 0 TO WS-PREFIX
    MOVE 1 TO WS-DELAY
    PERFORM SPAWN-PEER
    PERFORM POINT-CLIENT-AT-PEER
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-ST
    CALL "cvx_fixture_reap" USING BY REFERENCE WS-EXIT RETURNING WS-RC
    IF WS-ST NOT = CVX-OK OR CVX-R-VALUE-LEN = 0
        PERFORM FAIL-CASE
    END-IF.

*> A peer that sends part of a response and then goes quiet must hit
*> the deadline and fail, not hang. The assertion is on the outcome
*> and on the call actually returning.
TEST-STALLED-RESPONSE.
    MOVE "stalled response hits the deadline instead of hanging"
        TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE 200 TO WS-CODE
    PERFORM BUILD-SUCCESS-ENVELOPE
    MOVE 2 TO WS-MODE
    *> Enough for the status line and part of the headers, then silence.
    MOVE 30 TO WS-PREFIX
    MOVE 45000 TO WS-DELAY
    PERFORM SPAWN-PEER
    PERFORM POINT-CLIENT-AT-PEER
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-ST
    CALL "cvx_fixture_kill" RETURNING WS-RC
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF.

END PROGRAM TEST-HTTP-FIXTURES.
