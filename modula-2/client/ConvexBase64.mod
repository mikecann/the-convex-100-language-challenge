IMPLEMENTATION MODULE ConvexBase64;

(* gm2's ISO Strings.Length crashes when called on an array whose declared
   capacity is roughly 2 MiB or more (confirmed empirically: it is fine on
   a 1 MiB array and segfaults on a 2 MiB one, with no application code on
   the stack between the call and the crash). Several buffers in this
   client are exactly that large, so every module scans for the NUL
   terminator itself instead of trusting Strings.Length. *)
PROCEDURE TextLength (VAR s: ARRAY OF CHAR) : INTEGER;
VAR i, cap: INTEGER;
BEGIN
  cap := INTEGER(HIGH(s));
  i := 0;
  WHILE (i <= cap) AND (s[i] <> 0C) DO INC(i) END;
  RETURN i;
END TextLength;


(* gm2's constant folder cannot index directly into a CONST string literal
   (it aborts with "constant type should have been resolved"), so the
   alphabet is a plain array assigned once in the module body below and
   indexed as an ordinary variable instead. *)
VAR
  Alphabet: ARRAY [0..63] OF CHAR;

PROCEDURE Encode (data: ARRAY OF CHAR; dataLength: INTEGER; VAR destination: ARRAY OF CHAR);
VAR
  index, outIndex: INTEGER;
  b0, b1, b2: CARDINAL;
  triple: CARDINAL;
BEGIN
  outIndex := 0;
  index := 0;
  WHILE index + 3 <= dataLength DO
    b0 := CARDINAL(ORD(data[index]));
    b1 := CARDINAL(ORD(data[index + 1]));
    b2 := CARDINAL(ORD(data[index + 2]));
    triple := (b0 * 65536) + (b1 * 256) + b2;
    destination[outIndex] := Alphabet[(triple DIV 262144) MOD 64];
    destination[outIndex + 1] := Alphabet[(triple DIV 4096) MOD 64];
    destination[outIndex + 2] := Alphabet[(triple DIV 64) MOD 64];
    destination[outIndex + 3] := Alphabet[triple MOD 64];
    INC(outIndex, 4);
    INC(index, 3);
  END;
  IF dataLength - index = 1 THEN
    b0 := CARDINAL(ORD(data[index]));
    triple := b0 * 65536;
    destination[outIndex] := Alphabet[(triple DIV 262144) MOD 64];
    destination[outIndex + 1] := Alphabet[(triple DIV 4096) MOD 64];
    destination[outIndex + 2] := "=";
    destination[outIndex + 3] := "=";
    INC(outIndex, 4);
  ELSIF dataLength - index = 2 THEN
    b0 := CARDINAL(ORD(data[index]));
    b1 := CARDINAL(ORD(data[index + 1]));
    triple := (b0 * 65536) + (b1 * 256);
    destination[outIndex] := Alphabet[(triple DIV 262144) MOD 64];
    destination[outIndex + 1] := Alphabet[(triple DIV 4096) MOD 64];
    destination[outIndex + 2] := Alphabet[(triple DIV 64) MOD 64];
    destination[outIndex + 3] := "=";
    INC(outIndex, 4);
  END;
  destination[outIndex] := 0C;
END Encode;

PROCEDURE DecodeValue (ch: CHAR) : INTEGER;
BEGIN
  IF (ch >= "A") AND (ch <= "Z") THEN RETURN ORD(ch) - ORD("A") END;
  IF (ch >= "a") AND (ch <= "z") THEN RETURN ORD(ch) - ORD("a") + 26 END;
  IF (ch >= "0") AND (ch <= "9") THEN RETURN ORD(ch) - ORD("0") + 52 END;
  IF ch = "+" THEN RETURN 62 END;
  IF ch = "/" THEN RETURN 63 END;
  RETURN -1;
END DecodeValue;

PROCEDURE Decode (text: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR; VAR outLength: INTEGER) : BOOLEAN;
VAR
  textLength, index, outIndex, padCount: INTEGER;
  v0, v1, v2, v3: INTEGER;
  triple: CARDINAL;
BEGIN
  outLength := 0;
  textLength := INTEGER(TextLength(text));
  IF textLength = 0 THEN RETURN FALSE END;
  IF textLength MOD 4 <> 0 THEN RETURN FALSE END;
  outIndex := 0;
  index := 0;
  WHILE index < textLength DO
    v0 := DecodeValue(text[index]);
    v1 := DecodeValue(text[index + 1]);
    padCount := 0;
    IF text[index + 2] = "=" THEN
      v2 := 0;
      INC(padCount);
    ELSE
      v2 := DecodeValue(text[index + 2]);
    END;
    IF text[index + 3] = "=" THEN
      v3 := 0;
      INC(padCount);
    ELSE
      v3 := DecodeValue(text[index + 3]);
    END;
    IF (v0 < 0) OR (v1 < 0) OR (v2 < 0) OR (v3 < 0) THEN RETURN FALSE END;
    (* only the final quartet of a well formed base64 string may carry padding *)
    IF (padCount > 0) AND (index + 4 <> textLength) THEN RETURN FALSE END;
    triple := (CARDINAL(v0) * 262144) + (CARDINAL(v1) * 4096) + (CARDINAL(v2) * 64) + CARDINAL(v3);
    IF outIndex > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
    destination[outIndex] := CHR((triple DIV 65536) MOD 256);
    INC(outIndex);
    IF padCount < 2 THEN
      IF outIndex > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outIndex] := CHR((triple DIV 256) MOD 256);
      INC(outIndex);
    END;
    IF padCount < 1 THEN
      IF outIndex > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outIndex] := CHR(triple MOD 256);
      INC(outIndex);
    END;
    INC(index, 4);
  END;
  outLength := outIndex;
  RETURN TRUE;
END Decode;

BEGIN
  Alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
END ConvexBase64.
