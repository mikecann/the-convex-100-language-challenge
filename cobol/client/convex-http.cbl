>>SOURCE FORMAT IS FREE
*> ==================================================================
*> HTTP/1.1 request and response framing, written in COBOL.
*>
*> The native layer supplies only "move these bytes before this
*> deadline". Building the request line, parsing the status line and
*> headers, honouring Content-Length or chunked framing, and enforcing
*> every bound is done here.
*>
*> Two rules shape the reader:
*>
*>  * A declared length is validated before a single byte of the thing
*>    it describes is accepted. An oversized Content-Length or chunk
*>    size is refused while it is still just a number.
*>
*>  * One absolute deadline covers connect, write, and the whole read.
*>    A peer that dribbles a byte at a time cannot extend the request
*>    by resetting a per-read timer.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CVXHTTP.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

01 WS-MAX-BODY              BINARY-LONG VALUE 2097152.
01 WS-MAX-HEADER-BYTES      BINARY-LONG VALUE 16384.
01 WS-MAX-HEADERS           BINARY-LONG VALUE 64.
01 WS-MAX-LINE              BINARY-LONG VALUE 8192.

*> Receive buffer. Header parsing and body reading share it, so bytes
*> that arrive in the same packet as the headers are never lost.
01 WS-RX                    PIC X(2113536).
01 WS-RX-LEN                BINARY-LONG.
01 WS-RX-POS                BINARY-LONG.

01 WS-REQ                   PIC X(12288).
01 WS-REQ-LEN               BINARY-LONG.
*> Raw incoming status-code bytes are copied in and out of this field
*> by reference modification (see HTTP-READ-STATUS-LINE), so it stays
*> plain alphanumeric rather than numeric-edited.
01 WS-NUMTEXT               PIC X(32).
*> `MOVE` from a BINARY-LONG straight to an alphanumeric field pads
*> with leading zeros, not spaces, so `FUNCTION TRIM` in
*> HTTP-BUILD-REQUEST could not remove them from the Content-Length
*> value; a numeric-edited intermediate suppresses them to spaces.
01 WS-BODY-LEN-EDIT          PIC Z(9)9.

01 WS-HANDLE                BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-GOT                   BINARY-LONG.
01 WS-SENT                  BINARY-LONG.
01 WS-I                     BINARY-LONG.
01 WS-J                     BINARY-LONG.
01 WS-LINE-START            BINARY-LONG.
01 WS-LINE-LEN              BINARY-LONG.
01 WS-HDR-COUNT             BINARY-LONG.
01 WS-HDR-BYTES             BINARY-LONG.
01 WS-CONTENT-LENGTH        BINARY-LONG.
01 WS-HAS-LENGTH            BINARY-LONG.
01 WS-CHUNKED               BINARY-LONG.
01 WS-CHUNK-SIZE            BINARY-LONG.
01 WS-BODY-LEN              BINARY-LONG.
01 WS-DONE                  BINARY-LONG.
01 WS-ERR                   BINARY-LONG.
*> The parsed status line's code, shared scratch between both entries
*> below. `cvx-http-read-into` receives no `CVX-HTTP-REQ` (it only
*> reads a handle the caller already opened), so `CVX-HR-CODE` -- a
*> field inside that group item -- has no bound storage on that call
*> path; touching it there is a reference to unallocated memory.
*> `cvx-http-post` still copies this into `CVX-HR-CODE` afterward,
*> since that field is the caller-visible "filled in on return" result
*> for its own group-item parameter.
01 WS-STATUS-CODE           BINARY-LONG.
01 WS-CH                    PIC X.
01 WS-LOWER                 PIC X(64).
01 WS-CRLF                  PIC X(2).
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-NOW                   BINARY-DOUBLE.
01 WS-HEXDIG                BINARY-LONG.
01 WS-NAME-LEN              BINARY-LONG.
01 WS-VALUE-START           BINARY-LONG.
01 WS-VALUE-LEN             BINARY-LONG.

