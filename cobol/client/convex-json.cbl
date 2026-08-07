>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Strict, bounded JSON reader and writer, owned entirely by COBOL.
*>
*> Design notes that matter for review:
*>
*>  * Every buffer is WORKING-STORAGE. The parser never allocates, so
*>    the memory ceiling of the whole client is fixed at link time and
*>    a hostile document cannot grow the process. Limits are checked
*>    before any byte is consumed into a node.
*>
*>  * A parsed node keeps the raw span it came from. Values that flow
*>    straight through the client, such as a Convex query result on its
*>    way into an adapter event, are re-emitted verbatim from that span
*>    rather than re-encoded, so nothing drifts on a round trip.
*>
*>  * Documents live in numbered slots so the HTTP reply, the Live
*>    frame, and the adapter command in flight never share storage.
*>
*> Node kinds: 1 null, 2 false, 3 true, 4 number, 5 string,
*>             6 array, 7 object.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CVXJSON.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

*> One slot, not four: the HTTP reply, the adapter's own inbound
*> command, and the incoming Live frame are never readable at the same
*> time. The adapter extracts every field it needs from its command
*> into small WORKING-STORAGE before it ever calls into the HTTP path;
*> an HTTP call and a Live pump step are always sequential and never
*> nested; and every Live delivery is copied out of the parsed tree
*> into convex.cbl's own delivery queue before the slot could next be
*> reused. Four slots of 2 MiB source apiece was the single largest
*> contributor to this client exceeding the shared adapter memory-
*> growth budget; see cvx-limits.cpy for the sibling convention in
*> convex.cbl and the adapter.
01 WS-JSON-SLOTS            BINARY-LONG VALUE 1.
01 WS-JSON-MAX-BYTES        BINARY-LONG VALUE 2097152.
01 WS-JSON-MAX-NODES        BINARY-LONG VALUE 8192.
01 WS-JSON-MAX-DEPTH        BINARY-LONG VALUE 128.

*> GnuCOBOL only allows reference modification (the `(start:len)` form
*> below) on a data item, never directly on a literal, so the nibble
*> lookup for a `\u00XX` control-character escape needs its own
*> WORKING-STORAGE copy of the digit table -- mirroring the one
*> `cvx-util.cbl` already keeps for `cvx-hex-encode`.
01 WS-HEX-DIGITS            PIC X(16) VALUE "0123456789abcdef".

*> One document slot, reused in sequence by the HTTP reply, the
*> adapter's own inbound command, and the incoming Live frame. The
*> node table stays private to this program (nothing outside it ever
*> needs to see how a document was indexed), but the 2 MiB source text
*> itself is the shared external scratch: see cvx-scratch.cpy.
01 WS-DOCS.
   05 WS-DOC OCCURS 1 TIMES.
      10 WS-DOC-LEN         BINARY-LONG.
      10 WS-DOC-ROOT        BINARY-LONG.
      10 WS-DOC-COUNT       BINARY-LONG.
      10 WS-DOC-NODE OCCURS 8192 TIMES.
         15 WS-N-TYPE       BINARY-LONG.
         15 WS-N-START      BINARY-LONG.
         15 WS-N-END        BINARY-LONG.
         15 WS-N-KEY-START  BINARY-LONG.
         15 WS-N-KEY-LEN    BINARY-LONG.
         15 WS-N-FIRST      BINARY-LONG.
         15 WS-N-LAST       BINARY-LONG.
         15 WS-N-NEXT       BINARY-LONG.
         15 WS-N-INT        BINARY-DOUBLE.
         15 WS-N-IS-INT     BINARY-LONG.

