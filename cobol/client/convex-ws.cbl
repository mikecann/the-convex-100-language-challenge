>>SOURCE FORMAT IS FREE
*> ==================================================================
*> RFC 6455 WebSocket transport, written in COBOL.
*>
*> The parser is resumable by construction. Raw bytes accumulate in
*> WS-WRX and a frame is only decoded once it is entirely present, so
*> a read that times out halfway through a frame simply leaves the
*> bytes buffered. Parser state is never rewound to a guessed frame
*> boundary, which is the failure this design exists to prevent.
*>
*> A declared payload length is compared against the frame limit the
*> moment the length field is decoded, before the client waits for or
*> copies any payload byte.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CVXWS.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

01 WS-MAX-FRAME             BINARY-LONG VALUE 2097152.
01 WS-MAX-MESSAGE           BINARY-LONG VALUE 2097152.
01 WS-MAX-FRAGMENTS         BINARY-LONG VALUE 4096.
01 WS-RX-CAP                BINARY-LONG VALUE 4227072.

01 WS-GUID                  PIC X(36) VALUE
   "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".

*> Raw receive buffer and its consumed prefix.
01 WS-WRX                   PIC X(4227072).
01 WS-WRX-LEN               BINARY-LONG VALUE 0.
01 WS-WRX-POS               BINARY-LONG VALUE 1.

*> Reassembly state for fragmented messages.
01 WS-MSG                   PIC X(2097152).
01 WS-MSG-LEN               BINARY-LONG VALUE 0.
01 WS-FRAG-ACTIVE           BINARY-LONG VALUE 0.
01 WS-FRAG-OPCODE           BINARY-LONG VALUE 0.
01 WS-FRAG-COUNT            BINARY-LONG VALUE 0.

01 WS-HANDSHAKE             PIC X(1024).
01 WS-HS-LEN                BINARY-LONG.
*> Outgoing frame header. Kept separate from WS-HANDSHAKE so a pong
*> emitted during polling can never overwrite handshake state.
01 WS-FHDR                  PIC X(16).
01 WS-KEY-RAW               PIC X(16).
01 WS-KEY-B64               PIC X(32).
01 WS-KEY-B64-LEN           BINARY-LONG.
01 WS-ACCEPT-SRC            PIC X(64).
01 WS-ACCEPT-SHA            PIC X(20).
01 WS-ACCEPT-B64            PIC X(32).
01 WS-ACCEPT-B64-LEN        BINARY-LONG.
01 WS-SEEN-ACCEPT           PIC X(32).
01 WS-HAS-ACCEPT            BINARY-LONG.

01 WS-MASK                  PIC X(4).
01 WS-OUT-FRAME             PIC X(2097166).
01 WS-OUT-LEN               BINARY-LONG.
01 WS-XOR-IN                PIC X.
01 WS-XOR-KEY               PIC X.
01 WS-XOR-OUT               PIC X.

01 WS-HANDLE                BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-GOT                   BINARY-LONG.
01 WS-SENT                  BINARY-LONG.
01 WS-I                     BINARY-LONG.
01 WS-J                     BINARY-LONG.
01 WS-K                     BINARY-LONG.
01 WS-B1                    BINARY-LONG.
01 WS-B2                    BINARY-LONG.
01 WS-FIN                   BINARY-LONG.
01 WS-RSV                   BINARY-LONG.
01 WS-OPCODE                BINARY-LONG.
01 WS-MASKED                BINARY-LONG.
01 WS-MARKER                BINARY-LONG.
01 WS-PAYLEN                BINARY-DOUBLE.
01 WS-HDRLEN                BINARY-LONG.
01 WS-AVAIL                 BINARY-LONG.
01 WS-NEEDED                BINARY-DOUBLE.
01 WS-ERR                   BINARY-LONG.
01 WS-COMPLETE              BINARY-LONG.
*> Snapshot of WS-WRX-POS from before the last WS-TRY-FRAME, so the
*> poll loop can tell whether it actually consumed a frame.
01 WS-PREV-WRX-POS          BINARY-LONG.
01 WS-CLOSE-CODE            BINARY-LONG.
01 WS-BYTE                  BINARY-LONG.
01 WS-CH                    PIC X.
01 WS-LINE-START            BINARY-LONG.
01 WS-LINE-LEN              BINARY-LONG.
01 WS-DONE                  BINARY-LONG.
01 WS-NAME-LEN              BINARY-LONG.
01 WS-VALUE-START           BINARY-LONG.
01 WS-VALUE-LEN             BINARY-LONG.
01 WS-LOWER                 PIC X(64).
01 WS-HDR-COUNT             BINARY-LONG.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-SIXTEEN               BINARY-LONG VALUE 16.
01 WS-TWENTY                BINARY-LONG VALUE 20.
01 WS-FIFTYTWO              BINARY-LONG VALUE 52.

