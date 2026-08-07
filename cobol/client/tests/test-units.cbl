>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Deterministic language-local tests for the pieces that do not need
*> a socket: JSON parsing and encoding, base64, the Convex timestamp
*> codec, UTF-8 validation, and number integrality.
*>
*> No network, no clock, no randomness. Every case is a fixed byte
*> string with a fixed expected outcome, so a failure here is always
*> reproducible.
*>
*> Exit status 0 means every case passed; 1 means at least one did
*> not, and each failure is named on stderr.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. TEST-UNITS.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

01 WS-FAILURES              BINARY-LONG VALUE 0.
01 WS-CHECKS                BINARY-LONG VALUE 0.
01 WS-NAME                  PIC X(64).

01 WS-SLOT                  BINARY-LONG VALUE 1.
01 WS-DOC                   PIC X(4096).
01 WS-DOC-LEN               BINARY-LONG.
01 WS-ST                    BINARY-LONG.
01 WS-NODE                  BINARY-LONG.
01 WS-CHILD                 BINARY-LONG.
01 WS-TYPE                  BINARY-LONG.
01 WS-KEY                   PIC X(64).
01 WS-KEY-LEN               BINARY-LONG.
01 WS-OUT                   PIC X(4096).
01 WS-OUT-LEN               BINARY-LONG.
01 WS-NUM                   BINARY-DOUBLE.
01 WS-COUNT                 BINARY-LONG.

01 WS-BIN                   PIC X(64).
01 WS-BIN-LEN               BINARY-LONG.
01 WS-B64                   PIC X(128).
01 WS-B64-LEN               BINARY-LONG.

01 WS-TSVAL                 PIC 9(20).
01 WS-TSVAL2                PIC 9(20).
01 WS-TSTEXT                PIC X(12).

01 WS-UTF                   PIC X(64).
01 WS-UTF-LEN               BINARY-LONG.
01 WS-I                     BINARY-LONG.

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    CALL "cvx-util-init"

    PERFORM TEST-JSON-OBJECT
    PERFORM TEST-JSON-VERBATIM-SPAN
    PERFORM TEST-JSON-INTEGRAL-FORMS
    PERFORM TEST-JSON-REJECTIONS
    PERFORM TEST-JSON-ESCAPES
    PERFORM TEST-JSON-ESC-OUTPUT
    PERFORM TEST-BASE64
    PERFORM TEST-TIMESTAMP
    PERFORM TEST-UTF8

    DISPLAY "test-units: " WS-CHECKS " checks, "
        WS-FAILURES " failures" UPON SYSERR
    IF WS-FAILURES > 0
        MOVE 1 TO RETURN-CODE
    END-IF
    STOP RUN.

*> ------------------------------------------------------------------
*> Assertions
*> ------------------------------------------------------------------
CHECK-TRUE.
    ADD 1 TO WS-CHECKS.

FAIL-CASE.
    ADD 1 TO WS-FAILURES
    DISPLAY "FAIL " FUNCTION TRIM(WS-NAME) UPON SYSERR.

*> ------------------------------------------------------------------
*> JSON
*> ------------------------------------------------------------------
TEST-JSON-OBJECT.
    MOVE "nested object member lookup" TO WS-NAME
    MOVE '{"a":{"count":7},"b":[1,2,3]}' TO WS-DOC
    MOVE 29 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "a" TO WS-KEY
    MOVE 1 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    IF WS-CHILD = 0
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    MOVE "count" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-CHILD WS-KEY WS-KEY-LEN
        WS-NODE
    CALL "cvx-json-int" USING WS-SLOT WS-NODE WS-NUM WS-ST
    IF WS-ST NOT = CVX-OK OR WS-NUM NOT = 7
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF

    *> An absent member must be distinguishable from a present null.
    MOVE "absent member returns zero" TO WS-NAME
    PERFORM CHECK-TRUE
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "missing" TO WS-KEY
    MOVE 7 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    IF WS-CHILD NOT = 0
        PERFORM FAIL-CASE
    END-IF

    MOVE "array element count and indexing" TO WS-NAME
    PERFORM CHECK-TRUE
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "b" TO WS-KEY
    MOVE 1 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-count" USING WS-SLOT WS-CHILD WS-COUNT
    IF WS-COUNT NOT = 3
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    MOVE 2 TO WS-COUNT
    CALL "cvx-json-index" USING WS-SLOT WS-CHILD WS-COUNT WS-NODE
    CALL "cvx-json-int" USING WS-SLOT WS-NODE WS-NUM WS-ST
    IF WS-NUM NOT = 2
        PERFORM FAIL-CASE
    END-IF.

