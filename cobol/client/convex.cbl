>>SOURCE FORMAT IS FREE
*> ==================================================================
*> The educational Convex client for COBOL.
*>
*> HTTP calls use Convex's documented /api/query, /api/mutation, and
*> /api/action endpoints. Live uses the pinned sync profile over a
*> WebSocket at /api/sync.
*>
*> Concurrency: COBOL has no threads, so this client is a cooperative
*> single owner rather than a worker plus mutexes. Exactly one routine,
*> LIVE-PUMP, ever touches the socket: it drains queued commands, then
*> reads at most one message, then returns. Callers reach the socket
*> only by queueing a command and pumping, so the "one worker owns the
*> transport" rule holds by construction instead of by discipline.
*>
*> Delivery buffering is an explicit bounded queue owned by this
*> client, not a runtime mailbox. It is capped by both entry count and
*> a byte budget, and the oldest delivery is dropped when a slow
*> consumer lets it fill.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CVXCONV.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-http.cpy".

01 WS-MAX-SUBS              BINARY-LONG VALUE 64.
01 WS-MAX-DELIVERIES        BINARY-LONG VALUE 16.
01 WS-DELIVERY-BYTES-CAP    BINARY-LONG VALUE 20971520.
01 WS-INITIAL-BACKOFF-MS    BINARY-LONG VALUE 100.
01 WS-MAX-BACKOFF-MS        BINARY-LONG VALUE 15000.
01 WS-INITIAL-TS            PIC X(12) VALUE "AAAAAAAAAAA=".

*> ---- deployment configuration ------------------------------------
01 WS-CONFIGURED            BINARY-LONG VALUE 0.
01 WS-HOST                  PIC X(256).
01 WS-HOST-LEN              BINARY-LONG.
01 WS-PORT                  BINARY-LONG.
01 WS-SECURE                BINARY-LONG.
01 WS-CLIENTV               PIC X(64).
01 WS-CLIENTV-LEN           BINARY-LONG.
01 WS-TOKEN                 PIC X(4096).
01 WS-TOKEN-LEN             BINARY-LONG VALUE 0.
01 WS-CLOSED                BINARY-LONG VALUE 0.

*> ---- HTTP scratch -------------------------------------------------
*> WS-BODY (the outgoing request) and WS-RESP (the incoming response)
*> are both live for the same cvx-http-post call, so each keeps its
*> own 2 MiB region. WS-ARGS-ESC (the escaped function path) still
*> shares WS-RESP's region: it is written and fully consumed while
*> building WS-BODY, strictly before cvx-http-post -- and therefore
*> WS-RESP -- is ever touched for this call.
01 WS-BODY                  PIC X(2097152).
01 WS-BODY-LEN              BINARY-LONG.
01 WS-RESP                  PIC X(2097152).
01 WS-ARGS-ESC REDEFINES WS-RESP PIC X(2097152).
01 WS-RESP-LEN              BINARY-LONG.

*> ---- Live transport state ----------------------------------------
01 WS-LIVE-HANDLE           BINARY-LONG VALUE -1.
01 WS-LIVE-UP               BINARY-LONG VALUE 0.
01 WS-LIVE-STARTED          BINARY-LONG VALUE 0.
01 WS-QS-VERSION            BINARY-LONG VALUE 0.
01 WS-REMOTE-QS             BINARY-LONG VALUE 0.
01 WS-REMOTE-ID             BINARY-LONG VALUE 0.
01 WS-REMOTE-TS             PIC X(12) VALUE "AAAAAAAAAAA=".
01 WS-MAX-OBSERVED-TS       PIC 9(20) VALUE 0.
01 WS-CONN-COUNT            BINARY-LONG VALUE 0.
01 WS-CLOSE-REASON          PIC X(256) VALUE "InitialConnect".
01 WS-CLOSE-REASON-LEN      BINARY-LONG VALUE 14.
01 WS-GENERATION            BINARY-LONG VALUE 0.
01 WS-BACKOFF-MS            BINARY-LONG VALUE 100.
01 WS-NEXT-CONNECT-AT       BINARY-DOUBLE VALUE 0.
01 WS-HAS-NEXT-CONNECT      BINARY-LONG VALUE 0.
01 WS-NEXT-QUERY-ID         BINARY-LONG VALUE 0.
01 WS-SESSION-RAW           PIC X(16).
01 WS-SESSION-HEX           PIC X(32).
01 WS-SESSION-HEX-LEN       BINARY-LONG.

*> ---- subscriptions ------------------------------------------------
01 WS-SUBS.
   05 WS-SUB OCCURS 64 TIMES.
      10 WS-S-ACTIVE        BINARY-LONG.
      10 WS-S-QUERY-ID      BINARY-LONG.
      10 WS-S-PATH          PIC X(256).
      10 WS-S-PATH-LEN      BINARY-LONG.
      10 WS-S-ARGS          PIC X(8192).
      10 WS-S-ARGS-LEN      BINARY-LONG.
      *> Signature of the last published state, so an unchanged
      *> rehydration after a reconnect is suppressed.
      10 WS-S-SIG           PIC X(64).
      10 WS-S-SIG-LEN       BINARY-LONG.

*> ---- bounded delivery queue --------------------------------------
01 WS-DELIVERIES.
   05 WS-DLV OCCURS 16 TIMES.
      10 WS-D-SUB           BINARY-LONG.
      10 WS-D-GEN           BINARY-LONG.
      10 WS-D-IS-ERROR      BINARY-LONG.
      10 WS-D-VALUE         PIC X(131072).
      10 WS-D-VALUE-LEN     BINARY-LONG.
      10 WS-D-LOGS          PIC X(16384).
      10 WS-D-LOGS-LEN      BINARY-LONG.
      10 WS-D-HAS-LOGS      BINARY-LONG.
      10 WS-D-ENAME         PIC X(32).
      10 WS-D-ENAME-LEN     BINARY-LONG.
      10 WS-D-EMSG          PIC X(1024).
      10 WS-D-EMSG-LEN      BINARY-LONG.
      10 WS-D-EDATA         PIC X(8192).
      10 WS-D-EDATA-LEN     BINARY-LONG.
      10 WS-D-BYTES         BINARY-LONG.
01 WS-DLV-COUNT             BINARY-LONG VALUE 0.
01 WS-DLV-BYTES             BINARY-LONG VALUE 0.

*> ---- message building --------------------------------------------
01 WS-MSGBUF                PIC X(262144).
01 WS-MSGLEN                BINARY-LONG.
01 WS-INBUF                 PIC X(2097152).
01 WS-INLEN                 BINARY-LONG.
*> Numeric-edited, not plain alphanumeric: every use below is
*> `MOVE <numeric> TO WS-NUMTEXT` followed by `FUNCTION TRIM`, and JSON
*> forbids leading zeros in a number. A plain PIC X field pads with
*> zeros (not spaces) on that MOVE, which TRIM cannot remove, so every
*> connectionCount/queryId/version this client sent was malformed JSON
*> the moment the value needed more than one digit. The Z's suppress
*> leading zeros to spaces, which TRIM does strip.
01 WS-NUMTEXT               PIC Z(23)9.
01 WS-TSTEXT                PIC X(12).
01 WS-TSVAL                 PIC 9(20).
01 WS-TSVAL2                PIC 9(20).

