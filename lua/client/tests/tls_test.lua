package.path = "./client/?.lua;" .. package.path
local Convex = require("convex")

-- The fixture server presents an untrusted self-signed certificate. The native
-- client must reject it before it can interpret the server's non-Convex body.
local client = assert(Convex.new("https://127.0.0.1:19443"))
local result, err = client:query("fixture:test", {})
assert(result == nil and err.name == "TransportError")
assert(err.message:match("certificate verify failed"), "TLS failure did not prove certificate verification")
