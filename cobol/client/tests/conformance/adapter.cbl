>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Test-only conformance executable: NDJSON adapter protocol v1.
*>
*> This is test infrastructure, not part of the educational client
*> API. It calls the real client for every operation.
*>
*> Stdout carries protocol events only. Diagnostics go to stderr.
*> Optional fields are omitted when absent rather than serialized as
*> null, because the shared controller validates every event strictly.
*>
*> Because COBOL has no threads, one loop interleaves three duties:
*> read controller input, step the Live owner, and forward any queued
*> Live delivery. There is no relay thread to race with, so the
*> ordering barriers the shared controller checks fall out of the
*> single-threaded sequence directly.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CONVEX-ADAPTER.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".
*> The raw command line being assembled and parsed is fully consumed by
*> cvx-json-parse, as PROCESS-LINE's very first step, before this
*> program next writes into CVX-RESULT -- the client itself does not
*> set CVX-R-VALUE until DO-CALL's cvx-client-call, which always runs
*> after that parse -- and CVX-R-VALUE is always read into WS-EVT
*> before this program loops back to assemble the next line, so the
*> two never need to hold different content at once. Redefining
*> CVX-RESULT (only its leading 2 MiB, exactly CVX-R-VALUE's own span)
*> removes WS-LINE's private 2 MiB entirely rather than merely sharing
*> it with something else.
01 WS-LINE REDEFINES CVX-RESULT PIC X(2097152).

01 WS-MAX-LINE              BINARY-LONG VALUE 2097152.
*> Shares convex.cbl's WS-SLOT-HTTP slot rather than owning a private
*> one: EXTRACT-COMMAND-FIELDS below always finishes copying every
*> field this adapter needs out of the parsed command (id, op,
*> subscriptionId, path, args, token) into small WORKING-STORAGE
*> before PROCESS-LINE ever dispatches into a client call, so the
*> command's parsed document is never read again once dispatch begins
*> and the slot is free for the HTTP reply to reuse. That reuse is
*> what keeps this client's JSON module to two slots instead of four;
*> see convex-json.cbl's WS-JSON-SLOTS comment.
01 WS-SLOT-CMD              BINARY-LONG VALUE 1.

*> ---- transport for the controller connection ---------------------
01 WS-TCP-MODE              BINARY-LONG VALUE 0.
01 WS-CTRL-HANDLE           BINARY-LONG VALUE -1.
01 WS-LISTEN                PIC X(128).
01 WS-LISTEN-LEN            BINARY-LONG.

*> ---- line assembly ------------------------------------------------
01 WS-CHUNK                 PIC X(65536).
01 WS-CHUNK-LEN             BINARY-LONG.
01 WS-LINE-LEN              BINARY-LONG VALUE 0.
01 WS-DISCARDING            BINARY-LONG VALUE 0.

*> ---- emitted event ------------------------------------------------
*> WS-EVT redefines the shared external scratch (cvx-scratch.cpy)
*> instead of owning its own 2 MiB, so convex-json.cbl's one document
*> slot -- which also redefines it -- occupies the same physical
*> memory as this adapter's event buffer rather than adding to it. This
*> is safe specifically because WS-EVT is never the *source* of a
*> cvx-json-parse call: it is built from already-decoded pieces
*> (WS-CMD-ID via WS-ESC, CVX-R-VALUE, CVX-R-LOGS) and only ever
*> written out afterward. See cvx-scratch.cpy's warning before
*> redefining it with anything that also feeds a parse.
COPY "cvx-scratch.cpy".
01 WS-EVT REDEFINES CVX-SHARED-SCRATCH PIC X(2162688).
01 WS-EVT-LEN               BINARY-LONG.
*> WS-ESC and WS-SPAN are two names for one shared, deliberately small
*> buffer: EXTRACT-COMMAND-FIELDS is the only reader of WS-SPAN and
*> always finishes there before DO-HELLO, DO-CALL, DO-CLOSE, or any of
*> the EMIT-* paragraphs -- the only writers of WS-ESC -- next run.
*>
*> 8192 bytes, not 2 MiB: every legitimate use of this buffer is
*> bounded well under that (an escaped id/subscriptionId/error name or
*> message, or a decoded/raw command field -- id, op, subscriptionId,
*> path, token, or the args object, none of which this adapter accepts
*> past its own small declared caps). What is NOT safe is trusting that
*> bound implicitly: cvx-json-string and cvx-json-copy-span write
*> exactly as many bytes as the source span calls for regardless of
*> this buffer's real size, so EXTRACT-COMMAND-FIELDS below checks
*> cvx-json-span-len first and skips any field whose raw span would
*> overflow it, the same way it already discarded an oversized decoded
*> result before this buffer shrank.
01 WS-ESC                   PIC X(8192).
01 WS-SPAN REDEFINES WS-ESC PIC X(8192).
01 WS-ESC-LEN               BINARY-LONG.

*> ---- adapter state ------------------------------------------------
01 WS-HELLO-SEEN            BINARY-LONG VALUE 0.
01 WS-CLOSING               BINARY-LONG VALUE 0.
01 WS-CLIENT-READY          BINARY-LONG VALUE 0.

01 WS-RELAYS.
   05 WS-RELAY OCCURS 64 TIMES.
      10 WS-RL-USED         BINARY-LONG.
      10 WS-RL-SUBID        PIC X(128).
      10 WS-RL-SUBID-LEN    BINARY-LONG.
      10 WS-RL-SUBIX        BINARY-LONG.

*> ---- parsed command ----------------------------------------------
01 WS-CMD-ID                PIC X(128).
01 WS-CMD-ID-LEN            BINARY-LONG.
01 WS-CMD-OP                PIC X(32).
01 WS-CMD-OP-LEN            BINARY-LONG.
01 WS-CMD-SUBID             PIC X(128).
01 WS-CMD-SUBID-LEN         BINARY-LONG.
01 WS-CMD-PATH              PIC X(256).
01 WS-CMD-PATH-LEN          BINARY-LONG.
01 WS-CMD-ARGS              PIC X(8192).
01 WS-CMD-ARGS-LEN          BINARY-LONG.
01 WS-CMD-TOKEN             PIC X(4096).
01 WS-CMD-TOKEN-LEN         BINARY-LONG.
01 WS-CMD-PV                BINARY-DOUBLE.
01 WS-HAS-ARGS              BINARY-LONG.
01 WS-HAS-PATH              BINARY-LONG.

*> ---- scratch ------------------------------------------------------
01 WS-ST                    BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-I                     BINARY-LONG.
01 WS-J                     BINARY-LONG.
01 WS-K                     BINARY-LONG.
01 WS-N                     BINARY-LONG.
01 WS-NODE                  BINARY-LONG.
01 WS-CHILD                 BINARY-LONG.
01 WS-TYPE                  BINARY-LONG.
01 WS-KEY                   PIC X(64).
01 WS-KEY-LEN               BINARY-LONG.
01 WS-SPAN-LEN               BINARY-LONG.
*> The raw span a field would need, checked via cvx-json-span-len
*> before it is ever copied into the small WS-SPAN buffer.
01 WS-RAWLEN                BINARY-LONG.
01 WS-OP                    BINARY-LONG.
01 WS-SUBIX                 BINARY-LONG.
01 WS-RELAYIX               BINARY-LONG.
01 WS-GEN                   BINARY-LONG.
01 WS-TIMEOUT               BINARY-LONG VALUE 20.
01 WS-PUMP-MS               BINARY-LONG VALUE 20.
01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-ERRNAME               PIC X(32).
01 WS-ERRNAME-LEN           BINARY-LONG.
01 WS-ERRMSG                PIC X(1024).
01 WS-ERRMSG-LEN            BINARY-LONG.
01 WS-URL                   PIC X(1024).
01 WS-URL-LEN               BINARY-LONG.
01 WS-TOKEN-ENV             PIC X(4096).
01 WS-TOKEN-ENV-LEN         BINARY-LONG.
01 WS-CLIENTV               PIC X(64) VALUE "cobol-0.1.0".
01 WS-CLIENTV-LEN           BINARY-LONG VALUE 11.
01 WS-ONE                   BINARY-LONG VALUE 1.
01 WS-TWO                   BINARY-LONG VALUE 2.
01 WS-CH                    PIC X.
01 WS-EOF-SEEN              BINARY-LONG VALUE 0.

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    CALL "cvx-util-init"
    PERFORM SETUP-TRANSPORT

    PERFORM UNTIL WS-CLOSING = 1
        PERFORM READ-CONTROLLER-INPUT
        IF WS-CLOSING = 1
            EXIT PERFORM
        END-IF
        *> Step the Live owner, then forward whatever it produced.
        IF WS-CLIENT-READY = 1
            CALL "cvx-live-pump" USING WS-PUMP-MS WS-ST
            PERFORM DRAIN-DELIVERIES
        END-IF
        IF WS-EOF-SEEN = 1 AND WS-LINE-LEN = 0
            MOVE 1 TO WS-CLOSING
        END-IF
    END-PERFORM

    PERFORM SHUTDOWN-ADAPTER
    STOP RUN.

*> ------------------------------------------------------------------
*> Transport: stdin/stdout by default, one accepted TCP connection
*> when ADAPTER_LISTEN is set. The NDJSON stream is identical.
*> ------------------------------------------------------------------
SETUP-TRANSPORT.
    MOVE SPACES TO WS-LISTEN
    ACCEPT WS-LISTEN FROM ENVIRONMENT "ADAPTER_LISTEN"
    IF WS-LISTEN NOT = SPACES
        COMPUTE WS-LISTEN-LEN =
            FUNCTION LENGTH(FUNCTION TRIM(WS-LISTEN))
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        COMPUTE WS-DEADLINE = WS-NOW + 30000
        CALL "cvx_listen_accept" USING
            BY REFERENCE WS-LISTEN
            BY VALUE WS-LISTEN-LEN
            BY VALUE WS-DEADLINE
            RETURNING WS-CTRL-HANDLE
        IF WS-CTRL-HANDLE < 0
            DISPLAY "adapter could not accept a controller connection"
                UPON SYSERR
            MOVE 1 TO RETURN-CODE
            STOP RUN
        END-IF
        MOVE 1 TO WS-TCP-MODE
    END-IF.

*> ------------------------------------------------------------------
*> Input: bytes arrive in chunks and are split on newlines. A line
*> longer than the limit is reported once and then discarded through
*> its terminator, so a hostile stream cannot desynchronise framing.
*> ------------------------------------------------------------------
READ-CONTROLLER-INPUT.
    MOVE 0 TO WS-CHUNK-LEN
    IF WS-TCP-MODE = 1
        CALL "cvx_net_readable" USING
            BY VALUE WS-CTRL-HANDLE
            BY VALUE WS-TIMEOUT
            RETURNING WS-RC
        IF WS-RC NOT = 1
            EXIT PARAGRAPH
        END-IF
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        COMPUTE WS-DEADLINE = WS-NOW + 1000
        CALL "cvx_net_read" USING
            BY VALUE WS-CTRL-HANDLE
            BY REFERENCE WS-CHUNK
            BY VALUE 65536
            BY VALUE WS-DEADLINE
            BY REFERENCE WS-CHUNK-LEN
            RETURNING WS-RC
    ELSE
        CALL "cvx_std_readable" USING
            BY VALUE WS-TIMEOUT
            RETURNING WS-RC
        IF WS-RC NOT = 1
            EXIT PARAGRAPH
        END-IF
        CALL "cvx_std_read" USING
            BY REFERENCE WS-CHUNK
            BY VALUE 65536
            BY REFERENCE WS-CHUNK-LEN
            RETURNING WS-RC
    END-IF

    EVALUATE WS-RC
        WHEN CVX-OK
            CONTINUE
        WHEN CVX-AGAIN
            EXIT PARAGRAPH
        WHEN CVX-TIMEOUT
            EXIT PARAGRAPH
        WHEN CVX-EOF
            MOVE 1 TO WS-EOF-SEEN
            EXIT PARAGRAPH
        WHEN OTHER
            MOVE 1 TO WS-EOF-SEEN
            EXIT PARAGRAPH
    END-EVALUATE

    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > WS-CHUNK-LEN
        MOVE WS-CHUNK(WS-I:1) TO WS-CH
        EVALUATE TRUE
            WHEN WS-CH = FUNCTION CHAR(11)
                IF WS-DISCARDING = 1
                    MOVE 0 TO WS-DISCARDING
                    MOVE 0 TO WS-LINE-LEN
                ELSE
                    PERFORM PROCESS-LINE
                    MOVE 0 TO WS-LINE-LEN
                END-IF
                IF WS-CLOSING = 1
                    EXIT PERFORM
                END-IF
            WHEN WS-DISCARDING = 1
                CONTINUE
            WHEN WS-LINE-LEN >= WS-MAX-LINE
                MOVE "ProtocolError" TO WS-ERRNAME
                MOVE 13 TO WS-ERRNAME-LEN
                MOVE "adapter command exceeds 2 MiB" TO WS-ERRMSG
                MOVE 29 TO WS-ERRMSG-LEN
                MOVE 0 TO WS-CMD-ID-LEN
                PERFORM EMIT-ERROR
                MOVE 1 TO WS-DISCARDING
                MOVE 0 TO WS-LINE-LEN
            WHEN OTHER
                ADD 1 TO WS-LINE-LEN
                MOVE WS-CH TO WS-LINE(WS-LINE-LEN:1)
        END-EVALUATE
    END-PERFORM.

*> ------------------------------------------------------------------
*> Command dispatch
*> ------------------------------------------------------------------
PROCESS-LINE.
    *> Tolerate a CR before the newline.
    IF WS-LINE-LEN > 0
            AND WS-LINE(WS-LINE-LEN:1) = FUNCTION CHAR(14)
        SUBTRACT 1 FROM WS-LINE-LEN
    END-IF
    IF WS-LINE-LEN = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO WS-CMD-ID-LEN
    MOVE 0 TO WS-CMD-OP-LEN
    MOVE 0 TO WS-CMD-SUBID-LEN
    MOVE 0 TO WS-CMD-PATH-LEN
    MOVE 0 TO WS-CMD-ARGS-LEN
    MOVE 0 TO WS-CMD-TOKEN-LEN
    MOVE 0 TO WS-HAS-ARGS
    MOVE 0 TO WS-HAS-PATH
    MOVE -1 TO WS-CMD-PV

    CALL "cvx-json-parse" USING WS-SLOT-CMD WS-LINE WS-LINE-LEN WS-ST
    IF WS-ST NOT = CVX-OK
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "adapter command was not valid JSON" TO WS-ERRMSG
        MOVE 34 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-json-root" USING WS-SLOT-CMD WS-NODE
    CALL "cvx-json-type" USING WS-SLOT-CMD WS-NODE WS-TYPE
    IF WS-TYPE NOT = 7
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "adapter command must be an object" TO WS-ERRMSG
        MOVE 33 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF

    PERFORM EXTRACT-COMMAND-FIELDS
    IF WS-CMD-ID-LEN = 0 OR WS-CMD-OP-LEN = 0
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "adapter command requires id and op" TO WS-ERRMSG
        MOVE 34 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF

    IF WS-HELLO-SEEN = 0
            AND WS-CMD-OP(1:WS-CMD-OP-LEN) NOT = "hello"
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "hello must be the first adapter command" TO WS-ERRMSG
        MOVE 39 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF

    EVALUATE WS-CMD-OP(1:WS-CMD-OP-LEN)
        WHEN "hello"
            PERFORM DO-HELLO
        WHEN "query"
            MOVE 1 TO WS-OP
            PERFORM DO-CALL
        WHEN "mutation"
            MOVE 2 TO WS-OP
            PERFORM DO-CALL
        WHEN "action"
            MOVE 3 TO WS-OP
            PERFORM DO-CALL
        WHEN "setAuth"
            PERFORM DO-SET-AUTH
        WHEN "subscribe"
            PERFORM DO-SUBSCRIBE
        WHEN "unsubscribe"
            PERFORM DO-UNSUBSCRIBE
        WHEN "debugDisconnect"
            PERFORM DO-DEBUG-DISCONNECT
        WHEN "close"
            PERFORM DO-CLOSE
        WHEN OTHER
            MOVE "ProtocolError" TO WS-ERRNAME
            MOVE 13 TO WS-ERRNAME-LEN
            MOVE "unknown adapter operation" TO WS-ERRMSG
            MOVE 25 TO WS-ERRMSG-LEN
            PERFORM EMIT-ERROR
    END-EVALUATE.

*> Every extraction below calls cvx-json-span-len before it ever calls
*> cvx-json-string or cvx-json-copy-span, and skips the field (leaving
*> it absent, exactly as an oversized decoded value was already
*> silently left absent below) when the raw span would not fit in the
*> now much smaller WS-SPAN buffer. See WS-ESC's own comment above.
EXTRACT-COMMAND-FIELDS.
    MOVE "id" TO WS-KEY
    MOVE 2 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-span-len" USING WS-SLOT-CMD WS-CHILD WS-RAWLEN
        IF WS-RAWLEN <= 8192
            CALL "cvx-json-string" USING WS-SLOT-CMD WS-CHILD WS-SPAN
                WS-SPAN-LEN WS-ST
            IF WS-ST = CVX-OK AND WS-SPAN-LEN >= 1
                    AND WS-SPAN-LEN <= 128
                MOVE WS-SPAN(1:WS-SPAN-LEN) TO WS-CMD-ID(1:WS-SPAN-LEN)
                MOVE WS-SPAN-LEN TO WS-CMD-ID-LEN
            END-IF
        END-IF
    END-IF

    MOVE "op" TO WS-KEY
    MOVE 2 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-span-len" USING WS-SLOT-CMD WS-CHILD WS-RAWLEN
        IF WS-RAWLEN <= 8192
            CALL "cvx-json-string" USING WS-SLOT-CMD WS-CHILD WS-SPAN
                WS-SPAN-LEN WS-ST
            IF WS-ST = CVX-OK AND WS-SPAN-LEN >= 1
                    AND WS-SPAN-LEN <= 32
                MOVE WS-SPAN(1:WS-SPAN-LEN) TO WS-CMD-OP(1:WS-SPAN-LEN)
                MOVE WS-SPAN-LEN TO WS-CMD-OP-LEN
            END-IF
        END-IF
    END-IF

    MOVE "subscriptionId" TO WS-KEY
    MOVE 14 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-span-len" USING WS-SLOT-CMD WS-CHILD WS-RAWLEN
        IF WS-RAWLEN <= 8192
            CALL "cvx-json-string" USING WS-SLOT-CMD WS-CHILD WS-SPAN
                WS-SPAN-LEN WS-ST
            IF WS-ST = CVX-OK AND WS-SPAN-LEN >= 1
                    AND WS-SPAN-LEN <= 128
                MOVE WS-SPAN(1:WS-SPAN-LEN)
                    TO WS-CMD-SUBID(1:WS-SPAN-LEN)
                MOVE WS-SPAN-LEN TO WS-CMD-SUBID-LEN
            END-IF
        END-IF
    END-IF

    MOVE "path" TO WS-KEY
    MOVE 4 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        MOVE 1 TO WS-HAS-PATH
        CALL "cvx-json-span-len" USING WS-SLOT-CMD WS-CHILD WS-RAWLEN
        IF WS-RAWLEN <= 8192
            CALL "cvx-json-string" USING WS-SLOT-CMD WS-CHILD WS-SPAN
                WS-SPAN-LEN WS-ST
            IF WS-ST = CVX-OK AND WS-SPAN-LEN <= 256
                MOVE WS-SPAN(1:WS-SPAN-LEN)
                    TO WS-CMD-PATH(1:WS-SPAN-LEN)
                MOVE WS-SPAN-LEN TO WS-CMD-PATH-LEN
            END-IF
        END-IF
    END-IF

    *> args is forwarded to the client as its raw JSON span, so an
    *> argument object round-trips byte for byte.
    MOVE "args" TO WS-KEY
    MOVE 4 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-type" USING WS-SLOT-CMD WS-CHILD WS-TYPE
        IF WS-TYPE = 7
            MOVE 1 TO WS-HAS-ARGS
            CALL "cvx-json-span-len" USING WS-SLOT-CMD WS-CHILD
                WS-RAWLEN
            IF WS-RAWLEN <= 8192
                CALL "cvx-json-copy-span" USING WS-SLOT-CMD WS-CHILD
                    WS-SPAN WS-SPAN-LEN WS-ST
                IF WS-SPAN-LEN <= 8192
                    MOVE WS-SPAN(1:WS-SPAN-LEN)
                        TO WS-CMD-ARGS(1:WS-SPAN-LEN)
                    MOVE WS-SPAN-LEN TO WS-CMD-ARGS-LEN
                END-IF
            END-IF
        END-IF
    END-IF

    MOVE "token" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-span-len" USING WS-SLOT-CMD WS-CHILD WS-RAWLEN
        IF WS-RAWLEN <= 8192
            CALL "cvx-json-string" USING WS-SLOT-CMD WS-CHILD WS-SPAN
                WS-SPAN-LEN WS-ST
            IF WS-ST = CVX-OK AND WS-SPAN-LEN <= 4096
                MOVE WS-SPAN(1:WS-SPAN-LEN)
                    TO WS-CMD-TOKEN(1:WS-SPAN-LEN)
                MOVE WS-SPAN-LEN TO WS-CMD-TOKEN-LEN
            END-IF
        END-IF
    END-IF

    MOVE "protocolVersion" TO WS-KEY
    MOVE 15 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT-CMD WS-NODE WS-KEY
        WS-KEY-LEN WS-CHILD
    IF WS-CHILD NOT = 0
        CALL "cvx-json-int" USING WS-SLOT-CMD WS-CHILD WS-CMD-PV WS-ST
    END-IF.

DO-HELLO.
    IF WS-HELLO-SEEN = 1
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "hello may only be sent once" TO WS-ERRMSG
        MOVE 27 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    IF WS-CMD-PV NOT = 1
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "unsupported adapter protocol version" TO WS-ERRMSG
        MOVE 36 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO WS-HELLO-SEEN
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    CALL "cvx-json-esc-string" USING WS-CMD-ID WS-CMD-ID-LEN
        WS-ESC WS-ESC-LEN
    STRING
        '{"protocolVersion":1,"id":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        ',"type":"ready","language":"cobol",' DELIMITED SIZE
        '"implementation":"native-gnucobol",' DELIMITED SIZE
        '"runtime":"GnuCOBOL"}' DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT.

*> Create the client lazily, so a controller that only says hello and
*> close never touches the network.
ENSURE-CLIENT.
    IF WS-CLIENT-READY = 1
        EXIT PARAGRAPH
    END-IF
    MOVE SPACES TO WS-URL
    ACCEPT WS-URL FROM ENVIRONMENT "CONVEX_URL"
    COMPUTE WS-URL-LEN = FUNCTION LENGTH(FUNCTION TRIM(WS-URL))
    IF WS-URL = SPACES
        MOVE "ConfigError" TO WS-ERRNAME
        MOVE 11 TO WS-ERRNAME-LEN
        MOVE "CONVEX_URL is required" TO WS-ERRMSG
        MOVE 22 TO WS-ERRMSG-LEN
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-client-init" USING WS-URL WS-URL-LEN WS-CLIENTV
        WS-CLIENTV-LEN CVX-ERROR WS-ST
    IF WS-ST NOT = CVX-OK
        MOVE CVX-E-NAME(1:CVX-E-NAME-LEN)
            TO WS-ERRNAME(1:CVX-E-NAME-LEN)
        MOVE CVX-E-NAME-LEN TO WS-ERRNAME-LEN
        MOVE CVX-E-MSG(1:CVX-E-MSG-LEN) TO WS-ERRMSG(1:CVX-E-MSG-LEN)
        MOVE CVX-E-MSG-LEN TO WS-ERRMSG-LEN
        EXIT PARAGRAPH
    END-IF
    MOVE SPACES TO WS-TOKEN-ENV
    ACCEPT WS-TOKEN-ENV FROM ENVIRONMENT "CONVEX_AUTH_TOKEN"
    IF WS-TOKEN-ENV NOT = SPACES
        COMPUTE WS-TOKEN-ENV-LEN =
            FUNCTION LENGTH(FUNCTION TRIM(WS-TOKEN-ENV))
        CALL "cvx-client-set-auth" USING WS-TOKEN-ENV
            WS-TOKEN-ENV-LEN CVX-ERROR WS-ST
    END-IF
    MOVE 1 TO WS-CLIENT-READY.

DO-CALL.
    MOVE 0 TO WS-ERRNAME-LEN
    PERFORM ENSURE-CLIENT
    IF WS-CLIENT-READY = 0
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    IF WS-HAS-PATH = 0 OR WS-CMD-PATH-LEN < 3 OR WS-HAS-ARGS = 0
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "call requires a path and an args object" TO WS-ERRMSG
        MOVE 39 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-client-call" USING WS-OP WS-CMD-PATH WS-CMD-PATH-LEN
        WS-CMD-ARGS WS-CMD-ARGS-LEN CVX-RESULT CVX-ERROR WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM EMIT-STRUCTURED-ERROR
        EXIT PARAGRAPH
    END-IF
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    CALL "cvx-json-esc-string" USING WS-CMD-ID WS-CMD-ID-LEN
        WS-ESC WS-ESC-LEN
    STRING
        '{"id":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        ',"type":"result","value":' DELIMITED SIZE
        CVX-R-VALUE(1:CVX-R-VALUE-LEN) DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    *> logs is omitted entirely when Convex sent none.
    IF CVX-R-HAS-LOGS = 1
        STRING
            ',"logs":' DELIMITED SIZE
            CVX-R-LOGS(1:CVX-R-LOGS-LEN) DELIMITED SIZE
            INTO WS-EVT
            WITH POINTER WS-EVT-LEN
        END-STRING
    END-IF
    STRING "}" DELIMITED SIZE INTO WS-EVT WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT.

DO-SET-AUTH.
    MOVE 0 TO WS-ERRNAME-LEN
    PERFORM ENSURE-CLIENT
    IF WS-CLIENT-READY = 0
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-client-set-auth" USING WS-CMD-TOKEN WS-CMD-TOKEN-LEN
        CVX-ERROR WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM EMIT-STRUCTURED-ERROR
        EXIT PARAGRAPH
    END-IF
    PERFORM EMIT-ACK.

DO-SUBSCRIBE.
    MOVE 0 TO WS-ERRNAME-LEN
    PERFORM ENSURE-CLIENT
    IF WS-CLIENT-READY = 0
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    IF WS-CMD-SUBID-LEN = 0 OR WS-HAS-PATH = 0 OR WS-HAS-ARGS = 0
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "subscribe requires subscriptionId, path, and args"
            TO WS-ERRMSG
        MOVE 48 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    *> Same-id replacement retires the old relay first, so no value
    *> from the previous subscription can cross this acknowledgement.
    PERFORM FIND-RELAY
    IF WS-RELAYIX NOT = 0
        MOVE WS-RL-SUBIX(WS-RELAYIX) TO WS-SUBIX
        CALL "cvx-live-unsubscribe" USING WS-SUBIX CVX-ERROR WS-ST
        MOVE 0 TO WS-RL-USED(WS-RELAYIX)
    END-IF
    CALL "cvx-live-subscribe" USING WS-CMD-PATH WS-CMD-PATH-LEN
        WS-CMD-ARGS WS-CMD-ARGS-LEN WS-SUBIX CVX-ERROR WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM EMIT-STRUCTURED-ERROR
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO WS-RELAYIX
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 64
        IF WS-RL-USED(WS-I) = 0
            MOVE WS-I TO WS-RELAYIX
            EXIT PERFORM
        END-IF
    END-PERFORM
    IF WS-RELAYIX = 0
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "adapter relay table is full" TO WS-ERRMSG
        MOVE 27 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO WS-RL-USED(WS-RELAYIX)
    MOVE SPACES TO WS-RL-SUBID(WS-RELAYIX)
    MOVE WS-CMD-SUBID(1:WS-CMD-SUBID-LEN)
        TO WS-RL-SUBID(WS-RELAYIX)(1:WS-CMD-SUBID-LEN)
    MOVE WS-CMD-SUBID-LEN TO WS-RL-SUBID-LEN(WS-RELAYIX)
    MOVE WS-SUBIX TO WS-RL-SUBIX(WS-RELAYIX)
    *> Acknowledge before any delivery is forwarded.
    PERFORM EMIT-ACK.

DO-UNSUBSCRIBE.
    IF WS-CMD-SUBID-LEN = 0
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "unsubscribe requires subscriptionId" TO WS-ERRMSG
        MOVE 35 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    PERFORM FIND-RELAY
    IF WS-RELAYIX NOT = 0
        MOVE WS-RL-SUBIX(WS-RELAYIX) TO WS-SUBIX
        CALL "cvx-live-unsubscribe" USING WS-SUBIX CVX-ERROR WS-ST
        MOVE 0 TO WS-RL-USED(WS-RELAYIX)
    END-IF
    PERFORM EMIT-ACK.

*> The client discards the retired connection's deliveries as part of
*> the disconnect, so acknowledging here is already a real barrier.
DO-DEBUG-DISCONNECT.
    IF WS-CLIENT-READY = 0
        MOVE "ProtocolError" TO WS-ERRNAME
        MOVE 13 TO WS-ERRNAME-LEN
        MOVE "Live has not been started" TO WS-ERRMSG
        MOVE 25 TO WS-ERRMSG-LEN
        PERFORM EMIT-ERROR
        EXIT PARAGRAPH
    END-IF
    CALL "cvx-live-debug-disconnect" USING WS-GEN CVX-ERROR WS-ST
    IF WS-ST NOT = CVX-OK
        PERFORM EMIT-STRUCTURED-ERROR
        EXIT PARAGRAPH
    END-IF
    PERFORM EMIT-ACK.

DO-CLOSE.
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    CALL "cvx-json-esc-string" USING WS-CMD-ID WS-CMD-ID-LEN
        WS-ESC WS-ESC-LEN
    STRING
        '{"id":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        ',"type":"closed"}' DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT
    MOVE 1 TO WS-CLOSING.

