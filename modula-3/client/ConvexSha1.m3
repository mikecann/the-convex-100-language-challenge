MODULE ConvexSha1;

IMPORT Text, Word, TextWr, Wr;

CONST Mask32 = 16_FFFFFFFF;

PROCEDURE Add32(a, b: Word.T): Word.T =
  BEGIN RETURN Word.And(Word.Plus(a, b), Mask32); END Add32;

PROCEDURE Rotl32(x: Word.T; n: INTEGER): Word.T =
  BEGIN
    RETURN Word.And(
      Word.Or(Word.LeftShift(x, n), Word.RightShift(x, 32 - n)),
      Mask32);
  END Rotl32;

PROCEDURE ByteAt(s: TEXT; i: CARDINAL): Word.T =
  BEGIN
    IF i >= Text.Length(s) THEN RETURN 0; END;
    RETURN ORD(Text.GetChar(s, i));
  END ByteAt;

PROCEDURE Digest(s: TEXT): TEXT =
  VAR
    msgLen := Text.Length(s);
    (* message length in bits, as a 64-bit big-endian count *)
    bitLen := Word.Times(msgLen, 8);
    (* padded length: original + 1 (0x80) + zeros to 56 mod 64, + 8 *)
    padded: TEXT;
    h0, h1, h2, h3, h4: Word.T;
    a, b, c, d, e, f, k, temp: Word.T;
    w: ARRAY [0 .. 79] OF Word.T;
    numBlocks: CARDINAL;
    padLen: CARDINAL;
  BEGIN
    h0 := 16_67452301; h1 := 16_EFCDAB89; h2 := 16_98BADCFE;
    h3 := 16_10325476; h4 := 16_C3D2E1F0;

    (* build the padded message as an explicit byte buffer *)
    padLen := msgLen + 1;
    WHILE padLen MOD 64 # 56 DO INC(padLen); END;
    padLen := padLen + 8;
    VAR buf := NEW(REF ARRAY OF CHAR, padLen);
    BEGIN
      FOR i := 0 TO msgLen - 1 DO buf[i] := Text.GetChar(s, i); END;
      buf[msgLen] := VAL(16_80, CHAR);
      FOR i := msgLen + 1 TO padLen - 9 DO buf[i] := VAL(0, CHAR); END;
      (* 64-bit big-endian bit length; messages here are far below 2^32
         bits, so the high 4 bytes are always zero *)
      FOR i := 0 TO 3 DO buf[padLen - 8 + i] := VAL(0, CHAR); END;
      buf[padLen - 4] := VAL(Word.And(Word.RightShift(bitLen, 24), 16_FF), CHAR);
      buf[padLen - 3] := VAL(Word.And(Word.RightShift(bitLen, 16), 16_FF), CHAR);
      buf[padLen - 2] := VAL(Word.And(Word.RightShift(bitLen, 8), 16_FF), CHAR);
      buf[padLen - 1] := VAL(Word.And(bitLen, 16_FF), CHAR);
      padded := Text.FromChars(buf^);
    END;

    numBlocks := padLen DIV 64;
    FOR block := 0 TO numBlocks - 1 DO
      VAR base := block * 64;
      BEGIN
        FOR t := 0 TO 15 DO
          w[t] := Word.Or(Word.Or(
                    Word.LeftShift(ByteAt(padded, base + t * 4), 24),
                    Word.LeftShift(ByteAt(padded, base + t * 4 + 1), 16)),
                  Word.Or(
                    Word.LeftShift(ByteAt(padded, base + t * 4 + 2), 8),
                    ByteAt(padded, base + t * 4 + 3)));
        END;
        FOR t := 16 TO 79 DO
          w[t] := Rotl32(Word.Xor(Word.Xor(w[t - 3], w[t - 8]), Word.Xor(w[t - 14], w[t - 16])), 1);
        END;

        a := h0; b := h1; c := h2; d := h3; e := h4;
        FOR t := 0 TO 79 DO
          IF t <= 19 THEN
            f := Word.Or(Word.And(b, c), Word.And(Word.Not(b), d));
            k := 16_5A827999;
          ELSIF t <= 39 THEN
            f := Word.Xor(Word.Xor(b, c), d);
            k := 16_6ED9EBA1;
          ELSIF t <= 59 THEN
            f := Word.Or(Word.Or(Word.And(b, c), Word.And(b, d)), Word.And(c, d));
            k := 16_8F1BBCDC;
          ELSE
            f := Word.Xor(Word.Xor(b, c), d);
            k := 16_CA62C1D6;
          END;
          temp := Add32(Add32(Add32(Rotl32(a, 5), f), e), Add32(k, w[t]));
          e := d; d := c; c := Rotl32(b, 30); b := a; a := temp;
        END;

        h0 := Add32(h0, a); h1 := Add32(h1, b); h2 := Add32(h2, c);
        h3 := Add32(h3, d); h4 := Add32(h4, e);
      END;
    END;

    VAR out := TextWr.New();
      PROCEDURE PutWordBE(x: Word.T) =
        BEGIN
          Wr.PutChar(out, VAL(Word.And(Word.RightShift(x, 24), 16_FF), CHAR));
          Wr.PutChar(out, VAL(Word.And(Word.RightShift(x, 16), 16_FF), CHAR));
          Wr.PutChar(out, VAL(Word.And(Word.RightShift(x, 8), 16_FF), CHAR));
          Wr.PutChar(out, VAL(Word.And(x, 16_FF), CHAR));
        END PutWordBE;
    BEGIN
      PutWordBE(h0); PutWordBE(h1); PutWordBE(h2); PutWordBE(h3); PutWordBE(h4);
      RETURN TextWr.ToText(out);
    END;
  END Digest;

BEGIN
END ConvexSha1.