*> ---- scratch ------------------------------------------------------
01 WS-RC                    BINARY-LONG.
01 WS-ST                    BINARY-LONG.
01 WS-I                     BINARY-LONG.
01 WS-J                     BINARY-LONG.
01 WS-K                     BINARY-LONG.
01 WS-N                     BINARY-LONG.
01 WS-SLOT                  BINARY-LONG.
01 WS-NODE                  BINARY-LONG.
01 WS-CHILD                 BINARY-LONG.
01 WS-CHILD2                BINARY-LONG.
*> APPLY-TRANSITION needs the "modifications" array node to survive
*> the call to ADOPT-END-VERSION, which reuses WS-CHILD as its own
*> scratch for the endVersion sub-lookups. Sharing WS-CHILD for both
*> meant ADOPT-END-VERSION silently overwrote the array reference, so
*> the modification loop ran cvx-json-count against whatever
*> ADOPT-END-VERSION had left in WS-CHILD (the endVersion "ts" string
*> node) instead of the array -- reading a non-array node's count as 0
*> and skipping every modification, including the very first delivery.
01 WS-MODS-NODE             BINARY-LONG.
01 WS-TYPE                  BINARY-LONG.
01 WS-COUNT                 BINARY-LONG.
01 WS-OPCODE                BINARY-LONG.
01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-SPAN-LEN              BINARY-LONG.
01 WS-SPAN                  PIC X(2097152).
01 WS-TEXT                  PIC X(1024).
01 WS-TEXT-LEN              BINARY-LONG.
01 WS-KEYTEXT               PIC X(64).
01 WS-BIGINT                BINARY-DOUBLE.
01 WS-FOUND                 BINARY-LONG.
01 WS-SUBIX                 BINARY-LONG.
01 WS-QID                   BINARY-LONG.
01 WS-CHARGE                BINARY-LONG.
01 WS-SIXTEEN               BINARY-LONG VALUE 16.
01 WS-ONE                   BINARY-LONG VALUE 1.
01 WS-ZERO                  BINARY-LONG VALUE 0.
01 WS-SLOT-HTTP             BINARY-LONG VALUE 1.
01 WS-SLOT-LIVE             BINARY-LONG VALUE 2.
01 WS-URLBUF                PIC X(1024).
01 WS-URLLEN                BINARY-LONG.
01 WS-CH                    PIC X.
01 WS-AUTH-DIRTY            BINARY-LONG VALUE 0.

LINKAGE SECTION.
COPY "cvx-client.cpy".
01 LK-URL                   PIC X(1024).
01 LK-URL-LEN               BINARY-LONG.
01 LK-CLIENTV               PIC X(64).
01 LK-CLIENTV-LEN           BINARY-LONG.
01 LK-TOKEN                 PIC X(4096).
01 LK-TOKEN-LEN             BINARY-LONG.
01 LK-OP                    BINARY-LONG.
01 LK-PATH                  PIC X(256).
01 LK-PATH-LEN              BINARY-LONG.
01 LK-ARGS                  PIC X(8192).
01 LK-ARGS-LEN              BINARY-LONG.
01 LK-STATUS                BINARY-LONG.
01 LK-SUBIX                 BINARY-LONG.
01 LK-TIMEOUT               BINARY-LONG.
01 LK-GEN                   BINARY-LONG.

PROCEDURE DIVISION.
CVXCONV-MAIN SECTION.
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-client-init: parse and validate the deployment URL.
*> Credentials, query strings, and fragments are rejected rather than
*> quietly dropped, so a misconfigured URL fails loudly.
*> ------------------------------------------------------------------
ENTRY "cvx-client-init" USING LK-URL LK-URL-LEN LK-CLIENTV
        LK-CLIENTV-LEN CVX-ERROR LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    CALL "cvx-util-init"
    IF LK-URL-LEN < 8 OR LK-URL-LEN > 1024
        PERFORM SET-CONFIG-ERROR
        GOBACK
    END-IF
    MOVE LK-URL(1:LK-URL-LEN) TO WS-URLBUF(1:LK-URL-LEN)
    MOVE LK-URL-LEN TO WS-URLLEN

    EVALUATE TRUE
        WHEN WS-URLBUF(1:8) = "https://"
            MOVE 1 TO WS-SECURE
            MOVE 443 TO WS-PORT
            MOVE 9 TO WS-I
        WHEN WS-URLBUF(1:7) = "http://"
            MOVE 0 TO WS-SECURE
            MOVE 80 TO WS-PORT
            MOVE 8 TO WS-I
        WHEN OTHER
            PERFORM SET-CONFIG-ERROR
            GOBACK
    END-EVALUATE

    *> Everything up to the first slash is the authority.
    MOVE 0 TO WS-J
    PERFORM VARYING WS-K FROM WS-I BY 1 UNTIL WS-K > WS-URLLEN
        MOVE WS-URLBUF(WS-K:1) TO WS-CH
        IF WS-CH = "/"
            MOVE WS-K TO WS-J
            EXIT PERFORM
        END-IF
        IF WS-CH = "@" OR WS-CH = "?" OR WS-CH = "#"
            PERFORM SET-CONFIG-ERROR
            GOBACK
        END-IF
    END-PERFORM
    IF WS-J = 0
        COMPUTE WS-J = WS-URLLEN + 1
    END-IF
    COMPUTE WS-N = WS-J - WS-I
    IF WS-N < 1 OR WS-N > 256
        PERFORM SET-CONFIG-ERROR
        GOBACK
    END-IF

    *> Split an optional :port off the end of the authority.
    MOVE 0 TO WS-K
    PERFORM VARYING WS-COUNT FROM WS-I BY 1 UNTIL WS-COUNT >= WS-J
        IF WS-URLBUF(WS-COUNT:1) = ":"
            MOVE WS-COUNT TO WS-K
        END-IF
    END-PERFORM
    IF WS-K > 0
        COMPUTE WS-HOST-LEN = WS-K - WS-I
        COMPUTE WS-COUNT = WS-J - WS-K - 1
        IF WS-COUNT < 1 OR WS-COUNT > 5
            PERFORM SET-CONFIG-ERROR
            GOBACK
        END-IF
        MOVE 0 TO WS-PORT
        PERFORM VARYING WS-N FROM 1 BY 1 UNTIL WS-N > WS-COUNT
            MOVE WS-URLBUF(WS-K + WS-N:1) TO WS-CH
            IF WS-CH < "0" OR WS-CH > "9"
                PERFORM SET-CONFIG-ERROR
                GOBACK
            END-IF
            COMPUTE WS-PORT = WS-PORT * 10
                + (FUNCTION ORD(WS-CH) - 49)
        END-PERFORM
        IF WS-PORT < 1 OR WS-PORT > 65535
            PERFORM SET-CONFIG-ERROR
            GOBACK
        END-IF
    ELSE
        COMPUTE WS-HOST-LEN = WS-J - WS-I
    END-IF
    IF WS-HOST-LEN < 1
        PERFORM SET-CONFIG-ERROR
        GOBACK
    END-IF
    MOVE SPACES TO WS-HOST
    MOVE WS-URLBUF(WS-I:WS-HOST-LEN) TO WS-HOST(1:WS-HOST-LEN)

    MOVE SPACES TO WS-CLIENTV
    MOVE LK-CLIENTV(1:LK-CLIENTV-LEN) TO WS-CLIENTV(1:LK-CLIENTV-LEN)
    MOVE LK-CLIENTV-LEN TO WS-CLIENTV-LEN
    MOVE 0 TO WS-TOKEN-LEN
    MOVE 0 TO WS-CLOSED
    MOVE 1 TO WS-CONFIGURED
    *> This is a fresh client instance in every sense that matters to a
    *> caller, so its query numbering starts fresh too: WS-NEXT-QUERY-ID
    *> is otherwise never reset, and two `cvx-client-init` calls in the
    *> same process (as every language-local test after the first one
    *> does) would silently hand out query IDs that keep climbing past 1
    *> -- never matching a peer that, reasonably, expects a new client to
    *> start at 1, and so never resolving `WS-S-QUERY-ID` back to an
    *> active subscription.
    MOVE 0 TO WS-NEXT-QUERY-ID
    GOBACK.

SET-CONFIG-ERROR.
    MOVE CVX-ERR TO LK-STATUS
    MOVE "ConfigError" TO CVX-E-NAME
    MOVE 11 TO CVX-E-NAME-LEN
    MOVE "deployment URL must be an absolute http(s) URL with no "
        & "credentials, query, or fragment" TO CVX-E-MSG
    MOVE 86 TO CVX-E-MSG-LEN
    MOVE 0 TO CVX-E-DATA-LEN.

*> `PERFORM paragraph-name` (no THRU) only stops at the next
*> paragraph-name; an ENTRY statement is not a paragraph boundary, so
*> without this guard a `PERFORM SET-CONFIG-ERROR` would fall straight
*> through into cvx-client-set-auth's own body -- still inside
*> whichever entry actually called SET-CONFIG-ERROR, touching that
*> entry's LK-TOKEN/LK-TOKEN-LEN, which were never bound for this
*> call. That is a reference to unallocated memory, not merely wrong
*> behaviour; every PERFORM-only paragraph immediately before an ENTRY
*> in this file gets the same guard.
SET-CONFIG-ERROR-EXIT.
    EXIT.

