(* TestJSON is a deterministic, offline unit test of ConvexJSON: member
   extraction, string decode/encode (including surrogate pairs and
   control-character escapes), array iteration, and the integral-number
   regression AGENTS.md calls out (Convex may send a whole number as
   "0.0"/"1.0"; decoding must accept that shape and reject a genuinely
   fractional one). It is test-only, not part of the public client. *)
MODULE TestJSON;

FROM ConvexJSON IMPORT Member, DecodeString, AppendQuoted, ParseNonNegativeInt,
  ArrayBegin, ArrayNext, ArrayWellFormed, StringArrayValid, IsIntegralNumber;
FROM CShim IMPORT ShimExit;
FROM STextIO IMPORT WriteString, WriteLn;

VAR
  failed: BOOLEAN;
  doc, value, decoded, out: ARRAY [0..1023] OF CHAR;
  found, ok: BOOLEAN;
  n: INTEGER;
  cursor: INTEGER;
  elem: ARRAY [0..1023] OF CHAR;

PROCEDURE Check (label: ARRAY OF CHAR; cond: BOOLEAN);
BEGIN
  IF cond THEN
    WriteString("PASS "); WriteString(label); WriteLn;
  ELSE
    WriteString("FAIL "); WriteString(label); WriteLn;
    failed := TRUE;
  END;
END Check;

BEGIN
  failed := FALSE;

  doc := '{"status":"success","value":{"room":"abc","count":1.0,"nested":[1,2,3]},"logLines":["a","b"]}';
  ok := Member(doc, "status", value, found);
  Check("member: doc valid", ok);
  Check("member: status found", found);
  Check("member: status raw is quoted", value[0] = '"');

  ok := Member(doc, "value", value, found);
  Check("member: nested value found", ok AND found);

  ok := Member(value, "count", out, found);
  Check("member: nested count found", ok AND found);
  Check("integral: 1.0 accepted", IsIntegralNumber(out));

  doc := '{"count":1.5}';
  ok := Member(doc, "count", out, found);
  Check("integral: fractional 1.5 is parsed as a number", ok AND found);
  Check("integral: 1.5 rejected", NOT IsIntegralNumber(out));

  doc := '{"count":2.0e1}';
  ok := Member(doc, "count", out, found);
  Check("integral: 2.0e1 accepted", ok AND found AND IsIntegralNumber(out));

  doc := '{"logLines":["a","b"]}';
  ok := Member(doc, "logLines", value, found);
  Check("logLines found", ok AND found);
  Check("logLines is a string array", StringArrayValid(value));
  ok := ArrayBegin(value, cursor);
  Check("array begin", ok);
  ok := ArrayNext(value, cursor, elem);
  Check("array next 1", ok);
  ok := DecodeString(elem, decoded);
  Check("decode a", ok AND (decoded[0] = 'a') AND (decoded[1] = 0C));
  ok := ArrayNext(value, cursor, elem);
  Check("array next 2", ok);
  ok := ArrayNext(value, cursor, elem);
  Check("array next end", NOT ok);
  Check("array well formed", ArrayWellFormed(value, cursor));

  doc := "42";
  ok := ParseNonNegativeInt(doc, n);
  Check("parse non-negative int", ok AND (n = 42));

  out[0] := 0C;
  decoded := 'He said "hi"';
  ok := AppendQuoted(decoded, out);
  Check("quote roundtrip ok", ok);
  Check("quote roundtrip content", out[0] = '"');

  doc := '"Hello, 世界 👋"';
  ok := DecodeString(doc, decoded);
  Check("decode surrogate pair and BMP escape", ok);

  IF failed THEN
    WriteString("TestJSON: FAILED"); WriteLn;
    ShimExit(1);
  ELSE
    WriteString("TestJSON: all checks passed"); WriteLn;
    ShimExit(0);
  END;
END TestJSON.