LINKAGE SECTION.
01 LK-HOST                  PIC X(256).
01 LK-HOST-LEN              BINARY-LONG.
01 LK-PORT                  BINARY-LONG.
01 LK-SECURE                BINARY-LONG.
01 LK-PATH                  PIC X(256).
01 LK-PATH-LEN              BINARY-LONG.
01 LK-CLIENTV               PIC X(64).
01 LK-CLIENTV-LEN           BINARY-LONG.
01 LK-DEADLINE              BINARY-DOUBLE.
01 LK-HANDLE                BINARY-LONG.
01 LK-STATUS                BINARY-LONG.
01 LK-BUF                   PIC X(2097152).
01 LK-LEN                   BINARY-LONG.
01 LK-OPCODE                BINARY-LONG.

PROCEDURE DIVISION.
CVXWS-MAIN SECTION.
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-ws-connect: open the socket and complete the RFC 6455 upgrade.
*> The Sec-WebSocket-Accept value is recomputed locally and compared,
*> so a server that does not actually speak WebSocket is rejected
*> before any frame is parsed.
*> ------------------------------------------------------------------
ENTRY "cvx-ws-connect" USING LK-HOST LK-HOST-LEN LK-PORT LK-SECURE
        LK-PATH LK-PATH-LEN LK-CLIENTV LK-CLIENTV-LEN LK-DEADLINE
        LK-HANDLE LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE LK-DEADLINE TO WS-DEADLINE
    PERFORM WS-RESET-STATE

    CALL "cvx_net_open" USING
        BY REFERENCE LK-HOST
        BY VALUE LK-HOST-LEN
        BY VALUE LK-PORT
        BY VALUE LK-SECURE
        BY VALUE WS-DEADLINE
        RETURNING WS-HANDLE
    IF WS-HANDLE < 0
        MOVE WS-HANDLE TO LK-STATUS
        MOVE -1 TO LK-HANDLE
        GOBACK
    END-IF
    MOVE WS-HANDLE TO LK-HANDLE

    *> A fresh 16 byte nonce per connection, as required.
    CALL "cvx_random_bytes" USING
        BY REFERENCE WS-KEY-RAW
        BY VALUE WS-SIXTEEN
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE CVX-ERR TO LK-STATUS
        PERFORM WS-CLOSE-HANDLE
        GOBACK
    END-IF
    CALL "cvx-b64-encode" USING WS-KEY-RAW WS-SIXTEEN
        WS-KEY-B64 WS-KEY-B64-LEN

    MOVE SPACES TO WS-ACCEPT-SRC
    MOVE WS-KEY-B64(1:WS-KEY-B64-LEN) TO WS-ACCEPT-SRC(1:WS-KEY-B64-LEN)
    MOVE WS-GUID TO WS-ACCEPT-SRC(WS-KEY-B64-LEN + 1:36)
    COMPUTE WS-FIFTYTWO = WS-KEY-B64-LEN + 36
    CALL "cvx_sha1" USING
        BY REFERENCE WS-ACCEPT-SRC
        BY VALUE WS-FIFTYTWO
        BY REFERENCE WS-ACCEPT-SHA
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE CVX-ERR TO LK-STATUS
        PERFORM WS-CLOSE-HANDLE
        GOBACK
    END-IF
    CALL "cvx-b64-encode" USING WS-ACCEPT-SHA WS-TWENTY
        WS-ACCEPT-B64 WS-ACCEPT-B64-LEN

    MOVE SPACES TO WS-HANDSHAKE
    MOVE 1 TO WS-HS-LEN
    STRING
        "GET " DELIMITED SIZE
        LK-PATH(1:LK-PATH-LEN) DELIMITED SIZE
        " HTTP/1.1" X"0D0A" DELIMITED SIZE
        "Host: " DELIMITED SIZE
        LK-HOST(1:LK-HOST-LEN) DELIMITED SIZE
        X"0D0A" DELIMITED SIZE
        "Upgrade: websocket" X"0D0A" DELIMITED SIZE
        "Connection: Upgrade" X"0D0A" DELIMITED SIZE
        "Sec-WebSocket-Key: " DELIMITED SIZE
        WS-KEY-B64(1:WS-KEY-B64-LEN) DELIMITED SIZE
        X"0D0A" DELIMITED SIZE
        "Sec-WebSocket-Version: 13" X"0D0A" DELIMITED SIZE
        "Convex-Client: " DELIMITED SIZE
        LK-CLIENTV(1:LK-CLIENTV-LEN) DELIMITED SIZE
        X"0D0A" X"0D0A" DELIMITED SIZE
        INTO WS-HANDSHAKE
        WITH POINTER WS-HS-LEN
    END-STRING
    SUBTRACT 1 FROM WS-HS-LEN

    CALL "cvx_net_write" USING
        BY VALUE WS-HANDLE
        BY REFERENCE WS-HANDSHAKE
        BY VALUE WS-HS-LEN
        BY VALUE WS-DEADLINE
        BY REFERENCE WS-SENT
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE WS-RC TO LK-STATUS
        PERFORM WS-CLOSE-HANDLE
        GOBACK
    END-IF

    PERFORM WS-READ-UPGRADE
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
        PERFORM WS-CLOSE-HANDLE
    END-IF
    GOBACK.