*> A newline in a token would let a caller inject a header.
ENTRY "cvx-client-set-auth" USING LK-TOKEN LK-TOKEN-LEN CVX-ERROR
        LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    IF LK-TOKEN-LEN < 0 OR LK-TOKEN-LEN > 4096
        PERFORM SET-CONFIG-ERROR
        GOBACK
    END-IF
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > LK-TOKEN-LEN
        MOVE LK-TOKEN(WS-I:1) TO WS-CH
        IF WS-CH = FUNCTION CHAR(11) OR WS-CH = FUNCTION CHAR(14)
            PERFORM SET-CONFIG-ERROR
            GOBACK
        END-IF
    END-PERFORM
    MOVE SPACES TO WS-TOKEN
    IF LK-TOKEN-LEN > 0
        MOVE LK-TOKEN(1:LK-TOKEN-LEN) TO WS-TOKEN(1:LK-TOKEN-LEN)
    END-IF
    MOVE LK-TOKEN-LEN TO WS-TOKEN-LEN
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-client-call: one HTTP query, mutation, or action.
*> ------------------------------------------------------------------
ENTRY "cvx-client-call" USING LK-OP LK-PATH LK-PATH-LEN LK-ARGS
        LK-ARGS-LEN CVX-RESULT CVX-ERROR LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO CVX-R-VALUE-LEN
    MOVE 0 TO CVX-R-LOGS-LEN
    MOVE 0 TO CVX-R-HAS-LOGS
    MOVE 0 TO CVX-R-IS-ERROR
    IF WS-CONFIGURED = 0 OR WS-CLOSED = 1
        PERFORM SET-CLOSED-ERROR
        GOBACK
    END-IF
    IF LK-PATH-LEN < 3
        PERFORM SET-CONFIG-ERROR
        GOBACK
    END-IF

    MOVE SPACES TO CVX-HR-HOST
    MOVE WS-HOST(1:WS-HOST-LEN) TO CVX-HR-HOST(1:WS-HOST-LEN)
    MOVE WS-HOST-LEN TO CVX-HR-HOST-LEN
    MOVE WS-PORT TO CVX-HR-PORT
    MOVE WS-SECURE TO CVX-HR-SECURE
    MOVE SPACES TO CVX-HR-PATH
    EVALUATE LK-OP
        WHEN 1
            MOVE "/api/query" TO CVX-HR-PATH
            MOVE 10 TO CVX-HR-PATH-LEN
        WHEN 2
            MOVE "/api/mutation" TO CVX-HR-PATH
            MOVE 13 TO CVX-HR-PATH-LEN
        WHEN OTHER
            MOVE "/api/action" TO CVX-HR-PATH
            MOVE 11 TO CVX-HR-PATH-LEN
    END-EVALUATE
    MOVE SPACES TO CVX-HR-TOKEN
    IF WS-TOKEN-LEN > 0
        MOVE WS-TOKEN(1:WS-TOKEN-LEN) TO CVX-HR-TOKEN(1:WS-TOKEN-LEN)
    END-IF
    MOVE WS-TOKEN-LEN TO CVX-HR-TOKEN-LEN
    MOVE SPACES TO CVX-HR-CLIENTV
    MOVE WS-CLIENTV(1:WS-CLIENTV-LEN)
        TO CVX-HR-CLIENTV(1:WS-CLIENTV-LEN)
    MOVE WS-CLIENTV-LEN TO CVX-HR-CLIENTV-LEN
    *> One absolute deadline for the whole exchange.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE CVX-HR-DEADLINE = WS-NOW + 30000

    *> Body: {"path":...,"args":...,"format":"json"}. No bulk clear:
    *> cvx-http-post only reads the first WS-BODY-LEN bytes, so spacing
    *> the full 2 MiB buffer first would only dirty pages the request
    *> never uses.
    MOVE 1 TO WS-BODY-LEN
    CALL "cvx-json-esc-string" USING LK-PATH LK-PATH-LEN
        WS-ARGS-ESC WS-SPAN-LEN
    STRING
        '{"path":' DELIMITED SIZE
        WS-ARGS-ESC(1:WS-SPAN-LEN) DELIMITED SIZE
        ',"args":' DELIMITED SIZE
        LK-ARGS(1:LK-ARGS-LEN) DELIMITED SIZE
        ',"format":"json"}' DELIMITED SIZE
        INTO WS-BODY
        WITH POINTER WS-BODY-LEN
    END-STRING
    SUBTRACT 1 FROM WS-BODY-LEN

    CALL "cvx-http-post" USING CVX-HTTP-REQ WS-BODY WS-BODY-LEN
        WS-RESP WS-RESP-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        MOVE CVX-ERR TO LK-STATUS
        MOVE "TransportError" TO CVX-E-NAME
        MOVE 14 TO CVX-E-NAME-LEN
        MOVE "HTTP transport failed" TO CVX-E-MSG
        MOVE 21 TO CVX-E-MSG-LEN
        MOVE 0 TO CVX-E-DATA-LEN
        GOBACK
    END-IF

    PERFORM DECODE-ENVELOPE
    GOBACK.

SET-CLOSED-ERROR.
    MOVE CVX-ERR TO LK-STATUS
    MOVE "ClosedError" TO CVX-E-NAME
    MOVE 11 TO CVX-E-NAME-LEN
    MOVE "client is closed or not configured" TO CVX-E-MSG
    MOVE 34 TO CVX-E-MSG-LEN
    MOVE 0 TO CVX-E-DATA-LEN.

*> Decode the Convex response envelope. A structured function failure
*> stays a structured failure; it is never flattened into a value.
DECODE-ENVELOPE.
    CALL "cvx-json-parse" USING WS-SLOT-HTTP WS-RESP WS-RESP-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        MOVE CVX-ERR TO LK-STATUS
        MOVE "TransportError" TO CVX-E-NAME
        MOVE 14 TO CVX-E-NAME-LEN
        MOVE "Convex returned a non-JSON response" TO CVX-E-MSG
        MOVE 35 TO CVX-E-MSG-LEN
        MOVE 0 TO CVX-E-DATA-LEN
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT-HTTP WS-NODE
    CALL "cvx-json-type" USING WS-SLOT-HTTP WS-NODE WS-TYPE
    IF WS-TYPE NOT = 7
        PERFORM SET-PROTOCOL-ERROR
        EXIT PARAGRAPH
    END-IF

    MOVE "status" TO WS-KEYTEXT
    MOVE 6 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-HTTP WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD = 0
        PERFORM SET-PROTOCOL-ERROR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-string" USING WS-SLOT-HTTP WS-CHILD WS-SPAN
        WS-SPAN-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM SET-PROTOCOL-ERROR
        EXIT PARAGRAPH
    END-IF

    *> logLines is optional but must be an array of strings when sent.
    MOVE "logLines" TO WS-KEYTEXT
    MOVE 8 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-HTTP WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD2
    IF WS-CHILD2 NOT = 0
        CALL "cvx-json-type" USING WS-SLOT-HTTP WS-CHILD2 WS-TYPE
        IF WS-TYPE NOT = 6
            PERFORM SET-PROTOCOL-ERROR
            EXIT PARAGRAPH
        END-IF
        CALL "cvx-json-copy-span" USING WS-SLOT-HTTP WS-CHILD2
            CVX-R-LOGS CVX-R-LOGS-LEN WS-ST
        MOVE 1 TO CVX-R-HAS-LOGS
    END-IF

    EVALUATE TRUE
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "success"
            MOVE "value" TO WS-KEYTEXT
            MOVE 5 TO WS-TEXT-LEN
            CALL "cvx-json-member" USING WS-SLOT-HTTP WS-NODE
                WS-KEYTEXT WS-TEXT-LEN WS-CHILD
            IF WS-CHILD = 0
                PERFORM SET-PROTOCOL-ERROR
                EXIT PARAGRAPH
            END-IF
            CALL "cvx-json-copy-span" USING WS-SLOT-HTTP WS-CHILD
                CVX-R-VALUE CVX-R-VALUE-LEN WS-ST
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "error"
            MOVE CVX-ERR TO LK-STATUS
            MOVE 1 TO CVX-R-IS-ERROR
            MOVE "FunctionError" TO CVX-E-NAME
            MOVE 13 TO CVX-E-NAME-LEN
            MOVE "errorMessage" TO WS-KEYTEXT
            MOVE 12 TO WS-TEXT-LEN
            CALL "cvx-json-member" USING WS-SLOT-HTTP WS-NODE
                WS-KEYTEXT WS-TEXT-LEN WS-CHILD
            IF WS-CHILD NOT = 0
                CALL "cvx-json-string" USING WS-SLOT-HTTP WS-CHILD
                    WS-SPAN WS-SPAN-LEN WS-ST
                IF WS-SPAN-LEN > 1024
                    MOVE 1024 TO WS-SPAN-LEN
                END-IF
                MOVE WS-SPAN(1:WS-SPAN-LEN) TO CVX-E-MSG(1:WS-SPAN-LEN)
                MOVE WS-SPAN-LEN TO CVX-E-MSG-LEN
            ELSE
                MOVE "Convex function failed" TO CVX-E-MSG
                MOVE 22 TO CVX-E-MSG-LEN
            END-IF
            MOVE "errorData" TO WS-KEYTEXT
            MOVE 9 TO WS-TEXT-LEN
            CALL "cvx-json-member" USING WS-SLOT-HTTP WS-NODE
                WS-KEYTEXT WS-TEXT-LEN WS-CHILD
            MOVE 0 TO CVX-E-DATA-LEN
            IF WS-CHILD NOT = 0
                CALL "cvx-json-copy-span" USING WS-SLOT-HTTP WS-CHILD
                    CVX-E-DATA CVX-E-DATA-LEN WS-ST
            END-IF
        WHEN OTHER
            PERFORM SET-PROTOCOL-ERROR
    END-EVALUATE.