LINKAGE SECTION.
COPY "cvx-http.cpy".
01 LK-BODY                  PIC X(2097152).
01 LK-BODY-LEN              BINARY-LONG.
01 LK-OUT                   PIC X(2097152).
01 LK-OUT-LEN               BINARY-LONG.
01 LK-STATUS                BINARY-LONG.
*> Used only by cvx-http-read-into, which reads a connection the
*> caller already owns.
01 LK-HANDLE                BINARY-LONG.
01 LK-DEADLINE              BINARY-DOUBLE.
01 LK-CODE                  BINARY-LONG.

PROCEDURE DIVISION.
CVXHTTP-MAIN SECTION.
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-http-post: one complete request/response exchange.
*> Connection: close is requested every time, so there is no pooled
*> state to go stale between calls and no keep-alive race to reason
*> about in a single threaded client.
*> ------------------------------------------------------------------
ENTRY "cvx-http-post" USING CVX-HTTP-REQ LK-BODY LK-BODY-LEN
        LK-OUT LK-OUT-LEN LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-OUT-LEN
    MOVE 0 TO WS-STATUS-CODE
    MOVE 0 TO CVX-HR-CODE
    MOVE CVX-HR-DEADLINE TO WS-DEADLINE
    MOVE 0 TO WS-RX-LEN
    MOVE 1 TO WS-RX-POS
    MOVE 0 TO WS-ERR

    IF LK-BODY-LEN < 0 OR LK-BODY-LEN > WS-MAX-BODY
        MOVE CVX-LIMIT TO LK-STATUS
        GOBACK
    END-IF

    CALL "cvx_net_open" USING
        BY REFERENCE CVX-HR-HOST
        BY VALUE CVX-HR-HOST-LEN
        BY VALUE CVX-HR-PORT
        BY VALUE CVX-HR-SECURE
        BY VALUE WS-DEADLINE
        RETURNING WS-HANDLE
    IF WS-HANDLE < 0
        MOVE WS-HANDLE TO LK-STATUS
        GOBACK
    END-IF

    PERFORM HTTP-BUILD-REQUEST
    CALL "cvx_net_write" USING
        BY VALUE WS-HANDLE
        BY REFERENCE WS-REQ
        BY VALUE WS-REQ-LEN
        BY VALUE WS-DEADLINE
        BY REFERENCE WS-SENT
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE WS-RC TO LK-STATUS
        PERFORM HTTP-CLOSE
        GOBACK
    END-IF
    IF LK-BODY-LEN > 0
        CALL "cvx_net_write" USING
            BY VALUE WS-HANDLE
            BY REFERENCE LK-BODY
            BY VALUE LK-BODY-LEN
            BY VALUE WS-DEADLINE
            BY REFERENCE WS-SENT
            RETURNING WS-RC
        IF WS-RC NOT = CVX-OK
            MOVE WS-RC TO LK-STATUS
            PERFORM HTTP-CLOSE
            GOBACK
        END-IF
    END-IF

    PERFORM HTTP-READ-STATUS-LINE
    MOVE WS-STATUS-CODE TO CVX-HR-CODE
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
        PERFORM HTTP-CLOSE
        GOBACK
    END-IF
    PERFORM HTTP-READ-HEADERS
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
        PERFORM HTTP-CLOSE
        GOBACK
    END-IF
    PERFORM HTTP-READ-BODY
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
        PERFORM HTTP-CLOSE
        GOBACK
    END-IF

    MOVE WS-BODY-LEN TO LK-OUT-LEN
    PERFORM HTTP-CLOSE
    GOBACK.

HTTP-CLOSE.
    CALL "cvx_net_close" USING BY VALUE WS-HANDLE RETURNING WS-RC.

*> `PERFORM paragraph-name` (no THRU) only stops at the next
*> paragraph-name; an ENTRY statement is not a paragraph boundary. A
*> `PERFORM HTTP-CLOSE` from inside cvx-http-post's error paths would
*> otherwise fall straight through into cvx-http-read-into's own body
*> below -- still inside the active cvx-http-post call -- and touch
*> LK-CODE, which is not one of cvx-http-post's parameters and so has
*> no bound storage there. That is a reference to unallocated memory,
*> not merely wrong behaviour.
HTTP-CLOSE-EXIT.
    EXIT.

