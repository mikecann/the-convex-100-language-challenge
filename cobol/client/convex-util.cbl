>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Byte, base64, UTF-8, and Convex timestamp primitives.
*>
*> COBOL has no bit operators in the portable subset, so exclusive-or
*> is served from a table built once at start-up. Everything else here
*> is ordinary character arithmetic: FUNCTION ORD returns an ordinal
*> position, so a byte value is always ORD(c) - 1 and a byte is built
*> with FUNCTION CHAR(value + 1).
*> ==================================================================
*> `cvx-ts-decode` below calls the sibling entry point `cvx-ts-encode`
*> (its canonicity check) while it is itself still active. Every ENTRY
*> here shares one WORKING-STORAGE instance and one activation record,
*> so without RECURSIVE that self-call re-enters an already-active,
*> non-reentrant program -- GnuCOBOL's runtime surfaced this as a
*> segfault ("attempt to reference unallocated memory") rather than a
*> clean diagnostic.
IDENTIFICATION DIVISION.
PROGRAM-ID. CVXUTIL IS RECURSIVE.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".

*> Built on first use; WORKING-STORAGE survives between CALLs.
01 WS-XOR-READY             BINARY-LONG VALUE 0.
01 WS-XOR-TABLE.
   05 WS-XOR-ROW OCCURS 256 TIMES.
      10 WS-XOR-CELL        PIC X OCCURS 256 TIMES.

01 WS-B64-ALPHABET          PIC X(64) VALUE
   "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".
01 WS-HEX-DIGITS            PIC X(16) VALUE "0123456789abcdef".

01 WS-A                     BINARY-LONG.
01 WS-B                     BINARY-LONG.
01 WS-RA                    BINARY-LONG.
01 WS-RB                    BINARY-LONG.
01 WS-QA                    BINARY-LONG.
01 WS-QB                    BINARY-LONG.
01 WS-MA                    BINARY-LONG.
01 WS-MB                    BINARY-LONG.
01 WS-RES                   BINARY-LONG.
01 WS-BIT                   BINARY-LONG.
01 WS-I                     BINARY-LONG.
01 WS-J                     BINARY-LONG.
01 WS-K                     BINARY-LONG.
01 WS-N                     BINARY-LONG.
01 WS-BYTE                  BINARY-LONG.
01 WS-BYTE2                 BINARY-LONG.
01 WS-BYTE3                 BINARY-LONG.
01 WS-BYTE4                 BINARY-LONG.
01 WS-NEED                  BINARY-LONG.
01 WS-CP                    BINARY-LONG.
01 WS-LOW                   BINARY-LONG.
01 WS-HIGH                  BINARY-LONG.
01 WS-OK                    BINARY-LONG.
01 WS-GROUP                 BINARY-LONG.
01 WS-VAL                   BINARY-LONG.

*> Fixed lengths passed by reference to cvx-b64-encode, which needs
*> modifiable items rather than literals.
01 WS-EIGHT                 BINARY-LONG VALUE 8.
01 WS-TWELVE                BINARY-LONG VALUE 12.

*> Full unsigned 64-bit range without bignums: base-256 decomposition
*> over a 20-digit decimal item.
01 WS-TS-WORK               PIC 9(20).
01 WS-TS-QUOT               PIC 9(20).
01 WS-TS-REM                PIC 9(20).
01 WS-TS-BYTES.
   05 WS-TS-BYTE            PIC X OCCURS 8 TIMES.
01 WS-TS-ROUNDTRIP          PIC X(12).
01 WS-TS-SCRATCH            PIC 9(20).

*> LINKAGE items occupy no storage. They are declared at the largest
*> buffer any caller passes so that reference modification stays inside
*> the declared length and -Wall has nothing to complain about.
LINKAGE SECTION.
01 LK-A-CHAR                PIC X.
01 LK-B-CHAR                PIC X.
01 LK-OUT-CHAR              PIC X.
01 LK-IN-BUF                PIC X(2097152).
01 LK-IN-LEN                BINARY-LONG.
01 LK-OUT-BUF               PIC X(2097152).
01 LK-OUT-LEN               BINARY-LONG.
01 LK-STATUS                BINARY-LONG.
01 LK-TS-TEXT               PIC X(12).
01 LK-TS-VALUE              PIC 9(20).

