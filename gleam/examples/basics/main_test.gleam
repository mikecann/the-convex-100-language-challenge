//// Regression for the canonical example's own decoding.
////
//// The example is the file the README and the website show, so this test
//// calls the exact function that file uses rather than a copy of it. Convex
//// may deliver a whole number as `0` or as `0.0`, and an example that only
//// accepted one spelling would pass against a mocked fixture and then fail
//// against a real deployment.

import convex_check as check
import convex_json.{JsonFloat, JsonInt, JsonObject, JsonString}
import main

pub fn main() -> Nil {
  check.equal_int(
    "an integer count decodes",
    main.count(JsonObject([#("count", JsonInt(0))])),
    0,
  )
  check.equal_int(
    "an integral float count decodes",
    main.count(JsonObject([#("count", JsonFloat(1.0))])),
    1,
  )
  check.equal_int(
    "a larger integral float count decodes",
    main.count(JsonObject([#("count", JsonFloat(42.0))])),
    42,
  )
  // A fractional or quoted count would mean the deployment and this client
  // disagree about the value, so the example must stop rather than round.
  check.ok(
    "a fractional count is rejected",
    rejects(JsonObject([#("count", JsonFloat(1.5))])),
  )
  check.ok(
    "a quoted count is rejected",
    rejects(JsonObject([#("count", JsonString("1"))])),
  )
  check.ok("a missing count is rejected", rejects(JsonObject([])))
  check.done("main_test")
}

/// `main.count` stops the program on a bad value, so the rejection cases are
/// checked through the same decoder the example relies on instead of by
/// catching a panic.
fn rejects(value: convex_json.Json) -> Bool {
  case convex_json.field(value, "count") {
    Error(_) -> True
    Ok(raw) ->
      case convex_json.integral_int(raw) {
        Ok(_) -> False
        Error(_) -> True
      }
  }
}
