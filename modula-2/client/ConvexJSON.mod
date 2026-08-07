IMPLEMENTATION MODULE ConvexJSON;

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


(* Assigned once in this module's body below. Earlier in this codebase a
   MODULE level CONST string literal crashed gm2's constant folder when
   indexed (see ConvexBase64.mod); re-assigning a literal to a PROCEDURE
   local array on every call turned out to have its own failure mode here
   (AppendQuoted segfaulted deep inside a fresh call), so this table is
   plain module storage set up exactly once instead of either. *)
VAR
  HexDigits: ARRAY [0..15] OF CHAR;

(* ---------- small character classifiers ---------- *)

PROCEDURE IsDigit (ch: CHAR) : BOOLEAN;
BEGIN
  RETURN (ch >= "0") AND (ch <= "9");
END IsDigit;

PROCEDURE IsSpace (ch: CHAR) : BOOLEAN;
BEGIN
  RETURN (ch = " ") OR (ch = CHR(9)) OR (ch = CHR(10)) OR (ch = CHR(13));
END IsSpace;

PROCEDURE HexValue (ch: CHAR) : INTEGER;
BEGIN
  IF (ch >= "0") AND (ch <= "9") THEN RETURN INTEGER(ORD(ch)) - INTEGER(ORD("0")) END;
  IF (ch >= "a") AND (ch <= "f") THEN RETURN INTEGER(ORD(ch)) - INTEGER(ORD("a")) + 10 END;
  IF (ch >= "A") AND (ch <= "F") THEN RETURN INTEGER(ORD(ch)) - INTEGER(ORD("A")) + 10 END;
  RETURN -1;
END HexValue;

PROCEDURE DocLen (VAR doc: ARRAY OF CHAR) : INTEGER;
BEGIN
  RETURN INTEGER(TextLength(doc));
END DocLen;

(* gm2's ISO Strings.Equal cannot be resolved by this compiler build (only
   Strings.Length links); a direct character comparison avoids depending on
   it. *)
PROCEDURE StrEqual (VAR a, b: ARRAY OF CHAR) : BOOLEAN;
VAR
  lengthA, lengthB, i: INTEGER;
BEGIN
  lengthA := INTEGER(TextLength(a));
  lengthB := INTEGER(TextLength(b));
  IF lengthA <> lengthB THEN RETURN FALSE END;
  FOR i := 0 TO lengthA - 1 DO
    IF a[i] <> b[i] THEN RETURN FALSE END;
  END;
  RETURN TRUE;
END StrEqual;

PROCEDURE AtChar (VAR doc: ARRAY OF CHAR; length, pos: INTEGER; ch: CHAR) : BOOLEAN;
BEGIN
  RETURN (pos < length) AND (doc[pos] = ch);
END AtChar;

PROCEDURE SkipSpace (VAR doc: ARRAY OF CHAR; length: INTEGER; VAR pos: INTEGER);
BEGIN
  WHILE (pos < length) AND IsSpace(doc[pos]) DO INC(pos) END;
END SkipSpace;

PROCEDURE ExtractSlice (VAR source: ARRAY OF CHAR; start, count: INTEGER; VAR dest: ARRAY OF CHAR) : BOOLEAN;
VAR
  i: INTEGER;
BEGIN
  IF count > INTEGER(HIGH(dest)) THEN RETURN FALSE END;
  FOR i := 0 TO count - 1 DO
    dest[i] := source[start + i];
  END;
  dest[count] := 0C;
  RETURN TRUE;
END ExtractSlice;

(* ---------- scanning (validate + advance, no decoding) ---------- *)

PROCEDURE ScanString (VAR doc: ARRAY OF CHAR; length: INTEGER; VAR pos: INTEGER) : BOOLEAN;
VAR
  ch: CHAR;
  i: INTEGER;
