(* ConvexJson - implementation. See ConvexJson.i3 for the public shape.

   TEXT in this build of CM3 is a sequence of 8-bit CHAR, so this module
   treats JSON text as a byte stream throughout: only the JSON-structural
   bytes (quote, backslash, the ASCII control range, and the escape
   letters) are ever inspected or escaped. Any UTF-8 encoded content
   simply passes through untouched, both on encode and on decode, which
   is exactly what the JSON grammar allows. *)
UNSAFE MODULE ConvexJson;

IMPORT Text, TextWr, Wr, Fmt;

TYPE
  ArrayT = ARRAY OF T;
  ArrayText = ARRAY OF TEXT;

REVEAL
  T = Public BRANDED "ConvexJson.T" OBJECT
        isInt: BOOLEAN := FALSE;
        num: LONGREAL := 0.0d0;
        str: TEXT := NIL;
        items: REF ArrayT := NIL;
        keys: REF ArrayText := NIL;
        vals: REF ArrayT := NIL;
        len: CARDINAL := 0;
        cap: CARDINAL := 0;
      END;

(* singletons for the two constant kinds *)
VAR
  nullValue: T;
  falseValue: T;
  trueValue: T;

PROCEDURE NewNull(): T = BEGIN RETURN nullValue; END NewNull;

PROCEDURE NewBool(b: BOOLEAN): T =
  BEGIN
    IF b THEN RETURN trueValue; ELSE RETURN falseValue; END;
  END NewBool;

PROCEDURE NewInt(n: INTEGER): T =
  VAR v := NEW(T, kind := Kind.Number);
  BEGIN
    v.num := FLOAT(n, LONGREAL);
    v.isInt := TRUE;
    RETURN v;
  END NewInt;

PROCEDURE NewFloat(n: LONGREAL): T =
  VAR v := NEW(T, kind := Kind.Number);
  BEGIN
    v.num := n;
    v.isInt := FALSE;
    RETURN v;
  END NewFloat;

PROCEDURE NewString(s: TEXT): T =
  VAR v := NEW(T, kind := Kind.Str);
  BEGIN
    v.str := s;
    RETURN v;
  END NewString;

PROCEDURE NewArray(): T =
  VAR v := NEW(T, kind := Kind.Arr);
  BEGIN
    v.len := 0;
    v.cap := 0;
    v.items := NIL;
    RETURN v;
  END NewArray;

PROCEDURE NewObject(): T =
  VAR v := NEW(T, kind := Kind.Obj);
  BEGIN
    v.len := 0;
    v.cap := 0;
    v.keys := NIL;
    v.vals := NIL;
    RETURN v;
  END NewObject;

(* -- growth helpers ---------------------------------------------------- *)

PROCEDURE GrowArr(v: T) =
  VAR newCap: CARDINAL; newItems: REF ArrayT;
  BEGIN
    IF v.len < v.cap THEN RETURN; END;
    IF v.cap = 0 THEN newCap := 4; ELSE newCap := v.cap * 2; END;
    newItems := NEW(REF ArrayT, newCap);
    FOR i := 0 TO v.len - 1 DO newItems[i] := v.items[i]; END;
    v.items := newItems;
    v.cap := newCap;
  END GrowArr;

PROCEDURE GrowObj(v: T) =
  VAR newCap: CARDINAL; newKeys: REF ArrayText; newVals: REF ArrayT;
  BEGIN
    IF v.len < v.cap THEN RETURN; END;
    IF v.cap = 0 THEN newCap := 4; ELSE newCap := v.cap * 2; END;
    newKeys := NEW(REF ArrayText, newCap);
    newVals := NEW(REF ArrayT, newCap);
    FOR i := 0 TO v.len - 1 DO
      newKeys[i] := v.keys[i];
      newVals[i] := v.vals[i];
    END;
    v.keys := newKeys;
    v.vals := newVals;
    v.cap := newCap;
  END GrowObj;

PROCEDURE ArrayAppend(a: T; v: T) =
  BEGIN
    GrowArr(a);
    a.items[a.len] := v;
    INC(a.len);
  END ArrayAppend;

PROCEDURE ArrayLen(a: T): CARDINAL = BEGIN RETURN a.len; END ArrayLen;

PROCEDURE ArrayGet(a: T; i: CARDINAL): T = BEGIN RETURN a.items[i]; END ArrayGet;