*> ------------------------------------------------------------------
*> cvx-http-read-into: the response half of an exchange, against a
*> handle the caller already owns.
*>
*> cvx-http-post is exactly this preceded by connect and write, so the
*> fixture tests drive the real reader rather than a copy of it. The
*> entry grants no new capability: it cannot open a connection, only
*> read one it was handed.
*> ------------------------------------------------------------------
ENTRY "cvx-http-read-into" USING LK-HANDLE LK-DEADLINE LK-CODE
        LK-OUT LK-OUT-LEN LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-OUT-LEN
    MOVE 0 TO LK-CODE
    MOVE LK-HANDLE TO WS-HANDLE
    MOVE LK-DEADLINE TO WS-DEADLINE
    MOVE 0 TO WS-RX-LEN
    MOVE 1 TO WS-RX-POS
    MOVE 0 TO WS-ERR
    MOVE 0 TO WS-STATUS-CODE

    PERFORM HTTP-READ-STATUS-LINE
    IF WS-ERR = 0
        PERFORM HTTP-READ-HEADERS
    END-IF
    IF WS-ERR = 0
        PERFORM HTTP-READ-BODY
    END-IF
    MOVE WS-STATUS-CODE TO LK-CODE
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    MOVE WS-BODY-LEN TO LK-OUT-LEN
    GOBACK.

*> ------------------------------------------------------------------
*> Request construction
*> ------------------------------------------------------------------
HTTP-BUILD-REQUEST.
    MOVE SPACES TO WS-REQ
    MOVE 1 TO WS-REQ-LEN
    MOVE LK-BODY-LEN TO WS-BODY-LEN-EDIT
    MOVE WS-BODY-LEN-EDIT TO WS-NUMTEXT
    STRING
        "POST " DELIMITED SIZE
        CVX-HR-PATH(1:CVX-HR-PATH-LEN) DELIMITED SIZE
        " HTTP/1.1" X"0D0A" DELIMITED SIZE
        "Host: " DELIMITED SIZE
        CVX-HR-HOST(1:CVX-HR-HOST-LEN) DELIMITED SIZE
        X"0D0A" DELIMITED SIZE
        "Content-Type: application/json" X"0D0A" DELIMITED SIZE
        "Accept: application/json" X"0D0A" DELIMITED SIZE
        "Connection: close" X"0D0A" DELIMITED SIZE
        "Convex-Client: " DELIMITED SIZE
        CVX-HR-CLIENTV(1:CVX-HR-CLIENTV-LEN) DELIMITED SIZE
        X"0D0A" DELIMITED SIZE
        "Content-Length: " DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        X"0D0A" DELIMITED SIZE
        INTO WS-REQ
        WITH POINTER WS-REQ-LEN
    END-STRING
    *> An empty token means "no Authorization header at all", which is
    *> how the adapter clears auth between conformance cases.
    IF CVX-HR-TOKEN-LEN > 0
        STRING
            "Authorization: Bearer " DELIMITED SIZE
            CVX-HR-TOKEN(1:CVX-HR-TOKEN-LEN) DELIMITED SIZE
            X"0D0A" DELIMITED SIZE
            INTO WS-REQ
            WITH POINTER WS-REQ-LEN
        END-STRING
    END-IF
    STRING
        X"0D0A" DELIMITED SIZE
        INTO WS-REQ
        WITH POINTER WS-REQ-LEN
    END-STRING
    SUBTRACT 1 FROM WS-REQ-LEN.

*> ------------------------------------------------------------------
*> Response reading
*> ------------------------------------------------------------------

