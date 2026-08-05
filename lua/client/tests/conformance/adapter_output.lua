local condition = require("cqueues.condition")
local socket = require("socket")
local json = require("json")

local Output = {}
Output.__index = Output
Output.MAX_PENDING = 256

function Output.new(stream, options)
	options = options or {}
	local max_pending = options.max_pending or Output.MAX_PENDING
	assert(type(max_pending) == "number" and max_pending >= 1 and max_pending % 1 == 0)
	return setmetatable({
		stream = stream,
		queue = {},
		changed = condition.new(),
		finished = false,
		failed = nil,
		max_pending = max_pending,
		tcp_offset = 1,
		now = options.now or socket.gettime,
		wait_writable = options.wait_writable or function(peer, timeout)
			local _, writable, wait_error = socket.select(nil, { peer }, timeout)
			if #writable == 0 then
				return nil, wait_error or "timeout"
			end
			return true
		end,
	}, Output)
end

function Output:_overflow()
	self.failed = "adapter output queue exceeded " .. self.max_pending .. " pending events"
	self.finished = true
	-- Enqueue never waits for capacity because the Live owner may be producing
	-- the event that unblocks a controller lifecycle command. Closing the stalled
	-- stream wakes the sole writer and turns backpressure into a bounded adapter
	-- transport failure instead of deadlocking either side.
	if self.stream.close then
		pcall(function()
			self.stream:close()
		end)
	end
	self.changed:signal(1)
	error(self.failed, 3)
end

-- The generation check and JSON publication happen without yielding. Once a
-- line enters this FIFO, the single writer must finish it before any later ack.
function Output:enqueue(event, subscriptions, subscription_id, entry)
	if entry and subscriptions[subscription_id] ~= entry then
		return false
	end
	if #self.queue >= self.max_pending then
		self:_overflow()
	end
	local encoded, encode_error = json.encode(event)
	assert(encoded, encode_error)
	self.queue[#self.queue + 1] = encoded .. "\n"
	self.changed:signal(1)
	return true
end

function Output:finish()
	self.finished = true
	self.changed:signal(1)
end

function Output:run_stdio()
	while not self.finished or #self.queue > 0 do
		if #self.queue == 0 then
			self.changed:wait()
		else
			-- Keep the in-flight line in the queue so the bound includes a writer
			-- blocked inside the kernel on a stopped stdout reader.
			local line = self.queue[1]
			local ok, write_error = self.stream:write(line)
			assert(ok, write_error)
			if self.stream.flush then
				assert(self.stream:flush())
			end
			table.remove(self.queue, 1)
		end
	end
end

function Output:flush_tcp(timeout)
	local deadline = self.now() + (timeout or 5)
	while #self.queue > 0 do
		local line = self.queue[1]
		local sent, send_error, last_byte = self.stream:send(line, self.tcp_offset)
		if sent then
			table.remove(self.queue, 1)
			self.tcp_offset = 1
		else
			if send_error ~= "timeout" then
				return nil, "write adapter event: " .. tostring(send_error)
			end
			self.tcp_offset = (last_byte or (self.tcp_offset - 1)) + 1
			local remaining = deadline - self.now()
			if remaining <= 0 then
				return nil, "timed out writing adapter event"
			end
			local writable, wait_error = self.wait_writable(self.stream, remaining)
			if not writable then
				return nil, "timed out writing adapter event: " .. tostring(wait_error)
			end
		end
	end
	return true
end

return Output