PROCEDURE ObjectSet(o: T; key: TEXT; v: T) =
  BEGIN
    FOR i := 0 TO o.len - 1 DO
      IF Text.Equal(o.keys[i], key) THEN
        o.vals[i] := v;
        RETURN;
      END;
    END;
    GrowObj(o);
    o.keys[o.len] := key;
    o.vals[o.len] := v;
    INC(o.len);
  END ObjectSet;

PROCEDURE ObjectGet(o: T; key: TEXT): T =
  BEGIN
    FOR i := 0 TO o.len - 1 DO
      IF Text.Equal(o.keys[i], key) THEN RETURN o.vals[i]; END;
    END;
    RETURN NIL;
  END ObjectGet;

PROCEDURE ObjectHas(o: T; key: TEXT): BOOLEAN =
  BEGIN RETURN ObjectGet(o, key) # NIL; END ObjectHas;

PROCEDURE ObjectLen(o: T): CARDINAL = BEGIN RETURN o.len; END ObjectLen;

PROCEDURE ObjectKeyAt(o: T; i: CARDINAL): TEXT = BEGIN RETURN o.keys[i]; END ObjectKeyAt;

PROCEDURE IsNull(v: T): BOOLEAN = BEGIN RETURN v.kind = Kind.Null; END IsNull;

PROCEDURE BoolOf(v: T): BOOLEAN RAISES {Error} =
  BEGIN
    IF v.kind = Kind.True THEN RETURN TRUE; END;
    IF v.kind = Kind.False THEN RETURN FALSE; END;
    RAISE Error("expected a JSON boolean");
  END BoolOf;

PROCEDURE NumOf(v: T): LONGREAL RAISES {Error} =
  BEGIN
    IF v.kind # Kind.Number THEN RAISE Error("expected a JSON number"); END;
    RETURN v.num;
  END NumOf;

PROCEDURE StrOf(v: T): TEXT RAISES {Error} =
  BEGIN
    IF v.kind # Kind.Str THEN RAISE Error("expected a JSON string"); END;
    RETURN v.str;
  END StrOf;

(* -- encoding ------------------------------------------------------------ *)

PROCEDURE EncodeStringInto(wr: Wr.T; s: TEXT) =
  VAR n := Text.Length(s); c: CHAR;
  BEGIN
    Wr.PutChar(wr, '"');
    FOR i := 0 TO n - 1 DO
      c := Text.GetChar(s, i);
      CASE c OF
      | '"' => Wr.PutText(wr, "\\\"");
      | '\\' => Wr.PutText(wr, "\\\\");
      ELSE
        IF ORD(c) = 10 THEN Wr.PutText(wr, "\\n");
        ELSIF ORD(c) = 13 THEN Wr.PutText(wr, "\\r");
        ELSIF ORD(c) = 9 THEN Wr.PutText(wr, "\\t");
        ELSIF ORD(c) < 32 THEN
          Wr.PutText(wr, "\\u00");
          Wr.PutText(wr, HexDigit(ORD(c) DIV 16));
          Wr.PutText(wr, HexDigit(ORD(c) MOD 16));
        ELSE
          Wr.PutChar(wr, c);
        END;
      END;
    END;
    Wr.PutChar(wr, '"');
  END EncodeStringInto;

PROCEDURE HexDigit(d: [0 .. 15]): TEXT =
  CONST digits = ARRAY [0 .. 15] OF CHAR{
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};
  BEGIN RETURN Text.FromChar(digits[d]); END HexDigit;

PROCEDURE EncodeNumberInto(wr: Wr.T; v: T) =
  VAR asInt: INTEGER;
  BEGIN
    IF v.isInt AND ABS(v.num) < 4611686018427387904.0d0 (* 2^62 *) THEN
      asInt := ROUND(v.num);
      Wr.PutText(wr, Fmt.Int(asInt));
    ELSE
      Wr.PutText(wr, Fmt.LongReal(v.num, Fmt.Style.Auto));
    END;
  END EncodeNumberInto;

