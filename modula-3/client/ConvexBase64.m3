MODULE ConvexBase64;

IMPORT Text, TextWr, Wr;

CONST Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

PROCEDURE Encode(s: TEXT): TEXT =
  VAR
    n := Text.Length(s);
    out := TextWr.New();
    i := 0;
    b0, b1, b2: INTEGER;
  BEGIN
    WHILE i + 3 <= n DO
      b0 := ORD(Text.GetChar(s, i));
      b1 := ORD(Text.GetChar(s, i + 1));
      b2 := ORD(Text.GetChar(s, i + 2));
      Wr.PutChar(out, Text.GetChar(Alphabet, b0 DIV 4));
      Wr.PutChar(out, Text.GetChar(Alphabet, ((b0 MOD 4) * 16) + (b1 DIV 16)));
      Wr.PutChar(out, Text.GetChar(Alphabet, ((b1 MOD 16) * 4) + (b2 DIV 64)));
      Wr.PutChar(out, Text.GetChar(Alphabet, b2 MOD 64));
      INC(i, 3);
    END;
    IF n - i = 1 THEN
      b0 := ORD(Text.GetChar(s, i));
      Wr.PutChar(out, Text.GetChar(Alphabet, b0 DIV 4));
      Wr.PutChar(out, Text.GetChar(Alphabet, (b0 MOD 4) * 16));
      Wr.PutText(out, "==");
    ELSIF n - i = 2 THEN
      b0 := ORD(Text.GetChar(s, i));
      b1 := ORD(Text.GetChar(s, i + 1));
      Wr.PutChar(out, Text.GetChar(Alphabet, b0 DIV 4));
      Wr.PutChar(out, Text.GetChar(Alphabet, ((b0 MOD 4) * 16) + (b1 DIV 16)));
      Wr.PutChar(out, Text.GetChar(Alphabet, (b1 MOD 16) * 4));
      Wr.PutText(out, "=");
    END;
    RETURN TextWr.ToText(out);
  END Encode;

PROCEDURE DecodeChar(c: CHAR): INTEGER RAISES {Error} =
  BEGIN
    IF c >= 'A' AND c <= 'Z' THEN RETURN ORD(c) - ORD('A'); END;
    IF c >= 'a' AND c <= 'z' THEN RETURN ORD(c) - ORD('a') + 26; END;
    IF c >= '0' AND c <= '9' THEN RETURN ORD(c) - ORD('0') + 52; END;
    IF c = '+' THEN RETURN 62; END;
    IF c = '/' THEN RETURN 63; END;
    RAISE Error;
  END DecodeChar;

PROCEDURE Decode(s: TEXT): TEXT RAISES {Error} =
  VAR
    n := Text.Length(s);
    out := TextWr.New();
    i := 0;
    c0, c1, c2, c3: CHAR;
    v0, v1, v2, v3: INTEGER;
  BEGIN
    WHILE i < n DO
      c0 := Text.GetChar(s, i);
      IF i + 1 >= n THEN RAISE Error; END;
      c1 := Text.GetChar(s, i + 1);
      c2 := 'A'; c3 := 'A';
      IF i + 2 < n THEN c2 := Text.GetChar(s, i + 2); END;
      IF i + 3 < n THEN c3 := Text.GetChar(s, i + 3); END;

      v0 := DecodeChar(c0);
      v1 := DecodeChar(c1);
      Wr.PutChar(out, VAL((v0 * 4) + (v1 DIV 16), CHAR));

      IF i + 2 < n AND c2 # '=' THEN
        v2 := DecodeChar(c2);
        Wr.PutChar(out, VAL(((v1 MOD 16) * 16) + (v2 DIV 4), CHAR));
        IF i + 3 < n AND c3 # '=' THEN
          v3 := DecodeChar(c3);
          Wr.PutChar(out, VAL(((v2 MOD 4) * 64) + v3, CHAR));
        END;
      END;
      INC(i, 4);
    END;
    RETURN TextWr.ToText(out);
  END Decode;

BEGIN
END ConvexBase64.