*> The raw span is what the adapter re-emits, so it must come back
*> byte identical rather than re-encoded.
TEST-JSON-VERBATIM-SPAN.
    MOVE "verbatim span round trip" TO WS-NAME
    MOVE '{"v":{"k":[1,{"z":null}],"s":"x y"}}' TO WS-DOC
    MOVE 36 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "v" TO WS-KEY
    MOVE 1 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-copy-span" USING WS-SLOT WS-CHILD WS-OUT
        WS-OUT-LEN WS-ST
    IF WS-OUT-LEN NOT = 30
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    IF WS-OUT(1:30) NOT = '{"k":[1,{"z":null}],"s":"x y"}'
        PERFORM FAIL-CASE
    END-IF.

*> Convex may send a whole count as 0.0; that must decode as integral
*> while a genuine fraction must not.
TEST-JSON-INTEGRAL-FORMS.
    MOVE "0.0 decodes as integral zero" TO WS-NAME
    MOVE '{"count":0.0}' TO WS-DOC
    MOVE 13 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "count" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT WS-CHILD WS-NUM WS-ST
    IF WS-ST NOT = CVX-OK OR WS-NUM NOT = 0
        PERFORM FAIL-CASE
    END-IF

    MOVE "1.0 decodes as integral one" TO WS-NAME
    MOVE '{"count":1.0}' TO WS-DOC
    MOVE 13 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT WS-CHILD WS-NUM WS-ST
    IF WS-ST NOT = CVX-OK OR WS-NUM NOT = 1
        PERFORM FAIL-CASE
    END-IF

    MOVE "fractional value is refused" TO WS-NAME
    MOVE '{"count":1.5}' TO WS-DOC
    MOVE 13 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT WS-CHILD WS-NUM WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "negative integer decodes" TO WS-NAME
    MOVE '{"count":-42}' TO WS-DOC
    MOVE 13 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT WS-CHILD WS-NUM WS-ST
    IF WS-ST NOT = CVX-OK OR WS-NUM NOT = -42
        PERFORM FAIL-CASE
    END-IF

    *> A quoted number is a string, not a count.
    MOVE "quoted number is not an integer" TO WS-NAME
    MOVE '{"count":"1"}' TO WS-DOC
    MOVE 13 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT WS-CHILD WS-NUM WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF.

TEST-JSON-REJECTIONS.
    MOVE "trailing data is rejected" TO WS-NAME
    MOVE '{"a":1} junk' TO WS-DOC
    MOVE 12 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "unterminated object is rejected" TO WS-NAME
    MOVE '{"a":1' TO WS-DOC
    MOVE 6 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "leading zero is rejected" TO WS-NAME
    MOVE '{"a":01}' TO WS-DOC
    MOVE 8 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "raw control character in string is rejected" TO WS-NAME
    MOVE '{"a":"x"}' TO WS-DOC
    MOVE FUNCTION CHAR(11) TO WS-DOC(7:1)
    MOVE 9 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "bad escape is rejected" TO WS-NAME
    MOVE '{"a":"\q"}' TO WS-DOC
    MOVE 10 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF.