COPY "cvx-scratch.cpy".
*> The one document slot's 2 MiB source text. cvx-json-parse below
*> still copies its caller's buffer in here rather than aliasing it
*> directly, so this redefinition is what actually saves the memory:
*> whichever program last redefined CVX-SHARED-SCRATCH for its own
*> 2 MiB scratch (the adapter's WS-ESC group) and this program's own
*> copy of a parsed document occupy the very same physical page.
01 WS-DOC-SRC REDEFINES CVX-SHARED-SCRATCH PIC X(2097152).

*> Parser working state.
01 WS-D                     BINARY-LONG.
01 WS-POS                   BINARY-LONG.
01 WS-LEN                   BINARY-LONG.
01 WS-CH                    PIC X.
01 WS-STATE                 BINARY-LONG.
01 WS-NODE                  BINARY-LONG.
01 WS-LAST                  BINARY-LONG.
01 WS-PARENT                BINARY-LONG.
01 WS-DEPTH                 BINARY-LONG.
01 WS-STACK.
   05 WS-STACK-NODE         BINARY-LONG OCCURS 128 TIMES.
01 WS-PEND-KEY-START        BINARY-LONG.
01 WS-PEND-KEY-LEN          BINARY-LONG.
01 WS-HAS-PEND-KEY          BINARY-LONG.
01 WS-ERR                   BINARY-LONG.
01 WS-I                     BINARY-LONG.
01 WS-J                     BINARY-LONG.
01 WS-K                     BINARY-LONG.
01 WS-BYTE                  BINARY-LONG.
01 WS-COUNT                 BINARY-LONG.
01 WS-SPAN-START            BINARY-LONG.
01 WS-SPAN-LEN              BINARY-LONG.
01 WS-DIGITS                BINARY-LONG.
01 WS-FRACZERO              BINARY-LONG.
01 WS-NEG                   BINARY-LONG.
01 WS-ACC                   BINARY-DOUBLE.
01 WS-TMP-STATUS            BINARY-LONG.
01 WS-ESC-OUT               BINARY-LONG.
01 WS-HEXVAL                BINARY-LONG.
01 WS-HEXDIG                BINARY-LONG.
*> Dedicated scratch for the UTF-8 emitter. It must not reuse WS-J or
*> WS-K, which carry the enclosing string walk's cursor bound while an
*> escape is being decoded.
01 WS-U1                    BINARY-LONG.
01 WS-U2                    BINARY-LONG.

01 WS-ST-VALUE              BINARY-LONG VALUE 1.
01 WS-ST-OPEN               BINARY-LONG VALUE 2.
01 WS-ST-AFTER              BINARY-LONG VALUE 3.
01 WS-ST-DONE               BINARY-LONG VALUE 4.

LINKAGE SECTION.
01 LK-SLOT                  BINARY-LONG.
01 LK-BUF                   PIC X(2097152).
01 LK-LEN                   BINARY-LONG.
01 LK-STATUS                BINARY-LONG.
01 LK-NODE                  BINARY-LONG.
01 LK-CHILD                 BINARY-LONG.
01 LK-TYPE                  BINARY-LONG.
01 LK-KEY                   PIC X(256).
01 LK-KEY-LEN               BINARY-LONG.
01 LK-OUT                   PIC X(2097152).
01 LK-OUT-LEN               BINARY-LONG.
01 LK-INT                   BINARY-DOUBLE.
01 LK-INDEX                 BINARY-LONG.

PROCEDURE DIVISION.
CVXJSON-MAIN SECTION.
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-json-parse: validate and index one document into a slot.
*> Rejects invalid UTF-8, oversize input, excessive depth or node
*> count, and any trailing data after the top level value.
*> ------------------------------------------------------------------
ENTRY "cvx-json-parse" USING LK-SLOT LK-BUF LK-LEN LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE LK-SLOT TO WS-D
    IF WS-D < 1 OR WS-D > WS-JSON-SLOTS
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    IF LK-LEN < 1 OR LK-LEN > WS-JSON-MAX-BYTES
        MOVE CVX-LIMIT TO LK-STATUS
        GOBACK
    END-IF

    CALL "cvx-utf8-valid" USING LK-BUF LK-LEN WS-TMP-STATUS
    IF WS-TMP-STATUS NOT = CVX-OK
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF

    MOVE LK-BUF(1:LK-LEN) TO WS-DOC-SRC(1:LK-LEN)
    MOVE LK-LEN TO WS-DOC-LEN(WS-D)
    MOVE LK-LEN TO WS-LEN
    MOVE 0 TO WS-DOC-COUNT(WS-D)
    MOVE 0 TO WS-DOC-ROOT(WS-D)
    MOVE 1 TO WS-POS
    MOVE 0 TO WS-DEPTH
    MOVE 0 TO WS-ERR
    MOVE 0 TO WS-LAST
    MOVE 0 TO WS-HAS-PEND-KEY
    MOVE WS-ST-VALUE TO WS-STATE

    PERFORM UNTIL WS-STATE = WS-ST-DONE OR WS-ERR NOT = 0
        EVALUATE WS-STATE
            WHEN WS-ST-VALUE
                PERFORM JSON-PARSE-VALUE
            WHEN WS-ST-OPEN
                PERFORM JSON-OPEN-CONTAINER
            WHEN WS-ST-AFTER
                PERFORM JSON-AFTER-VALUE
        END-EVALUATE
    END-PERFORM

    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF

    PERFORM JSON-SKIP-WS
    IF WS-POS <= WS-LEN
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    MOVE WS-LAST TO WS-DOC-ROOT(WS-D)
    GOBACK.

*> ------------------------------------------------------------------
*> Accessors
*> ------------------------------------------------------------------
ENTRY "cvx-json-root" USING LK-SLOT LK-NODE.
    MOVE LK-SLOT TO WS-D
    MOVE WS-DOC-ROOT(WS-D) TO LK-NODE
    GOBACK.

ENTRY "cvx-json-type" USING LK-SLOT LK-NODE LK-TYPE.
    MOVE LK-SLOT TO WS-D
    MOVE 0 TO LK-TYPE
    IF LK-NODE >= 1 AND LK-NODE <= WS-DOC-COUNT(WS-D)
        MOVE WS-N-TYPE(WS-D, LK-NODE) TO LK-TYPE
    END-IF
    GOBACK.

*> Object member lookup by exact key bytes. Returns 0 when absent, so
*> a caller can tell "field missing" from "field present and null".
ENTRY "cvx-json-member" USING LK-SLOT LK-NODE LK-KEY LK-KEY-LEN
        LK-CHILD.
    MOVE LK-SLOT TO WS-D
    MOVE 0 TO LK-CHILD
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        GOBACK
    END-IF
    IF WS-N-TYPE(WS-D, LK-NODE) NOT = 7
        GOBACK
    END-IF
    MOVE WS-N-FIRST(WS-D, LK-NODE) TO WS-I
    PERFORM UNTIL WS-I = 0
        IF WS-N-KEY-LEN(WS-D, WS-I) = LK-KEY-LEN
            MOVE WS-N-KEY-START(WS-D, WS-I) TO WS-J
            IF WS-DOC-SRC(WS-J:LK-KEY-LEN)
                    = LK-KEY(1:LK-KEY-LEN)
                MOVE WS-I TO LK-CHILD
                MOVE 0 TO WS-I
            END-IF
        END-IF
        IF WS-I NOT = 0
            MOVE WS-N-NEXT(WS-D, WS-I) TO WS-I
        END-IF
    END-PERFORM
    GOBACK.

ENTRY "cvx-json-count" USING LK-SLOT LK-NODE LK-OUT-LEN.
    MOVE LK-SLOT TO WS-D
    MOVE 0 TO LK-OUT-LEN
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        GOBACK
    END-IF
    MOVE 0 TO WS-COUNT
    MOVE WS-N-FIRST(WS-D, LK-NODE) TO WS-I
    PERFORM UNTIL WS-I = 0
        ADD 1 TO WS-COUNT
        MOVE WS-N-NEXT(WS-D, WS-I) TO WS-I
    END-PERFORM
    MOVE WS-COUNT TO LK-OUT-LEN
    GOBACK.

ENTRY "cvx-json-index" USING LK-SLOT LK-NODE LK-INDEX LK-CHILD.
    MOVE LK-SLOT TO WS-D
    MOVE 0 TO LK-CHILD
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        GOBACK
    END-IF
    MOVE 0 TO WS-COUNT
    MOVE WS-N-FIRST(WS-D, LK-NODE) TO WS-I
    PERFORM UNTIL WS-I = 0
        ADD 1 TO WS-COUNT
        IF WS-COUNT = LK-INDEX
            MOVE WS-I TO LK-CHILD
            MOVE 0 TO WS-I
        ELSE
            MOVE WS-N-NEXT(WS-D, WS-I) TO WS-I
        END-IF
    END-PERFORM
    GOBACK.

*> Verbatim raw span. This is how a Convex value reaches an adapter
*> event without being re-encoded, so no formatting detail changes.
ENTRY "cvx-json-copy-span" USING LK-SLOT LK-NODE LK-OUT LK-OUT-LEN
        LK-STATUS.
    MOVE LK-SLOT TO WS-D
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-OUT-LEN
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    MOVE WS-N-START(WS-D, LK-NODE) TO WS-SPAN-START
    COMPUTE WS-SPAN-LEN =
        WS-N-END(WS-D, LK-NODE) - WS-SPAN-START + 1
    IF WS-SPAN-LEN < 1
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    MOVE WS-DOC-SRC(WS-SPAN-START:WS-SPAN-LEN)
        TO LK-OUT(1:WS-SPAN-LEN)
    MOVE WS-SPAN-LEN TO LK-OUT-LEN
    GOBACK.

*> Decoded string value with JSON escapes resolved. \uXXXX is encoded
*> back to UTF-8; lone surrogates are rejected rather than emitted as
*> replacement characters.
ENTRY "cvx-json-string" USING LK-SLOT LK-NODE LK-OUT LK-OUT-LEN
        LK-STATUS.
    MOVE LK-SLOT TO WS-D
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-OUT-LEN
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    IF WS-N-TYPE(WS-D, LK-NODE) NOT = 5
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    *> Span includes the surrounding quotes; walk the interior.
    COMPUTE WS-I = WS-N-START(WS-D, LK-NODE) + 1
    COMPUTE WS-K = WS-N-END(WS-D, LK-NODE) - 1
    MOVE 0 TO WS-ESC-OUT
    PERFORM UNTIL WS-I > WS-K OR LK-STATUS NOT = CVX-OK
        MOVE WS-DOC-SRC(WS-I:1) TO WS-CH
        IF WS-CH = "\"
            ADD 1 TO WS-I
            MOVE WS-DOC-SRC(WS-I:1) TO WS-CH
            EVALUATE WS-CH
                WHEN QUOTE
                    ADD 1 TO WS-ESC-OUT
                    MOVE QUOTE TO LK-OUT(WS-ESC-OUT:1)
                WHEN "\"
                    ADD 1 TO WS-ESC-OUT
                    MOVE "\" TO LK-OUT(WS-ESC-OUT:1)
                WHEN "/"
                    ADD 1 TO WS-ESC-OUT
                    MOVE "/" TO LK-OUT(WS-ESC-OUT:1)
                WHEN "b"
                    ADD 1 TO WS-ESC-OUT
                    MOVE FUNCTION CHAR(9) TO LK-OUT(WS-ESC-OUT:1)
                WHEN "f"
                    ADD 1 TO WS-ESC-OUT
                    MOVE FUNCTION CHAR(13) TO LK-OUT(WS-ESC-OUT:1)
                WHEN "n"
                    ADD 1 TO WS-ESC-OUT
                    MOVE FUNCTION CHAR(11) TO LK-OUT(WS-ESC-OUT:1)
                WHEN "r"
                    ADD 1 TO WS-ESC-OUT
                    MOVE FUNCTION CHAR(14) TO LK-OUT(WS-ESC-OUT:1)
                WHEN "t"
                    ADD 1 TO WS-ESC-OUT
                    MOVE FUNCTION CHAR(10) TO LK-OUT(WS-ESC-OUT:1)
                WHEN "u"
                    PERFORM JSON-DECODE-U
                WHEN OTHER
                    MOVE CVX-ERR TO LK-STATUS
            END-EVALUATE
        ELSE
            ADD 1 TO WS-ESC-OUT
            MOVE WS-CH TO LK-OUT(WS-ESC-OUT:1)
        END-IF
        ADD 1 TO WS-I
    END-PERFORM
    MOVE WS-ESC-OUT TO LK-OUT-LEN
    GOBACK.

*> Integral number extraction. Convex may encode a whole count as 0.0,
*> so an all-zero fraction still counts as integral; anything genuinely
*> fractional, or out of signed 64-bit range, is refused rather than
*> silently truncated.
ENTRY "cvx-json-int" USING LK-SLOT LK-NODE LK-INT LK-STATUS.
    MOVE LK-SLOT TO WS-D
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-INT
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    IF WS-N-TYPE(WS-D, LK-NODE) NOT = 4
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    IF WS-N-IS-INT(WS-D, LK-NODE) NOT = 1
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    MOVE WS-N-INT(WS-D, LK-NODE) TO LK-INT
    GOBACK.

ENTRY "cvx-json-bool" USING LK-SLOT LK-NODE LK-INT LK-STATUS.
    MOVE LK-SLOT TO WS-D
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-INT
    IF LK-NODE < 1 OR LK-NODE > WS-DOC-COUNT(WS-D)
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    EVALUATE WS-N-TYPE(WS-D, LK-NODE)
        WHEN 3
            MOVE 1 TO LK-INT
        WHEN 2
            MOVE 0 TO LK-INT
        WHEN OTHER
            MOVE CVX-ERR TO LK-STATUS
    END-EVALUATE
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-json-esc-string: quote and escape a byte string for output.
*> Control characters below 0x20 become \u00XX so the result is always
*> legal JSON regardless of what a Convex log line contained.
*> ------------------------------------------------------------------
ENTRY "cvx-json-esc-string" USING LK-BUF LK-LEN LK-OUT LK-OUT-LEN.
    MOVE 0 TO WS-ESC-OUT
    ADD 1 TO WS-ESC-OUT
    MOVE QUOTE TO LK-OUT(WS-ESC-OUT:1)
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > LK-LEN
        MOVE LK-BUF(WS-I:1) TO WS-CH
        COMPUTE WS-BYTE = FUNCTION ORD(WS-CH) - 1
        EVALUATE TRUE
            WHEN WS-CH = QUOTE
                MOVE "\" TO LK-OUT(WS-ESC-OUT + 1:1)
                MOVE QUOTE TO LK-OUT(WS-ESC-OUT + 2:1)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-CH = "\"
                MOVE "\" TO LK-OUT(WS-ESC-OUT + 1:1)
                MOVE "\" TO LK-OUT(WS-ESC-OUT + 2:1)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-BYTE = 8
                MOVE "\b" TO LK-OUT(WS-ESC-OUT + 1:2)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-BYTE = 12
                MOVE "\f" TO LK-OUT(WS-ESC-OUT + 1:2)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-BYTE = 10
                MOVE "\n" TO LK-OUT(WS-ESC-OUT + 1:2)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-BYTE = 13
                MOVE "\r" TO LK-OUT(WS-ESC-OUT + 1:2)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-BYTE = 9
                MOVE "\t" TO LK-OUT(WS-ESC-OUT + 1:2)
                ADD 2 TO WS-ESC-OUT
            WHEN WS-BYTE < 32
                MOVE "\u00" TO LK-OUT(WS-ESC-OUT + 1:4)
                COMPUTE WS-J = FUNCTION INTEGER(WS-BYTE / 16)
                COMPUTE WS-K = FUNCTION MOD(WS-BYTE, 16)
                MOVE WS-HEX-DIGITS(WS-J + 1:1)
                    TO LK-OUT(WS-ESC-OUT + 5:1)
                MOVE WS-HEX-DIGITS(WS-K + 1:1)
                    TO LK-OUT(WS-ESC-OUT + 6:1)
                ADD 6 TO WS-ESC-OUT
            WHEN OTHER
                MOVE WS-CH TO LK-OUT(WS-ESC-OUT + 1:1)
                ADD 1 TO WS-ESC-OUT
        END-EVALUATE
    END-PERFORM
    ADD 1 TO WS-ESC-OUT
    MOVE QUOTE TO LK-OUT(WS-ESC-OUT:1)
    MOVE WS-ESC-OUT TO LK-OUT-LEN
    GOBACK.

*> ==================================================================
*> Parser internals
*> ==================================================================
JSON-SKIP-WS.
    PERFORM UNTIL WS-POS > WS-LEN
        MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
        IF WS-CH = SPACE
                OR WS-CH = FUNCTION CHAR(10)
                OR WS-CH = FUNCTION CHAR(14)
                OR WS-CH = FUNCTION CHAR(11)
            ADD 1 TO WS-POS
        ELSE
            EXIT PERFORM
        END-IF
    END-PERFORM.

*> Allocate a node, attaching it to the container on top of the stack
*> and consuming any pending object key.
JSON-NEW-NODE.
    IF WS-DOC-COUNT(WS-D) >= WS-JSON-MAX-NODES
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO WS-DOC-COUNT(WS-D)
    MOVE WS-DOC-COUNT(WS-D) TO WS-NODE
    MOVE 0 TO WS-N-TYPE(WS-D, WS-NODE)
    MOVE WS-POS TO WS-N-START(WS-D, WS-NODE)
    MOVE WS-POS TO WS-N-END(WS-D, WS-NODE)
    MOVE 0 TO WS-N-FIRST(WS-D, WS-NODE)
    MOVE 0 TO WS-N-LAST(WS-D, WS-NODE)
    MOVE 0 TO WS-N-NEXT(WS-D, WS-NODE)
    MOVE 0 TO WS-N-KEY-START(WS-D, WS-NODE)
    MOVE 0 TO WS-N-KEY-LEN(WS-D, WS-NODE)
    MOVE 0 TO WS-N-INT(WS-D, WS-NODE)
    MOVE 0 TO WS-N-IS-INT(WS-D, WS-NODE)

    IF WS-HAS-PEND-KEY = 1
        MOVE WS-PEND-KEY-START TO WS-N-KEY-START(WS-D, WS-NODE)
        MOVE WS-PEND-KEY-LEN TO WS-N-KEY-LEN(WS-D, WS-NODE)
        MOVE 0 TO WS-HAS-PEND-KEY
    END-IF

    IF WS-DEPTH > 0
        MOVE WS-STACK-NODE(WS-DEPTH) TO WS-PARENT
        IF WS-N-FIRST(WS-D, WS-PARENT) = 0
            MOVE WS-NODE TO WS-N-FIRST(WS-D, WS-PARENT)
        ELSE
            MOVE WS-N-LAST(WS-D, WS-PARENT) TO WS-I
            MOVE WS-NODE TO WS-N-NEXT(WS-D, WS-I)
        END-IF
        MOVE WS-NODE TO WS-N-LAST(WS-D, WS-PARENT)
    END-IF.

JSON-PARSE-VALUE.
    PERFORM JSON-SKIP-WS
    IF WS-POS > WS-LEN
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    PERFORM JSON-NEW-NODE
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
    EVALUATE TRUE
        WHEN WS-CH = "{"
            MOVE 7 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-PUSH
            MOVE WS-ST-OPEN TO WS-STATE
        WHEN WS-CH = "["
            MOVE 6 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-PUSH
            MOVE WS-ST-OPEN TO WS-STATE
        WHEN WS-CH = QUOTE
            MOVE 5 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-SCAN-STRING
            MOVE WS-NODE TO WS-LAST
            MOVE WS-ST-AFTER TO WS-STATE
        WHEN WS-CH = "t"
            MOVE 3 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-SCAN-TRUE
            MOVE WS-NODE TO WS-LAST
            MOVE WS-ST-AFTER TO WS-STATE
        WHEN WS-CH = "f"
            MOVE 2 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-SCAN-FALSE
            MOVE WS-NODE TO WS-LAST
            MOVE WS-ST-AFTER TO WS-STATE
        WHEN WS-CH = "n"
            MOVE 1 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-SCAN-NULL
            MOVE WS-NODE TO WS-LAST
            MOVE WS-ST-AFTER TO WS-STATE
        WHEN OTHER
            MOVE 4 TO WS-N-TYPE(WS-D, WS-NODE)
            PERFORM JSON-SCAN-NUMBER
            MOVE WS-NODE TO WS-LAST
            MOVE WS-ST-AFTER TO WS-STATE
    END-EVALUATE.

JSON-PUSH.
    IF WS-DEPTH >= WS-JSON-MAX-DEPTH
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO WS-DEPTH
    MOVE WS-NODE TO WS-STACK-NODE(WS-DEPTH).

*> Just pushed a container: step past its opening bracket and either
*> close it immediately or set up its first member.
JSON-OPEN-CONTAINER.
    ADD 1 TO WS-POS
    PERFORM JSON-SKIP-WS
    IF WS-POS > WS-LEN
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    MOVE WS-STACK-NODE(WS-DEPTH) TO WS-PARENT
    MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
    EVALUATE TRUE
        WHEN WS-N-TYPE(WS-D, WS-PARENT) = 7 AND WS-CH = "}"
            PERFORM JSON-CLOSE-CONTAINER
        WHEN WS-N-TYPE(WS-D, WS-PARENT) = 6 AND WS-CH = "]"
            PERFORM JSON-CLOSE-CONTAINER
        WHEN WS-N-TYPE(WS-D, WS-PARENT) = 7
            PERFORM JSON-READ-KEY
            MOVE WS-ST-VALUE TO WS-STATE
        WHEN OTHER
            MOVE WS-ST-VALUE TO WS-STATE
    END-EVALUATE.

JSON-CLOSE-CONTAINER.
    MOVE WS-STACK-NODE(WS-DEPTH) TO WS-PARENT
    MOVE WS-POS TO WS-N-END(WS-D, WS-PARENT)
    ADD 1 TO WS-POS
    SUBTRACT 1 FROM WS-DEPTH
    MOVE WS-PARENT TO WS-LAST
    MOVE WS-ST-AFTER TO WS-STATE.

*> A value finished. Either the document is complete or the enclosing
*> container wants a separator or its closing bracket.
JSON-AFTER-VALUE.
    IF WS-DEPTH = 0
        MOVE WS-ST-DONE TO WS-STATE
        EXIT PARAGRAPH
    END-IF
    PERFORM JSON-SKIP-WS
    IF WS-POS > WS-LEN
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    MOVE WS-STACK-NODE(WS-DEPTH) TO WS-PARENT
    MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
    EVALUATE TRUE
        WHEN WS-CH = ","
            ADD 1 TO WS-POS
            PERFORM JSON-SKIP-WS
            IF WS-N-TYPE(WS-D, WS-PARENT) = 7
                PERFORM JSON-READ-KEY
            END-IF
            MOVE WS-ST-VALUE TO WS-STATE
        WHEN WS-N-TYPE(WS-D, WS-PARENT) = 7 AND WS-CH = "}"
            PERFORM JSON-CLOSE-CONTAINER
        WHEN WS-N-TYPE(WS-D, WS-PARENT) = 6 AND WS-CH = "]"
            PERFORM JSON-CLOSE-CONTAINER
        WHEN OTHER
            MOVE 1 TO WS-ERR
    END-EVALUATE.

*> Read one object key and its colon, leaving the key span pending for
*> the value node that follows.
JSON-READ-KEY.
    PERFORM JSON-SKIP-WS
    IF WS-POS > WS-LEN
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-DOC-SRC(WS-POS:1) NOT = QUOTE
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    MOVE WS-POS TO WS-SPAN-START
    PERFORM JSON-SCAN-RAW-STRING
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    *> Key span excludes the quotes; comparisons stay byte exact.
    COMPUTE WS-PEND-KEY-START = WS-SPAN-START + 1
    COMPUTE WS-PEND-KEY-LEN = WS-POS - WS-SPAN-START - 2
    MOVE 1 TO WS-HAS-PEND-KEY
    PERFORM JSON-SKIP-WS
    IF WS-POS > WS-LEN
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-DOC-SRC(WS-POS:1) NOT = ":"
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO WS-POS.

*> Advance WS-POS past a complete quoted string, validating escapes.
*> On return WS-POS sits one past the closing quote.
JSON-SCAN-RAW-STRING.
    ADD 1 TO WS-POS
    PERFORM UNTIL WS-POS > WS-LEN
        MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
        COMPUTE WS-BYTE = FUNCTION ORD(WS-CH) - 1
        EVALUATE TRUE
            WHEN WS-CH = QUOTE
                ADD 1 TO WS-POS
                EXIT PARAGRAPH
            WHEN WS-CH = "\"
                ADD 1 TO WS-POS
                IF WS-POS > WS-LEN
                    MOVE 1 TO WS-ERR
                    EXIT PARAGRAPH
                END-IF
                MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
                IF WS-CH = "u"
                    PERFORM VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 4
                        IF WS-POS + WS-J > WS-LEN
                            MOVE 1 TO WS-ERR
                            EXIT PARAGRAPH
                        END-IF
                        PERFORM JSON-CHECK-HEX
                        IF WS-ERR NOT = 0
                            EXIT PARAGRAPH
                        END-IF
                    END-PERFORM
                    ADD 4 TO WS-POS
                ELSE
                    IF WS-CH NOT = QUOTE AND WS-CH NOT = "\"
                            AND WS-CH NOT = "/" AND WS-CH NOT = "b"
                            AND WS-CH NOT = "f" AND WS-CH NOT = "n"
                            AND WS-CH NOT = "r" AND WS-CH NOT = "t"
                        MOVE 1 TO WS-ERR
                        EXIT PARAGRAPH
                    END-IF
                END-IF
                ADD 1 TO WS-POS
            WHEN WS-BYTE < 32
                *> Raw control characters are illegal inside a JSON
                *> string and must be escaped by the sender.
                MOVE 1 TO WS-ERR
                EXIT PARAGRAPH
            WHEN OTHER
                ADD 1 TO WS-POS
        END-EVALUATE
    END-PERFORM
    MOVE 1 TO WS-ERR.

JSON-CHECK-HEX.
    MOVE WS-DOC-SRC(WS-POS + WS-J:1) TO WS-CH
    IF NOT ((WS-CH >= "0" AND WS-CH <= "9")
            OR (WS-CH >= "a" AND WS-CH <= "f")
            OR (WS-CH >= "A" AND WS-CH <= "F"))
        MOVE 1 TO WS-ERR
    END-IF.

JSON-SCAN-STRING.
    MOVE WS-POS TO WS-SPAN-START
    PERFORM JSON-SCAN-RAW-STRING
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    MOVE WS-SPAN-START TO WS-N-START(WS-D, WS-NODE)
    COMPUTE WS-N-END(WS-D, WS-NODE) = WS-POS - 1.

JSON-SCAN-TRUE.
    IF WS-POS + 3 > WS-LEN
            OR WS-DOC-SRC(WS-POS:4) NOT = "true"
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-N-END(WS-D, WS-NODE) = WS-POS + 3
    ADD 4 TO WS-POS.

JSON-SCAN-FALSE.
    IF WS-POS + 4 > WS-LEN
            OR WS-DOC-SRC(WS-POS:5) NOT = "false"
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-N-END(WS-D, WS-NODE) = WS-POS + 4
    ADD 5 TO WS-POS.

JSON-SCAN-NULL.
    IF WS-POS + 3 > WS-LEN
            OR WS-DOC-SRC(WS-POS:4) NOT = "null"
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-N-END(WS-D, WS-NODE) = WS-POS + 3
    ADD 4 TO WS-POS.

*> JSON number grammar, plus the integrality decision the example and
*> the adapter rely on.
JSON-SCAN-NUMBER.
    MOVE WS-POS TO WS-SPAN-START
    MOVE 0 TO WS-NEG
    MOVE 0 TO WS-DIGITS
    MOVE 1 TO WS-FRACZERO
    MOVE 0 TO WS-ACC

    IF WS-DOC-SRC(WS-POS:1) = "-"
        MOVE 1 TO WS-NEG
        ADD 1 TO WS-POS
    END-IF

    *> Integer part: a leading zero may not be followed by digits.
    IF WS-POS > WS-LEN
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-DOC-SRC(WS-POS:1) = "0"
        ADD 1 TO WS-POS
        MOVE 1 TO WS-DIGITS
        IF WS-POS <= WS-LEN
                AND WS-DOC-SRC(WS-POS:1) >= "0"
                AND WS-DOC-SRC(WS-POS:1) <= "9"
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
    ELSE
        PERFORM UNTIL WS-POS > WS-LEN
            MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
            IF WS-CH >= "0" AND WS-CH <= "9"
                COMPUTE WS-BYTE = FUNCTION ORD(WS-CH) - 49
                *> Guard the accumulator before it can overflow the
                *> signed 64-bit item.
                IF WS-ACC > 922337203685477580
                    MOVE 0 TO WS-DIGITS
                    EXIT PERFORM
                END-IF
                COMPUTE WS-ACC = WS-ACC * 10 + WS-BYTE
                ADD 1 TO WS-DIGITS
                ADD 1 TO WS-POS
            ELSE
                EXIT PERFORM
            END-IF
        END-PERFORM
        IF WS-DIGITS = 0
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
    END-IF

    *> Fractional part. All-zero fractions keep the value integral,
    *> which is what makes Convex's 0.0 acceptable as a count.
    IF WS-POS <= WS-LEN AND WS-DOC-SRC(WS-POS:1) = "."
        ADD 1 TO WS-POS
        MOVE 0 TO WS-K
        PERFORM UNTIL WS-POS > WS-LEN
            MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
            IF WS-CH >= "0" AND WS-CH <= "9"
                IF WS-CH NOT = "0"
                    MOVE 0 TO WS-FRACZERO
                END-IF
                ADD 1 TO WS-K
                ADD 1 TO WS-POS
            ELSE
                EXIT PERFORM
            END-IF
        END-PERFORM
        IF WS-K = 0
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
    END-IF

    *> Exponent form is valid JSON and is kept for verbatim re-emission,
    *> but this client does not claim to reduce it to an integer.
    IF WS-POS <= WS-LEN
            AND (WS-DOC-SRC(WS-POS:1) = "e"
                 OR WS-DOC-SRC(WS-POS:1) = "E")
        ADD 1 TO WS-POS
        IF WS-POS <= WS-LEN
                AND (WS-DOC-SRC(WS-POS:1) = "+"
                     OR WS-DOC-SRC(WS-POS:1) = "-")
            ADD 1 TO WS-POS
        END-IF
        MOVE 0 TO WS-K
        PERFORM UNTIL WS-POS > WS-LEN
            MOVE WS-DOC-SRC(WS-POS:1) TO WS-CH
            IF WS-CH >= "0" AND WS-CH <= "9"
                ADD 1 TO WS-K
                ADD 1 TO WS-POS
            ELSE
                EXIT PERFORM
            END-IF
        END-PERFORM
        IF WS-K = 0
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
        MOVE 0 TO WS-FRACZERO
    END-IF

    MOVE WS-SPAN-START TO WS-N-START(WS-D, WS-NODE)
    COMPUTE WS-N-END(WS-D, WS-NODE) = WS-POS - 1
    IF WS-DIGITS > 0 AND WS-FRACZERO = 1
        MOVE 1 TO WS-N-IS-INT(WS-D, WS-NODE)
        IF WS-NEG = 1
            COMPUTE WS-N-INT(WS-D, WS-NODE) = 0 - WS-ACC
        ELSE
            MOVE WS-ACC TO WS-N-INT(WS-D, WS-NODE)
        END-IF
    END-IF.

*> \uXXXX to UTF-8. Surrogate pairs are joined; an unpaired surrogate
*> is an error rather than a silently substituted character.
JSON-DECODE-U.
    MOVE 0 TO WS-HEXVAL
    PERFORM VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 4
        MOVE WS-DOC-SRC(WS-I + WS-J:1) TO WS-CH
        EVALUATE TRUE
            WHEN WS-CH >= "0" AND WS-CH <= "9"
                COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 49
            WHEN WS-CH >= "a" AND WS-CH <= "f"
                COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 88
            WHEN WS-CH >= "A" AND WS-CH <= "F"
                COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 56
            WHEN OTHER
                MOVE CVX-ERR TO LK-STATUS
                EXIT PARAGRAPH
        END-EVALUATE
        COMPUTE WS-HEXVAL = WS-HEXVAL * 16 + WS-HEXDIG
    END-PERFORM
    ADD 4 TO WS-I

    IF WS-HEXVAL >= 55296 AND WS-HEXVAL <= 56319
        *> High surrogate: a low surrogate must follow immediately.
        IF WS-I + 6 > WS-K + 1
            MOVE CVX-ERR TO LK-STATUS
            EXIT PARAGRAPH
        END-IF
        IF WS-DOC-SRC(WS-I + 1:2) NOT = "\u"
            MOVE CVX-ERR TO LK-STATUS
            EXIT PARAGRAPH
        END-IF
        MOVE WS-HEXVAL TO WS-ACC
        ADD 2 TO WS-I
        MOVE 0 TO WS-HEXVAL
        PERFORM VARYING WS-J FROM 0 BY 1 UNTIL WS-J > 3
            MOVE WS-DOC-SRC(WS-I + WS-J:1) TO WS-CH
            EVALUATE TRUE
                WHEN WS-CH >= "0" AND WS-CH <= "9"
                    COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 49
                WHEN WS-CH >= "a" AND WS-CH <= "f"
                    COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 88
                WHEN WS-CH >= "A" AND WS-CH <= "F"
                    COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 56
                WHEN OTHER
                    MOVE CVX-ERR TO LK-STATUS
                    EXIT PARAGRAPH
            END-EVALUATE
            COMPUTE WS-HEXVAL = WS-HEXVAL * 16 + WS-HEXDIG
        END-PERFORM
        IF WS-HEXVAL < 56320 OR WS-HEXVAL > 57343
            MOVE CVX-ERR TO LK-STATUS
            EXIT PARAGRAPH
        END-IF
        COMPUTE WS-HEXVAL = 65536 + (WS-ACC - 55296) * 1024
                          + (WS-HEXVAL - 56320)
        ADD 3 TO WS-I
    ELSE
        IF WS-HEXVAL >= 56320 AND WS-HEXVAL <= 57343
            MOVE CVX-ERR TO LK-STATUS
            EXIT PARAGRAPH
        END-IF
    END-IF

    PERFORM JSON-EMIT-UTF8.

JSON-EMIT-UTF8.
    EVALUATE TRUE
        WHEN WS-HEXVAL < 128
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-HEXVAL + 1)
                TO LK-OUT(WS-ESC-OUT:1)
        WHEN WS-HEXVAL < 2048
            COMPUTE WS-U1 = 192 + FUNCTION INTEGER(WS-HEXVAL / 64)
            COMPUTE WS-U2 = 128 + FUNCTION MOD(WS-HEXVAL, 64)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U2 + 1) TO LK-OUT(WS-ESC-OUT:1)
        WHEN WS-HEXVAL < 65536
            COMPUTE WS-U1 = 224 + FUNCTION INTEGER(WS-HEXVAL / 4096)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
            COMPUTE WS-U1 =
                128 + FUNCTION MOD(FUNCTION INTEGER(WS-HEXVAL / 64), 64)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
            COMPUTE WS-U1 = 128 + FUNCTION MOD(WS-HEXVAL, 64)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
        WHEN OTHER
            COMPUTE WS-U1 = 240 + FUNCTION INTEGER(WS-HEXVAL / 262144)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
            COMPUTE WS-U1 = 128
                + FUNCTION MOD(FUNCTION INTEGER(WS-HEXVAL / 4096), 64)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
            COMPUTE WS-U1 = 128
                + FUNCTION MOD(FUNCTION INTEGER(WS-HEXVAL / 64), 64)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
            COMPUTE WS-U1 = 128 + FUNCTION MOD(WS-HEXVAL, 64)
            ADD 1 TO WS-ESC-OUT
            MOVE FUNCTION CHAR(WS-U1 + 1) TO LK-OUT(WS-ESC-OUT:1)
    END-EVALUATE.

END PROGRAM CVXJSON.