SET-PROTOCOL-ERROR.
    MOVE CVX-ERR TO LK-STATUS
    MOVE "ProtocolError" TO CVX-E-NAME
    MOVE 13 TO CVX-E-NAME-LEN
    MOVE "Convex response envelope was not understood" TO CVX-E-MSG
    MOVE 43 TO CVX-E-MSG-LEN
    MOVE 0 TO CVX-E-DATA-LEN.

*> See the comment on SET-CONFIG-ERROR-EXIT: this guard keeps a
*> `PERFORM SET-PROTOCOL-ERROR` from falling through into
*> cvx-live-subscribe's body and touching its unbound LK-SUBIX.
SET-PROTOCOL-ERROR-EXIT.
    EXIT.

*> ==================================================================
*> Live
*> ==================================================================

*> cvx-live-subscribe: register a query and, once the socket is up,
*> send its Add. Returns the subscription index the caller polls.
ENTRY "cvx-live-subscribe" USING LK-PATH LK-PATH-LEN LK-ARGS
        LK-ARGS-LEN LK-SUBIX CVX-ERROR LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-SUBIX
    IF WS-CONFIGURED = 0 OR WS-CLOSED = 1
        PERFORM SET-CLOSED-ERROR
        GOBACK
    END-IF
    MOVE 0 TO WS-SUBIX
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-MAX-SUBS
        IF WS-S-ACTIVE(WS-I) = 0
            MOVE WS-I TO WS-SUBIX
            EXIT PERFORM
        END-IF
    END-PERFORM
    IF WS-SUBIX = 0 OR LK-ARGS-LEN > 8192
        MOVE CVX-ERR TO LK-STATUS
        MOVE "ProtocolError" TO CVX-E-NAME
        MOVE 13 TO CVX-E-NAME-LEN
        MOVE "Live subscription capacity exceeded" TO CVX-E-MSG
        MOVE 35 TO CVX-E-MSG-LEN
        MOVE 0 TO CVX-E-DATA-LEN
        GOBACK
    END-IF

    ADD 1 TO WS-NEXT-QUERY-ID
    MOVE 1 TO WS-S-ACTIVE(WS-SUBIX)
    MOVE WS-NEXT-QUERY-ID TO WS-S-QUERY-ID(WS-SUBIX)
    MOVE SPACES TO WS-S-PATH(WS-SUBIX)
    MOVE LK-PATH(1:LK-PATH-LEN)
        TO WS-S-PATH(WS-SUBIX)(1:LK-PATH-LEN)
    MOVE LK-PATH-LEN TO WS-S-PATH-LEN(WS-SUBIX)
    MOVE SPACES TO WS-S-ARGS(WS-SUBIX)
    MOVE LK-ARGS(1:LK-ARGS-LEN)
        TO WS-S-ARGS(WS-SUBIX)(1:LK-ARGS-LEN)
    MOVE LK-ARGS-LEN TO WS-S-ARGS-LEN(WS-SUBIX)
    MOVE 0 TO WS-S-SIG-LEN(WS-SUBIX)
    MOVE 1 TO WS-LIVE-STARTED
    MOVE WS-SUBIX TO LK-SUBIX

    IF WS-LIVE-UP = 1
        PERFORM SEND-ADD-ONE
    END-IF
    GOBACK.

*> cvx-live-unsubscribe: retire the relay before acknowledging, and
*> drop any delivery already queued for it so nothing stale can be
*> read after the acknowledgement.
ENTRY "cvx-live-unsubscribe" USING LK-SUBIX CVX-ERROR LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    IF LK-SUBIX < 1 OR LK-SUBIX > WS-MAX-SUBS
        GOBACK
    END-IF
    IF WS-S-ACTIVE(LK-SUBIX) = 0
        GOBACK
    END-IF
    MOVE LK-SUBIX TO WS-SUBIX
    IF WS-LIVE-UP = 1
        PERFORM SEND-REMOVE-ONE
    END-IF
    MOVE 0 TO WS-S-ACTIVE(LK-SUBIX)
    PERFORM PURGE-SUB-DELIVERIES
    GOBACK.

*> cvx-live-debug-disconnect: adapter only. Hard drop the socket, then
*> acknowledge with the new generation. Deliveries belonging to the
*> retired connection are discarded so the caller has a real barrier.
ENTRY "cvx-live-debug-disconnect" USING LK-GEN CVX-ERROR LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    IF WS-LIVE-UP = 0
        MOVE CVX-ERR TO LK-STATUS
        MOVE "TransportError" TO CVX-E-NAME
        MOVE 14 TO CVX-E-NAME-LEN
        MOVE "Live WebSocket is not connected" TO CVX-E-MSG
        MOVE 31 TO CVX-E-MSG-LEN
        MOVE 0 TO CVX-E-DATA-LEN
        MOVE 0 TO LK-GEN
        GOBACK
    END-IF
    MOVE "DebugDisconnect" TO WS-CLOSE-REASON
    MOVE 15 TO WS-CLOSE-REASON-LEN
    PERFORM RETIRE-SOCKET
    MOVE 0 TO WS-DLV-COUNT
    MOVE 0 TO WS-DLV-BYTES
    *> Schedule the reconnect immediately; the pump performs it.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-NEXT-CONNECT-AT = WS-NOW + WS-INITIAL-BACKOFF-MS
    MOVE 1 TO WS-HAS-NEXT-CONNECT
    COMPUTE WS-BACKOFF-MS = WS-INITIAL-BACKOFF-MS * 2
    MOVE WS-GENERATION TO LK-GEN
    GOBACK.

ENTRY "cvx-live-generation" USING LK-GEN.
    MOVE WS-GENERATION TO LK-GEN
    GOBACK.