FIND-RELAY.
    MOVE 0 TO WS-RELAYIX
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 64
        IF WS-RL-USED(WS-I) = 1
                AND WS-RL-SUBID-LEN(WS-I) = WS-CMD-SUBID-LEN
                AND WS-RL-SUBID(WS-I)(1:WS-CMD-SUBID-LEN)
                    = WS-CMD-SUBID(1:WS-CMD-SUBID-LEN)
            MOVE WS-I TO WS-RELAYIX
            EXIT PERFORM
        END-IF
    END-PERFORM.

*> ------------------------------------------------------------------
*> Live delivery forwarding
*> ------------------------------------------------------------------
DRAIN-DELIVERIES.
    PERFORM VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 64
        IF WS-RL-USED(WS-J) = 1
            MOVE WS-RL-SUBIX(WS-J) TO WS-SUBIX
            PERFORM UNTIL 1 = 2
                CALL "cvx-live-next" USING WS-SUBIX CVX-RESULT
                    CVX-ERROR WS-ST
                IF WS-ST NOT = CVX-OK
                    EXIT PERFORM
                END-IF
                MOVE WS-J TO WS-RELAYIX
                PERFORM EMIT-SUBSCRIPTION
            END-PERFORM
        END-IF
    END-PERFORM.

EMIT-SUBSCRIPTION.
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    CALL "cvx-json-esc-string" USING WS-RL-SUBID(WS-RELAYIX)
        WS-RL-SUBID-LEN(WS-RELAYIX) WS-ESC WS-ESC-LEN
    STRING
        '{"type":"subscription","subscriptionId":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    IF CVX-R-IS-ERROR = 1
        PERFORM APPEND-ERROR-OBJECT
    ELSE
        STRING
            ',"value":' DELIMITED SIZE
            CVX-R-VALUE(1:CVX-R-VALUE-LEN) DELIMITED SIZE
            INTO WS-EVT
            WITH POINTER WS-EVT-LEN
        END-STRING
    END-IF
    IF CVX-R-HAS-LOGS = 1
        STRING
            ',"logs":' DELIMITED SIZE
            CVX-R-LOGS(1:CVX-R-LOGS-LEN) DELIMITED SIZE
            INTO WS-EVT
            WITH POINTER WS-EVT-LEN
        END-STRING
    END-IF
    STRING "}" DELIMITED SIZE INTO WS-EVT WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT.