BEGIN
  IF NOT AtChar(doc, length, pos, '"') THEN RETURN FALSE END;
  INC(pos);
  LOOP
    IF pos >= length THEN RETURN FALSE END;
    ch := doc[pos];
    IF ch = '"' THEN
      INC(pos);
      RETURN TRUE;
    END;
    IF ch = '\' THEN
      INC(pos);
      IF pos >= length THEN RETURN FALSE END;
      ch := doc[pos];
      IF (ch = '"') OR (ch = '\') OR (ch = '/') OR (ch = 'b') OR (ch = 'f')
         OR (ch = 'n') OR (ch = 'r') OR (ch = 't') THEN
        INC(pos);
      ELSIF ch = 'u' THEN
        INC(pos);
        FOR i := 1 TO 4 DO
          IF pos >= length THEN RETURN FALSE END;
          IF HexValue(doc[pos]) < 0 THEN RETURN FALSE END;
          INC(pos);
        END;
      ELSE
        RETURN FALSE;
      END;
    ELSIF ORD(ch) < 32 THEN
      RETURN FALSE;
    ELSE
      INC(pos);
    END;
  END;
END ScanString;

PROCEDURE ScanNumber (VAR doc: ARRAY OF CHAR; length: INTEGER; VAR pos: INTEGER) : BOOLEAN;
BEGIN
  IF pos >= length THEN RETURN FALSE END;
  IF doc[pos] = '-' THEN INC(pos) END;
  IF pos >= length THEN RETURN FALSE END;
  IF NOT IsDigit(doc[pos]) THEN RETURN FALSE END;
  IF doc[pos] = '0' THEN
    INC(pos);
  ELSE
    WHILE (pos < length) AND IsDigit(doc[pos]) DO INC(pos) END;
  END;
  IF (pos < length) AND (doc[pos] = '.') THEN
    INC(pos);
    IF (pos >= length) OR NOT IsDigit(doc[pos]) THEN RETURN FALSE END;
    WHILE (pos < length) AND IsDigit(doc[pos]) DO INC(pos) END;
  END;
  IF (pos < length) AND ((doc[pos] = 'e') OR (doc[pos] = 'E')) THEN
    INC(pos);
    IF (pos < length) AND ((doc[pos] = '+') OR (doc[pos] = '-')) THEN INC(pos) END;
    IF (pos >= length) OR NOT IsDigit(doc[pos]) THEN RETURN FALSE END;
    WHILE (pos < length) AND IsDigit(doc[pos]) DO INC(pos) END;
  END;
  RETURN TRUE;
END ScanNumber;

PROCEDURE ScanValue (VAR doc: ARRAY OF CHAR; length: INTEGER; VAR pos: INTEGER) : BOOLEAN;
BEGIN
  SkipSpace(doc, length, pos);
  IF pos >= length THEN RETURN FALSE END;
  IF doc[pos] = '"' THEN RETURN ScanString(doc, length, pos) END;
  IF doc[pos] = '{' THEN
    INC(pos);
    SkipSpace(doc, length, pos);
    IF AtChar(doc, length, pos, '}') THEN
      INC(pos);
      RETURN TRUE;
    END;
    LOOP
      IF NOT AtChar(doc, length, pos, '"') THEN RETURN FALSE END;
      IF NOT ScanString(doc, length, pos) THEN RETURN FALSE END;
      SkipSpace(doc, length, pos);
      IF NOT AtChar(doc, length, pos, ':') THEN RETURN FALSE END;
      INC(pos);
      IF NOT ScanValue(doc, length, pos) THEN RETURN FALSE END;
      SkipSpace(doc, length, pos);
      IF pos >= length THEN RETURN FALSE END;
      IF AtChar(doc, length, pos, '}') THEN
        INC(pos);
        RETURN TRUE;
      END;
      IF NOT AtChar(doc, length, pos, ',') THEN RETURN FALSE END;
      INC(pos);
      SkipSpace(doc, length, pos);
    END;
  END;
  IF doc[pos] = '[' THEN
    INC(pos);
    SkipSpace(doc, length, pos);
    IF AtChar(doc, length, pos, ']') THEN
      INC(pos);
      RETURN TRUE;
    END;
    LOOP
      IF NOT ScanValue(doc, length, pos) THEN RETURN FALSE END;
      SkipSpace(doc, length, pos);
      IF pos >= length THEN RETURN FALSE END;
      IF AtChar(doc, length, pos, ']') THEN
        INC(pos);
        RETURN TRUE;
      END;
      IF NOT AtChar(doc, length, pos, ',') THEN RETURN FALSE END;
      INC(pos);
      SkipSpace(doc, length, pos);
    END;
  END;
  IF doc[pos] = 't' THEN
    IF (pos + 3 < length) AND (doc[pos+1] = 'r') AND (doc[pos+2] = 'u') AND (doc[pos+3] = 'e') THEN
      INC(pos, 4);
      RETURN TRUE;
    END;
    RETURN FALSE;
  END;
  IF doc[pos] = 'f' THEN
    IF (pos + 4 < length) AND (doc[pos+1] = 'a') AND (doc[pos+2] = 'l') AND (doc[pos+3] = 's') AND (doc[pos+4] = 'e') THEN
      INC(pos, 5);
      RETURN TRUE;
    END;
    RETURN FALSE;
  END;
  IF doc[pos] = 'n' THEN
    IF (pos + 3 < length) AND (doc[pos+1] = 'u') AND (doc[pos+2] = 'l') AND (doc[pos+3] = 'l') THEN
      INC(pos, 4);
      RETURN TRUE;
    END;
    RETURN FALSE;
  END;
  IF (doc[pos] = '-') OR IsDigit(doc[pos]) THEN RETURN ScanNumber(doc, length, pos) END;
  RETURN FALSE;
END ScanValue;

(* ---------- public API ---------- *)

PROCEDURE Member (VAR doc: ARRAY OF CHAR; key: ARRAY OF CHAR;
                   VAR value: ARRAY OF CHAR; VAR found: BOOLEAN) : BOOLEAN;
VAR
  length, pos, keyStart, valueStart, valueEnd: INTEGER;
  rawKey, decodedKey: ARRAY [0..511] OF CHAR;
BEGIN
  found := FALSE;
  value[0] := 0C;
  length := DocLen(doc);
  pos := 0;
  SkipSpace(doc, length, pos);
  IF NOT AtChar(doc, length, pos, '{') THEN RETURN FALSE END;
  INC(pos);
  SkipSpace(doc, length, pos);
  IF AtChar(doc, length, pos, '}') THEN
    INC(pos);
    SkipSpace(doc, length, pos);
    RETURN pos >= length;
  END;
  LOOP
    IF NOT AtChar(doc, length, pos, '"') THEN RETURN FALSE END;
    keyStart := pos;
    IF NOT ScanString(doc, length, pos) THEN RETURN FALSE END;
    IF NOT ExtractSlice(doc, keyStart, pos - keyStart, rawKey) THEN RETURN FALSE END;
    IF NOT DecodeString(rawKey, decodedKey) THEN RETURN FALSE END;
    SkipSpace(doc, length, pos);
    IF NOT AtChar(doc, length, pos, ':') THEN RETURN FALSE END;
    INC(pos);
    valueStart := pos;
    IF NOT ScanValue(doc, length, pos) THEN RETURN FALSE END;
    valueEnd := pos;
    IF StrEqual(decodedKey, key) THEN
      found := TRUE;
      IF NOT ExtractSlice(doc, valueStart, valueEnd - valueStart, value) THEN RETURN FALSE END;
    END;
    SkipSpace(doc, length, pos);
    IF pos >= length THEN RETURN FALSE END;
    IF AtChar(doc, length, pos, '}') THEN
      INC(pos);
      EXIT;
    END;
    IF NOT AtChar(doc, length, pos, ',') THEN RETURN FALSE END;
    INC(pos);
    SkipSpace(doc, length, pos);
  END;
  SkipSpace(doc, length, pos);
  RETURN pos >= length;
END Member;

PROCEDURE ArrayBegin (VAR array: ARRAY OF CHAR; VAR cursor: INTEGER) : BOOLEAN;
VAR
  length: INTEGER;
BEGIN
  length := DocLen(array);
  cursor := 0;
  SkipSpace(array, length, cursor);
  IF NOT AtChar(array, length, cursor, '[') THEN RETURN FALSE END;
  INC(cursor);
  RETURN TRUE;
END ArrayBegin;

PROCEDURE ArrayNext (VAR array: ARRAY OF CHAR; VAR cursor: INTEGER;
                      VAR element: ARRAY OF CHAR) : BOOLEAN;
VAR
  length, elementStart: INTEGER;
BEGIN
  element[0] := 0C;
  length := DocLen(array);
  SkipSpace(array, length, cursor);
  IF cursor >= length THEN RETURN FALSE END;
  IF array[cursor] = ']' THEN
    INC(cursor);
    RETURN FALSE;
  END;
  elementStart := cursor;
  IF NOT ScanValue(array, length, cursor) THEN
    cursor := -1;
    RETURN FALSE;
  END;
  IF NOT ExtractSlice(array, elementStart, cursor - elementStart, element) THEN
    cursor := -1;
    RETURN FALSE;
  END;
  SkipSpace(array, length, cursor);
  IF AtChar(array, length, cursor, ',') THEN
    INC(cursor);
  END;
  RETURN TRUE;
END ArrayNext;

PROCEDURE ArrayWellFormed (VAR array: ARRAY OF CHAR; cursor: INTEGER) : BOOLEAN;
VAR
  length: INTEGER;
BEGIN
  IF cursor < 0 THEN RETURN FALSE END;
  length := DocLen(array);
  SkipSpace(array, length, cursor);
  RETURN cursor >= length;
END ArrayWellFormed;

PROCEDURE StringArrayValid (VAR doc: ARRAY OF CHAR) : BOOLEAN;
VAR
  length, pos: INTEGER;
BEGIN
  length := DocLen(doc);
  pos := 0;
  SkipSpace(doc, length, pos);
  IF NOT AtChar(doc, length, pos, '[') THEN RETURN FALSE END;
  INC(pos);
  SkipSpace(doc, length, pos);
  IF AtChar(doc, length, pos, ']') THEN
    INC(pos);
    SkipSpace(doc, length, pos);
    RETURN pos >= length;
  END;
  LOOP
    IF NOT AtChar(doc, length, pos, '"') THEN RETURN FALSE END;
    IF NOT ScanString(doc, length, pos) THEN RETURN FALSE END;
    SkipSpace(doc, length, pos);
    IF pos >= length THEN RETURN FALSE END;
    IF AtChar(doc, length, pos, ']') THEN
      INC(pos);
      SkipSpace(doc, length, pos);
      RETURN pos >= length;
    END;
    IF NOT AtChar(doc, length, pos, ',') THEN RETURN FALSE END;
    INC(pos);
    SkipSpace(doc, length, pos);
  END;
END StringArrayValid;

PROCEDURE AppendUtf8 (code: INTEGER; VAR dest: ARRAY OF CHAR; VAR pos: INTEGER) : BOOLEAN;
BEGIN
  IF code <= 07FH THEN
    IF pos > INTEGER(HIGH(dest)) THEN RETURN FALSE END;
    dest[pos] := CHR(code);
    INC(pos);
  ELSIF code <= 07FFH THEN
    IF pos + 1 > INTEGER(HIGH(dest)) THEN RETURN FALSE END;
    dest[pos] := CHR(0C0H + (code DIV 40H));
    dest[pos+1] := CHR(080H + (code MOD 40H));
    INC(pos, 2);
  ELSIF code <= 0FFFFH THEN
    IF pos + 2 > INTEGER(HIGH(dest)) THEN RETURN FALSE END;
    dest[pos] := CHR(0E0H + (code DIV 1000H));
    dest[pos+1] := CHR(080H + ((code DIV 40H) MOD 40H));
    dest[pos+2] := CHR(080H + (code MOD 40H));
    INC(pos, 3);
  ELSE
    IF pos + 3 > INTEGER(HIGH(dest)) THEN RETURN FALSE END;
    dest[pos] := CHR(0F0H + (code DIV 40000H));
    dest[pos+1] := CHR(080H + ((code DIV 1000H) MOD 40H));
    dest[pos+2] := CHR(080H + ((code DIV 40H) MOD 40H));
    dest[pos+3] := CHR(080H + (code MOD 40H));
    INC(pos, 4);
  END;
  RETURN TRUE;
END AppendUtf8;

PROCEDURE DecodeString (VAR raw: ARRAY OF CHAR; VAR decoded: ARRAY OF CHAR) : BOOLEAN;
VAR
  length, pos, outPos, code, lowCode, i, digit: INTEGER;
  ch: CHAR;
BEGIN
  decoded[0] := 0C;
  length := DocLen(raw);
  IF length < 2 THEN RETURN FALSE END;
  IF (raw[0] <> '"') OR (raw[length-1] <> '"') THEN RETURN FALSE END;
  pos := 1;
  outPos := 0;
  WHILE pos < length - 1 DO
    ch := raw[pos];
    IF ch <> '\' THEN
      IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
      decoded[outPos] := ch;
      INC(outPos);
      INC(pos);
    ELSE
      INC(pos);
      IF pos >= length - 1 THEN RETURN FALSE END;
      ch := raw[pos];
      IF (ch = '"') OR (ch = '\') OR (ch = '/') THEN
        IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
        decoded[outPos] := ch;
        INC(outPos);
        INC(pos);
      ELSIF ch = 'b' THEN
        IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
        decoded[outPos] := CHR(8); INC(outPos); INC(pos);
      ELSIF ch = 'f' THEN
        IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
        decoded[outPos] := CHR(12); INC(outPos); INC(pos);
      ELSIF ch = 'n' THEN
        IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
        decoded[outPos] := CHR(10); INC(outPos); INC(pos);
      ELSIF ch = 'r' THEN
        IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
        decoded[outPos] := CHR(13); INC(outPos); INC(pos);
      ELSIF ch = 't' THEN
        IF outPos > INTEGER(HIGH(decoded)) THEN RETURN FALSE END;
        decoded[outPos] := CHR(9); INC(outPos); INC(pos);
      ELSIF ch = 'u' THEN
        INC(pos);
        IF pos + 4 > length - 1 THEN RETURN FALSE END;
        code := 0;
        FOR i := 0 TO 3 DO
          digit := HexValue(raw[pos + i]);
          IF digit < 0 THEN RETURN FALSE END;
          code := code * 16 + digit;
        END;
        INC(pos, 4);
        IF (code >= 0D800H) AND (code <= 0DBFFH) THEN
          IF (pos + 6 > length - 1) OR (raw[pos] <> '\') OR (raw[pos+1] <> 'u') THEN RETURN FALSE END;
          INC(pos, 2);
          lowCode := 0;
          FOR i := 0 TO 3 DO
            digit := HexValue(raw[pos + i]);
            IF digit < 0 THEN RETURN FALSE END;
            lowCode := lowCode * 16 + digit;
          END;
          INC(pos, 4);
          IF (lowCode < 0DC00H) OR (lowCode > 0DFFFH) THEN RETURN FALSE END;
          code := 010000H + ((code - 0D800H) * 400H) + (lowCode - 0DC00H);
        ELSIF (code >= 0DC00H) AND (code <= 0DFFFH) THEN
          RETURN FALSE;
        END;
        IF NOT AppendUtf8(code, decoded, outPos) THEN RETURN FALSE END;
      ELSE
        RETURN FALSE;
      END;
    END;
  END;
  decoded[outPos] := 0C;
  RETURN TRUE;
END DecodeString;

PROCEDURE AppendQuoted (VAR text: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR) : BOOLEAN;
VAR
  outPos, textLength, i: INTEGER;
  ch: CHAR;
  code: INTEGER;
BEGIN
  outPos := INTEGER(TextLength(destination));
  IF outPos > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
  destination[outPos] := '"';
  INC(outPos);
  textLength := DocLen(text);
  FOR i := 0 TO textLength - 1 DO
    ch := text[i];
    IF ch = '"' THEN
      IF outPos + 1 > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outPos] := '\'; destination[outPos+1] := '"'; INC(outPos, 2);
    ELSIF ch = '\' THEN
      IF outPos + 1 > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outPos] := '\'; destination[outPos+1] := '\'; INC(outPos, 2);
    ELSIF ch = CHR(10) THEN
      IF outPos + 1 > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outPos] := '\'; destination[outPos+1] := 'n'; INC(outPos, 2);
    ELSIF ch = CHR(13) THEN
      IF outPos + 1 > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outPos] := '\'; destination[outPos+1] := 'r'; INC(outPos, 2);
    ELSIF ch = CHR(9) THEN
      IF outPos + 1 > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outPos] := '\'; destination[outPos+1] := 't'; INC(outPos, 2);
    ELSIF ORD(ch) < 32 THEN
      IF outPos + 5 > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      code := INTEGER(ORD(ch));
      destination[outPos] := '\'; destination[outPos+1] := 'u';
      destination[outPos+2] := '0'; destination[outPos+3] := '0';
      destination[outPos+4] := HexDigits[code DIV 16];
      destination[outPos+5] := HexDigits[code MOD 16];
      INC(outPos, 6);
    ELSE
      IF outPos > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
      destination[outPos] := ch;
      INC(outPos);
    END;
  END;
  IF outPos > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
  destination[outPos] := '"';
  INC(outPos);
  IF outPos > INTEGER(HIGH(destination)) THEN RETURN FALSE END;
  destination[outPos] := 0C;
  RETURN TRUE;