*> cvx-live-close: retire everything in one bounded operation.
ENTRY "cvx-live-close" USING LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    IF WS-LIVE-UP = 1
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        COMPUTE WS-DEADLINE = WS-NOW + 2000
        CALL "cvx-ws-send-close" USING WS-LIVE-HANDLE WS-DEADLINE WS-ST
    END-IF
    MOVE "ClientClosed" TO WS-CLOSE-REASON
    MOVE 12 TO WS-CLOSE-REASON-LEN
    PERFORM RETIRE-SOCKET
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-MAX-SUBS
        MOVE 0 TO WS-S-ACTIVE(WS-I)
    END-PERFORM
    MOVE 0 TO WS-DLV-COUNT
    MOVE 0 TO WS-DLV-BYTES
    MOVE 0 TO WS-HAS-NEXT-CONNECT
    MOVE 0 TO WS-LIVE-STARTED
    MOVE 1 TO WS-CLOSED
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-live-pump: the single owner step.
*>
*> Connects when due, then reads at most one message. Everything that
*> touches WS-LIVE-HANDLE happens here or in a routine this calls,
*> which is what keeps the transport single owner without threads.
*> ------------------------------------------------------------------
ENTRY "cvx-live-pump" USING LK-TIMEOUT LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    IF WS-CLOSED = 1 OR WS-LIVE-STARTED = 0
        GOBACK
    END-IF
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC

    IF WS-LIVE-UP = 0
        IF WS-HAS-NEXT-CONNECT = 0
                OR WS-NOW >= WS-NEXT-CONNECT-AT
            PERFORM CONNECT-NOW
        END-IF
        GOBACK
    END-IF

    COMPUTE WS-DEADLINE = WS-NOW + LK-TIMEOUT
    CALL "cvx-ws-poll" USING WS-LIVE-HANDLE WS-DEADLINE WS-OPCODE
        WS-INBUF WS-INLEN WS-ST
    EVALUATE WS-ST
        WHEN CVX-OK
            PERFORM HANDLE-LIVE-MESSAGE
        WHEN CVX-TIMEOUT
            CONTINUE
        WHEN CVX-EOF
            MOVE "ServerClosed" TO WS-CLOSE-REASON
            MOVE 12 TO WS-CLOSE-REASON-LEN
            PERFORM RETIRE-AND-REPORT
        WHEN OTHER
            MOVE "ProtocolFailure" TO WS-CLOSE-REASON
            MOVE 15 TO WS-CLOSE-REASON-LEN
            PERFORM RETIRE-AND-REPORT
    END-EVALUATE
    GOBACK.

CONNECT-NOW.
    MOVE SPACES TO WS-TEXT
    MOVE "/api/sync" TO WS-TEXT
    MOVE 9 TO WS-TEXT-LEN
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + 10000
    CALL "cvx-ws-connect" USING WS-HOST WS-HOST-LEN WS-PORT WS-SECURE
        WS-TEXT WS-TEXT-LEN WS-CLIENTV WS-CLIENTV-LEN WS-DEADLINE
        WS-LIVE-HANDLE WS-ST
    IF WS-ST NOT = CVX-OK
        ADD 1 TO WS-CONN-COUNT
        MOVE "ConnectFailed" TO WS-CLOSE-REASON
        MOVE 13 TO WS-CLOSE-REASON-LEN
        PERFORM SCHEDULE-RECONNECT
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO WS-LIVE-UP
    MOVE 0 TO WS-QS-VERSION
    MOVE 0 TO WS-REMOTE-QS
    MOVE 0 TO WS-REMOTE-ID
    MOVE WS-INITIAL-TS TO WS-REMOTE-TS
    MOVE 0 TO WS-HAS-NEXT-CONNECT
    *> A healthy handshake resets the backoff, so a run of good
    *> connections never inherits an old maximum delay.
    MOVE WS-INITIAL-BACKOFF-MS TO WS-BACKOFF-MS

    PERFORM SEND-CONNECT-MESSAGE
    IF WS-LIVE-UP = 1
        PERFORM SEND-ADD-ALL
    END-IF.

SCHEDULE-RECONNECT.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-NEXT-CONNECT-AT = WS-NOW + WS-BACKOFF-MS
    MOVE 1 TO WS-HAS-NEXT-CONNECT
    COMPUTE WS-BACKOFF-MS = WS-BACKOFF-MS * 2
    IF WS-BACKOFF-MS > WS-MAX-BACKOFF-MS
        MOVE WS-MAX-BACKOFF-MS TO WS-BACKOFF-MS
    END-IF.

RETIRE-SOCKET.
    IF WS-LIVE-HANDLE >= 0
        CALL "cvx_net_close" USING BY VALUE WS-LIVE-HANDLE
            RETURNING WS-RC
    END-IF
    MOVE -1 TO WS-LIVE-HANDLE
    MOVE 0 TO WS-LIVE-UP
    MOVE 0 TO WS-QS-VERSION
    MOVE 0 TO WS-REMOTE-QS
    MOVE 0 TO WS-REMOTE-ID
    MOVE WS-INITIAL-TS TO WS-REMOTE-TS
    CALL "cvx-ws-reset"
    ADD 1 TO WS-GENERATION
    ADD 1 TO WS-CONN-COUNT.

*> Retire, then publish a recoverable transport failure to every live
*> subscription. The subscription stays registered, so the next
*> connection rebuilds it and can deliver a later valid value.
RETIRE-AND-REPORT.
    PERFORM RETIRE-SOCKET
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-MAX-SUBS
        IF WS-S-ACTIVE(WS-I) = 1
            MOVE WS-I TO WS-SUBIX
            MOVE "TransportError" TO WS-TEXT
            MOVE 14 TO WS-TEXT-LEN
            PERFORM QUEUE-TRANSPORT-ERROR
        END-IF
    END-PERFORM
    PERFORM SCHEDULE-RECONNECT.

*> ------------------------------------------------------------------
*> Outgoing sync messages
*> ------------------------------------------------------------------
SEND-CONNECT-MESSAGE.
    CALL "cvx_random_bytes" USING
        BY REFERENCE WS-SESSION-RAW
        BY VALUE WS-SIXTEEN
        RETURNING WS-RC
    CALL "cvx-hex-encode" USING WS-SESSION-RAW WS-SIXTEEN
        WS-SESSION-HEX WS-SESSION-HEX-LEN
    MOVE SPACES TO WS-MSGBUF
    MOVE 1 TO WS-MSGLEN
    MOVE WS-CONN-COUNT TO WS-NUMTEXT
    STRING
        '{"type":"Connect","sessionId":"' DELIMITED SIZE
        WS-SESSION-HEX(1:WS-SESSION-HEX-LEN) DELIMITED SIZE
        '","connectionCount":' DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        ',"lastCloseReason":"' DELIMITED SIZE
        WS-CLOSE-REASON(1:WS-CLOSE-REASON-LEN) DELIMITED SIZE
        '","clientTs":0' DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    IF WS-MAX-OBSERVED-TS > 0
        MOVE WS-MAX-OBSERVED-TS TO WS-TSVAL
        CALL "cvx-ts-encode" USING WS-TSVAL WS-TSTEXT
        STRING
            ',"maxObservedTimestamp":"' DELIMITED SIZE
            WS-TSTEXT DELIMITED SIZE
            '"' DELIMITED SIZE
            INTO WS-MSGBUF
            WITH POINTER WS-MSGLEN
        END-STRING
    END-IF
    STRING "}" DELIMITED SIZE INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    SUBTRACT 1 FROM WS-MSGLEN
    PERFORM SEND-MSGBUF.

*> Resend every active Add on a fresh connection so the server rebuilds
*> the full query set.
SEND-ADD-ALL.
    MOVE 0 TO WS-COUNT
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-MAX-SUBS
        IF WS-S-ACTIVE(WS-I) = 1
            ADD 1 TO WS-COUNT
        END-IF
    END-PERFORM
    IF WS-COUNT = 0
        EXIT PARAGRAPH
    END-IF
    MOVE SPACES TO WS-MSGBUF
    MOVE 1 TO WS-MSGLEN
    STRING
        '{"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,'
            DELIMITED SIZE
        '"modifications":[' DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    MOVE 0 TO WS-N
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-MAX-SUBS
        IF WS-S-ACTIVE(WS-I) = 1
            IF WS-N > 0
                STRING "," DELIMITED SIZE INTO WS-MSGBUF
                    WITH POINTER WS-MSGLEN
                END-STRING
            END-IF
            MOVE WS-I TO WS-SUBIX
            PERFORM APPEND-ADD-MODIFICATION
            ADD 1 TO WS-N
        END-IF
    END-PERFORM
    STRING "]}" DELIMITED SIZE INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    SUBTRACT 1 FROM WS-MSGLEN
    PERFORM SEND-MSGBUF
    MOVE 1 TO WS-QS-VERSION.