*> Pull more bytes into the shared receive buffer. Returns WS-ERR on a
*> deadline breach or a peer that closed mid message.
HTTP-FILL.
    IF WS-RX-LEN >= WS-MAX-BODY + 16384
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx_net_read" USING
        BY VALUE WS-HANDLE
        BY REFERENCE WS-RX(WS-RX-LEN + 1:1)
        BY VALUE 65536
        BY VALUE WS-DEADLINE
        BY REFERENCE WS-GOT
        RETURNING WS-RC
    EVALUATE WS-RC
        WHEN CVX-OK
            ADD WS-GOT TO WS-RX-LEN
        WHEN CVX-EOF
            MOVE 2 TO WS-DONE
        WHEN OTHER
            MOVE 1 TO WS-ERR
    END-EVALUATE.

*> Find the next CRLF terminated line inside the buffer, reading more
*> bytes if it is not complete yet.
HTTP-NEXT-LINE.
    MOVE 0 TO WS-LINE-LEN
    MOVE WS-RX-POS TO WS-LINE-START
    MOVE 0 TO WS-DONE
    PERFORM UNTIL WS-DONE NOT = 0 OR WS-ERR NOT = 0
        MOVE 0 TO WS-I
        PERFORM VARYING WS-J FROM WS-LINE-START BY 1
                UNTIL WS-J > WS-RX-LEN - 1
            IF WS-RX(WS-J:2) = X"0D0A"
                MOVE WS-J TO WS-I
                EXIT PERFORM
            END-IF
        END-PERFORM
        IF WS-I > 0
            COMPUTE WS-LINE-LEN = WS-I - WS-LINE-START
            COMPUTE WS-RX-POS = WS-I + 2
            MOVE 1 TO WS-DONE
        ELSE
            IF WS-RX-LEN - WS-LINE-START > WS-MAX-LINE
                MOVE 1 TO WS-ERR
            ELSE
                PERFORM HTTP-FILL
                IF WS-DONE = 2
                    MOVE 1 TO WS-ERR
                END-IF
            END-IF
        END-IF
    END-PERFORM.

HTTP-READ-STATUS-LINE.
    PERFORM HTTP-NEXT-LINE
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    IF WS-LINE-LEN < 12
            OR WS-RX(WS-LINE-START:5) NOT = "HTTP/"
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    MOVE WS-RX(WS-LINE-START + 9:3) TO WS-NUMTEXT(1:3)
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 3
        MOVE WS-NUMTEXT(WS-I:1) TO WS-CH
        IF WS-CH < "0" OR WS-CH > "9"
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
    END-PERFORM
    COMPUTE WS-STATUS-CODE = FUNCTION NUMVAL(WS-NUMTEXT(1:3)).

HTTP-READ-HEADERS.
    MOVE 0 TO WS-HDR-COUNT
    MOVE 0 TO WS-HDR-BYTES
    MOVE 0 TO WS-CONTENT-LENGTH
    MOVE 0 TO WS-HAS-LENGTH
    MOVE 0 TO WS-CHUNKED
    PERFORM UNTIL WS-ERR NOT = 0
        PERFORM HTTP-NEXT-LINE
        IF WS-ERR NOT = 0
            EXIT PERFORM
        END-IF
        IF WS-LINE-LEN = 0
            EXIT PERFORM
        END-IF
        ADD 1 TO WS-HDR-COUNT
        ADD WS-LINE-LEN TO WS-HDR-BYTES
        IF WS-HDR-COUNT > WS-MAX-HEADERS
                OR WS-HDR-BYTES > WS-MAX-HEADER-BYTES
            MOVE 1 TO WS-ERR
            EXIT PERFORM
        END-IF
        PERFORM HTTP-PARSE-HEADER
    END-PERFORM
    *> Exactly one framing rule must apply. Accepting both invites the
    *> classic request smuggling ambiguity.
    IF WS-ERR = 0 AND WS-CHUNKED = 1 AND WS-HAS-LENGTH = 1
        MOVE 1 TO WS-ERR
    END-IF.