END AppendQuoted;

PROCEDURE ParseNonNegativeInt (VAR raw: ARRAY OF CHAR; VAR value: INTEGER) : BOOLEAN;
VAR
  length, i: INTEGER;
BEGIN
  value := 0;
  length := DocLen(raw);
  IF length = 0 THEN RETURN FALSE END;
  FOR i := 0 TO length - 1 DO
    IF NOT IsDigit(raw[i]) THEN RETURN FALSE END;
    value := value * 10 + INTEGER(ORD(raw[i]) - ORD('0'));
  END;
  RETURN TRUE;
END ParseNonNegativeInt;

PROCEDURE IsIntegralNumber (VAR raw: ARRAY OF CHAR) : BOOLEAN;
VAR
  length, pos: INTEGER;
BEGIN
  length := DocLen(raw);
  pos := 0;
  IF NOT ScanNumber(raw, length, pos) THEN RETURN FALSE END;
  IF pos <> length THEN RETURN FALSE END;
  (* Reject only when a fractional part has a nonzero digit and there is no
     exponent large enough to clear it; a simple, sufficient rule for the
     small counters this client decodes is: no '.' at all, or every digit
     after '.' is '0' up to (but not including) an 'e'/'E'. *)
  pos := 0;
  WHILE (pos < length) AND (raw[pos] <> '.') DO INC(pos) END;
  IF pos >= length THEN RETURN TRUE END;
  INC(pos);
  WHILE (pos < length) AND (raw[pos] <> 'e') AND (raw[pos] <> 'E') DO
    IF raw[pos] <> '0' THEN RETURN FALSE END;
    INC(pos);
  END;
  RETURN TRUE;
END IsIntegralNumber;

BEGIN
  HexDigits := "0123456789abcdef";
END ConvexJSON.
