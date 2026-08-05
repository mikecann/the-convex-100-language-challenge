package.path = "./client/tests/conformance/?.lua;./client/?.lua;" .. package.path
local cqueues = require("cqueues")
local condition = require("cqueues.condition")
local json = require("json")
local Output = require("adapter_output")

-- Pause inside the actual stdout write. An already-published subscription line
-- must finish before an acknowledgement that invalidates its generation.
local started = condition.new()
local release = condition.new()
local lines = {}
local stream = { paused = false }
function stream:write(line)
	if not self.paused then
		self.paused = true
		started:signal(1)
		release:wait()
	end
	lines[#lines + 1] = assert(json.decode(line))
	return true
end
function stream:flush()
	return true
end

local cq = cqueues.new()
local writer = Output.new(stream)
local entry = {}
local subscriptions = { counter = entry }
cq:wrap(function()
	writer:run_stdio()
end)
cq:wrap(function()
	assert(
		writer:enqueue(
			{ type = "subscription", subscriptionId = "counter", value = 1 },
			subscriptions,
			"counter",
			entry
		)
	)
	started:wait()
	subscriptions.counter = nil
	assert(writer:enqueue({ type = "ack", id = "unsubscribe" }))
	release:signal(1)
	writer:finish()
end)
assert(cq:loop())
assert(lines[1].type == "subscription" and lines[2].type == "ack", "ack overtook a started relay write")

-- If invalidation wins before publication, the stale generation never enters
-- the writer queue and only the acknowledgement is emitted.
writer = Output.new({})
subscriptions.counter = entry
subscriptions.counter = nil
assert(
	not writer:enqueue(
		{ type = "subscription", subscriptionId = "counter", value = 2 },
		subscriptions,
		"counter",
		entry
	)
)
assert(writer:enqueue({ type = "ack", id = "replacement" }))
assert(#writer.queue == 1 and assert(json.decode(writer.queue[1])).type == "ack")

-- LuaSocket reports a partial last-byte index on nonblocking timeout. Resume
-- from that exact byte until one complete NDJSON line reaches the peer.
local tcp = { received = "", chunk = 7 }
function tcp:send(data, first)
	local last = math.min(first + self.chunk - 1, #data)
	self.received = self.received .. data:sub(first, last)
	if last < #data then
		return nil, "timeout", last
	end
	return last
end
writer = Output.new(tcp, {
	wait_writable = function()
		return true
	end,
})
local event = { id = "large", type = "result", value = string.rep("x", 128) }
local expected = assert(json.encode(event)) .. "\n"
assert(writer:enqueue(event))
assert(writer:flush_tcp(1))
assert(tcp.received == expected, "partial TCP sends truncated or duplicated NDJSON")

-- Backpressure is bounded even when the peer never becomes writable.
local clock = 0
tcp = {}
function tcp:send(_, first)
	return nil, "timeout", first - 1
end
writer = Output.new(tcp, {
	now = function()
		clock = clock + 0.6
		return clock
	end,
	wait_writable = function()
		return true
	end,
})
assert(writer:enqueue(event))
local flushed, flush_error = writer:flush_tcp(1)
assert(flushed == nil and flush_error:match("timed out"), "permanent TCP backpressure was not bounded")