WS-CLOSE-HANDLE.
    CALL "cvx_net_close" USING BY VALUE WS-HANDLE RETURNING WS-RC
    MOVE -1 TO LK-HANDLE.

*> `PERFORM paragraph-name` (no THRU) only stops at the next
*> paragraph-name; an ENTRY statement is not a paragraph boundary. A
*> `PERFORM WS-CLOSE-HANDLE` from inside cvx-ws-connect's error paths
*> would otherwise fall straight through into cvx-ws-reset's body and
*> then its own GOBACK, silently skipping the caller's own follow-up
*> GOBACK -- not a crash here (cvx-ws-reset takes no parameters to
*> touch unbound), but still control flow the caller never asked for.
WS-CLOSE-HANDLE-EXIT.
    EXIT.

*> Reset every piece of parser state. Called on connect and whenever
*> the Live owner retires a socket, so a new connection can never
*> inherit a half decoded frame from the previous one.
ENTRY "cvx-ws-reset".
    PERFORM WS-RESET-STATE
    GOBACK.

WS-RESET-STATE.
    MOVE 0 TO WS-WRX-LEN
    MOVE 1 TO WS-WRX-POS
    MOVE 0 TO WS-MSG-LEN
    MOVE 0 TO WS-FRAG-ACTIVE
    MOVE 0 TO WS-FRAG-OPCODE
    MOVE 0 TO WS-FRAG-COUNT
    MOVE 0 TO WS-ERR.

*> ------------------------------------------------------------------
*> Handshake response
*> ------------------------------------------------------------------
WS-READ-UPGRADE.
    MOVE 0 TO WS-ERR
    MOVE 0 TO WS-HAS-ACCEPT
    MOVE 0 TO WS-HDR-COUNT
    PERFORM WS-NEXT-LINE
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    IF WS-LINE-LEN < 12
            OR WS-WRX(WS-LINE-START:13) NOT = "HTTP/1.1 101 "
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    PERFORM UNTIL WS-ERR NOT = 0
        PERFORM WS-NEXT-LINE
        IF WS-ERR NOT = 0 OR WS-LINE-LEN = 0
            EXIT PERFORM
        END-IF
        ADD 1 TO WS-HDR-COUNT
        IF WS-HDR-COUNT > 64
            MOVE 1 TO WS-ERR
            EXIT PERFORM
        END-IF
        PERFORM WS-PARSE-UPGRADE-HEADER
    END-PERFORM
    IF WS-ERR NOT = 0
        EXIT PARAGRAPH
    END-IF
    IF WS-HAS-ACCEPT = 0
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-SEEN-ACCEPT(1:WS-ACCEPT-B64-LEN)
            NOT = WS-ACCEPT-B64(1:WS-ACCEPT-B64-LEN)
        MOVE 1 TO WS-ERR
    END-IF.