HTTP-PARSE-HEADER.
    MOVE 0 TO WS-NAME-LEN
    PERFORM VARYING WS-I FROM 0 BY 1 UNTIL WS-I >= WS-LINE-LEN
        IF WS-RX(WS-LINE-START + WS-I:1) = ":"
            MOVE WS-I TO WS-NAME-LEN
            EXIT PERFORM
        END-IF
    END-PERFORM
    IF WS-NAME-LEN = 0 OR WS-NAME-LEN > 64
        EXIT PARAGRAPH
    END-IF
    MOVE SPACES TO WS-LOWER
    MOVE WS-RX(WS-LINE-START:WS-NAME-LEN) TO WS-LOWER(1:WS-NAME-LEN)
    MOVE FUNCTION LOWER-CASE(WS-LOWER) TO WS-LOWER

    *> Skip the colon and any optional whitespace.
    COMPUTE WS-VALUE-START = WS-LINE-START + WS-NAME-LEN + 1
    COMPUTE WS-VALUE-LEN = WS-LINE-LEN - WS-NAME-LEN - 1
    PERFORM UNTIL WS-VALUE-LEN <= 0
            OR WS-RX(WS-VALUE-START:1) NOT = SPACE
        ADD 1 TO WS-VALUE-START
        SUBTRACT 1 FROM WS-VALUE-LEN
    END-PERFORM
    IF WS-VALUE-LEN <= 0
        EXIT PARAGRAPH
    END-IF

    EVALUATE TRUE
        WHEN WS-LOWER(1:15) = "content-length "
                OR WS-LOWER(1:14) = "content-length"
            IF WS-VALUE-LEN > 18
                MOVE 1 TO WS-ERR
                EXIT PARAGRAPH
            END-IF
            PERFORM VARYING WS-I FROM 0 BY 1
                    UNTIL WS-I >= WS-VALUE-LEN
                MOVE WS-RX(WS-VALUE-START + WS-I:1) TO WS-CH
                IF WS-CH < "0" OR WS-CH > "9"
                    MOVE 1 TO WS-ERR
                    EXIT PARAGRAPH
                END-IF
            END-PERFORM
            COMPUTE WS-CONTENT-LENGTH = FUNCTION NUMVAL(
                WS-RX(WS-VALUE-START:WS-VALUE-LEN))
            MOVE 1 TO WS-HAS-LENGTH
            *> Refuse an oversized body while it is still a number.
            IF WS-CONTENT-LENGTH > WS-MAX-BODY
                MOVE 1 TO WS-ERR
            END-IF
        WHEN WS-LOWER(1:18) = "transfer-encoding "
                OR WS-LOWER(1:17) = "transfer-encoding"
            IF FUNCTION LOWER-CASE(
                    WS-RX(WS-VALUE-START:WS-VALUE-LEN)) = "chunked"
                MOVE 1 TO WS-CHUNKED
            ELSE
                MOVE 1 TO WS-ERR
            END-IF
    END-EVALUATE.

HTTP-READ-BODY.
    MOVE 0 TO WS-BODY-LEN
    EVALUATE TRUE
        WHEN WS-CHUNKED = 1
            PERFORM HTTP-READ-CHUNKED
        WHEN WS-HAS-LENGTH = 1
            PERFORM HTTP-READ-COUNTED
        WHEN OTHER
            *> Connection: close was requested, so a reply without
            *> either framing header ends at end of stream.
            PERFORM HTTP-READ-TO-EOF
    END-EVALUATE.

HTTP-READ-COUNTED.
    PERFORM UNTIL WS-RX-LEN - WS-RX-POS + 1 >= WS-CONTENT-LENGTH
            OR WS-ERR NOT = 0
        MOVE 0 TO WS-DONE
        PERFORM HTTP-FILL
        IF WS-DONE = 2
            MOVE 1 TO WS-ERR
        END-IF
    END-PERFORM
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    IF WS-CONTENT-LENGTH > 0
        MOVE WS-RX(WS-RX-POS:WS-CONTENT-LENGTH)
            TO LK-OUT(1:WS-CONTENT-LENGTH)
    END-IF
    MOVE WS-CONTENT-LENGTH TO WS-BODY-LEN.

