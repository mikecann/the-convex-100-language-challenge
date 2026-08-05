#!/usr/local/bin/lua
package.path = os.getenv("CONVEX_CLIENT_PATH") and (os.getenv("CONVEX_CLIENT_PATH") .. "/?.lua;" .. package.path)
	or ("./client/?.lua;" .. package.path)
local json = require("cjson.safe")
local socket = require("socket")
local cqueues = require("cqueues")
local cqueue_socket = require("cqueues.socket")
local Convex = require("convex")
local Events = require("adapter_events")

local function write(output, event)
	local line = assert(json.encode(event)) .. "\n"
	if output.write then
		output:write(line)
	else
		assert(output:send(line))
	end
	if output.flush then
		output:flush()
	end
end

local function new_state(output)
	return { output = output, client = nil, subscriptions = {}, closed = false }
end

local function ensure_client(state)
	if state.client then
		return state.client
	end
	local url = os.getenv("CONVEX_URL")
	if not url or url == "" then
		return nil, { name = "TransportError", message = "CONVEX_URL is required" }
	end
	local client, err = Convex.new(url, {
		bearer_token = os.getenv("CONVEX_AUTH_TOKEN") or "",
		client_version = "lua-0.1.0",
		cq = state.cq,
	})
	state.client = client
	return client, err
end

local function process_line(state, line)
	local output = state.output
	local command, decode_error = json.decode(line)
	if not command then
		write(
			output,
			Events.error(nil, { name = "ProtocolError", message = "decode command: " .. tostring(decode_error) })
		)
	elseif command.op == "hello" then
		if command.protocolVersion ~= 1 then
			write(
				output,
				Events.error(command.id, { name = "ProtocolError", message = "unsupported adapter protocol version" })
			)
		else
			write(output, {
				protocolVersion = 1,
				id = command.id,
				type = "ready",
				language = "lua",
				implementation = "native-lua-5.1-lua-http",
				runtime = _VERSION,
			})
		end
	elseif command.op == "close" then
		local closing = state.subscriptions
		state.subscriptions = {} -- invalidate every relay before any close can yield
		for _, entry in pairs(closing) do
			entry.subscription:close()
		end
		if state.client then
			state.client:close()
		end
		write(output, { id = command.id, type = "closed" })
		state.closed = true
	elseif command.op == "subscribe" then
		local client, client_error = ensure_client(state)
		if not client then
			write(output, Events.error(command.id, client_error))
		else
			local subscription_id = command.subscriptionId
			if not subscription_id or subscription_id == "" then
				write(
					output,
					Events.error(command.id, { name = "ProtocolError", message = "subscriptionId is required" })
				)
			else
				local previous = state.subscriptions[subscription_id]
				if previous then
					state.subscriptions[subscription_id] = nil -- invalidate before close can yield
					previous.subscription:close()
				end
				local subscription, err = client:subscribe(command.path, command.args or {})
				if not subscription then
					write(output, Events.error(command.id, err))
				else
					state.subscriptions[subscription_id] = { subscription = subscription }
					write(output, { id = command.id, type = "ack" })
				end
			end
		end
	elseif command.op == "unsubscribe" then
		local entry = state.subscriptions[command.subscriptionId]
		state.subscriptions[command.subscriptionId] = nil -- invalidate relay before ack
		local ok, err = true, nil
		if entry then
			ok, err = entry.subscription:close()
		end
		if ok then
			write(output, { id = command.id, type = "ack" })
		else
			write(output, Events.error(command.id, err))
		end
	elseif command.op == "debugDisconnect" then
		local client, client_error = ensure_client(state)
		local ok, err = client and client:debug_disconnect_for_adapter()
		if ok then
			write(output, { id = command.id, type = "ack" })
		else
			write(output, Events.error(command.id, err or client_error))
		end
	else
		if
			command.op ~= "query"
			and command.op ~= "mutation"
			and command.op ~= "action"
			and command.op ~= "setAuth"
		then
			write(output, Events.error(command.id, { name = "ProtocolError", message = "unknown adapter operation" }))
		else
			local client, client_error = ensure_client(state)
			if not client then
				write(output, Events.error(command.id, client_error))
			elseif command.op == "setAuth" then
				client:set_auth(command.token or "")
				write(output, { id = command.id, type = "ack" })
			else
				local result, err = client:call(command.op, command.path, command.args or {})
				if result then
					write(output, Events.result(command.id, result))
				else
					write(output, Events.error(command.id, err))
				end
			end
		end
	end
end

local function drain_live(state, step_owner)
	-- Give TLS/WebSocket readiness a bounded slice while the controller is idle.
	-- A zero-time poll can starve the initial handshake on a quiet connection.
	if step_owner and state.client and state.client.live then
		state.client.live.cq:step(0.1)
	end
	for subscription_id, entry in pairs(state.subscriptions) do
		while true do
			local update = entry.subscription:try_next_update()
			if not update then
				break
			end
			local delivered = Events.deliver_if_current(
				state.subscriptions,
				subscription_id,
				entry,
				update,
				function(current_update)
					if current_update.error then
						local event = Events.error(nil, current_update.error)
						event.type = "subscription"
						event.subscriptionId = subscription_id
						write(state.output, event)
					else
						write(state.output, Events.subscription(subscription_id, current_update))
					end
				end
			)
			if not delivered then
				break
			end
		end
	end
end

local function run_stdio()
	local cq = cqueues.new()
	local state = new_state(assert(cqueue_socket.fdopen(1)))
	state.cq = cq
	local input = assert(cqueue_socket.fdopen(0))
	cq:wrap(function()
		while not state.closed do
			local line = input:read("*l")
			if not line then
				local closing = state.subscriptions
				state.subscriptions = {} -- EOF invalidates relays just like explicit close
				for _, entry in pairs(closing) do
					entry.subscription:close()
				end
				if state.client then
					state.client:close()
				end
				state.closed = true
				break
			end
			process_line(state, line)
		end
	end)
	cq:wrap(function()
		while not state.closed do
			drain_live(state, false)
			cqueues.sleep(0.005)
		end
	end)
	assert(cq:loop())
	-- Explicit close and EOF both perform client cleanup before stopping the
	-- drain coroutine, so reaching here never leaves a Live owner behind.
end

local address = os.getenv("ADAPTER_LISTEN")
if address and address ~= "" then
	local host, port = address:match("^(.+):(%d+)$")
	assert(host and port, "ADAPTER_LISTEN must be host:port")
	local server = assert(socket.bind(host, tonumber(port)))
	local peer = assert(server:accept())
	peer:settimeout(0)
	local state = new_state(peer)
	local partial = ""
	while not state.closed do
		local line, receive_error, fragment = peer:receive("*l", partial)
		partial = fragment or ""
		if line then
			partial = ""
			process_line(state, line)
		elseif receive_error ~= "timeout" then
			break
		end
		drain_live(state, true)
		socket.sleep(0.005)
	end
	if state.client and not state.closed then
		state.client:close()
	end
	peer:close()
	server:close()
else
	run_stdio()
end