PROCEDURE DIVISION.
CVXUTIL-MAIN SECTION.
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-util-init: build the exclusive-or table. Safe to call repeatedly.
*> ------------------------------------------------------------------
ENTRY "cvx-util-init".
    IF WS-XOR-READY = 1
        GOBACK
    END-IF
    PERFORM VARYING WS-A FROM 0 BY 1 UNTIL WS-A > 255
        PERFORM VARYING WS-B FROM 0 BY 1 UNTIL WS-B > 255
            MOVE WS-A TO WS-RA
            MOVE WS-B TO WS-RB
            MOVE 0 TO WS-RES
            MOVE 1 TO WS-BIT
            PERFORM 8 TIMES
                DIVIDE WS-RA BY 2 GIVING WS-QA REMAINDER WS-MA
                DIVIDE WS-RB BY 2 GIVING WS-QB REMAINDER WS-MB
                IF WS-MA NOT = WS-MB
                    COMPUTE WS-RES = WS-RES + WS-BIT
                END-IF
                MOVE WS-QA TO WS-RA
                MOVE WS-QB TO WS-RB
                COMPUTE WS-BIT = WS-BIT * 2
            END-PERFORM
            MOVE FUNCTION CHAR(WS-RES + 1)
                TO WS-XOR-CELL(WS-A + 1, WS-B + 1)
        END-PERFORM
    END-PERFORM
    MOVE 1 TO WS-XOR-READY
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-xor: one byte exclusive-or, used by WebSocket masking.
*> ------------------------------------------------------------------
ENTRY "cvx-xor" USING LK-A-CHAR LK-B-CHAR LK-OUT-CHAR.
    IF WS-XOR-READY NOT = 1
        CALL "cvx-util-init"
    END-IF
    COMPUTE WS-A = FUNCTION ORD(LK-A-CHAR)
    COMPUTE WS-B = FUNCTION ORD(LK-B-CHAR)
    MOVE WS-XOR-CELL(WS-A, WS-B) TO LK-OUT-CHAR
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-b64-encode: standard base64 with padding.
*> ------------------------------------------------------------------
ENTRY "cvx-b64-encode" USING LK-IN-BUF LK-IN-LEN LK-OUT-BUF LK-OUT-LEN.
    MOVE 0 TO WS-J
    MOVE 1 TO WS-I
    PERFORM UNTIL WS-I > LK-IN-LEN
        COMPUTE WS-BYTE = FUNCTION ORD(LK-IN-BUF(WS-I:1)) - 1
        MOVE 0 TO WS-BYTE2
        MOVE 0 TO WS-BYTE3
        MOVE 1 TO WS-GROUP
        IF WS-I + 1 <= LK-IN-LEN
            COMPUTE WS-BYTE2 = FUNCTION ORD(LK-IN-BUF(WS-I + 1:1)) - 1
            MOVE 2 TO WS-GROUP
        END-IF
        IF WS-I + 2 <= LK-IN-LEN
            COMPUTE WS-BYTE3 = FUNCTION ORD(LK-IN-BUF(WS-I + 2:1)) - 1
            MOVE 3 TO WS-GROUP
        END-IF

        COMPUTE WS-VAL = FUNCTION INTEGER(WS-BYTE / 4)
        ADD 1 TO WS-J
        MOVE WS-B64-ALPHABET(WS-VAL + 1:1) TO LK-OUT-BUF(WS-J:1)

        COMPUTE WS-VAL = FUNCTION MOD(WS-BYTE, 4) * 16
                       + FUNCTION INTEGER(WS-BYTE2 / 16)
        ADD 1 TO WS-J
        MOVE WS-B64-ALPHABET(WS-VAL + 1:1) TO LK-OUT-BUF(WS-J:1)

        ADD 1 TO WS-J
        IF WS-GROUP >= 2
            COMPUTE WS-VAL = FUNCTION MOD(WS-BYTE2, 16) * 4
                           + FUNCTION INTEGER(WS-BYTE3 / 64)
            MOVE WS-B64-ALPHABET(WS-VAL + 1:1) TO LK-OUT-BUF(WS-J:1)
        ELSE
            MOVE "=" TO LK-OUT-BUF(WS-J:1)
        END-IF

        ADD 1 TO WS-J
        IF WS-GROUP >= 3
            COMPUTE WS-VAL = FUNCTION MOD(WS-BYTE3, 64)
            MOVE WS-B64-ALPHABET(WS-VAL + 1:1) TO LK-OUT-BUF(WS-J:1)
        ELSE
            MOVE "=" TO LK-OUT-BUF(WS-J:1)
        END-IF

        COMPUTE WS-I = WS-I + 3
    END-PERFORM
    MOVE WS-J TO LK-OUT-LEN
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-hex-encode: lowercase hex, used for session identifiers.
*> ------------------------------------------------------------------
ENTRY "cvx-hex-encode" USING LK-IN-BUF LK-IN-LEN LK-OUT-BUF LK-OUT-LEN.
    MOVE 0 TO WS-J
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > LK-IN-LEN
        COMPUTE WS-BYTE = FUNCTION ORD(LK-IN-BUF(WS-I:1)) - 1
        COMPUTE WS-HIGH = FUNCTION INTEGER(WS-BYTE / 16)
        COMPUTE WS-LOW = FUNCTION MOD(WS-BYTE, 16)
        ADD 1 TO WS-J
        MOVE WS-HEX-DIGITS(WS-HIGH + 1:1) TO LK-OUT-BUF(WS-J:1)
        ADD 1 TO WS-J
        MOVE WS-HEX-DIGITS(WS-LOW + 1:1) TO LK-OUT-BUF(WS-J:1)
    END-PERFORM
    MOVE WS-J TO LK-OUT-LEN
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-utf8-valid: strict UTF-8 validation.
*>
*> Rejects overlong forms, surrogate halves, and anything above
*> U+10FFFF, so a hostile Live text frame cannot smuggle a byte
*> sequence past the JSON scanner that a stricter peer would refuse.
*> Returns CVX-OK or CVX-ERR.
*> ------------------------------------------------------------------
ENTRY "cvx-utf8-valid" USING LK-IN-BUF LK-IN-LEN LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE 1 TO WS-I
    PERFORM UNTIL WS-I > LK-IN-LEN
        COMPUTE WS-BYTE = FUNCTION ORD(LK-IN-BUF(WS-I:1)) - 1
        EVALUATE TRUE
            WHEN WS-BYTE <= 127
                MOVE 0 TO WS-NEED
                MOVE 0 TO WS-CP
            WHEN WS-BYTE >= 194 AND WS-BYTE <= 223
                MOVE 1 TO WS-NEED
                COMPUTE WS-CP = WS-BYTE - 192
            WHEN WS-BYTE >= 224 AND WS-BYTE <= 239
                MOVE 2 TO WS-NEED
                COMPUTE WS-CP = WS-BYTE - 224
            WHEN WS-BYTE >= 240 AND WS-BYTE <= 244
                MOVE 3 TO WS-NEED
                COMPUTE WS-CP = WS-BYTE - 240
            WHEN OTHER
                MOVE CVX-ERR TO LK-STATUS
                MOVE 0 TO WS-NEED
                EXIT PERFORM
        END-EVALUATE

        IF WS-I + WS-NEED > LK-IN-LEN
            MOVE CVX-ERR TO LK-STATUS
            EXIT PERFORM
        END-IF

        MOVE 1 TO WS-OK
        PERFORM VARYING WS-K FROM 1 BY 1 UNTIL WS-K > WS-NEED
            COMPUTE WS-BYTE2 =
                FUNCTION ORD(LK-IN-BUF(WS-I + WS-K:1)) - 1
            IF WS-BYTE2 < 128 OR WS-BYTE2 > 191
                MOVE 0 TO WS-OK
                EXIT PERFORM
            END-IF
            COMPUTE WS-CP = WS-CP * 64 + (WS-BYTE2 - 128)
        END-PERFORM
        IF WS-OK = 0
            MOVE CVX-ERR TO LK-STATUS
            EXIT PERFORM
        END-IF

        *> Reject overlong encodings, UTF-16 surrogates, and values
        *> beyond the Unicode maximum.
        EVALUATE WS-NEED
            WHEN 1
                IF WS-CP < 128
                    MOVE CVX-ERR TO LK-STATUS
                END-IF
            WHEN 2
                IF WS-CP < 2048
                    MOVE CVX-ERR TO LK-STATUS
                END-IF
                IF WS-CP >= 55296 AND WS-CP <= 57343
                    MOVE CVX-ERR TO LK-STATUS
                END-IF
            WHEN 3
                IF WS-CP < 65536 OR WS-CP > 1114111
                    MOVE CVX-ERR TO LK-STATUS
                END-IF
        END-EVALUATE
        IF LK-STATUS NOT = CVX-OK
            EXIT PERFORM
        END-IF

        COMPUTE WS-I = WS-I + WS-NEED + 1
    END-PERFORM
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-ts-encode: Convex sync timestamps travel as base64 of a
*> little-endian unsigned 64-bit integer, always 12 characters with a
*> single trailing pad.
*> ------------------------------------------------------------------
ENTRY "cvx-ts-encode" USING LK-TS-VALUE LK-TS-TEXT.
    MOVE LK-TS-VALUE TO WS-TS-WORK
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 8
        DIVIDE WS-TS-WORK BY 256 GIVING WS-TS-QUOT REMAINDER WS-TS-REM
        MOVE FUNCTION CHAR(WS-TS-REM + 1) TO WS-TS-BYTE(WS-I)
        MOVE WS-TS-QUOT TO WS-TS-WORK
    END-PERFORM
    CALL "cvx-b64-encode" USING WS-TS-BYTES WS-EIGHT
        LK-TS-TEXT WS-TWELVE
    GOBACK.