HTTP-READ-TO-EOF.
    MOVE 0 TO WS-DONE
    PERFORM UNTIL WS-DONE = 2 OR WS-ERR NOT = 0
        PERFORM HTTP-FILL
    END-PERFORM
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-BODY-LEN = WS-RX-LEN - WS-RX-POS + 1
    IF WS-BODY-LEN < 0
        MOVE 0 TO WS-BODY-LEN
    END-IF
    IF WS-BODY-LEN > WS-MAX-BODY
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-BODY-LEN > 0
        MOVE WS-RX(WS-RX-POS:WS-BODY-LEN) TO LK-OUT(1:WS-BODY-LEN)
    END-IF.

HTTP-READ-CHUNKED.
    MOVE 0 TO WS-DONE
    PERFORM UNTIL WS-DONE = 1 OR WS-ERR NOT = 0
        PERFORM HTTP-NEXT-LINE
        IF WS-ERR NOT = 0
            EXIT PERFORM
        END-IF
        PERFORM HTTP-PARSE-CHUNK-SIZE
        IF WS-ERR NOT = 0
            EXIT PERFORM
        END-IF
        IF WS-CHUNK-SIZE = 0
            *> Consume the trailer section, then stop.
            PERFORM UNTIL WS-ERR NOT = 0
                PERFORM HTTP-NEXT-LINE
                IF WS-ERR NOT = 0 OR WS-LINE-LEN = 0
                    EXIT PERFORM
                END-IF
            END-PERFORM
            MOVE 1 TO WS-DONE
            EXIT PERFORM
        END-IF
        *> The running total is checked before the chunk is copied.
        IF WS-BODY-LEN + WS-CHUNK-SIZE > WS-MAX-BODY
            MOVE 1 TO WS-ERR
            EXIT PERFORM
        END-IF
        PERFORM UNTIL WS-RX-LEN - WS-RX-POS + 1 >= WS-CHUNK-SIZE + 2
                OR WS-ERR NOT = 0
            MOVE 0 TO WS-DONE
            PERFORM HTTP-FILL
            IF WS-DONE = 2
                MOVE 1 TO WS-ERR
            END-IF
        END-PERFORM
        MOVE 0 TO WS-DONE
        IF WS-ERR NOT = 0
            EXIT PERFORM
        END-IF
        MOVE WS-RX(WS-RX-POS:WS-CHUNK-SIZE)
            TO LK-OUT(WS-BODY-LEN + 1:WS-CHUNK-SIZE)
        ADD WS-CHUNK-SIZE TO WS-BODY-LEN
        COMPUTE WS-RX-POS = WS-RX-POS + WS-CHUNK-SIZE
        IF WS-RX(WS-RX-POS:2) NOT = X"0D0A"
            MOVE 1 TO WS-ERR
            EXIT PERFORM
        END-IF
        ADD 2 TO WS-RX-POS
    END-PERFORM.

HTTP-PARSE-CHUNK-SIZE.
    MOVE 0 TO WS-CHUNK-SIZE
    IF WS-LINE-LEN < 1
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    PERFORM VARYING WS-I FROM 0 BY 1 UNTIL WS-I >= WS-LINE-LEN
        MOVE WS-RX(WS-LINE-START + WS-I:1) TO WS-CH
        *> A chunk extension after ";" is legal and ignored.
        IF WS-CH = ";"
            EXIT PERFORM
        END-IF
        EVALUATE TRUE
            WHEN WS-CH >= "0" AND WS-CH <= "9"
                COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 49
            WHEN WS-CH >= "a" AND WS-CH <= "f"
                COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 88
            WHEN WS-CH >= "A" AND WS-CH <= "F"
                COMPUTE WS-HEXDIG = FUNCTION ORD(WS-CH) - 56
            WHEN OTHER
                MOVE 1 TO WS-ERR
                EXIT PARAGRAPH
        END-EVALUATE
        *> Bound the declared size before it is ever used to size a
        *> copy, rather than after.
        IF WS-CHUNK-SIZE > 134217728
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
        COMPUTE WS-CHUNK-SIZE = WS-CHUNK-SIZE * 16 + WS-HEXDIG
    END-PERFORM
    IF WS-CHUNK-SIZE > WS-MAX-BODY
        MOVE 1 TO WS-ERR
    END-IF.

END PROGRAM CVXHTTP.