PROCEDURE EncodeInto(wr: Wr.T; v: T) =
  BEGIN
    CASE v.kind OF
    | Kind.Null => Wr.PutText(wr, "null");
    | Kind.False => Wr.PutText(wr, "false");
    | Kind.True => Wr.PutText(wr, "true");
    | Kind.Number => EncodeNumberInto(wr, v);
    | Kind.Str => EncodeStringInto(wr, v.str);
    | Kind.Arr =>
        Wr.PutChar(wr, '[');
        FOR i := 0 TO v.len - 1 DO
          IF i > 0 THEN Wr.PutChar(wr, ','); END;
          EncodeInto(wr, v.items[i]);
        END;
        Wr.PutChar(wr, ']');
    | Kind.Obj =>
        Wr.PutChar(wr, '{');
        FOR i := 0 TO v.len - 1 DO
          IF i > 0 THEN Wr.PutChar(wr, ','); END;
          EncodeStringInto(wr, v.keys[i]);
          Wr.PutChar(wr, ':');
          EncodeInto(wr, v.vals[i]);
        END;
        Wr.PutChar(wr, '}');
    END;
  END EncodeInto;

PROCEDURE Encode(v: T): TEXT =
  VAR wr := TextWr.New();
  BEGIN
    EncodeInto(wr, v);
    RETURN TextWr.ToText(wr);
  END Encode;

(* -- decoding -------------------------------------------------------- *)

TYPE
  Cursor = RECORD
    buf: REF ARRAY OF CHAR;
    len: CARDINAL;
    pos: CARDINAL;
  END;

PROCEDURE Peek(VAR cur: Cursor): CHAR =
  BEGIN
    IF cur.pos >= cur.len THEN RETURN '\000'; END;
    RETURN cur.buf[cur.pos];
  END Peek;

PROCEDURE Advance(VAR cur: Cursor) = BEGIN INC(cur.pos); END Advance;

PROCEDURE SkipWs(VAR cur: Cursor) =
  BEGIN
    WHILE cur.pos < cur.len
      AND (cur.buf[cur.pos] = ' ' OR cur.buf[cur.pos] = '\t'
           OR cur.buf[cur.pos] = '\n' OR cur.buf[cur.pos] = '\r') DO
      INC(cur.pos);
    END;
  END SkipWs;

PROCEDURE Expect(VAR cur: Cursor; c: CHAR) RAISES {Error} =
  BEGIN
    IF Peek(cur) # c THEN RAISE Error("unexpected character in JSON"); END;
    Advance(cur);
  END Expect;

PROCEDURE ExpectLiteral(VAR cur: Cursor; lit: TEXT) RAISES {Error} =
  BEGIN
    FOR i := 0 TO Text.Length(lit) - 1 DO
      Expect(cur, Text.GetChar(lit, i));
    END;
  END ExpectLiteral;

PROCEDURE HexVal(c: CHAR): INTEGER RAISES {Error} =
  BEGIN
    IF c >= '0' AND c <= '9' THEN RETURN ORD(c) - ORD('0'); END;
    IF c >= 'a' AND c <= 'f' THEN RETURN ORD(c) - ORD('a') + 10; END;
    IF c >= 'A' AND c <= 'F' THEN RETURN ORD(c) - ORD('A') + 10; END;
    RAISE Error("invalid \\u escape");
  END HexVal;

(* Encode a Unicode code point as UTF-8 bytes appended to "acc". *)
PROCEDURE AppendUtf8(acc: TextWr.T; cp: INTEGER) =
  BEGIN
    IF cp < 16_80 THEN
      Wr.PutChar(acc, VAL(cp, CHAR));
    ELSIF cp < 16_800 THEN
      Wr.PutChar(acc, VAL(16_C0 + cp DIV 16_40, CHAR));
      Wr.PutChar(acc, VAL(16_80 + cp MOD 16_40, CHAR));
    ELSIF cp < 16_10000 THEN
      Wr.PutChar(acc, VAL(16_E0 + cp DIV 16_1000, CHAR));
      Wr.PutChar(acc, VAL(16_80 + (cp DIV 16_40) MOD 16_40, CHAR));
      Wr.PutChar(acc, VAL(16_80 + cp MOD 16_40, CHAR));
    ELSE
      Wr.PutChar(acc, VAL(16_F0 + cp DIV 16_40000, CHAR));
      Wr.PutChar(acc, VAL(16_80 + (cp DIV 16_1000) MOD 16_40, CHAR));
      Wr.PutChar(acc, VAL(16_80 + (cp DIV 16_40) MOD 16_40, CHAR));
      Wr.PutChar(acc, VAL(16_80 + cp MOD 16_40, CHAR));
    END;
  END AppendUtf8;