WS-PARSE-UPGRADE-HEADER.
    MOVE 0 TO WS-NAME-LEN
    PERFORM VARYING WS-I FROM 0 BY 1 UNTIL WS-I >= WS-LINE-LEN
        IF WS-WRX(WS-LINE-START + WS-I:1) = ":"
            MOVE WS-I TO WS-NAME-LEN
            EXIT PERFORM
        END-IF
    END-PERFORM
    IF WS-NAME-LEN = 0 OR WS-NAME-LEN > 64
        EXIT PARAGRAPH
    END-IF
    MOVE SPACES TO WS-LOWER
    MOVE WS-WRX(WS-LINE-START:WS-NAME-LEN) TO WS-LOWER(1:WS-NAME-LEN)
    MOVE FUNCTION LOWER-CASE(WS-LOWER) TO WS-LOWER
    IF WS-LOWER(1:WS-NAME-LEN) NOT = "sec-websocket-accept"
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-VALUE-START = WS-LINE-START + WS-NAME-LEN + 1
    COMPUTE WS-VALUE-LEN = WS-LINE-LEN - WS-NAME-LEN - 1
    PERFORM UNTIL WS-VALUE-LEN <= 0
            OR WS-WRX(WS-VALUE-START:1) NOT = SPACE
        ADD 1 TO WS-VALUE-START
        SUBTRACT 1 FROM WS-VALUE-LEN
    END-PERFORM
    IF WS-VALUE-LEN <= 0 OR WS-VALUE-LEN > 32
        EXIT PARAGRAPH
    END-IF
    MOVE SPACES TO WS-SEEN-ACCEPT
    MOVE WS-WRX(WS-VALUE-START:WS-VALUE-LEN)
        TO WS-SEEN-ACCEPT(1:WS-VALUE-LEN)
    MOVE 1 TO WS-HAS-ACCEPT.

WS-NEXT-LINE.
    MOVE 0 TO WS-DONE
    MOVE WS-WRX-POS TO WS-LINE-START
    PERFORM UNTIL WS-DONE NOT = 0 OR WS-ERR NOT = 0
        MOVE 0 TO WS-I
        PERFORM VARYING WS-J FROM WS-LINE-START BY 1
                UNTIL WS-J > WS-WRX-LEN - 1
            IF WS-WRX(WS-J:2) = X"0D0A"
                MOVE WS-J TO WS-I
                EXIT PERFORM
            END-IF
        END-PERFORM
        IF WS-I > 0
            COMPUTE WS-LINE-LEN = WS-I - WS-LINE-START
            COMPUTE WS-WRX-POS = WS-I + 2
            MOVE 1 TO WS-DONE
        ELSE
            IF WS-WRX-LEN - WS-LINE-START > 8192
                MOVE 1 TO WS-ERR
            ELSE
                PERFORM WS-FILL
            END-IF
        END-IF
    END-PERFORM.

*> ------------------------------------------------------------------
*> Byte level buffering
*> ------------------------------------------------------------------

*> Slide unread bytes to the front so a long lived connection does not
*> walk off the end of the buffer.
WS-COMPACT.
    IF WS-WRX-POS > 1
        IF WS-WRX-LEN >= WS-WRX-POS
            COMPUTE WS-AVAIL = WS-WRX-LEN - WS-WRX-POS + 1
            MOVE WS-WRX(WS-WRX-POS:WS-AVAIL) TO WS-WRX(1:WS-AVAIL)
            MOVE WS-AVAIL TO WS-WRX-LEN
        ELSE
            MOVE 0 TO WS-WRX-LEN
        END-IF
        MOVE 1 TO WS-WRX-POS
    END-IF.

