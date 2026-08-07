use "pony_test"

// The JSON codec carries the two Convex-specific promises: exact numbers and
// byte-identical UTF-8 round trips. Both are asserted here rather than assumed.

class iso _TestJsonRoundTrip is UnitTest
  fun name(): String => "json/round-trip"

  fun apply(h: TestHelper) ? =>
    // A number keeps its source lexeme, so a value echoed through Convex comes
    // back exactly as the backend wrote it.
    let source: String val =
      """{"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],""" +
      """"number":42.5,"nil":null}}"""
    h.assert_eq[String](source, JsonEncode(JsonDecode(source)?)?)

    let list = """["Καλημέρα","مرحبا","kia ora","🟨🟩🟦"]"""
    h.assert_eq[String](list, JsonEncode(JsonDecode(list)?)?)

    // Escapes decode, and re-encode in their shortest legal form.
    let escaped = "\"a\\\"b\\\\c\\nd\""
    h.assert_eq[String](escaped, JsonEncode(JsonDecode(escaped)?)?)

    // A surrogate pair becomes one code point, encoded as UTF-8 rather than
    // as a pair of escapes.
    match JsonDecode("\"\\ud83d\\ude00\"")?
    | let text: String => h.assert_eq[String]("😀", text)
    else
      h.fail("surrogate pair did not decode to a string")
    end
    // A lone surrogate half is not a code point and must be refused.
    h.assert_error({()? => JsonDecode("\"\\ud83d\"")? })

class iso _TestJsonStrict is UnitTest
  fun name(): String => "json/strict"

  fun apply(h: TestHelper) =>
    // Trailing content, extensions, and malformed numbers are all refused. A
    // Convex response that is not exactly one JSON value is a protocol fault.
    h.assert_error({()? => JsonDecode("{} {}")? })
    h.assert_error({()? => JsonDecode("{\"a\":1,}")? })
    h.assert_error({()? => JsonDecode("[1,]")? })
    h.assert_error({()? => JsonDecode("NaN")? })
    h.assert_error({()? => JsonDecode("01")? })
    h.assert_error({()? => JsonDecode("1.")? })
    h.assert_error({()? => JsonDecode(".5")? })
    h.assert_error({()? => JsonDecode("+1")? })
    h.assert_error({()? => JsonDecode("\"unterminated")? })
    // A raw control character inside a string must be escaped.
    h.assert_error({()? => JsonDecode("\"a\nb\"")? })
    // Nesting is bounded, so a deeply nested payload cannot exhaust the stack.
    h.assert_error({()? =>
      var deep: String iso = String(200)
      var index: USize = 0
      while index < 80 do
        deep.append("[")
        index = index + 1
      end
      index = 0
      while index < 80 do
        deep.append("]")
        index = index + 1
      end
      JsonDecode(consume deep)?
    })

class iso _TestJsonIntegral is UnitTest
  fun name(): String => "json/integral-numbers"

  fun apply(h: TestHelper) ? =>
    // Convex may send a count as `0`, `0.0`, or `0e0`. All three are the same
    // integer, and none of them may go near a float on the way in.
    h.assert_eq[I64](0, JsonNumber("0")?.integral()?)
    h.assert_eq[I64](0, JsonNumber("0.0")?.integral()?)
    h.assert_eq[I64](1, JsonNumber("1.0")?.integral()?)
    h.assert_eq[I64](100, JsonNumber("1e2")?.integral()?)
    h.assert_eq[I64](1, JsonNumber("100e-2")?.integral()?)
    h.assert_eq[I64](-1, JsonNumber("-1.000")?.integral()?)
    h.assert_eq[I64](-100, JsonNumber("-1E2")?.integral()?)

    // Exactness at the edges of the range, where a double would already have
    // lost the answer.
    h.assert_eq[I64](
      9007199254740993, JsonNumber("9007199254740993")?.integral()?)
    h.assert_eq[I64](
      I64.max_value(), JsonNumber("9223372036854775807")?.integral()?)
    h.assert_eq[I64](
      I64.min_value(), JsonNumber("-9223372036854775808")?.integral()?)

    // Fractional, overflowing, and non-finite values are refused rather than
    // rounded into something plausible.
    h.assert_error({()? => JsonNumber("1.5")?.integral()? })
    h.assert_error({()? => JsonNumber("0.1")?.integral()? })
    h.assert_error({()? => JsonNumber("9223372036854775808")?.integral()? })
    h.assert_error({()? => JsonNumber("-9223372036854775809")?.integral()? })
    h.assert_error({()? => JsonNumber("1e400")?.integral()? })
    h.assert_error({()? => JsonNumber("1e-1")?.integral()? })

    // A quoted number is a string, not a number.
    match JsonDecode("\"1\"")?
    | let text: String => h.assert_eq[String]("1", text)
    else
      h.fail("a quoted number must decode as a string")
    end

class iso _TestJsonObjects is UnitTest
  fun name(): String => "json/objects"

  fun apply(h: TestHelper) ? =>
    let fields = JsonDecode.parse_object(
      """{"status":"success","value":{"count":1.0},"logLines":["a","b"]}""")?
    h.assert_eq[String]("success", fields.string_field("status")?)
    h.assert_true(fields.contains("value"))
    h.assert_false(fields.contains("errorData"))

    let logs = fields.string_list("logLines")?
    h.assert_eq[USize](2, logs.size())
    h.assert_eq[String]("b", logs(1)?)

    // An absent log list is empty, but a present one that is not an array of
    // strings is a protocol error rather than a silent empty list.
    let absent = JsonDecode.parse_object("{}")?.string_list("logLines")?
    h.assert_eq[USize](0, absent.size())
    h.assert_error({()? =>
      JsonDecode.parse_object("""{"logLines":[1]}""")?.string_list("logLines")?
    })

    // Encoding preserves member order, which is what makes a rehydrated Live
    // value comparable to the one already delivered.
    let built = JsonOf.obj3(
      "room", "demo", "count", JsonNumber.from_i64(1), "ok", true)
    h.assert_eq[String]("""{"room":"demo","count":1,"ok":true}""",
      JsonEncode(built)?)