TEST-JSON-ESCAPES.
    MOVE "escape decoding" TO WS-NAME
    MOVE '{"a":"q\"b\\c\nd"}' TO WS-DOC
    MOVE 18 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "a" TO WS-KEY
    MOVE 1 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-string" USING WS-SLOT WS-CHILD WS-OUT WS-OUT-LEN
        WS-ST
    IF WS-OUT-LEN NOT = 7
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    IF WS-OUT(1:1) NOT = "q" OR WS-OUT(2:1) NOT = QUOTE
            OR WS-OUT(3:1) NOT = "b" OR WS-OUT(4:1) NOT = "\"
            OR WS-OUT(5:1) NOT = "c"
            OR WS-OUT(6:1) NOT = FUNCTION CHAR(11)
            OR WS-OUT(7:1) NOT = "d"
        PERFORM FAIL-CASE
    END-IF

    *> A lone surrogate must be refused, not replaced.
    MOVE "lone surrogate is refused" TO WS-NAME
    MOVE '{"a":"\ud800"}' TO WS-DOC
    MOVE 14 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST = CVX-OK
        CALL "cvx-json-root" USING WS-SLOT WS-NODE
        CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY
            WS-KEY-LEN WS-CHILD
        CALL "cvx-json-string" USING WS-SLOT WS-CHILD WS-OUT
            WS-OUT-LEN WS-ST
        IF WS-ST = CVX-OK
            PERFORM FAIL-CASE
        END-IF
    END-IF.

TEST-JSON-ESC-OUTPUT.
    MOVE "string escaping for output" TO WS-NAME
    MOVE SPACES TO WS-DOC
    MOVE "a" TO WS-DOC(1:1)
    MOVE QUOTE TO WS-DOC(2:1)
    MOVE FUNCTION CHAR(11) TO WS-DOC(3:1)
    MOVE "b" TO WS-DOC(4:1)
    MOVE 4 TO WS-DOC-LEN
    PERFORM CHECK-TRUE
    CALL "cvx-json-esc-string" USING WS-DOC WS-DOC-LEN WS-OUT
        WS-OUT-LEN
    *> `"a\"\nb"` is 8 characters including both quotes: the opening
    *> quote, `a`, the two-character `\"` escape, the two-character
    *> `\n` escape, `b`, and the closing quote.
    IF WS-OUT-LEN NOT = 8
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    IF WS-OUT(1:8) NOT = '"a\"\nb"'
        PERFORM FAIL-CASE
    END-IF

    *> Escaped output must parse back to the original bytes.
    MOVE "escaped output re-parses" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE SPACES TO WS-DOC
    *> STRING's POINTER phrase is a 1-based starting position, not a
    *> length: it must be initialised to 1, not 0, or the first
    *> character has nowhere valid to land and the whole reconstructed
    *> document comes out malformed.
    MOVE 1 TO WS-DOC-LEN
    STRING '{"a":' DELIMITED SIZE
        WS-OUT(1:WS-OUT-LEN) DELIMITED SIZE
        '}' DELIMITED SIZE
        INTO WS-DOC WITH POINTER WS-DOC-LEN
    END-STRING
    SUBTRACT 1 FROM WS-DOC-LEN
    CALL "cvx-json-parse" USING WS-SLOT WS-DOC WS-DOC-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "a" TO WS-KEY
    MOVE 1 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-string" USING WS-SLOT WS-CHILD WS-OUT WS-OUT-LEN
        WS-ST
    IF WS-OUT-LEN NOT = 4
        PERFORM FAIL-CASE
    END-IF.