*> data is omitted when Convex sent no errorData, rather than being
*> serialized as null.
APPEND-ERROR-OBJECT.
    CALL "cvx-json-esc-string" USING CVX-E-NAME CVX-E-NAME-LEN
        WS-ESC WS-ESC-LEN
    STRING
        ',"error":{"name":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    CALL "cvx-json-esc-string" USING CVX-E-MSG CVX-E-MSG-LEN
        WS-ESC WS-ESC-LEN
    STRING
        ',"message":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    IF CVX-E-DATA-LEN > 0
        STRING
            ',"data":' DELIMITED SIZE
            CVX-E-DATA(1:CVX-E-DATA-LEN) DELIMITED SIZE
            INTO WS-EVT
            WITH POINTER WS-EVT-LEN
        END-STRING
    END-IF
    STRING "}" DELIMITED SIZE INTO WS-EVT WITH POINTER WS-EVT-LEN
    END-STRING.

*> ------------------------------------------------------------------
*> Event emission
*> ------------------------------------------------------------------
EMIT-ACK.
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    CALL "cvx-json-esc-string" USING WS-CMD-ID WS-CMD-ID-LEN
        WS-ESC WS-ESC-LEN
    STRING
        '{"id":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        ',"type":"ack"}' DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT.

*> A structured client failure keeps its name, message, and data.
EMIT-STRUCTURED-ERROR.
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    CALL "cvx-json-esc-string" USING WS-CMD-ID WS-CMD-ID-LEN
        WS-ESC WS-ESC-LEN
    STRING
        '{"id":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        ',"type":"error"' DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    PERFORM APPEND-ERROR-OBJECT
    STRING "}" DELIMITED SIZE INTO WS-EVT WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT.

