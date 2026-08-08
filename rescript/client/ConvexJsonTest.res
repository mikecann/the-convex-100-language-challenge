open ConvexTestSupport

// Convex sends counts as JSON doubles. The regression that matters is the
// integral-but-not-integer form, which a naive "is this an int" check rejects
// and a naive truncation silently corrupts.
test("integral JSON numbers decode, fractional and out-of-range ones do not", async () => {
  equal(ConvexJson.asInt(Js.Json.number(0.0)), Some(0))
  equal(ConvexJson.asInt(Js.Json.number(1.0)), Some(1))
  equal(ConvexJson.asInt(Js.Json.number(-7.0)), Some(-7))
  equal(ConvexJson.asInt(Js.Json.parseExn("0.0")), Some(0))
  equal(ConvexJson.asInt(Js.Json.parseExn("1e2")), Some(100))
  equal(ConvexJson.asInt(Js.Json.number(1.5)), None)
  equal(ConvexJson.asInt(Js.Json.number(-0.25)), None)
  equal(ConvexJson.asInt(Js.Json.string("1")), None)
  equal(ConvexJson.asInt(Js.Json.null), None)
  equal(ConvexJson.asInt(Js.Json.boolean(true)), None)
  equal(ConvexJson.asInt(Js.Json.number(Js.Float._NaN)), None)
  equal(ConvexJson.asInt(Js.Json.number(infinity)), None)
  equal(ConvexJson.asInt(Js.Json.number(neg_infinity)), None)
  // Beyond an idiomatic ReScript int, so it is refused instead of wrapping.
  equal(ConvexJson.asInt(Js.Json.number(2147483648.0)), None)
  equal(ConvexJson.asInt(Js.Json.number(9007199254740993.0)), None)
})

test("count fields are read through the same integral rules", async () => {
  let state = ConvexJson.object_([("count", Js.Json.number(1.0))])
  equal(ConvexJson.intField(state, "count"), Some(1))
  let fractional = ConvexJson.object_([("count", Js.Json.number(1.25))])
  equal(ConvexJson.intField(fractional, "count"), None)
  equal(ConvexJson.intField(ConvexJson.emptyObject(), "count"), None)
})

test("field decoding refuses the wrong shape instead of guessing", async () => {
  let json = Js.Json.parseExn(`{"room":"one","count":2,"ok":true,"nested":{"id":"x"},"list":[1,2]}`)
  equal(ConvexJson.stringField(json, "room"), Some("one"))
  equal(ConvexJson.stringField(json, "count"), None)
  equal(ConvexJson.stringFieldOr(json, "missing", "fallback"), "fallback")
  equal(
    switch ConvexJson.field(json, "ok") {
    | Some(value) => ConvexJson.asBool(value)
    | None => None
    },
    Some(true),
  )
  equal(
    switch ConvexJson.objectField(json, "nested") {
    | Some(dict) => Js.Dict.get(dict, "id")
    | None => None
    },
    Some(Js.Json.string("x")),
  )
  equal(
    switch ConvexJson.field(json, "list") {
    | Some(value) =>
      switch ConvexJson.asArray(value) {
      | Some(items) => Js.Array2.length(items)
      | None => -1
      }
    | None => -1
    },
    2,
  )
  ok(ConvexJson.isNull(Js.Json.null), "null classifies as null")
  ok(!ConvexJson.isNull(Js.Json.string("")), "an empty string is not null")
})

test("log lines survive as strings and never collapse a result", async () => {
  let json = Js.Json.parseExn(`{"logLines":["one","two"],"other":"x"}`)
  deepEqual(ConvexJson.logLines(json, "logLines"), ["one", "two"])
  deepEqual(ConvexJson.logLines(json, "missing"), [])
  // A non-array or non-string entry is dropped rather than crashing a result.
  deepEqual(ConvexJson.logLines(Js.Json.parseExn(`{"logLines":"nope"}`), "logLines"), [])
  deepEqual(ConvexJson.logLines(Js.Json.parseExn(`{"logLines":[1,"two"]}`), "logLines"), ["two"])
})

test("invalid JSON is reported, not thrown into a caller", async () => {
  switch ConvexJson.parse("{not json") {
  | Ok(_) => fail("invalid JSON parsed")
  | Error(message) => ok(Js.String2.length(message) > 0, "the parse failure explains itself")
  }
  switch ConvexJson.parse(`{"ok":true}`) {
  | Ok(json) => equal(ConvexJson.stringField(json, "missing"), None)
  | Error(_) => fail("valid JSON failed to parse")
  }
})

test("structural equality drives unchanged-value suppression", async () => {
  let left = Js.Json.parseExn(`{"count":1,"room":"a"}`)
  let right = Js.Json.parseExn(`{"count":1,"room":"a"}`)
  ok(ConvexJson.equal(left, right), "identical payloads compare equal")
  ok(
    !ConvexJson.equal(left, Js.Json.parseExn(`{"count":2,"room":"a"}`)),
    "a changed count compares unequal",
  )
})
