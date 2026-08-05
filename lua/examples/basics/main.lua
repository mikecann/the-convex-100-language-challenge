#!/usr/local/bin/lua
package.path = (os.getenv("CONVEX_CLIENT_PATH") or "./client") .. "/?.lua;" .. package.path
local Convex = require("convex")

local function checked(result, err)
	if result and type(result) ~= "table" then
		return result
	end
	if result and not result.error then
		return result
	end
	if result and result.error then
		err = result.error
	end
	error((err and err.name or "Error") .. ": " .. (err and err.message or "unknown failure"))
end

local function checked_count(value, operation)
	if type(value) ~= "number" or value % 1 ~= 0 then
		error(operation .. " count must be a whole number")
	end
	return value
end

local function main()
	local deployment_url = assert(os.getenv("CONVEX_URL"), "CONVEX_URL is required")
	-- Create a native Lua client for the test deployment.
	local client = assert(Convex.new(deployment_url))
	-- The verifier supplies a unique room so independent runs never collide.
	local room = arg[1] or "lua-example"
	-- Read the room's starting state through Convex's documented HTTP query API.
	local current = checked(client:query("demo:state", { room = room }))
	-- Lua's JSON decoder produces an idiomatic table, so validate its count
	-- before using it as application state or machine-checked output.
	local initial = checked_count(current.value.count, "current query")
	print("current count: " .. initial)

	-- Start Live before the mutation so no change can land between subscribing
	-- and listening for the room's reactive state.
	local subscription = checked(client:subscribe("demo:state", { room = room }))
	-- Convex first hydrates a Live query with its current value. It must agree
	-- with the HTTP query before this example writes anything.
	local live_initial = checked(subscription:next_update(10))
	local live_initial_count = checked_count(live_initial.value.count, "initial Live value")
	assert(live_initial_count == initial, "initial Live value disagreed with HTTP")
	print("live initial count: " .. live_initial_count)

	-- The runId is the mutation's idempotency key. Reusing it would return the
	-- same logical write instead of incrementing this room twice.
	local run_id = table.concat({ "lua", room, tostring(os.time()), tostring(math.random(1, 2147483646)) }, ":")
	local mutation = checked(client:mutation("demo:increment", { room = room, language = "lua", runId = run_id }))
	assert(mutation.value.applied == true, "mutation was not applied")
	local changed = checked_count(mutation.value.state.count, "mutation")
	assert(changed == initial + 1, "mutation count did not advance by one")
	print("mutation applied: true")
	print("mutation count: " .. changed)

	-- Receive the resulting change from Live, without polling through HTTP.
	local live_changed = checked(subscription:next_update(10))
	local live_changed_count = checked_count(live_changed.value.count, "updated Live value")
	assert(live_changed_count == changed, "updated Live value disagreed with mutation")
	print("live updated count: " .. live_changed_count)
	-- Only print verification after HTTP and Live agree on the complete journey.
	print("verified count: " .. initial .. " -> " .. live_changed_count)

	-- Stop this query before closing the shared client worker.
	checked(subscription:close())
	client:close()
end

main()
