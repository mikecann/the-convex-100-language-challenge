package.path = "./client/?.lua;" .. package.path
local json = require("json")
local errno = require("cqueues.errno")
local Live = require("live")

assert(json.is_array(assert(json.decode("[]"))), "decoded JSON array lost its identity")
assert(not json.is_array(assert(json.decode("{}"))), "decoded JSON object passed the array predicate")
assert(not json.is_array({}), "untagged Lua table passed the JSON array predicate")

local function assert_equal(actual, expected, label)
	assert(
		actual == expected,
		string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual))
	)
end

local FakeSocket = {}
FakeSocket.__index = FakeSocket

function FakeSocket.new(server)
	local instance = setmetatable(
		{ server = server, incoming = {}, closed = false, request = { headers = { append = function() end } } },
		FakeSocket
	)
	instance.socket = {
		shutdown = function() end,
		close = function()
			instance.closed = true
			instance.forced_closed = true
		end,
	}
	return instance
end

function FakeSocket:connect()
	if self.server.connect_failures and self.server.connect_failures > 0 then
		self.server.connect_failures = self.server.connect_failures - 1
		return nil, "fixture handshake failure"
	end
	self.server.connections[#self.server.connections + 1] = self
	return true
end

function FakeSocket:send(payload)
	local message = assert(json.decode(payload))
	self.server.sent[#self.server.sent + 1] = message
	if message.type == "ModifyQuerySet" then
		local modification_type = message.modifications[1] and message.modifications[1].type
		if self.server.fail_next_modify == modification_type then
			self.server.fail_next_modify = nil
			return nil, self.server.fail_message or "fixture query-set write failure"
		end
		self.server:on_modify(self, message)
	end
	return true
end

function FakeSocket:receive()
	if self.closed then
		return nil, "closed", 0
	end
	if self.fail_receive then
		self.fail_receive = false
		return nil, "fixture transport cut", 0
	end
	if #self.incoming == 0 then
		require("cqueues").sleep(0.001)
		return nil, "timeout", errno.ETIMEDOUT
	end
	return json.encode(table.remove(self.incoming, 1)), "text"
end

function FakeSocket:close(_, reason)
	assert(#reason <= 123, "fixture rejected an oversized close reason")
	self.close_reason = reason
	if self.server.fail_next_close then
		self.server.fail_next_close = false
		error("fixture graceful close failure")
	end
	if self.server.fail_next_close_return then
		self.server.fail_next_close_return = false
		return nil, "fixture graceful close returned failure"
	end
	self.closed = true
	return true
end

local function transition(start_query_set, end_query_set, start_ts, end_ts, modification)
	return {
		type = "Transition",
		startVersion = { querySet = start_query_set, identity = 0, ts = start_ts },
		endVersion = { querySet = end_query_set, identity = 0, ts = end_ts },
		modifications = { modification },
	}
end

local function server_for_updates()
	local server = { connections = {}, sent = {}, generation = 0 }
	function server:new_socket()
		return FakeSocket.new(self)
	end
	function server:on_modify(socket, message)
		local change = message.modifications[1]
		if change.type == "Add" and not self.suppress_add_update then
			self.generation = self.generation + 1
			socket.incoming[#socket.incoming + 1] = transition(0, message.newVersion, "AAAAAAAAAAA=", "AQAAAAAAAAA=", {
				type = "QueryUpdated",
				queryId = change.queryId,
				value = { count = self.hydration_count or 0 },
				logLines = {},
			})
		end
	end
	return server
end

-- One owner sends Add, delivers initial/external values, reports QueryFailed,
-- recovers the same subscription, and sends Remove before close acknowledges.
local server = server_for_updates()
local manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
local subscription = assert(manager:subscribe("demo:state", { room = "unit" }))
assert_equal(assert(subscription:next_update(1)).value.count, 0, "initial value")
local socket = server.connections[1]
socket.incoming[#socket.incoming + 1] = transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", {
	type = "QueryUpdated",
	queryId = subscription.query_id,
	value = { count = 1 },
	logLines = {},
})
assert_equal(assert(subscription:next_update(1)).value.count, 1, "external value")
socket.incoming[#socket.incoming + 1] = transition(1, 1, "AgAAAAAAAAA=", "AwAAAAAAAAA=", {
	type = "QueryFailed",
	queryId = subscription.query_id,
	errorMessage = "fixture failure",
	errorData = { code = "TEST" },
	logLines = { "failure log" },
})
assert_equal(assert(subscription:next_update(1)).error.name, "FunctionError", "query failure")
socket.incoming[#socket.incoming + 1] = transition(1, 1, "AwAAAAAAAAA=", "BAAAAAAAAAA=", {
	type = "QueryUpdated",
	queryId = subscription.query_id,
	value = { count = 2 },
	logLines = {},
})
assert_equal(assert(subscription:next_update(1)).value.count, 2, "query recovery")
local close_ok, close_error = subscription:close()
if not close_ok then
	error(close_error.message or tostring(close_error))