*> ------------------------------------------------------------------
*> base64, timestamps, UTF-8
*> ------------------------------------------------------------------
TEST-BASE64.
    MOVE "base64 of one byte pads twice" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE "M" TO WS-BIN(1:1)
    MOVE 1 TO WS-BIN-LEN
    CALL "cvx-b64-encode" USING WS-BIN WS-BIN-LEN WS-B64 WS-B64-LEN
    IF WS-B64-LEN NOT = 4 OR WS-B64(1:4) NOT = "TQ=="
        PERFORM FAIL-CASE
    END-IF

    MOVE "base64 of two bytes pads once" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE "Ma" TO WS-BIN(1:2)
    MOVE 2 TO WS-BIN-LEN
    CALL "cvx-b64-encode" USING WS-BIN WS-BIN-LEN WS-B64 WS-B64-LEN
    IF WS-B64-LEN NOT = 4 OR WS-B64(1:4) NOT = "TWE="
        PERFORM FAIL-CASE
    END-IF

    MOVE "base64 of three bytes has no padding" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE "Man" TO WS-BIN(1:3)
    MOVE 3 TO WS-BIN-LEN
    CALL "cvx-b64-encode" USING WS-BIN WS-BIN-LEN WS-B64 WS-B64-LEN
    IF WS-B64-LEN NOT = 4 OR WS-B64(1:4) NOT = "TWFu"
        PERFORM FAIL-CASE
    END-IF.

TEST-TIMESTAMP.
    MOVE "zero timestamp is the documented constant" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE 0 TO WS-TSVAL
    CALL "cvx-ts-encode" USING WS-TSVAL WS-TSTEXT
    IF WS-TSTEXT NOT = "AAAAAAAAAAA="
        PERFORM FAIL-CASE
    END-IF

    MOVE "timestamp round trips" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE 1234567890123 TO WS-TSVAL
    CALL "cvx-ts-encode" USING WS-TSVAL WS-TSTEXT
    CALL "cvx-ts-decode" USING WS-TSTEXT WS-TSVAL2 WS-ST
    IF WS-ST NOT = CVX-OK OR WS-TSVAL2 NOT = WS-TSVAL
        PERFORM FAIL-CASE
    END-IF

    *> A non-canonical encoding must not be accepted, because the
    *> value is echoed back to Convex as maxObservedTimestamp.
    MOVE "non-canonical timestamp is refused" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE "AAAAAAAAAAB=" TO WS-TSTEXT
    CALL "cvx-ts-decode" USING WS-TSTEXT WS-TSVAL2 WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "missing pad character is refused" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE "AAAAAAAAAAAA" TO WS-TSTEXT
    CALL "cvx-ts-decode" USING WS-TSTEXT WS-TSVAL2 WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF.

TEST-UTF8.
    MOVE "plain ASCII is valid" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE "hello" TO WS-UTF
    MOVE 5 TO WS-UTF-LEN
    CALL "cvx-utf8-valid" USING WS-UTF WS-UTF-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "two byte sequence is valid" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE FUNCTION CHAR(196) TO WS-UTF(1:1)
    MOVE FUNCTION CHAR(169) TO WS-UTF(2:1)
    MOVE 2 TO WS-UTF-LEN
    CALL "cvx-utf8-valid" USING WS-UTF WS-UTF-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "overlong encoding is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE FUNCTION CHAR(193) TO WS-UTF(1:1)
    MOVE FUNCTION CHAR(129) TO WS-UTF(2:1)
    MOVE 2 TO WS-UTF-LEN
    CALL "cvx-utf8-valid" USING WS-UTF WS-UTF-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "truncated sequence is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE FUNCTION CHAR(196) TO WS-UTF(1:1)
    MOVE 1 TO WS-UTF-LEN
    CALL "cvx-utf8-valid" USING WS-UTF WS-UTF-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF

    MOVE "surrogate half is rejected" TO WS-NAME
    PERFORM CHECK-TRUE
    MOVE FUNCTION CHAR(238) TO WS-UTF(1:1)
    MOVE FUNCTION CHAR(161) TO WS-UTF(2:1)
    MOVE FUNCTION CHAR(129) TO WS-UTF(3:1)
    MOVE 3 TO WS-UTF-LEN
    CALL "cvx-utf8-valid" USING WS-UTF WS-UTF-LEN WS-ST
    IF WS-ST = CVX-OK
        PERFORM FAIL-CASE
    END-IF.

END PROGRAM TEST-UNITS.
