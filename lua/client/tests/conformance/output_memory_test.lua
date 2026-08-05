package.path = "./client/tests/conformance/?.lua;./client/?.lua;" .. package.path
local cqueues = require("cqueues")
local condition = require("cqueues.condition")
local cqueue_socket = require("cqueues.socket")
local Output = require("adapter_output")

local function read_cgroup_number(name)
	local file = io.open("/sys/fs/cgroup/" .. name, "r")
	if not file then
		return nil
	end
	local value = file:read("*l")
	file:close()
	return tonumber(value)
end

local expected_limit = tonumber(os.getenv("EXPECT_MEMORY_LIMIT_BYTES") or "")
if expected_limit then
	assert(read_cgroup_number("memory.max") == expected_limit, "Docker did not apply the expected memory limit")
end

-- This is a genuinely stopped stdout writer. The first 2 MiB line remains
-- in flight while the producer keeps publishing. The byte budget must fail
-- before the process approaches a 128 MiB container limit, close the stream,
-- and release the writer without waiting for the lifecycle watchdog.
local started = condition.new()
local write_end, stopped_reader = assert(cqueue_socket.pair())
local stream = { closed = false, raw = write_end }
function stream:write(line)
	started:signal(1)
	return self.raw:write(line)
end
function stream:close()
	self.closed = true
	return self.raw:close()
end

local cq = cqueues.new()
local writer = Output.new(stream)
local overflow
local watchdog_fired = false
local payload = string.rep("x", 2 * 1024 * 1024)
cq:wrap(function()
	writer:run_stdio()
end)
cq:wrap(function()
	assert(writer:enqueue({ type = "result", id = "large-1", value = payload }))
	started:wait()
	local index = 2
	while true do
		local ok, failure = pcall(function()
			writer:enqueue({ type = "result", id = "large-" .. index, value = payload })
		end)
		if not ok then
			overflow = failure
			break
		end
		index = index + 1
	end
end)
cq:wrap(function()
	cqueues.sleep(1)
	watchdog_fired = true
	writer:finish()
	stream:close()
end)

local loop_ok = cq:loop()
assert(not loop_ok, "closed stopped-reader writer unexpectedly completed")
assert(not watchdog_fired, "byte overflow blocked the lifecycle watchdog")
assert(type(overflow) == "table" and overflow.name == "TransportError", "overflow was not structured")
assert(overflow.message:match("byte limit"), "the event count fired before the byte budget")
assert(overflow.data.maxPendingBytes == Output.MAX_PENDING_BYTES)
assert(overflow.data.pendingBytes == writer.pending_bytes)
assert(overflow.data.attemptedBytes > 2 * 1024 * 1024)
assert(#writer.queue < Output.MAX_PENDING, "large events reached the event-count bound")
assert(writer.pending_bytes <= Output.MAX_PENDING_BYTES, "retained output exceeded its byte budget")
assert(stream.closed, "byte overflow did not wake the stopped writer")
stopped_reader:close()

local memory_peak = read_cgroup_number("memory.peak")
local expected_peak_ceiling = tonumber(os.getenv("EXPECT_MEMORY_PEAK_BELOW") or "")
if expected_peak_ceiling then
	assert(memory_peak and memory_peak < expected_peak_ceiling, "stopped-reader fixture used too much memory")
end

io.stdout:write(
	string.format(
		"structured byte overflow: pending=%d bytes events=%d memory_peak=%s\n",
		writer.pending_bytes,
		#writer.queue,
		tostring(memory_peak)
	)
)