APPEND-ADD-MODIFICATION.
    MOVE WS-S-QUERY-ID(WS-SUBIX) TO WS-NUMTEXT
    CALL "cvx-json-esc-string" USING WS-S-PATH(WS-SUBIX)
        WS-S-PATH-LEN(WS-SUBIX) WS-SPAN WS-SPAN-LEN
    STRING
        '{"type":"Add","queryId":' DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        ',"udfPath":' DELIMITED SIZE
        WS-SPAN(1:WS-SPAN-LEN) DELIMITED SIZE
        ',"args":[' DELIMITED SIZE
        WS-S-ARGS(WS-SUBIX)(1:WS-S-ARGS-LEN(WS-SUBIX)) DELIMITED SIZE
        ']}' DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING.

SEND-ADD-ONE.
    MOVE SPACES TO WS-MSGBUF
    MOVE 1 TO WS-MSGLEN
    MOVE WS-QS-VERSION TO WS-NUMTEXT
    STRING
        '{"type":"ModifyQuerySet","baseVersion":' DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    COMPUTE WS-N = WS-QS-VERSION + 1
    MOVE WS-N TO WS-NUMTEXT
    STRING
        ',"newVersion":' DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        ',"modifications":[' DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    PERFORM APPEND-ADD-MODIFICATION
    STRING "]}" DELIMITED SIZE INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    SUBTRACT 1 FROM WS-MSGLEN
    PERFORM SEND-MSGBUF
    IF WS-LIVE-UP = 1
        MOVE WS-N TO WS-QS-VERSION
    END-IF.

SEND-REMOVE-ONE.
    MOVE SPACES TO WS-MSGBUF
    MOVE 1 TO WS-MSGLEN
    MOVE WS-QS-VERSION TO WS-NUMTEXT
    STRING
        '{"type":"ModifyQuerySet","baseVersion":' DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    COMPUTE WS-N = WS-QS-VERSION + 1
    MOVE WS-N TO WS-NUMTEXT
    MOVE WS-S-QUERY-ID(WS-SUBIX) TO WS-TEXT
    STRING
        ',"newVersion":' DELIMITED SIZE
        FUNCTION TRIM(WS-NUMTEXT) DELIMITED SIZE
        ',"modifications":[{"type":"Remove","queryId":' DELIMITED SIZE
        FUNCTION TRIM(WS-TEXT) DELIMITED SIZE
        '}]}' DELIMITED SIZE
        INTO WS-MSGBUF
        WITH POINTER WS-MSGLEN
    END-STRING
    SUBTRACT 1 FROM WS-MSGLEN
    PERFORM SEND-MSGBUF
    IF WS-LIVE-UP = 1
        MOVE WS-N TO WS-QS-VERSION
    END-IF.

*> A failed write leaves the connection in an unknown state, so it is
*> retired rather than reused.
SEND-MSGBUF.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + 5000
    CALL "cvx-ws-send-text" USING WS-LIVE-HANDLE WS-MSGBUF WS-MSGLEN
        WS-DEADLINE WS-ST
    IF WS-ST NOT = CVX-OK
        MOVE "WriteFailed" TO WS-CLOSE-REASON
        MOVE 11 TO WS-CLOSE-REASON-LEN
        PERFORM RETIRE-SOCKET
        PERFORM SCHEDULE-RECONNECT
    END-IF.

*> ------------------------------------------------------------------
*> Incoming sync messages
*> ------------------------------------------------------------------
HANDLE-LIVE-MESSAGE.
    CALL "cvx-json-parse" USING WS-SLOT-LIVE WS-INBUF WS-INLEN WS-ST
    IF WS-ST NOT = CVX-OK
        MOVE "BadJson" TO WS-CLOSE-REASON
        MOVE 7 TO WS-CLOSE-REASON-LEN
        PERFORM RETIRE-AND-REPORT
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT-LIVE WS-NODE
    MOVE "type" TO WS-KEYTEXT
    MOVE 4 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD = 0
        MOVE "NoType" TO WS-CLOSE-REASON
        MOVE 6 TO WS-CLOSE-REASON-LEN
        PERFORM RETIRE-AND-REPORT
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-string" USING WS-SLOT-LIVE WS-CHILD WS-SPAN
        WS-SPAN-LEN WS-ST
    EVALUATE TRUE
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "Transition"
            PERFORM APPLY-TRANSITION
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "Ping"
            CONTINUE
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "MutationResponse"
            CONTINUE
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "ActionResponse"
            CONTINUE
        WHEN OTHER
            *> Anything else, including a TransitionChunk, is profile
            *> drift for this client and retires the connection.
            MOVE "UnsupportedMessage" TO WS-CLOSE-REASON
            MOVE 18 TO WS-CLOSE-REASON-LEN
            PERFORM RETIRE-AND-REPORT
    END-EVALUATE.

*> Validate the whole transition before publishing anything, so one
*> bad member rejects the batch instead of leaving a partial state.
APPLY-TRANSITION.
    MOVE "startVersion" TO WS-KEYTEXT
    MOVE 12 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD = 0
        PERFORM DRIFT-RETIRE
        EXIT PARAGRAPH
    END-IF
    PERFORM CHECK-START-VERSION
    IF WS-FOUND = 0
        PERFORM DRIFT-RETIRE
        EXIT PARAGRAPH
    END-IF

    MOVE "endVersion" TO WS-KEYTEXT
    MOVE 10 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD2
    IF WS-CHILD2 = 0
        PERFORM DRIFT-RETIRE
        EXIT PARAGRAPH
    END-IF

    MOVE "modifications" TO WS-KEYTEXT
    MOVE 13 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-MODS-NODE
    IF WS-MODS-NODE = 0
        PERFORM DRIFT-RETIRE
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-type" USING WS-SLOT-LIVE WS-MODS-NODE WS-TYPE
    IF WS-TYPE NOT = 6
        PERFORM DRIFT-RETIRE
        EXIT PARAGRAPH
    END-IF

    *> Commit the new version first, then publish each modification.
    PERFORM ADOPT-END-VERSION
    CALL "cvx-json-count" USING WS-SLOT-LIVE WS-MODS-NODE WS-COUNT
    PERFORM VARYING WS-K FROM 1 BY 1 UNTIL WS-K > WS-COUNT
        CALL "cvx-json-index" USING WS-SLOT-LIVE WS-MODS-NODE WS-K
            WS-NODE
        PERFORM APPLY-MODIFICATION
    END-PERFORM
    *> A valid transition proves the link is healthy.
    MOVE WS-INITIAL-BACKOFF-MS TO WS-BACKOFF-MS
    MOVE 0 TO WS-HAS-NEXT-CONNECT.

DRIFT-RETIRE.
    MOVE "ProfileDrift" TO WS-CLOSE-REASON
    MOVE 12 TO WS-CLOSE-REASON-LEN
    PERFORM RETIRE-AND-REPORT.

CHECK-START-VERSION.
    MOVE 0 TO WS-FOUND
    MOVE "querySet" TO WS-KEYTEXT
    MOVE 8 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-CHILD WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD2
    IF WS-CHILD2 = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-int" USING WS-SLOT-LIVE WS-CHILD2 WS-BIGINT WS-ST
    IF WS-ST NOT = CVX-OK OR WS-BIGINT NOT = WS-REMOTE-QS
        EXIT PARAGRAPH
    END-IF
    MOVE "identity" TO WS-KEYTEXT
    MOVE 8 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-CHILD WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD2
    IF WS-CHILD2 = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-int" USING WS-SLOT-LIVE WS-CHILD2 WS-BIGINT WS-ST
    IF WS-ST NOT = CVX-OK OR WS-BIGINT NOT = WS-REMOTE-ID
        EXIT PARAGRAPH
    END-IF
    MOVE "ts" TO WS-KEYTEXT
    MOVE 2 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-CHILD WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD2
    IF WS-CHILD2 = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-string" USING WS-SLOT-LIVE WS-CHILD2 WS-SPAN
        WS-SPAN-LEN WS-ST
    IF WS-SPAN-LEN NOT = 12
        EXIT PARAGRAPH
    END-IF
    IF WS-SPAN(1:12) NOT = WS-REMOTE-TS
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO WS-FOUND.

