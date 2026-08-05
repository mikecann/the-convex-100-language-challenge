package.path = "./client/?.lua;" .. package.path
local Convex = require("convex")
local json = require("json")

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

-- dkjson container metatables preserve the two distinct empty JSON values
-- through adapter decode, client copies, HTTP bodies, and event encoding.
local containers = assert(json.decode('{"array":[],"object":{}}'))
local round_trip = assert(json.decode(assert(json.encode(containers))))
assert(getmetatable(round_trip.array).__jsontype == "array")
assert(getmetatable(round_trip.object).__jsontype == "object")
assert(assert(json.encode(round_trip)):match('"array":%[%]'))
assert(assert(json.encode(round_trip)):match('"object":{}'))
assert(assert(json.encode({ array = Convex.array(), object = Convex.object() })):match('"array":%[%]'))
