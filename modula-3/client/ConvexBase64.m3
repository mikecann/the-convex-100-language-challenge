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

BEGIN
END ConvexBase64.
