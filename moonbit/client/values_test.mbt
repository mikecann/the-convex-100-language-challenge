// Decoding regressions for the value shapes Convex actually sends.
//
// The interesting cases are the ones a permissive decoder gets wrong: an
// integral number written in decimal form, a member that is present and null
// versus absent, and numbers that cannot be represented as an integer at all.

///|
test "integral counts accept both 0 and 0.0" {
  let plain = @json.parse("{\"count\":0}")
  let decimal = @json.parse("{\"count\":0.0}")
  let one = @json.parse("{\"count\":1.0}")
  @test.assert_eq(
    @convex.integer_value(
      @convex.required_field(plain, "count", "test"),
      "count",
    ),
    0L,
  )
  @test.assert_eq(
    @convex.integer_value(
      @convex.required_field(decimal, "count", "test"),
      "count",
    ),
    0L,
  )
  @test.assert_eq(
    @convex.integer_value(@convex.required_field(one, "count", "test"), "count"),
    1L,
  )
}

///|
test "integral counts reject fractional, quoted, and overflowing values" {
  let fractional = @json.parse("{\"count\":0.5}")
  let quoted = @json.parse("{\"count\":\"1\"}")
  let huge = @json.parse("{\"count\":1e300}")
  for probe in [fractional, quoted, huge] {
    let outcome = try {
      @convex.integer_value(
        @convex.required_field(probe, "count", "test"),
        "count",
      )
      |> ignore
      "accepted"
    } catch {
      @convex.ConvexError(info) => info.kind.to_string()
    }
    @test.assert_eq(outcome, "ProtocolError")
  }
}

///|
test "a present null member is not the same as an absent member" {
  let value = @json.parse("{\"updatedAt\":null}")
  @test.assert_eq(@convex.json_has_field(value, "updatedAt"), true)
  @test.assert_eq(@convex.json_has_field(value, "missing"), false)
  @test.assert_eq(@convex.json_field(value, "updatedAt") is Some(Null), true)
  @test.assert_eq(@convex.json_field(value, "missing") is None, true)
}

///|
test "required_field names the member it could not find" {
  let value = @json.parse("{}")
  let message = try {
    @convex.required_field(value, "value", "success response") |> ignore
    ""
  } catch {
    @convex.ConvexError(info) => info.message
  }
  @test.assert_eq(message.contains("value"), true)
}
