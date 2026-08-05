package.path = "./client/tests/conformance/?.lua;./client/?.lua;" .. package.path
local json = require("json")
local Events = require("adapter_events")

local function round_trip(event)
	return assert(json.decode(assert(json.encode(event))))
end

-- Success values are always present, while optional logs disappear rather
-- than becoming null or an ambiguous empty JSON object.
local result = round_trip(Events.result("query-1", { value = { count = 1 }, logs = {} }))
assert(result.type == "result" and result.id == "query-1" and result.value.count == 1)
assert(result.logs == nil)

-- Structured HTTP failures keep the function data and non-empty logs attached
-- to the error event instead of flattening them into a successful value.
local failed = round_trip(Events.error("mutation-1", {
	name = "FunctionError",
	message = "fixture failed",
	data = { code = "FIXTURE" },
	logs = { "fixture log" },
}))
assert(failed.type == "error" and failed.id == "mutation-1")
assert(failed.error.name == "FunctionError" and failed.error.data.code == "FIXTURE")
assert(failed.logs[1] == "fixture log")

-- Subscription failures reuse the structured error shape but replace the
-- request id with the stable subscription id required by adapter protocol v1.
local subscription_error = Events.error(nil, { name = "ProtocolError", message = "bad transition" })
subscription_error.type = "subscription"
subscription_error.subscriptionId = "sub-1"
subscription_error = round_trip(subscription_error)
assert(subscription_error.id == nil and subscription_error.subscriptionId == "sub-1")
assert(subscription_error.error.name == "ProtocolError")

local update = round_trip(Events.subscription("sub-1", { value = { count = 2 }, logs = {} }))
assert(update.type == "subscription" and update.subscriptionId == "sub-1")
assert(update.value.count == 2 and update.logs == nil)

local closed = round_trip({ id = "close-1", type = "closed" })
assert(closed.id == "close-1" and closed.type == "closed")
