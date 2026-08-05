-- A small native Lua client for Convex's documented JSON HTTP API.  Lua owns
-- the Convex request and response behaviour; the dependencies only provide
-- ordinary TLS, HTTP framing, and JSON encoding.
local http_request = require("http.request")
local json = require("cjson.safe")
local Live = require("live")

local Convex = {}
Convex.__index = Convex

local MAX_RESPONSE_BYTES = 2 * 1024 * 1024

local function fail(kind, message, data, logs)
	return nil, { name = kind, message = message, data = data, logs = logs }
end

local function valid_url(url)
	return type(url) == "string" and url:match("^https?://[^/%?#]+") ~= nil
end

local function encode(value, context)
	local encoded, err = json.encode(value)
	if not encoded then
		return fail("ProtocolError", "encode " .. context .. ": " .. tostring(err))
	end
	return encoded
end

function Convex.new(deployment_url, options)
	if not valid_url(deployment_url) then
		return fail("ProtocolError", "Convex deployment URL must use http or https and include a host")
	end
	if deployment_url:match("^https?://[^/]+@") then
		return fail("ProtocolError", "Convex deployment URL must not include user information")
	end
	options = options or {}
	return setmetatable({
		deployment_url = deployment_url:gsub("/+$", ""),
		bearer_token = options.bearer_token or "",
		client_version = options.client_version or "lua-0.1.0",
		live_cq = options.cq,
		closed = false,
		live = nil,
	}, Convex)
end

function Convex:set_auth(token)
	if self.closed then
		return fail("ClosedError", "Convex client is closed")
	end
	self.bearer_token = token or ""
	return true
end

function Convex:close()
	if self.live then
		self.live:close()
	end
	self.closed = true
	return true
end

function Convex:subscribe(path, args)
	if self.closed then
		return fail("ClosedError", "Convex client is closed")
	end
	if type(path) ~= "string" or path == "" then
		return fail("ProtocolError", "Convex function path is required")
	end
	if args ~= nil and type(args) ~= "table" then
		return fail("ProtocolError", "Convex arguments must be a named JSON object")
	end
	if not self.live then
		self.live = Live.Manager.new(self.deployment_url, self.client_version, { cq = self.live_cq })
	end
	return self.live:subscribe(path, args or {})
end

function Convex:debug_disconnect_for_adapter()
	if not self.live then
		return fail("TransportError", "Live WebSocket is not connected")
	end
	return self.live:debug_disconnect()
end

function Convex:call(operation, path, args)
	if self.closed then
		return fail("ClosedError", "Convex client is closed")
	end
	if operation ~= "query" and operation ~= "mutation" and operation ~= "action" then
		return fail("ProtocolError", "unknown Convex operation " .. tostring(operation))
	end
	if type(path) ~= "string" or path == "" then
		return fail("ProtocolError", "Convex function path is required")
	end
	if args == nil then
		args = {}
	end
	if type(args) ~= "table" then
		return fail("ProtocolError", "Convex arguments must be a named JSON object")
	end
	local body, body_error = encode({ path = path, args = args, format = "json" }, "Convex request")
	if not body then
		return nil, body_error
	end

	local endpoint = self.deployment_url .. "/api/" .. operation
	local request = http_request.new_from_uri(endpoint)
	request.headers:upsert(":method", "POST")
	request.headers:upsert("content-type", "application/json")
	request.headers:upsert("accept", "application/json")
	request.headers:upsert("convex-client", self.client_version)
	if self.bearer_token ~= "" then
		request.headers:upsert("authorization", "Bearer " .. self.bearer_token)
	end
	request:set_body(body)
	local response_headers, stream, request_errno = request:go(30)
	if not response_headers then
		return fail(
			"TransportError",
			"Convex " .. operation .. " request failed: " .. tostring(stream or request_errno)
		)
	end
	local response, read_error = stream:get_body_as_string(30)
	if not response then
		return fail("TransportError", "read Convex " .. operation .. " response: " .. tostring(read_error))
	end
	local code = response_headers:get(":status")
	if #response > MAX_RESPONSE_BYTES then
		return fail("TransportError", "response exceeds " .. MAX_RESPONSE_BYTES .. " bytes")
	end
	local decoded, decode_error = json.decode(response)
	if not decoded then
		return fail(
			"TransportError",
			"HTTP " .. tostring(code) .. " returned a non-Convex response: " .. tostring(decode_error)
		)
	end
	if decoded.status == "success" then
		if decoded.value == nil then
			return fail("ProtocolError", "success response omitted value")
		end
		return { value = decoded.value, logs = decoded.logLines or {} }
	end
	if decoded.status == "error" then
		return fail(
			"FunctionError",
			decoded.errorMessage or "Convex function failed",
			decoded.errorData,
			decoded.logLines or {}
		)
	end
	return fail(
		"ProtocolError",
		"HTTP " .. tostring(code) .. " response has unknown status " .. tostring(decoded.status)
	)
end

function Convex:query(path, args)
	return self:call("query", path, args)
end
function Convex:mutation(path, args)
	return self:call("mutation", path, args)
end
function Convex:action(path, args)
	return self:call("action", path, args)
end

return Convex
