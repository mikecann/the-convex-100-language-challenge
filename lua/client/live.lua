local json = require("json")
local cqueues = require("cqueues")
local condition = require("cqueues.condition")
local errno = require("cqueues.errno")
local websocket = require("http.websocket")
local random = require("openssl.rand")
local basexx = require("basexx")

local Live = {}
local INITIAL_TIMESTAMP = "AAAAAAAAAAA="
local INITIAL_BACKOFF = 0.1
local MAX_BACKOFF = 15
local MAX_BUFFERED_UPDATES = 16

local function close_frame_reason(reason)
	-- RFC 6455 leaves 123 bytes for a close reason. Keep the complete reason in
	-- connection metadata, but send a bounded ASCII diagnostic on the wire so a
	-- long or malformed transport error cannot prevent socket retirement.
	return tostring(reason):gsub("[^ -~]", "?"):sub(1, 123)
end

local function failure(name, message, data, logs)
	return { name = name, message = message, data = data, logs = logs or {} }
end

local function copy(value)
	if value == nil then
		return nil
	end
	local encoded = assert(json.encode(value))
	return assert(json.decode(encoded))
end

local function same_value(left, right)
	if left == right then
		return true
	end
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return false
	end
	local left_kind = getmetatable(left) and getmetatable(left).__jsontype
	local right_kind = getmetatable(right) and getmetatable(right).__jsontype
	if left_kind ~= right_kind then
		return false
	end
	for key, value in pairs(left) do
		if not same_value(value, right[key]) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function zero_version()
	return { querySet = 0, identity = 0, ts = INITIAL_TIMESTAMP }
end

local function session_id()
	local bytes = { random.bytes(16):byte(1, 16) }
	bytes[7] = (bytes[7] % 16) + 64
	bytes[9] = (bytes[9] % 64) + 128
	return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", unpack(bytes))
end

local function versions_equal(left, right)
	return left
		and right
		and left.querySet == right.querySet
		and left.identity == right.identity
		and left.ts == right.ts
end

local function valid_version(version)
	if
		type(version) ~= "table"
		or type(version.querySet) ~= "number"
		or version.querySet % 1 ~= 0
		or type(version.identity) ~= "number"
		or version.identity % 1 ~= 0
		or type(version.ts) ~= "string"
	then
		return false
	end
	local ok, decoded = pcall(basexx.from_base64, version.ts)
	return ok and type(decoded) == "string" and #decoded == 8
end

local function later_timestamp(left, right)
	if not left then
		return right
	end
	local left_bytes = basexx.from_base64(left)
	local right_bytes = basexx.from_base64(right)
	-- Convex timestamps are base64-encoded little-endian unsigned 64-bit
	-- values, so compare the most significant byte first.
	for index = 8, 1, -1 do
		if right_bytes:byte(index) > left_bytes:byte(index) then
			return right
		elseif right_bytes:byte(index) < left_bytes:byte(index) then
			return left
		end
	end
	return left
end

local Subscription = {}
Subscription.__index = Subscription

function Subscription.new(manager, query_id)
	return setmetatable({
		manager = manager,
		query_id = query_id,
		updates = {},
		changed = condition.new(),
		closed = false,
		finished = false,
	}, Subscription)
end