WS-FILL.
    PERFORM WS-COMPACT
    IF WS-WRX-LEN >= WS-RX-CAP - 65536
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx_net_read" USING
        BY VALUE WS-HANDLE
        BY REFERENCE WS-WRX(WS-WRX-LEN + 1:1)
        BY VALUE 65536
        BY VALUE WS-DEADLINE
        BY REFERENCE WS-GOT
        RETURNING WS-RC
    EVALUATE WS-RC
        WHEN CVX-OK
            ADD WS-GOT TO WS-WRX-LEN
        WHEN CVX-TIMEOUT
            MOVE 3 TO WS-ERR
        WHEN CVX-EOF
            MOVE 2 TO WS-ERR
        WHEN OTHER
            MOVE 1 TO WS-ERR
    END-EVALUATE.

*> See the comment on WS-CLOSE-HANDLE-EXIT: this guard keeps a
*> `PERFORM WS-FILL` from cvx-ws-connect's handshake read falling
*> through into cvx-ws-poll's body and touching its unbound LK-OPCODE,
*> LK-BUF, and LK-LEN.
WS-FILL-EXIT.
    EXIT.

*> ------------------------------------------------------------------
*> cvx-ws-poll: return the next complete application message.
*>
*> LK-STATUS is CVX-OK with LK-OPCODE and LK-LEN set when a message is
*> ready, CVX-TIMEOUT when nothing is complete yet and the buffered
*> bytes have been kept, CVX-EOF at a clean close, and CVX-ERR for a
*> protocol violation that must retire the connection.
*> ------------------------------------------------------------------
ENTRY "cvx-ws-poll" USING LK-HANDLE LK-DEADLINE LK-OPCODE LK-BUF
        LK-LEN LK-STATUS.
    MOVE LK-HANDLE TO WS-HANDLE
    MOVE LK-DEADLINE TO WS-DEADLINE
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-LEN
    MOVE 0 TO LK-OPCODE
    MOVE 0 TO WS-ERR
    MOVE 0 TO WS-COMPLETE

    *> A single `cvx_net_read` can return several whole frames at once
    *> (the three fragments of one reassembled message, say), and
    *> WS-TRY-FRAME only ever consumes the one already buffered at the
    *> front. Unconditionally filling after any incomplete result -- as
    *> this used to do -- ignores a second and third frame already
    *> sitting in WS-WRX and instead blocks in WS-FILL waiting for a
    *> read that will never come, until the deadline turns "already
    *> have it" into a spurious CVX-TIMEOUT. Only fill when
    *> WS-TRY-FRAME made no progress against the buffer; otherwise loop
    *> back and try it again first.
    PERFORM UNTIL WS-COMPLETE = 1 OR WS-ERR NOT = 0
        MOVE WS-WRX-POS TO WS-PREV-WRX-POS
        PERFORM WS-TRY-FRAME
        IF WS-ERR = 0 AND WS-COMPLETE = 0 AND WS-WRX-POS = WS-PREV-WRX-POS
            PERFORM WS-FILL
        END-IF
    END-PERFORM

    EVALUATE WS-ERR
        WHEN 0
            MOVE WS-MSG-LEN TO LK-LEN
            IF WS-MSG-LEN > 0
                MOVE WS-MSG(1:WS-MSG-LEN) TO LK-BUF(1:WS-MSG-LEN)
            END-IF
            MOVE WS-FRAG-OPCODE TO LK-OPCODE
            MOVE 0 TO WS-MSG-LEN
            MOVE 0 TO WS-FRAG-ACTIVE
            MOVE 0 TO WS-FRAG-COUNT
        WHEN 2
            MOVE CVX-EOF TO LK-STATUS
        WHEN 3
            *> Nothing complete yet. Buffered bytes stay exactly where
            *> they are so the next poll resumes mid frame.
            MOVE CVX-TIMEOUT TO LK-STATUS
        WHEN OTHER
            MOVE CVX-ERR TO LK-STATUS
    END-EVALUATE
    GOBACK.