end
assert_equal(server.sent[#server.sent].modifications[1].type, "Remove", "remove")
assert(manager:close())

-- Manager shutdown uses the same retirement path as reconnects. A graceful
-- close exception or false return must still close the underlying transport.
for _, failure_kind in ipairs({ "fail_next_close", "fail_next_close_return" }) do
	server = server_for_updates()
	manager = Live.Manager.new("http://unit.test", "lua-test", {
		websocket_factory = function()
			return server:new_socket()
		end,
	})
	subscription = assert(manager:subscribe("demo:state", { room = "manager-close-" .. failure_kind }))
	assert_equal(assert(subscription:next_update(1)).value.count, 0)
	local closing_socket = server.connections[1]
	server[failure_kind] = true
	assert(manager:close())
	assert(closing_socket.closed, "Manager close left the underlying transport open")
	assert(closing_socket.forced_closed, "Manager close did not force transport retirement")
end

-- A failed Add may already have reached the server. The client rejects that
-- subscription, retires the uncertain socket, reports a structured failure to
-- the remaining subscription, and replays only the still-active Add.
server = server_for_updates()
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
local survivor = assert(manager:subscribe("demo:state", { room = "add-write-survivor" }))
assert_equal(assert(survivor:next_update(1)).value.count, 0)
local uncertain_socket = server.connections[1]
server.fail_next_modify = "Add"
server.fail_message = string.rep("long transport failure ", 12)
server.fail_next_close = true
local rejected, add_write_error = manager:subscribe("demo:state", { room = "failed-add" })
assert(rejected == nil and add_write_error.name == "TransportError", "failed Add was not structured")
assert(uncertain_socket.closed and manager.socket == nil, "failed Add retained the uncertain socket")
assert(uncertain_socket.forced_closed, "failed graceful close did not force the transport closed")
assert(#uncertain_socket.close_reason <= 123, "failed Add sent an oversized close reason")
assert(#manager.last_close_reason > 123, "close-frame truncation also truncated connection metadata")
assert_equal(assert(survivor:next_update(1)).error.name, "TransportError", "survivor missed Add failure")
local deadline = require("cqueues").monotime() + 2
while #server.connections < 2 and require("cqueues").monotime() < deadline do
	manager.cq:step(0.2)
end
assert_equal(#server.connections, 2, "failed Add did not reconnect")
local replay = server.sent[#server.sent]
assert_equal(#replay.modifications, 1, "failed Add replayed a rejected query")
assert_equal(replay.modifications[1].queryId, survivor.query_id, "failed Add omitted the survivor")
assert(survivor:try_next_update() == nil, "replayed Add leaked unchanged hydration")

-- A failed Remove follows the same rule. The removed query stays invalidated,
-- while the surviving query is replayed on a fresh connection and recovers.
server.suppress_add_update = true
server.fail_message = nil
local removed = assert(manager:subscribe("demo:state", { room = "failed-remove" }))
server.fail_next_modify = "Remove"
local remove_ok, remove_error = removed:close()
assert(remove_ok == nil and remove_error.name == "TransportError", "failed Remove was not structured")
assert(server.connections[2].closed and manager.socket == nil, "failed Remove retained the uncertain socket")
assert_equal(assert(survivor:next_update(1)).error.name, "TransportError", "survivor missed Remove failure")
server.suppress_add_update = false
deadline = require("cqueues").monotime() + 2
while #server.connections < 3 and require("cqueues").monotime() < deadline do
	manager.cq:step(0.2)
end
assert_equal(#server.connections, 3, "failed Remove did not reconnect")
replay = server.sent[#server.sent]
assert_equal(#replay.modifications, 1, "failed Remove replayed an invalidated query")
assert_equal(replay.modifications[1].queryId, survivor.query_id, "failed Remove omitted the survivor")
server.connections[3].incoming[#server.connections[3].incoming + 1] = transition(
	1,
	1,
	"AQAAAAAAAAA=",
	"AgAAAAAAAAA=",
	{ type = "QueryUpdated", queryId = survivor.query_id, value = { count = 1 }, logLines = {} }
)
assert_equal(assert(survivor:next_update(1)).value.count, 1, "Remove failure stranded the survivor")
assert(manager:close())

-- Reconnect five times. Each Connect carries monotonically increasing metadata,
-- every connection resends Add, and unchanged hydration never crosses the
-- debugDisconnect acknowledgement as a duplicate application update.
server = server_for_updates()
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
subscription = assert(manager:subscribe("demo:state", { room = "reconnect" }))
assert_equal(assert(subscription:next_update(1)).value.count, 0)
for expected = 1, 5 do
	assert(manager:debug_disconnect())
	local deadline = require("cqueues").monotime() + 2
	while #server.connections < expected + 1 and require("cqueues").monotime() < deadline do
		manager.cq:step(0.2)
	end
	assert_equal(#server.connections, expected + 1, "connection count")
	assert(subscription:try_next_update() == nil, "unchanged hydration leaked after reconnect")
end
local connect_count, add_count = 0, 0
for _, message in ipairs(server.sent) do
	if message.type == "Connect" then
		assert_equal(message.connectionCount, connect_count, "Connect.connectionCount")
		if connect_count > 0 then
			assert(message.maxObservedTimestamp, "reconnect omitted maxObservedTimestamp")
			assert_equal(message.lastCloseReason, "DebugDisconnect", "Connect.lastCloseReason")
		end
		connect_count = connect_count + 1
	elseif message.type == "ModifyQuerySet" and message.modifications[1].type == "Add" then
		add_count = add_count + 1
	end
end
assert_equal(connect_count, 6, "six total connects")
assert_equal(add_count, 6, "Add replay count")
assert(manager:close())

-- Two failed handshakes grow transport backoff. A later healthy handshake
-- resets it, so the next outage does not inherit the older delay.
server = server_for_updates()
server.connect_failures = 2
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
subscription = assert(manager:subscribe("demo:state", { room = "backoff-reset" }))
assert_equal(assert(subscription:next_update(1)).error.name, "TransportError", "first connect failure")
assert_equal(assert(subscription:next_update(1)).error.name, "TransportError", "second connect failure")
assert_equal(assert(subscription:next_update(2)).value.count, 0, "post-backoff hydration")
assert_equal(manager.next_backoff, 0.1, "healthy handshake resets transport backoff")
assert(manager:close())

-- Convex protocol 0.10.4 sends QueryRemoved with only its type and queryId.
-- Accept that canonical shape without manufacturing a log array, advance the
-- version atomically, and remove the cached result without a stale delivery.
server = server_for_updates()
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
subscription = assert(manager:subscribe("demo:state", { room = "canonical-query-removed" }))
assert_equal(assert(subscription:next_update(1)).value.count, 0)
socket = server.connections[1]
socket.incoming[#socket.incoming + 1] = transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", {
	type = "QueryRemoved",
	queryId = subscription.query_id,
})
assert(manager:_receive())
assert_equal(manager.remote_version.querySet, 1, "QueryRemoved changed query-set version")
assert_equal(manager.remote_version.ts, "AgAAAAAAAAA=", "QueryRemoved did not advance timestamp")
assert(manager.remote_results[subscription.query_id] == nil, "QueryRemoved retained the cached result")
assert_equal(manager.max_observed_timestamp, "AgAAAAAAAAA=", "QueryRemoved did not advance max timestamp")
assert(subscription:try_next_update() == nil, "QueryRemoved emitted a stale subscription value")
assert(manager:close())

-- dkjson distinguishes JSON arrays and objects with metatables. Reject an
-- object-shaped modifications field, object-shaped logLines, and non-string
-- log entries before advancing any version, cached result, timestamp, backoff,
-- or subscription delivery state.
server = server_for_updates()
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
subscription = assert(manager:subscribe("demo:state", { room = "malformed-transition-shapes" }))
assert_equal(assert(subscription:next_update(1)).value.count, 0)
socket = server.connections[1]
local initial_remote_results = manager.remote_results
local initial_remote_result = manager.remote_results[subscription.query_id]
local initial_last_delivered = manager.subscriptions[subscription.query_id].last_delivered
local malformed_transitions = {
	{
		label = "object modifications",
		message = {
			type = "Transition",
			startVersion = { querySet = 1, identity = 0, ts = "AQAAAAAAAAA=" },
			endVersion = { querySet = 1, identity = 0, ts = "AgAAAAAAAAA=" },
			modifications = json.object({}),
		},
		error_pattern = "modifications must be an array",
	},
	{
		label = "object logLines",
		message = transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", {
			type = "QueryUpdated",
			queryId = subscription.query_id,
			value = { count = 99 },
			logLines = json.object({}),
		}),
		error_pattern = "logLines must be an array",
	},
	{
		label = "missing logLines",
		message = transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", {
			type = "QueryUpdated",
			queryId = subscription.query_id,
			value = { count = 99 },
		}),
		error_pattern = "logLines must be an array",
	},
	{
		label = "non-string logLines entry",
		message = transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", {
			type = "QueryUpdated",
			queryId = subscription.query_id,
			value = { count = 99 },
			logLines = { "valid", 7 },
		}),
		error_pattern = "logLines entries must be strings",
	},
	{
		label = "valid update before QueryRemoved with logLines",
		message = {
			type = "Transition",
			startVersion = { querySet = 1, identity = 0, ts = "AQAAAAAAAAA=" },
			endVersion = { querySet = 1, identity = 0, ts = "AgAAAAAAAAA=" },
			modifications = {
				{
					type = "QueryUpdated",
					queryId = subscription.query_id,
					value = { count = 99 },
					logLines = {},
				},
				{
					type = "QueryRemoved",
					queryId = subscription.query_id,
					logLines = {},
				},
			},
		},
		error_pattern = "QueryRemoved must not include logLines",
	},
}
for _, fixture in ipairs(malformed_transitions) do
	manager.next_backoff = 7
	socket.incoming[#socket.incoming + 1] = fixture.message
	local accepted, protocol_error = manager:_receive()
	assert(accepted == nil and protocol_error.name == "ProtocolError", fixture.label .. " was accepted")
	assert(protocol_error.message:match(fixture.error_pattern), fixture.label .. " reported the wrong failure")
	assert_equal(manager.remote_version.querySet, 1, fixture.label .. " changed query-set version")
	assert_equal(manager.remote_version.ts, "AQAAAAAAAAA=", fixture.label .. " changed timestamp")
	assert(manager.remote_results == initial_remote_results, fixture.label .. " replaced cached results")
	assert(
		manager.remote_results[subscription.query_id] == initial_remote_result,
		fixture.label .. " changed cached query state"
	)
	assert_equal(manager.max_observed_timestamp, "AQAAAAAAAAA=", fixture.label .. " changed max timestamp")
	assert(
		manager.subscriptions[subscription.query_id].last_delivered == initial_last_delivered,
		fixture.label .. " changed delivered state"
	)
	assert_equal(manager.next_backoff, 7, fixture.label .. " reset backoff before validation")
	assert(subscription:try_next_update() == nil, fixture.label .. " emitted an invalid subscription event")
end
assert(manager:close())

-- A protocol error is a typed subscription event, not a permanent strand.
-- The owner reconnects, suppresses unchanged hydration, resets backoff after a
-- valid transition, and the same subscription delivers a later value.
server = server_for_updates()
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
subscription = assert(manager:subscribe("demo:state", { room = "protocol-recovery" }))
assert_equal(assert(subscription:next_update(1)).value.count, 0)
server.connections[1].incoming[#server.connections[1].incoming + 1] =
	transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", { type = "QueryUpdated", value = { count = 99 } })
assert_equal(assert(subscription:next_update(1)).error.name, "ProtocolError", "protocol error")
local deadline = require("cqueues").monotime() + 2
while #server.connections < 2 and require("cqueues").monotime() < deadline do
	manager.cq:step(0.2)
end
local recovered_socket = server.connections[2]
assert(recovered_socket, "protocol reconnect did not occur")
recovered_socket.incoming[#recovered_socket.incoming + 1] = transition(1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", {
	type = "QueryUpdated",
	queryId = subscription.query_id,
	value = { count = 3 },
	logLines = {},
})
assert_equal(assert(subscription:next_update(1)).value.count, 3, "protocol recovery value")
assert_equal(manager.next_backoff, 0.1, "healthy transition resets backoff")

-- A transport failure follows the same recovery path and does not discard the
-- active Add. The subsequent connection can deliver a later valid value.
server.hydration_count = 3
recovered_socket.fail_receive = true
assert_equal(assert(subscription:next_update(1)).error.name, "TransportError", "transport error")
deadline = require("cqueues").monotime() + 2
while #server.connections < 3 and require("cqueues").monotime() < deadline do
	manager.cq:step(0.2)
end
recovered_socket = server.connections[3]
assert(recovered_socket, "transport reconnect did not occur")
while #recovered_socket.incoming > 0 do
	manager.cq:step(0.2)
end
assert_equal(manager.max_observed_timestamp, "AgAAAAAAAAA=", "hydration moved max timestamp backwards")
recovered_socket.incoming[#recovered_socket.incoming + 1] = transition(1, 1, "AQAAAAAAAAA=", "BAAAAAAAAAA=", {
	type = "QueryUpdated",
	queryId = subscription.query_id,
	value = { count = 4 },
	logLines = {},
})
assert_equal(assert(subscription:next_update(1)).value.count, 4, "transport recovery value")
assert(manager:close())

-- Close remains bounded while the owner is waiting on an idle/partial read.
-- lua-http preserves its parser state across the 100 ms receive deadline; the
-- owner gets a command turn instead of being stranded inside the frame.
server = server_for_updates()
manager = Live.Manager.new("http://unit.test", "lua-test", {
	websocket_factory = function()
		return server:new_socket()
	end,
})
subscription = assert(manager:subscribe("demo:state", { room = "bounded-close" }))
assert_equal(assert(subscription:next_update(1)).value.count, 0)
local close_started = require("cqueues").monotime()
assert(manager:close())
assert(require("cqueues").monotime() - close_started < 0.75, "close exceeded its bounded deadline")

-- The subscription owns a newest-16 queue. Overflow drops only the oldest
-- value and close invalidates all queued delivery before acknowledging.
local inert = {
	unsubscribe = function()
		return true
	end,
	cq = require("cqueues").new(),
}
subscription = Live.Subscription.new(inert, 9)
for count = 0, 16 do
	subscription:_deliver({ value = { count = count }, logs = {} })
end
for expected = 1, 16 do
	assert_equal(assert(subscription:next_update(0)).value.count, expected, "bounded queue")
end
subscription:_deliver({ value = { count = 99 }, logs = {} })
subscription:_finish()
assert(subscription:try_next_update() == nil, "finished subscription retained a stale update")

-- This models the relay pause after dequeue: invalidating the old generation
-- before replacement acknowledgement makes a late delivery a no-op.
local old_subscription = Live.Subscription.new(inert, 10)
old_subscription:_finish()
old_subscription:_deliver({ value = { count = 100 }, logs = {} })
assert(old_subscription:try_next_update() == nil, "replaced subscription accepted a stale relay")