*> An adapter-level failure that never reached the client.
EMIT-ERROR.
    *> No bulk clear: every STRING below starts at WS-EVT-LEN = 1 and
    *> EMIT-EVENT only ever reads the first WS-EVT-LEN bytes, so
    *> spacing out the full 2 MiB buffer first would only dirty pages
    *> nothing goes on to read -- real cost for a typically-small
    *> event, and one more contributor to the adapter's memory-growth
    *> budget for no behavioural benefit.
    MOVE 1 TO WS-EVT-LEN
    STRING '{' DELIMITED SIZE INTO WS-EVT WITH POINTER WS-EVT-LEN
    END-STRING
    IF WS-CMD-ID-LEN > 0
        CALL "cvx-json-esc-string" USING WS-CMD-ID WS-CMD-ID-LEN
            WS-ESC WS-ESC-LEN
        STRING
            '"id":' DELIMITED SIZE
            WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
            ',' DELIMITED SIZE
            INTO WS-EVT
            WITH POINTER WS-EVT-LEN
        END-STRING
    END-IF
    CALL "cvx-json-esc-string" USING WS-ERRNAME WS-ERRNAME-LEN
        WS-ESC WS-ESC-LEN
    STRING
        '"type":"error","error":{"name":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    CALL "cvx-json-esc-string" USING WS-ERRMSG WS-ERRMSG-LEN
        WS-ESC WS-ESC-LEN
    STRING
        ',"message":' DELIMITED SIZE
        WS-ESC(1:WS-ESC-LEN) DELIMITED SIZE
        '}}' DELIMITED SIZE
        INTO WS-EVT
        WITH POINTER WS-EVT-LEN
    END-STRING
    SUBTRACT 1 FROM WS-EVT-LEN
    PERFORM EMIT-EVENT.

EMIT-EVENT.
    ADD 1 TO WS-EVT-LEN
    MOVE FUNCTION CHAR(11) TO WS-EVT(WS-EVT-LEN:1)
    IF WS-TCP-MODE = 1
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        COMPUTE WS-DEADLINE = WS-NOW + 5000
        CALL "cvx_net_write" USING
            BY VALUE WS-CTRL-HANDLE
            BY REFERENCE WS-EVT
            BY VALUE WS-EVT-LEN
            BY VALUE WS-DEADLINE
            BY REFERENCE WS-N
            RETURNING WS-RC
    ELSE
        CALL "cvx_std_write" USING
            BY VALUE WS-ONE
            BY REFERENCE WS-EVT
            BY VALUE WS-EVT-LEN
            RETURNING WS-RC
    END-IF.

SHUTDOWN-ADAPTER.
    IF WS-CLIENT-READY = 1
        CALL "cvx-live-close" USING WS-ST
    END-IF
    IF WS-TCP-MODE = 1 AND WS-CTRL-HANDLE >= 0
        CALL "cvx_net_close" USING BY VALUE WS-CTRL-HANDLE
            RETURNING WS-RC
    END-IF.

END PROGRAM CONVEX-ADAPTER.
