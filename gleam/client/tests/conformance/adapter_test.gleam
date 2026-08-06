//// Exact serialization coverage for the test-only NDJSON adapter.
////
//// The shared controller validates these shapes strictly. Testing the
//// production builders here catches absent fields accidentally becoming null,
//// structured errors being flattened, or logs disappearing before Docker
//// reaches the shared harness.

import adapter
import convex_check as check
import convex_error
import convex_json.{JsonInt, JsonObject, JsonString} as json
import convex_live.{LiveFailure}
import gleam/option.{Some}

pub fn main() -> Nil {
  check.equal_string(
    "adapter serializes a successful result",
    json.to_string(
      adapter.result_event("query", JsonObject([#("count", JsonInt(1))]), [
        "read count",
      ]),
    ),
    "{\"id\":\"query\",\"type\":\"result\",\"value\":{\"count\":1},\"logs\":[\"read count\"]}",
  )

  let function_error =
    convex_error.function_error(
      "expected failure",
      Some(JsonObject([#("code", JsonString("EXPECTED"))])),
      ["failed deliberately"],
    )
  check.equal_string(
    "adapter preserves a structured function error",
    json.to_string(adapter.call_error_event("mutation", function_error)),
    "{\"id\":\"mutation\",\"type\":\"error\",\"error\":{\"name\":\"FunctionError\",\"message\":\"expected failure\",\"data\":{\"code\":\"EXPECTED\"},\"logs\":[\"failed deliberately\"]}}",
  )

  check.equal_string(
    "adapter serializes a subscription failure",
    json.to_string(adapter.subscription_event(
      "room-state",
      LiveFailure(function_error),
    )),
    "{\"type\":\"subscription\",\"subscriptionId\":\"room-state\",\"error\":{\"name\":\"FunctionError\",\"message\":\"expected failure\",\"data\":{\"code\":\"EXPECTED\"},\"logs\":[\"failed deliberately\"]}}",
  )

  check.equal_string(
    "adapter serializes close without optional nulls",
    json.to_string(adapter.closed_event("close")),
    "{\"id\":\"close\",\"type\":\"closed\"}",
  )

  check.done("adapter_test")
}