PROCEDURE ParseString(VAR cur: Cursor): TEXT RAISES {Error} =
  VAR acc := TextWr.New(); c: CHAR; cp, hi, lo: INTEGER;
  BEGIN
    Expect(cur, '"');
    LOOP
      IF cur.pos >= cur.len THEN RAISE Error("unterminated JSON string"); END;
      c := cur.buf[cur.pos];
      IF c = '"' THEN Advance(cur); EXIT; END;
      IF c = '\\' THEN
        Advance(cur);
        c := Peek(cur);
        CASE c OF
        | '"' => Wr.PutChar(acc, '"'); Advance(cur);
        | '\\' => Wr.PutChar(acc, '\\'); Advance(cur);
        | '/' => Wr.PutChar(acc, '/'); Advance(cur);
        | 'n' => Wr.PutChar(acc, VAL(10, CHAR)); Advance(cur);
        | 't' => Wr.PutChar(acc, VAL(9, CHAR)); Advance(cur);
        | 'r' => Wr.PutChar(acc, VAL(13, CHAR)); Advance(cur);
        | 'b' => Wr.PutChar(acc, VAL(8, CHAR)); Advance(cur);
        | 'f' => Wr.PutChar(acc, VAL(12, CHAR)); Advance(cur);
        | 'u' =>
            Advance(cur);
            cp := 0;
            FOR i := 1 TO 4 DO
              cp := cp * 16 + HexVal(Peek(cur));
              Advance(cur);
            END;
            (* a surrogate pair spells one code point above the BMP *)
            IF cp >= 16_D800 AND cp <= 16_DBFF
               AND cur.pos + 1 < cur.len
               AND cur.buf[cur.pos] = '\\' AND cur.buf[cur.pos + 1] = 'u' THEN
              hi := cp;
              Advance(cur); Advance(cur);
              lo := 0;
              FOR i := 1 TO 4 DO
                lo := lo * 16 + HexVal(Peek(cur));
                Advance(cur);
              END;
              cp := 16_10000 + (hi - 16_D800) * 16_400 + (lo - 16_DC00);
            END;
            AppendUtf8(acc, cp);
        ELSE
          RAISE Error("invalid escape in JSON string");
        END;
      ELSE
        Wr.PutChar(acc, c);
        Advance(cur);
      END;
    END;
    RETURN TextWr.ToText(acc);
  END ParseString;

PROCEDURE ParseNumber(VAR cur: Cursor): T RAISES {Error} =
  VAR start := cur.pos; sawDot := FALSE; sawExp := FALSE; c: CHAR;
  BEGIN
    IF Peek(cur) = '-' THEN Advance(cur); END;
    IF Peek(cur) = '\000' OR Peek(cur) < '0' OR Peek(cur) > '9' THEN
      RAISE Error("invalid JSON number");
    END;
    WHILE cur.pos < cur.len DO
      c := cur.buf[cur.pos];
      IF c >= '0' AND c <= '9' THEN
        Advance(cur);
      ELSIF c = '.' AND NOT sawDot AND NOT sawExp THEN
        sawDot := TRUE;
        Advance(cur);
      ELSIF (c = 'e' OR c = 'E') AND NOT sawExp THEN
        sawExp := TRUE;
        Advance(cur);
        IF Peek(cur) = '+' OR Peek(cur) = '-' THEN Advance(cur); END;
      ELSE
        EXIT;
      END;
    END;
    VAR
      n := cur.pos - start;
      lit := Text.FromChars(SUBARRAY(cur.buf^, start, n));
      v := NEW(T, kind := Kind.Number);
    BEGIN
      v.num := ParseLongReal(lit);
      v.isInt := NOT (sawDot OR sawExp);
      RETURN v;
    END;
  END ParseNumber;