function Subscription:_deliver(update)
	if self.finished then
		return
	end
	if #self.updates == MAX_BUFFERED_UPDATES then
		table.remove(self.updates, 1)
	end
	self.updates[#self.updates + 1] = update
	self.changed:signal(1)
end

function Subscription:_finish()
	if self.finished then
		return
	end
	self.finished = true
	self.updates = {}
	self.changed:signal(1)
end

function Subscription:next_update(timeout)
	local deadline = timeout and (cqueues.monotime() + timeout)
	while #self.updates == 0 and not self.finished do
		local remaining = deadline and (deadline - cqueues.monotime())
		if remaining and remaining <= 0 then
			return nil, failure("TransportError", "timed out waiting for Live update")
		end
		if cqueues.running() then
			self.changed:wait(remaining)
		else
			local ok, err = self.manager.cq:step(remaining)
			if not ok and err then
				return nil, failure("TransportError", tostring(err))
			end
		end
	end
	if self.finished and #self.updates == 0 then
		return nil, failure("ClosedError", "Live subscription is closed")
	end
	return table.remove(self.updates, 1)
end

function Subscription:try_next_update()
	if #self.updates > 0 then
		return table.remove(self.updates, 1)
	end
	return nil
end

function Subscription:close()
	if self.closed then
		return true
	end
	self.closed = true
	return self.manager:unsubscribe(self.query_id)
end

local Manager = {}
Manager.__index = Manager

function Manager.new(deployment_url, client_version, options)
	options = options or {}
	local ws_url = deployment_url:gsub("^https://", "wss://"):gsub("^http://", "ws://"):gsub("/+$", "") .. "/api/sync"
	local self = setmetatable({
		websocket_url = ws_url,
		client_version = client_version,
		cq = options.cq or cqueues.new(),
		websocket_factory = options.websocket_factory,
		commands = {},
		command_ready = condition.new(),
		subscriptions = {},
		remote_results = {},
		next_query_id = 0,
		query_set_version = 0,
		remote_version = zero_version(),
		connection_count = 0,
		last_close_reason = "InitialConnect",
		next_backoff = INITIAL_BACKOFF,
		reconnect_at = nil,
		max_observed_timestamp = nil,
		socket = nil,
		closed = false,
	}, Manager)
	self.cq:wrap(function()
		self:_owner()
	end)
	return self
end

function Manager:_wait(response)
	while not response.done do
		if cqueues.running() then
			response.changed:wait()
		else
			local ok, err = self.cq:step()
			if not ok and err then
				return nil, failure("TransportError", tostring(err))
			end
		end
	end
	return response.value, response.error
end

function Manager:_submit(kind, fields)
	if self.closed and kind ~= "close" then
		return nil, failure("ClosedError", "Convex Live manager is closed")
	end
	local response = { changed = condition.new(), done = false }
	fields = fields or {}
	fields.kind = kind
	fields.response = response
	self.commands[#self.commands + 1] = fields
	self.command_ready:signal(1)
	return self:_wait(response)
end

function Manager:_respond(command, value, err)
	command.response.value = value
	command.response.error = err
	command.response.done = true
	command.response.changed:signal(1)
end

function Manager:subscribe(path, args)
	args = json.object(args or {})
	return self:_submit("subscribe", { path = path, args = copy(args) })
end

function Manager:unsubscribe(query_id)
	if self.closed then
		return true
	end
	return self:_submit("unsubscribe", { query_id = query_id })
end

function Manager:debug_disconnect()
	return self:_submit("debug_disconnect")
end

function Manager:close()
	if self.closed then
		return true
	end
	return self:_submit("close")
end

function Manager:_add_modification(query_id, state)
	return { type = "Add", queryId = query_id, udfPath = state.path, args = { state.args } }
end

function Manager:_send(value, timeout)
	local encoded, encode_error = json.encode(value)
	if not encoded then
		return nil, failure("ProtocolError", "encode Live message: " .. tostring(encode_error))
	end
	local ok, err = self.socket:send(encoded, "text", timeout or 5)
	if not ok then
		return nil, failure("TransportError", "write Live message: " .. tostring(err))
	end
	return true
end

function Manager:_modify(modifications, timeout)
	local next_version = self.query_set_version + 1
	local ok, err = self:_send({
		type = "ModifyQuerySet",
		baseVersion = self.query_set_version,
		newVersion = next_version,
		modifications = modifications,
	}, timeout)
	if not ok then
		return nil, err
	end
	self.query_set_version = next_version
	return true
end

function Manager:_recover_query_set_write(err)
	-- A failed WebSocket send is ambiguous: the server may have applied all,
	-- part, or none of the frame. Retire that connection before publishing the
	-- structured error, then replay only the still-active set on a new socket.
	self:_disconnect("QuerySetWriteFailed: " .. err.message, true)
	self:_publish_error(err)
end

function Manager:_retire_socket(code, reason, timeout)
	if not self.socket then
		return false
	end
	local retired_socket = self.socket
	local invoked, close_result = pcall(function()
		return retired_socket:close(code, close_frame_reason(reason), timeout)
	end)
	if not (invoked and close_result) and retired_socket.socket then
		-- lua-http exposes the owned cqueues socket here. If its graceful close
		-- raises or returns failure, force the transport closed before proceeding.
		pcall(function()
			retired_socket.socket:shutdown()
		end)
		pcall(function()
			retired_socket.socket:close()
		end)
	end
	self.socket = nil
	return true
end

function Manager:_process_commands()
	while #self.commands > 0 do
		local command = table.remove(self.commands, 1)
		if command.kind == "subscribe" then
			local query_id = self.next_query_id
			self.next_query_id = query_id + 1
			local subscription = Subscription.new(self, query_id)
			local state =
				{ path = command.path, args = command.args, subscription = subscription, last_delivered = nil }
			self.subscriptions[query_id] = state
			if self.socket then
				local ok, err = self:_modify({ self:_add_modification(query_id, state) })
				if not ok then
					self.subscriptions[query_id] = nil
					state.subscription:_finish()
					self:_recover_query_set_write(err)
					self:_respond(command, nil, err)
				else
					self:_respond(command, subscription)
				end
			else
				self.reconnect_at = cqueues.monotime()
				self:_respond(command, subscription)
			end
		elseif command.kind == "unsubscribe" then
			local state = self.subscriptions[command.query_id]
			self.subscriptions[command.query_id] = nil
			self.remote_results[command.query_id] = nil
			if state then
				state.subscription:_finish() -- invalidate before the acknowledgement
				if self.socket then
					local ok, err = self:_modify({ { type = "Remove", queryId = command.query_id } }, 0.25)
					if not ok then
						self:_recover_query_set_write(err)
						self:_respond(command, nil, err)
					else
						self:_respond(command, true)
					end
				else
					self:_respond(command, true)
				end
			else
				self:_respond(command, true)
			end
		elseif command.kind == "debug_disconnect" then
			if not self.socket then
				self:_respond(command, nil, failure("TransportError", "Live WebSocket is not connected"))
			else
				self:_disconnect("DebugDisconnect", true)
				self:_respond(command, true) -- reconnect work is scheduled before ack
			end
		elseif command.kind == "close" then
			self.closed = true
			for _, state in pairs(self.subscriptions) do
				state.subscription:_finish()
			end
			self.subscriptions = {}
			self:_retire_socket(1000, "client closed", 0.25)
			self:_respond(command, true)
		end
	end
end

function Manager:_connect()
	local ws = self.websocket_factory and self.websocket_factory(self.websocket_url)
		or websocket.new_from_uri(self.websocket_url)
	if ws.request and ws.request.headers then
		ws.request.headers:append("convex-client", self.client_version)
	end
	local ok, err = ws:connect(10)
	if not ok then
		return nil, failure("TransportError", "connect Live WebSocket: " .. tostring(err))
	end
	self.socket = ws
	self.query_set_version = 0
	self.remote_version = zero_version()
	self.remote_results = {}
	local connect = {
		type = "Connect",
		sessionId = session_id(),
		connectionCount = self.connection_count,
		lastCloseReason = self.last_close_reason,
		clientTs = 0,
	}
	if self.max_observed_timestamp then
		connect.maxObservedTimestamp = self.max_observed_timestamp
	end
	local sent, send_error = self:_send(connect)
	if not sent then
		return nil, send_error
	end
	local modifications = {}
	for query_id, state in pairs(self.subscriptions) do
		modifications[#modifications + 1] = self:_add_modification(query_id, state)
	end
	table.sort(modifications, function(a, b)
		return a.queryId < b.queryId
	end)
	if #modifications > 0 then
		sent, send_error = self:_modify(modifications)
		if not sent then
			return nil, send_error
		end
	end
	self.next_backoff = INITIAL_BACKOFF
	self.reconnect_at = nil
	return true
end

function Manager:_disconnect(reason, reconnect)
	if self:_retire_socket(1001, reason, 0.1) then
		self.connection_count = self.connection_count + 1
	end
	self.last_close_reason = reason
	self.query_set_version = 0
	self.remote_version = zero_version()
	self.remote_results = {}
	if reconnect and next(self.subscriptions) then
		self.reconnect_at = cqueues.monotime() + self.next_backoff
		self.next_backoff = math.min(self.next_backoff * 2, MAX_BACKOFF)
	end
end

function Manager:_publish_error(err)
	for _, state in pairs(self.subscriptions) do
		state.subscription:_deliver({ error = err, logs = err.logs or {} })
	end
end

function Manager:_transition(message)
	if not valid_version(message.startVersion) or not valid_version(message.endVersion) then
		return nil, failure("ProtocolError", "Transition must include valid startVersion and endVersion objects")
	end
	if not versions_equal(message.startVersion, self.remote_version) then
		return nil, failure("ProtocolError", "Transition start version does not match the local version")
	end
	if type(message.modifications) ~= "table" then
		return nil, failure("ProtocolError", "Transition modifications must be an array")
	end
	for _, modification in ipairs(message.modifications) do
		if type(modification) ~= "table" or type(modification.queryId) ~= "number" or modification.queryId % 1 ~= 0 then
			return nil, failure("ProtocolError", "Transition modification requires an integer queryId")
		end
		if modification.type == "QueryUpdated" then
			if modification.value == nil then
				return nil, failure("ProtocolError", "QueryUpdated omitted value")
			end
		elseif modification.type == "QueryFailed" then
			if type(modification.errorMessage) ~= "string" then
				return nil, failure("ProtocolError", "QueryFailed omitted errorMessage")
			end
		elseif modification.type ~= "QueryRemoved" then
			return nil, failure("ProtocolError", "unknown Transition modification " .. tostring(modification.type))
		end
		if modification.logLines ~= nil and type(modification.logLines) ~= "table" then
			return nil, failure("ProtocolError", "Transition logLines must be an array")
		end
	end
	local changed = {}
	for _, modification in ipairs(message.modifications or {}) do
		local query_id = modification.queryId
		if modification.type == "QueryUpdated" then
			changed[query_id] = { value = copy(modification.value), logs = modification.logLines or {} }
			self.remote_results[query_id] = changed[query_id]
		elseif modification.type == "QueryFailed" then
			local err = failure(
				"FunctionError",
				modification.errorMessage or "Live query failed",
				copy(modification.errorData),
				modification.logLines or {}
			)
			changed[query_id] = { error = err, logs = err.logs }
			self.remote_results[query_id] = changed[query_id]
		elseif modification.type == "QueryRemoved" then
			self.remote_results[query_id] = nil
		end
	end
	self.remote_version = copy(message.endVersion)
	self.max_observed_timestamp = later_timestamp(self.max_observed_timestamp, self.remote_version.ts)
	for query_id, update in pairs(changed) do
		local state = self.subscriptions[query_id]
		if state then
			local duplicate = not update.error and same_value(state.last_delivered, update.value)
			if not duplicate then
				state.last_delivered = update.error and nil or copy(update.value)
				state.subscription:_deliver(update)
			end
		end
	end
	return true
end

function Manager:_receive()
	local payload, kind, receive_errno = self.socket:receive(0.1)
	if not payload then
		if receive_errno == errno.ETIMEDOUT then
			return true
		end
		return nil, failure("TransportError", "read Live WebSocket: " .. tostring(kind))
	end
	if kind ~= "text" then
		return nil, failure("ProtocolError", "Convex Live sent a non-text message")
	end
	local message, decode_error = json.decode(payload)
	if not message then
		return nil, failure("ProtocolError", "decode Live message: " .. tostring(decode_error))
	end
	self.next_backoff = INITIAL_BACKOFF -- a valid server message proves health
	if message.type == "Transition" then
		return self:_transition(message)
	end
	if message.type == "Ping" or message.type == "MutationResponse" or message.type == "ActionResponse" then
		return true
	end
	if message.type == "FatalError" or message.type == "AuthError" then
		return nil, failure("ProtocolError", message.type .. ": " .. tostring(message.error))
	end
	return nil, failure("ProtocolError", "unknown server message " .. tostring(message.type))
end

function Manager:_owner()
	while not self.closed do
		self:_process_commands()
		if self.closed then
			break
		end
		if
			not self.socket
			and next(self.subscriptions)
			and (not self.reconnect_at or cqueues.monotime() >= self.reconnect_at)
		then
			local ok, err = self:_connect()
			if not ok then
				self:_publish_error(err)
				self:_disconnect(err.message, true)
			end
		elseif self.socket then
			local ok, err = self:_receive()
			if not ok then
				self:_publish_error(err)
				self:_disconnect(err.message, true)
			end
		else
			self.command_ready:wait(self.reconnect_at and math.max(0, self.reconnect_at - cqueues.monotime()) or 1)
		end
	end
end

Live.Manager = Manager
Live.Subscription = Subscription
Live.failure = failure
return Live