ADOPT-END-VERSION.
    MOVE "querySet" TO WS-KEYTEXT
    MOVE 8 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-CHILD2 WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT-LIVE WS-CHILD WS-BIGINT WS-ST
    MOVE WS-BIGINT TO WS-REMOTE-QS
    MOVE "identity" TO WS-KEYTEXT
    MOVE 8 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-CHILD2 WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    CALL "cvx-json-int" USING WS-SLOT-LIVE WS-CHILD WS-BIGINT WS-ST
    MOVE WS-BIGINT TO WS-REMOTE-ID
    MOVE "ts" TO WS-KEYTEXT
    MOVE 2 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-CHILD2 WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    CALL "cvx-json-string" USING WS-SLOT-LIVE WS-CHILD WS-SPAN
        WS-SPAN-LEN WS-ST
    IF WS-SPAN-LEN = 12
        MOVE WS-SPAN(1:12) TO WS-REMOTE-TS
        MOVE WS-SPAN(1:12) TO WS-TSTEXT
        CALL "cvx-ts-decode" USING WS-TSTEXT WS-TSVAL WS-ST
        IF WS-ST = CVX-OK AND WS-TSVAL > WS-MAX-OBSERVED-TS
            MOVE WS-TSVAL TO WS-MAX-OBSERVED-TS
        END-IF
    END-IF.

APPLY-MODIFICATION.
    MOVE "queryId" TO WS-KEYTEXT
    MOVE 7 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-int" USING WS-SLOT-LIVE WS-CHILD WS-BIGINT WS-ST
    IF WS-ST NOT = CVX-OK
        EXIT PARAGRAPH
    END-IF
    MOVE WS-BIGINT TO WS-QID
    MOVE 0 TO WS-SUBIX
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-MAX-SUBS
        IF WS-S-ACTIVE(WS-I) = 1
                AND WS-S-QUERY-ID(WS-I) = WS-QID
            MOVE WS-I TO WS-SUBIX
            EXIT PERFORM
        END-IF
    END-PERFORM
    IF WS-SUBIX = 0
        EXIT PARAGRAPH
    END-IF

    MOVE "type" TO WS-KEYTEXT
    MOVE 4 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-string" USING WS-SLOT-LIVE WS-CHILD WS-SPAN
        WS-SPAN-LEN WS-ST
    EVALUATE TRUE
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "QueryUpdated"
            PERFORM QUEUE-QUERY-UPDATED
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "QueryFailed"
            PERFORM QUEUE-QUERY-FAILED
        WHEN WS-SPAN(1:WS-SPAN-LEN) = "QueryRemoved"
            CONTINUE
        WHEN OTHER
            CONTINUE
    END-EVALUATE.

QUEUE-QUERY-UPDATED.
    MOVE "value" TO WS-KEYTEXT
    MOVE 5 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD = 0
        EXIT PARAGRAPH
    END-IF
    PERFORM RESERVE-DELIVERY
    IF WS-N = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO WS-D-IS-ERROR(WS-N)
    CALL "cvx-json-copy-span" USING WS-SLOT-LIVE WS-CHILD
        WS-D-VALUE(WS-N) WS-D-VALUE-LEN(WS-N) WS-ST
    PERFORM ATTACH-LOGS
    *> Suppress an unchanged rehydration after a reconnect: the exact
    *> same value must not surface as a fresh update.
    PERFORM CHECK-SIGNATURE
    IF WS-FOUND = 1
        PERFORM RELEASE-DELIVERY
        EXIT PARAGRAPH
    END-IF
    PERFORM COMMIT-DELIVERY.

QUEUE-QUERY-FAILED.
    PERFORM RESERVE-DELIVERY
    IF WS-N = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO WS-D-IS-ERROR(WS-N)
    MOVE 0 TO WS-D-VALUE-LEN(WS-N)
    MOVE "FunctionError" TO WS-D-ENAME(WS-N)
    MOVE 13 TO WS-D-ENAME-LEN(WS-N)
    MOVE "errorMessage" TO WS-KEYTEXT
    MOVE 12 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-string" USING WS-SLOT-LIVE WS-CHILD WS-SPAN
            WS-SPAN-LEN WS-ST
        IF WS-SPAN-LEN > 1024
            MOVE 1024 TO WS-SPAN-LEN
        END-IF
        MOVE WS-SPAN(1:WS-SPAN-LEN)
            TO WS-D-EMSG(WS-N)(1:WS-SPAN-LEN)
        MOVE WS-SPAN-LEN TO WS-D-EMSG-LEN(WS-N)
    ELSE
        MOVE "Convex query failed" TO WS-D-EMSG(WS-N)
        MOVE 19 TO WS-D-EMSG-LEN(WS-N)
    END-IF
    MOVE "errorData" TO WS-KEYTEXT
    MOVE 9 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD
    MOVE 0 TO WS-D-EDATA-LEN(WS-N)
    IF WS-CHILD NOT = 0
        CALL "cvx-json-copy-span" USING WS-SLOT-LIVE WS-CHILD
            WS-D-EDATA(WS-N) WS-D-EDATA-LEN(WS-N) WS-ST
    END-IF
    PERFORM ATTACH-LOGS
    PERFORM CHECK-SIGNATURE
    IF WS-FOUND = 1
        PERFORM RELEASE-DELIVERY
        EXIT PARAGRAPH
    END-IF
    PERFORM COMMIT-DELIVERY.

QUEUE-TRANSPORT-ERROR.
    PERFORM RESERVE-DELIVERY
    IF WS-N = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO WS-D-IS-ERROR(WS-N)
    MOVE 0 TO WS-D-VALUE-LEN(WS-N)
    MOVE 0 TO WS-D-HAS-LOGS(WS-N)
    MOVE 0 TO WS-D-EDATA-LEN(WS-N)
    MOVE WS-TEXT(1:WS-TEXT-LEN) TO WS-D-ENAME(WS-N)(1:WS-TEXT-LEN)
    MOVE WS-TEXT-LEN TO WS-D-ENAME-LEN(WS-N)
    MOVE WS-CLOSE-REASON(1:WS-CLOSE-REASON-LEN)
        TO WS-D-EMSG(WS-N)(1:WS-CLOSE-REASON-LEN)
    MOVE WS-CLOSE-REASON-LEN TO WS-D-EMSG-LEN(WS-N)
    *> A transport failure always reaches the consumer; it is not
    *> suppressed by the unchanged-value rule.
    MOVE 0 TO WS-S-SIG-LEN(WS-SUBIX)
    PERFORM COMMIT-DELIVERY.

ATTACH-LOGS.
    MOVE 0 TO WS-D-HAS-LOGS(WS-N)
    MOVE 0 TO WS-D-LOGS-LEN(WS-N)
    MOVE "logLines" TO WS-KEYTEXT
    MOVE 8 TO WS-TEXT-LEN
    CALL "cvx-json-member" USING WS-SLOT-LIVE WS-NODE WS-KEYTEXT
        WS-TEXT-LEN WS-CHILD2
    IF WS-CHILD2 = 0
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-type" USING WS-SLOT-LIVE WS-CHILD2 WS-TYPE
    IF WS-TYPE NOT = 6
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-copy-span" USING WS-SLOT-LIVE WS-CHILD2
        WS-SPAN WS-SPAN-LEN WS-ST
    IF WS-SPAN-LEN <= 16384
        MOVE WS-SPAN(1:WS-SPAN-LEN)
            TO WS-D-LOGS(WS-N)(1:WS-SPAN-LEN)
        MOVE WS-SPAN-LEN TO WS-D-LOGS-LEN(WS-N)
        MOVE 1 TO WS-D-HAS-LOGS(WS-N)
    END-IF.