*> ------------------------------------------------------------------
*> cvx-ts-decode: strict inverse. A timestamp that does not re-encode
*> to exactly the same text is rejected, which rules out non-canonical
*> base64 and stray padding bits.
*> ------------------------------------------------------------------
ENTRY "cvx-ts-decode" USING LK-TS-TEXT LK-TS-VALUE LK-STATUS.
    MOVE CVX-OK TO LK-STATUS
    MOVE 0 TO LK-TS-VALUE
    IF LK-TS-TEXT(12:1) NOT = "="
        MOVE CVX-ERR TO LK-STATUS
        GOBACK
    END-IF
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 8
        MOVE FUNCTION CHAR(1) TO WS-TS-BYTE(WS-I)
    END-PERFORM

    MOVE 0 TO WS-J
    MOVE 0 TO WS-VAL
    MOVE 0 TO WS-BIT
    MOVE 0 TO WS-N
    PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > 11
        MOVE 0 TO WS-OK
        PERFORM VARYING WS-K FROM 1 BY 1 UNTIL WS-K > 64
            IF WS-B64-ALPHABET(WS-K:1) = LK-TS-TEXT(WS-I:1)
                COMPUTE WS-VAL = WS-K - 1
                MOVE 1 TO WS-OK
                EXIT PERFORM
            END-IF
        END-PERFORM
        IF WS-OK = 0
            MOVE CVX-ERR TO LK-STATUS
            GOBACK
        END-IF
        *> Accumulate six bits at a time into whole bytes.
        COMPUTE WS-BIT = WS-BIT * 64 + WS-VAL
        ADD 6 TO WS-N
        IF WS-N >= 8
            SUBTRACT 8 FROM WS-N
            COMPUTE WS-BYTE = FUNCTION INTEGER(WS-BIT / (2 ** WS-N))
            COMPUTE WS-BIT = FUNCTION MOD(WS-BIT, 2 ** WS-N)
            ADD 1 TO WS-J
            IF WS-J <= 8
                MOVE FUNCTION CHAR(WS-BYTE + 1) TO WS-TS-BYTE(WS-J)
            END-IF
        END-IF
    END-PERFORM

    MOVE 0 TO WS-TS-SCRATCH
    PERFORM VARYING WS-I FROM 8 BY -1 UNTIL WS-I < 1
        COMPUTE WS-BYTE = FUNCTION ORD(WS-TS-BYTE(WS-I)) - 1
        COMPUTE WS-TS-SCRATCH = WS-TS-SCRATCH * 256 + WS-BYTE
    END-PERFORM
    MOVE WS-TS-SCRATCH TO LK-TS-VALUE

    *> Canonicity check: re-encode and demand an exact match.
    CALL "cvx-ts-encode" USING LK-TS-VALUE WS-TS-ROUNDTRIP
    IF WS-TS-ROUNDTRIP NOT = LK-TS-TEXT
        MOVE CVX-ERR TO LK-STATUS
        MOVE 0 TO LK-TS-VALUE
    END-IF
    GOBACK.

END PROGRAM CVXUTIL.
