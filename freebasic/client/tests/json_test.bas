' Strictness coverage for the JSON codec. A lenient parser is how a malformed
' Convex envelope starts looking like a value, so every rejection below is
' part of the client's contract.

#include once "json.bi"
#include once "testing.bi"

dim as string reason

function Rejects(byref text as string) as boolean
  dim as string why
  dim as JsonValue ptr node = JsonParse(text, why)
  if node = 0 then
    return true
  end if
  JsonFree(node)
  return false
end function

function RoundTrip(byref text as string) as string
  dim as string why
  dim as JsonValue ptr node = JsonParse(text, why)
  if node = 0 then
    return "<parse failed: " & why & ">"
  end if
  dim as string rendered = JsonRender(node)
  JsonFree(node)
  return rendered
end function

' --- accepted documents ---------------------------------------------------
CheckEqual(RoundTrip("null"), "null", "null round trips")
CheckEqual(RoundTrip("true"), "true", "true round trips")
CheckEqual(RoundTrip("  false  "), "false", "surrounding whitespace is allowed")
CheckEqual(RoundTrip("0"), "0", "zero round trips")
CheckEqual(RoundTrip("-0"), "0", "negative zero normalises to an integer zero")
CheckEqual(RoundTrip("42.5"), "42.5", "a fraction keeps its short spelling")
CheckEqual(RoundTrip("1.0"), "1", "an integral double normalises, and stays whole")
CheckEqual(RoundTrip("1e2"), "100", "an exponent normalises to a whole number")
CheckEqual(RoundTrip("9223372036854775807"), "9223372036854775807", _
  "the largest 64-bit integer keeps an exact spelling")
CheckEqual(RoundTrip("-9223372036854775808"), "-9223372036854775808", _
  "the most negative 64-bit integer keeps an exact spelling")
CheckEqual(RoundTrip("[]"), "[]", "an empty array")
CheckEqual(RoundTrip("{}"), "{}", "an empty object")
CheckEqual(RoundTrip("[1,2,[3]]"), "[1,2,[3]]", "nested arrays keep their order")
CheckEqual(RoundTrip("{""a"":1,""b"":null}"), "{""a"":1,""b"":null}", _
  "object members keep their order")
CheckEqual(RoundTrip("""\u0041"""), """A""", "a basic unicode escape decodes")
CheckEqual(RoundTrip("""\ud83d\udc4b"""), """" & chr(240, 159, 145, 139) & """", _
  "a surrogate pair becomes one four byte code point")
CheckEqual(RoundTrip("""tab\there"""), """tab\there""", "a tab is re-escaped")
CheckEqual(RoundTrip("""\u0000"""), """\u0000""", "a NUL escape survives a round trip")
CheckEqual(RoundTrip("""" & chr(228, 184, 150) & """"), """" & chr(228, 184, 150) & """", _
  "multi-byte UTF-8 is emitted verbatim rather than escaped")

' --- rejected documents ---------------------------------------------------
Check(Rejects(""), "an empty document is rejected")
Check(Rejects("  "), "whitespace alone is rejected")
Check(Rejects("nul"), "a truncated literal is rejected")
Check(Rejects("True"), "a capitalised literal is rejected")
Check(Rejects("{""a"":1,}"), "a trailing comma in an object is rejected")
Check(Rejects("[1,]"), "a trailing comma in an array is rejected")
Check(Rejects("[1 2]"), "a missing comma is rejected")
Check(Rejects("{a:1}"), "an unquoted key is rejected")
Check(Rejects("{""a"" 1}"), "a missing colon is rejected")
Check(Rejects("{""a"":1}{}"), "trailing content after a value is rejected")
Check(Rejects("01"), "a leading zero is rejected")
Check(Rejects("-01"), "a negative leading zero is rejected")
Check(Rejects("1."), "a trailing decimal point is rejected")
Check(Rejects(".5"), "a bare fraction is rejected")
Check(Rejects("+1"), "an explicit plus sign is rejected")
Check(Rejects("1e"), "an empty exponent is rejected")
Check(Rejects("NaN"), "NaN is rejected")
Check(Rejects("Infinity"), "Infinity is rejected")
Check(Rejects("'single'"), "single quotes are rejected")
Check(Rejects("""unterminated"), "an unterminated string is rejected")
Check(Rejects("""raw" & chr(10) & "newline"""), _
  "a raw control character in a string is rejected")
Check(Rejects("""\x41"""), "an unknown escape is rejected")
Check(Rejects("""\u00"""), "a short unicode escape is rejected")
Check(Rejects("""\ud800"""), "a lone high surrogate is rejected")
Check(Rejects("""\udc00"""), "a lone low surrogate is rejected")
Check(Rejects("""\ud800A"""), "a high surrogate followed by a non surrogate is rejected")
Check(Rejects("{""a"":1,""a"":2}"), "a duplicate object key is rejected")
Check(Rejects(chr(34, 255, 34)), "a string that is not valid UTF-8 is rejected")

' Depth is bounded so a hostile document cannot exhaust the stack.
dim as string deep = string(JSON_MAX_DEPTH + 4, "[") & string(JSON_MAX_DEPTH + 4, "]")
Check(Rejects(deep), "a document nested past the depth bound is rejected")
dim as string shallow = string(8, "[") & string(8, "]")
Check(not Rejects(shallow), "a modestly nested document is accepted")

' --- tree building and comparison ----------------------------------------
dim as JsonValue ptr built = JsonNew(JSON_OBJECT)
JsonSet(built, "room", JsonNewString("demo"))
JsonSet(built, "count", JsonNewInteger(1))
JsonSet(built, "flag", JsonNewBool(false))
CheckEqual(JsonRender(built), "{""room"":""demo"",""count"":1,""flag"":false}", _
  "a hand-built object serializes in insertion order")
JsonSet(built, "count", JsonNewInteger(2))
CheckEqual(JsonRender(built), "{""room"":""demo"",""count"":2,""flag"":false}", _
  "setting an existing key replaces it in place")

dim as JsonValue ptr copy = JsonClone(built)
Check(JsonEqual(built, copy), "a clone compares equal to its source")
JsonSet(copy, "count", JsonNewInteger(3))
Check(not JsonEqual(built, copy), "a changed clone compares unequal")
JsonFree(copy)
JsonFree(built)

dim as JsonValue ptr orderedA = JsonParse("{""a"":1,""b"":2}", reason)
dim as JsonValue ptr orderedB = JsonParse("{""b"":2,""a"":1}", reason)
Check(JsonEqual(orderedA, orderedB), "object comparison ignores member order")
JsonFree(orderedA)
JsonFree(orderedB)

' --- whole number decoding ------------------------------------------------
dim as longint whole
dim as JsonValue ptr node = JsonParse("0.0", reason)
Check(JsonWholeNumber(node, whole) andalso whole = 0, "0.0 decodes as the whole number zero")
JsonFree(node)
node = JsonParse("1.0", reason)
Check(JsonWholeNumber(node, whole) andalso whole = 1, "1.0 decodes as the whole number one")
JsonFree(node)
node = JsonParse("0.5", reason)
Check(not JsonWholeNumber(node, whole), "a fraction is not a whole number")
JsonFree(node)
node = JsonParse("""1""", reason)
Check(not JsonWholeNumber(node, whole), "a quoted number is not a whole number")
JsonFree(node)
Check(Rejects("1e400"), "an exponent that overflows a double is rejected")

end TestSummary("freebasic json")