*> A cheap content signature. Identical consecutive states for one
*> subscription are collapsed, which is what makes a reconnect that
*> rehydrates the same value invisible to the consumer.
CHECK-SIGNATURE.
    MOVE 0 TO WS-FOUND
    MOVE SPACES TO WS-TEXT
    MOVE WS-D-VALUE-LEN(WS-N) TO WS-NUMTEXT
    MOVE 0 TO WS-J
    PERFORM VARYING WS-I FROM 1 BY 1
            UNTIL WS-I > WS-D-VALUE-LEN(WS-N)
        COMPUTE WS-J = FUNCTION MOD(WS-J * 31
            + (FUNCTION ORD(WS-D-VALUE(WS-N)(WS-I:1)) - 1), 1000000007)
    END-PERFORM
    PERFORM VARYING WS-I FROM 1 BY 1
            UNTIL WS-I > WS-D-EMSG-LEN(WS-N)
        COMPUTE WS-J = FUNCTION MOD(WS-J * 31
            + (FUNCTION ORD(WS-D-EMSG(WS-N)(WS-I:1)) - 1), 1000000007)
    END-PERFORM
    MOVE WS-J TO WS-NUMTEXT
    MOVE FUNCTION TRIM(WS-NUMTEXT) TO WS-TEXT
    COMPUTE WS-K = FUNCTION LENGTH(FUNCTION TRIM(WS-NUMTEXT))
    IF WS-S-SIG-LEN(WS-SUBIX) = WS-K
            AND WS-S-SIG(WS-SUBIX)(1:WS-K) = WS-TEXT(1:WS-K)
        MOVE 1 TO WS-FOUND
        EXIT PARAGRAPH
    END-IF
    MOVE WS-TEXT(1:WS-K) TO WS-S-SIG(WS-SUBIX)(1:WS-K)
    MOVE WS-K TO WS-S-SIG-LEN(WS-SUBIX).

*> Reserve the next queue entry, dropping the oldest delivery when the
*> count or byte budget is already full.
RESERVE-DELIVERY.
    IF WS-DLV-COUNT >= WS-MAX-DELIVERIES
        PERFORM DROP-OLDEST-DELIVERY
    END-IF
    COMPUTE WS-N = WS-DLV-COUNT + 1
    MOVE WS-SUBIX TO WS-D-SUB(WS-N)
    MOVE WS-GENERATION TO WS-D-GEN(WS-N)
    MOVE 0 TO WS-D-VALUE-LEN(WS-N)
    MOVE 0 TO WS-D-LOGS-LEN(WS-N)
    MOVE 0 TO WS-D-HAS-LOGS(WS-N)
    MOVE 0 TO WS-D-ENAME-LEN(WS-N)
    MOVE 0 TO WS-D-EMSG-LEN(WS-N)
    MOVE 0 TO WS-D-EDATA-LEN(WS-N)
    MOVE 0 TO WS-D-BYTES(WS-N).

RELEASE-DELIVERY.
    CONTINUE.

COMMIT-DELIVERY.
    COMPUTE WS-D-BYTES(WS-N) = 512 + WS-D-VALUE-LEN(WS-N)
        + WS-D-LOGS-LEN(WS-N) + WS-D-EMSG-LEN(WS-N)
        + WS-D-EDATA-LEN(WS-N)
    PERFORM UNTIL WS-DLV-COUNT = 0
            OR WS-DLV-BYTES + WS-D-BYTES(WS-N)
               <= WS-DELIVERY-BYTES-CAP
        PERFORM DROP-OLDEST-DELIVERY
        COMPUTE WS-N = WS-DLV-COUNT + 1
    END-PERFORM
    MOVE WS-N TO WS-DLV-COUNT
    ADD WS-D-BYTES(WS-N) TO WS-DLV-BYTES.

DROP-OLDEST-DELIVERY.
    IF WS-DLV-COUNT = 0
        EXIT PARAGRAPH
    END-IF
    SUBTRACT WS-D-BYTES(1) FROM WS-DLV-BYTES
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I >= WS-DLV-COUNT
        MOVE WS-DLV(WS-I + 1) TO WS-DLV(WS-I)
    END-PERFORM
    SUBTRACT 1 FROM WS-DLV-COUNT.

PURGE-SUB-DELIVERIES.
    MOVE 1 TO WS-I
    PERFORM UNTIL WS-I > WS-DLV-COUNT
        IF WS-D-SUB(WS-I) = WS-SUBIX
            SUBTRACT WS-D-BYTES(WS-I) FROM WS-DLV-BYTES
            PERFORM VARYING WS-J FROM WS-I BY 1
                    UNTIL WS-J >= WS-DLV-COUNT
                MOVE WS-DLV(WS-J + 1) TO WS-DLV(WS-J)
            END-PERFORM
            SUBTRACT 1 FROM WS-DLV-COUNT
        ELSE
            ADD 1 TO WS-I
        END-IF
    END-PERFORM.

*> See the comment on SET-CONFIG-ERROR-EXIT: this guard keeps a
*> `PERFORM PURGE-SUB-DELIVERIES` from falling through into
*> cvx-live-next's body and touching its unbound CVX-RESULT.
PURGE-SUB-DELIVERIES-EXIT.
    EXIT.

*> ------------------------------------------------------------------
*> cvx-live-next: take the oldest delivery for one subscription.
*> LK-STATUS is CVX-OK when a delivery was returned and CVX-TIMEOUT
*> when the queue holds nothing for this subscription yet.
*> ------------------------------------------------------------------
ENTRY "cvx-live-next" USING LK-SUBIX CVX-RESULT CVX-ERROR LK-STATUS.
    MOVE CVX-TIMEOUT TO LK-STATUS
    MOVE 0 TO CVX-R-VALUE-LEN
    MOVE 0 TO CVX-R-LOGS-LEN
    MOVE 0 TO CVX-R-HAS-LOGS
    MOVE 0 TO CVX-R-IS-ERROR
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-DLV-COUNT
        IF WS-D-SUB(WS-I) = LK-SUBIX
            MOVE WS-D-IS-ERROR(WS-I) TO CVX-R-IS-ERROR
            IF WS-D-VALUE-LEN(WS-I) > 0
                MOVE WS-D-VALUE(WS-I)(1:WS-D-VALUE-LEN(WS-I))
                    TO CVX-R-VALUE(1:WS-D-VALUE-LEN(WS-I))
            END-IF
            MOVE WS-D-VALUE-LEN(WS-I) TO CVX-R-VALUE-LEN
            IF WS-D-HAS-LOGS(WS-I) = 1
                MOVE WS-D-LOGS(WS-I)(1:WS-D-LOGS-LEN(WS-I))
                    TO CVX-R-LOGS(1:WS-D-LOGS-LEN(WS-I))
                MOVE WS-D-LOGS-LEN(WS-I) TO CVX-R-LOGS-LEN
                MOVE 1 TO CVX-R-HAS-LOGS
            END-IF
            IF WS-D-IS-ERROR(WS-I) = 1
                MOVE WS-D-ENAME(WS-I)(1:WS-D-ENAME-LEN(WS-I))
                    TO CVX-E-NAME(1:WS-D-ENAME-LEN(WS-I))
                MOVE WS-D-ENAME-LEN(WS-I) TO CVX-E-NAME-LEN
                MOVE WS-D-EMSG(WS-I)(1:WS-D-EMSG-LEN(WS-I))
                    TO CVX-E-MSG(1:WS-D-EMSG-LEN(WS-I))
                MOVE WS-D-EMSG-LEN(WS-I) TO CVX-E-MSG-LEN
                MOVE 0 TO CVX-E-DATA-LEN
                IF WS-D-EDATA-LEN(WS-I) > 0
                    MOVE WS-D-EDATA(WS-I)(1:WS-D-EDATA-LEN(WS-I))
                        TO CVX-E-DATA(1:WS-D-EDATA-LEN(WS-I))
                    MOVE WS-D-EDATA-LEN(WS-I) TO CVX-E-DATA-LEN
                END-IF
            END-IF
            MOVE CVX-OK TO LK-STATUS
            SUBTRACT WS-D-BYTES(WS-I) FROM WS-DLV-BYTES
            PERFORM VARYING WS-J FROM WS-I BY 1
                    UNTIL WS-J >= WS-DLV-COUNT
                MOVE WS-DLV(WS-J + 1) TO WS-DLV(WS-J)
            END-PERFORM
            SUBTRACT 1 FROM WS-DLV-COUNT
            EXIT PERFORM
        END-IF
    END-PERFORM
    GOBACK.

END PROGRAM CVXCONV.