*> Decode at most one frame from whatever is already buffered.
WS-TRY-FRAME.
    COMPUTE WS-AVAIL = WS-WRX-LEN - WS-WRX-POS + 1
    IF WS-AVAIL < 2
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-B1 = FUNCTION ORD(WS-WRX(WS-WRX-POS:1)) - 1
    COMPUTE WS-B2 = FUNCTION ORD(WS-WRX(WS-WRX-POS + 1:1)) - 1
    COMPUTE WS-FIN = FUNCTION INTEGER(WS-B1 / 128)
    COMPUTE WS-RSV = FUNCTION MOD(FUNCTION INTEGER(WS-B1 / 16), 8)
    COMPUTE WS-OPCODE = FUNCTION MOD(WS-B1, 16)
    COMPUTE WS-MASKED = FUNCTION INTEGER(WS-B2 / 128)
    COMPUTE WS-MARKER = FUNCTION MOD(WS-B2, 128)

    *> Reserved bits must be clear: no extension was negotiated.
    IF WS-RSV NOT = 0
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    *> A server frame is never masked.
    IF WS-MASKED NOT = 0
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF

    EVALUATE TRUE
        WHEN WS-MARKER < 126
            MOVE WS-MARKER TO WS-PAYLEN
            MOVE 2 TO WS-HDRLEN
        WHEN WS-MARKER = 126
            IF WS-AVAIL < 4
                EXIT PARAGRAPH
            END-IF
            COMPUTE WS-PAYLEN =
                (FUNCTION ORD(WS-WRX(WS-WRX-POS + 2:1)) - 1) * 256
                + (FUNCTION ORD(WS-WRX(WS-WRX-POS + 3:1)) - 1)
            MOVE 4 TO WS-HDRLEN
            *> Minimal length encoding is mandatory.
            IF WS-PAYLEN < 126
                MOVE 1 TO WS-ERR
                EXIT PARAGRAPH
            END-IF
        WHEN OTHER
            IF WS-AVAIL < 10
                EXIT PARAGRAPH
            END-IF
            MOVE 0 TO WS-PAYLEN
            PERFORM VARYING WS-I FROM 2 BY 1 UNTIL WS-I > 9
                COMPUTE WS-BYTE =
                    FUNCTION ORD(WS-WRX(WS-WRX-POS + WS-I:1)) - 1
                *> Refuse the declared size before it is used for
                *> anything, so a huge 64 bit length is rejected while
                *> it is still only a number.
                IF WS-PAYLEN > 134217728
                    MOVE 1 TO WS-ERR
                    EXIT PARAGRAPH
                END-IF
                COMPUTE WS-PAYLEN = WS-PAYLEN * 256 + WS-BYTE
            END-PERFORM
            MOVE 10 TO WS-HDRLEN
            IF WS-PAYLEN < 65536
                MOVE 1 TO WS-ERR
                EXIT PARAGRAPH
            END-IF
    END-EVALUATE

    IF WS-PAYLEN > WS-MAX-FRAME
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF

    *> Control frames must be short and never fragmented.
    IF WS-OPCODE >= 8
        IF WS-FIN = 0 OR WS-PAYLEN > 125
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
        END-IF
    END-IF

    COMPUTE WS-NEEDED = WS-HDRLEN + WS-PAYLEN
    IF WS-AVAIL < WS-NEEDED
        *> Incomplete. Leave everything buffered and try again later.
        EXIT PARAGRAPH
    END-IF

    COMPUTE WS-I = WS-WRX-POS + WS-HDRLEN
    COMPUTE WS-J = WS-PAYLEN
    COMPUTE WS-WRX-POS = WS-WRX-POS + WS-NEEDED

    EVALUATE TRUE
        WHEN WS-OPCODE = 9
            PERFORM WS-SEND-PONG
        WHEN WS-OPCODE = 10
            CONTINUE
        WHEN WS-OPCODE = 8
            PERFORM WS-VALIDATE-CLOSE
            IF WS-ERR = 0
                MOVE 2 TO WS-ERR
            END-IF
        WHEN WS-OPCODE = 2
            *> Convex Live is a text protocol; a binary frame is drift.
            MOVE 1 TO WS-ERR
        WHEN WS-OPCODE = 1
            IF WS-FRAG-ACTIVE = 1
                MOVE 1 TO WS-ERR
            ELSE
                MOVE 1 TO WS-FRAG-OPCODE
                MOVE 0 TO WS-MSG-LEN
                MOVE 0 TO WS-FRAG-COUNT
                PERFORM WS-APPEND-PAYLOAD
                IF WS-FIN = 1
                    MOVE 1 TO WS-COMPLETE
                ELSE
                    MOVE 1 TO WS-FRAG-ACTIVE
                END-IF
            END-IF
        WHEN WS-OPCODE = 0
            IF WS-FRAG-ACTIVE = 0
                MOVE 1 TO WS-ERR
            ELSE
                PERFORM WS-APPEND-PAYLOAD
                IF WS-ERR = 0 AND WS-FIN = 1
                    MOVE 1 TO WS-COMPLETE
                    MOVE 0 TO WS-FRAG-ACTIVE
                END-IF
            END-IF
        WHEN OTHER
            MOVE 1 TO WS-ERR
    END-EVALUATE.

