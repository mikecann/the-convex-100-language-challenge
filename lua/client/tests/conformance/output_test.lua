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
assert(writer.max_pending == 64 and Output.MAX_PENDING == 64, "default stdout FIFO event bound changed")
assert(
	writer.max_pending_bytes == 8 * 1024 * 1024 and Output.MAX_PENDING_BYTES == 8 * 1024 * 1024,
	"default stdout FIFO byte bound changed"
)
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
assert(#writer.queue == 1 and assert(json.decode(writer.queue[1].line)).type == "ack")

-- A stopped stdout reader must not turn the FIFO into an unbounded mailbox or
-- make the Live owner wait for queue space. The 5th pending event fails fast,
-- closes the stalled stream, and wakes the sole writer with at most 4 retained.
local blocked_started = condition.new()
local blocked_release = condition.new()
local blocked_stream = { closed = false }
function blocked_stream:write()
	blocked_started:signal(1)
	blocked_release:wait()
	if self.closed then
		return nil, "fixture stdout reader stopped"
	end
	return true
end
function blocked_stream:close()
	self.closed = true
	blocked_release:signal(1)
	return true
end

cq = cqueues.new()
writer = Output.new(blocked_stream, { max_pending = 4, max_pending_bytes = 1024 * 1024 })
local overflow_ok, overflow_error
local watchdog_fired = false
cq:wrap(function()
	writer:run_stdio()
end)
cq:wrap(function()
	assert(writer:enqueue({ type = "result", id = "blocked-1", value = 1 }))
	blocked_started:wait()
	for index = 2, 4 do
		assert(writer:enqueue({ type = "result", id = "blocked-" .. index, value = index }))
	end
	overflow_ok, overflow_error = pcall(function()
		writer:enqueue({ type = "result", id = "blocked-5", value = 5 })
	end)
end)
cq:wrap(function()
	cqueues.sleep(0.5)
	watchdog_fired = true
	writer:finish()
	blocked_stream:close()
end)
local loop_ok = cq:loop()
assert(not loop_ok, "closed stdout writer unexpectedly completed")
assert(not watchdog_fired, "stdout overflow waited on the lifecycle watchdog")
assert(not overflow_ok and type(overflow_error) == "table", "stopped reader did not report structured overflow")
assert(overflow_error.name == "TransportError" and overflow_error.message:match("event limit"))
assert(overflow_error.data.maxPendingEvents == 4 and overflow_error.data.pendingEvents == 4)
assert(blocked_stream.closed, "overflow did not close the stalled stdout stream")
assert(#writer.queue == 4, "stdout FIFO exceeded its configured pending-event bound")
assert(writer.pending_bytes <= writer.max_pending_bytes, "stdout FIFO exceeded its configured byte bound")

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
