UNSAFE MODULE ConvexRandom;

IMPORT Text, TlsShim;

PROCEDURE Bytes(n: INTEGER): TEXT RAISES {Error} =
  VAR buf := NEW(REF ARRAY OF CHAR, n);
  BEGIN
    IF n = 0 THEN RETURN ""; END;
    IF TlsShim.RandomBytes(ADR(buf[0]), n) = 0 THEN RAISE Error; END;
    RETURN Text.FromChars(buf^);
  END Bytes;

PROCEDURE HexBytes(n: INTEGER): TEXT RAISES {Error} =
  CONST hexd = "0123456789abcdef";
  VAR raw := Bytes(n); out := "";
  BEGIN
    FOR i := 0 TO Text.Length(raw) - 1 DO
      VAR b := ORD(Text.GetChar(raw, i));
      BEGIN
        out := out & Text.FromChar(Text.GetChar(hexd, b DIV 16))
                    & Text.FromChar(Text.GetChar(hexd, b MOD 16));
      END;
    END;
    RETURN out;
  END HexBytes;

BEGIN
END ConvexRandom.