WS-APPEND-PAYLOAD.
    ADD 1 TO WS-FRAG-COUNT
    IF WS-FRAG-COUNT > WS-MAX-FRAGMENTS
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-MSG-LEN + WS-J > WS-MAX-MESSAGE
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-J > 0
        MOVE WS-WRX(WS-I:WS-J) TO WS-MSG(WS-MSG-LEN + 1:WS-J)
        ADD WS-J TO WS-MSG-LEN
    END-IF.

*> Close payloads are either empty or a valid code plus valid UTF-8.
WS-VALIDATE-CLOSE.
    IF WS-J = 0
        EXIT PARAGRAPH
    END-IF
    IF WS-J = 1
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    COMPUTE WS-CLOSE-CODE =
        (FUNCTION ORD(WS-WRX(WS-I:1)) - 1) * 256
        + (FUNCTION ORD(WS-WRX(WS-I + 1:1)) - 1)
    EVALUATE TRUE
        WHEN WS-CLOSE-CODE = 1000 OR WS-CLOSE-CODE = 1001
                OR WS-CLOSE-CODE = 1002 OR WS-CLOSE-CODE = 1003
                OR WS-CLOSE-CODE = 1007 OR WS-CLOSE-CODE = 1008
                OR WS-CLOSE-CODE = 1009 OR WS-CLOSE-CODE = 1010
                OR WS-CLOSE-CODE = 1011
            CONTINUE
        WHEN WS-CLOSE-CODE >= 3000 AND WS-CLOSE-CODE <= 4999
            CONTINUE
        WHEN OTHER
            MOVE 1 TO WS-ERR
            EXIT PARAGRAPH
    END-EVALUATE
    IF WS-J > 2
        COMPUTE WS-K = WS-J - 2
        CALL "cvx-utf8-valid" USING WS-WRX(WS-I + 2:1) WS-K WS-RC
        IF WS-RC NOT = CVX-OK
            MOVE 1 TO WS-ERR
        END-IF
    END-IF.

WS-SEND-PONG.
    MOVE 10 TO WS-OPCODE
    IF WS-J > 0
        MOVE WS-WRX(WS-I:WS-J) TO WS-OUT-FRAME(1:WS-J)
    END-IF
    MOVE WS-J TO WS-OUT-LEN
    PERFORM WS-EMIT-FRAME.

*> See the comment on WS-CLOSE-HANDLE-EXIT: this guard keeps a
*> `PERFORM WS-SEND-PONG` from cvx-ws-poll's own body falling through
*> into cvx-ws-send-text's body and touching its unbound LK-BUF and
*> LK-LEN.
WS-SEND-PONG-EXIT.
    EXIT.

*> ------------------------------------------------------------------
*> cvx-ws-send-text / cvx-ws-send-close
*> ------------------------------------------------------------------
ENTRY "cvx-ws-send-text" USING LK-HANDLE LK-BUF LK-LEN LK-DEADLINE
        LK-STATUS.
    MOVE LK-HANDLE TO WS-HANDLE
    MOVE LK-DEADLINE TO WS-DEADLINE
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO WS-ERR
    IF LK-LEN < 0 OR LK-LEN > WS-MAX-FRAME
        MOVE CVX-LIMIT TO LK-STATUS
        GOBACK
    END-IF
    MOVE 1 TO WS-OPCODE
    IF LK-LEN > 0
        MOVE LK-BUF(1:LK-LEN) TO WS-OUT-FRAME(1:LK-LEN)
    END-IF
    MOVE LK-LEN TO WS-OUT-LEN
    PERFORM WS-EMIT-FRAME
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
    END-IF
    GOBACK.

