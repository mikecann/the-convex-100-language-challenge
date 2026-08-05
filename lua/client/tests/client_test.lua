package.path = "./client/?.lua;" .. package.path
local Convex = require("convex")

local function assert_equal(actual, expected)
	assert(actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local client, err = Convex.new("not-a-url")
assert(client == nil)
assert_equal(err.name, "ProtocolError")

client = assert(Convex.new("https://example.convex.cloud/"))
local result, call_error = client:query("", {})
assert(result == nil)
assert_equal(call_error.name, "ProtocolError")
assert(client:close())
result, call_error = client:query("demo:state", {})
assert(result == nil)
assert_equal(call_error.name, "ClosedError")