(* A tiny decimal-to-LONGREAL parser: Scan/LongReal-style routines pull
   in more of libm3 than this narrow need justifies, and this format is
   already fully constrained by ParseNumber's own scan above. *)
PROCEDURE ParseLongReal(lit: TEXT): LONGREAL =
  VAR
    n := Text.Length(lit);
    i := 0;
    neg := FALSE;
    intPart: LONGREAL := 0.0d0;
    fracPart: LONGREAL := 0.0d0;
    fracScale: LONGREAL := 1.0d0;
    expPart: INTEGER := 0;
    expNeg := FALSE;
    c: CHAR;
  BEGIN
    IF i < n AND Text.GetChar(lit, i) = '-' THEN neg := TRUE; INC(i); END;
    WHILE i < n DO
      c := Text.GetChar(lit, i);
      IF c < '0' OR c > '9' THEN EXIT; END;
      intPart := intPart * 10.0d0 + FLOAT(ORD(c) - ORD('0'), LONGREAL);
      INC(i);
    END;
    IF i < n AND Text.GetChar(lit, i) = '.' THEN
      INC(i);
      WHILE i < n DO
        c := Text.GetChar(lit, i);
        IF c < '0' OR c > '9' THEN EXIT; END;
        fracScale := fracScale * 10.0d0;
        fracPart := fracPart + FLOAT(ORD(c) - ORD('0'), LONGREAL) / fracScale;
        INC(i);
      END;
    END;
    IF i < n AND (Text.GetChar(lit, i) = 'e' OR Text.GetChar(lit, i) = 'E') THEN
      INC(i);
      IF i < n AND Text.GetChar(lit, i) = '-' THEN expNeg := TRUE; INC(i);
      ELSIF i < n AND Text.GetChar(lit, i) = '+' THEN INC(i);
      END;
      WHILE i < n DO
        c := Text.GetChar(lit, i);
        IF c < '0' OR c > '9' THEN EXIT; END;
        expPart := expPart * 10 + (ORD(c) - ORD('0'));
        INC(i);
      END;
    END;
    VAR result := intPart + fracPart;
    BEGIN
      IF expPart # 0 THEN
        VAR scale: LONGREAL := 1.0d0;
        BEGIN
          FOR k := 1 TO expPart DO scale := scale * 10.0d0; END;
          IF expNeg THEN result := result / scale; ELSE result := result * scale; END;
        END;
      END;
      IF neg THEN result := -result; END;
      RETURN result;
    END;
  END ParseLongReal;

PROCEDURE ParseValue(VAR cur: Cursor): T RAISES {Error} =
  VAR c: CHAR;
  BEGIN
    SkipWs(cur);
    c := Peek(cur);
    IF c = '"' THEN RETURN NewString(ParseString(cur));
    ELSIF c = '{' THEN RETURN ParseObject(cur);
    ELSIF c = '[' THEN RETURN ParseArray(cur);
    ELSIF c = 't' THEN ExpectLiteral(cur, "true"); RETURN trueValue;
    ELSIF c = 'f' THEN ExpectLiteral(cur, "false"); RETURN falseValue;
    ELSIF c = 'n' THEN ExpectLiteral(cur, "null"); RETURN nullValue;
    ELSIF c = '-' OR (c >= '0' AND c <= '9') THEN RETURN ParseNumber(cur);
    ELSE RAISE Error("unexpected character starting a JSON value");
    END;
  END ParseValue;

PROCEDURE ParseObject(VAR cur: Cursor): T RAISES {Error} =
  VAR o := NewObject(); key: TEXT; v: T;
  BEGIN
    Expect(cur, '{');
    SkipWs(cur);
    IF Peek(cur) = '}' THEN Advance(cur); RETURN o; END;
    LOOP
      SkipWs(cur);
      key := ParseString(cur);
      SkipWs(cur);
      Expect(cur, ':');
      v := ParseValue(cur);
      ObjectSet(o, key, v);
      SkipWs(cur);
      IF Peek(cur) = ',' THEN Advance(cur);
      ELSE Expect(cur, '}'); EXIT;
      END;
    END;
    RETURN o;
  END ParseObject;

PROCEDURE ParseArray(VAR cur: Cursor): T RAISES {Error} =
  VAR a := NewArray(); v: T;
  BEGIN
    Expect(cur, '[');
    SkipWs(cur);
    IF Peek(cur) = ']' THEN Advance(cur); RETURN a; END;
    LOOP
      v := ParseValue(cur);
      ArrayAppend(a, v);
      SkipWs(cur);
      IF Peek(cur) = ',' THEN Advance(cur); SkipWs(cur);
      ELSE Expect(cur, ']'); EXIT;
      END;
    END;
    RETURN a;
  END ParseArray;

PROCEDURE Decode(s: TEXT): T RAISES {Error} =
  VAR
    n := Text.Length(s);
    buf := NEW(REF ARRAY OF CHAR, n);
    cur: Cursor;
    v: T;
  BEGIN
    Text.SetChars(buf^, s);
    cur.buf := buf;
    cur.len := n;
    cur.pos := 0;
    v := ParseValue(cur);
    SkipWs(cur);
    IF cur.pos # cur.len THEN RAISE Error("trailing bytes after JSON value"); END;
    RETURN v;
  END Decode;

BEGIN
  nullValue := NEW(T, kind := Kind.Null);
  falseValue := NEW(T, kind := Kind.False);
  trueValue := NEW(T, kind := Kind.True);
END ConvexJson.