ENTRY "cvx-ws-send-close" USING LK-HANDLE LK-DEADLINE LK-STATUS.
    MOVE LK-HANDLE TO WS-HANDLE
    MOVE LK-DEADLINE TO WS-DEADLINE
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO WS-ERR
    MOVE 8 TO WS-OPCODE
    *> 1000 Normal Closure.
    MOVE FUNCTION CHAR(4) TO WS-OUT-FRAME(1:1)
    MOVE FUNCTION CHAR(233) TO WS-OUT-FRAME(2:1)
    MOVE 2 TO WS-OUT-LEN
    PERFORM WS-EMIT-FRAME
    IF WS-ERR NOT = 0
        MOVE CVX-ERR TO LK-STATUS
    END-IF
    GOBACK.

*> Build and write one masked client frame. Every client frame carries
*> a fresh random mask, as RFC 6455 requires.
WS-EMIT-FRAME.
    MOVE 0 TO WS-HDRLEN
    COMPUTE WS-B1 = 128 + WS-OPCODE
    MOVE FUNCTION CHAR(WS-B1 + 1) TO WS-FHDR(1:1)
    MOVE 1 TO WS-HDRLEN

    EVALUATE TRUE
        WHEN WS-OUT-LEN < 126
            COMPUTE WS-B2 = 128 + WS-OUT-LEN
            MOVE FUNCTION CHAR(WS-B2 + 1) TO WS-FHDR(2:1)
            MOVE 2 TO WS-HDRLEN
        WHEN WS-OUT-LEN < 65536
            MOVE FUNCTION CHAR(255) TO WS-FHDR(2:1)
            COMPUTE WS-I = FUNCTION INTEGER(WS-OUT-LEN / 256)
            COMPUTE WS-J = FUNCTION MOD(WS-OUT-LEN, 256)
            MOVE FUNCTION CHAR(WS-I + 1) TO WS-FHDR(3:1)
            MOVE FUNCTION CHAR(WS-J + 1) TO WS-FHDR(4:1)
            MOVE 4 TO WS-HDRLEN
        WHEN OTHER
            MOVE FUNCTION CHAR(256) TO WS-FHDR(2:1)
            MOVE WS-OUT-LEN TO WS-PAYLEN
            PERFORM VARYING WS-I FROM 9 BY -1 UNTIL WS-I < 2
                COMPUTE WS-J = FUNCTION MOD(WS-PAYLEN, 256)
                MOVE FUNCTION CHAR(WS-J + 1)
                    TO WS-FHDR(WS-I + 1:1)
                COMPUTE WS-PAYLEN = FUNCTION INTEGER(WS-PAYLEN / 256)
            END-PERFORM
            MOVE 10 TO WS-HDRLEN
    END-EVALUATE

    CALL "cvx_random_bytes" USING
        BY REFERENCE WS-MASK
        BY VALUE 4
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    MOVE WS-MASK TO WS-FHDR(WS-HDRLEN + 1:4)
    ADD 4 TO WS-HDRLEN

    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-OUT-LEN
        MOVE WS-OUT-FRAME(WS-I:1) TO WS-XOR-IN
        COMPUTE WS-K = FUNCTION MOD(WS-I - 1, 4) + 1
        MOVE WS-MASK(WS-K:1) TO WS-XOR-KEY
        CALL "cvx-xor" USING WS-XOR-IN WS-XOR-KEY WS-XOR-OUT
        MOVE WS-XOR-OUT TO WS-OUT-FRAME(WS-I:1)
    END-PERFORM

    CALL "cvx_net_write" USING
        BY VALUE WS-HANDLE
        BY REFERENCE WS-FHDR
        BY VALUE WS-HDRLEN
        BY VALUE WS-DEADLINE
        BY REFERENCE WS-SENT
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE 1 TO WS-ERR
        EXIT PARAGRAPH
    END-IF
    IF WS-OUT-LEN > 0
        CALL "cvx_net_write" USING
            BY VALUE WS-HANDLE
            BY REFERENCE WS-OUT-FRAME
            BY VALUE WS-OUT-LEN
            BY VALUE WS-DEADLINE
            BY REFERENCE WS-SENT
            RETURNING WS-RC
        IF WS-RC NOT = CVX-OK
            MOVE 1 TO WS-ERR
        END-IF
    END-IF.

END PROGRAM CVXWS.
