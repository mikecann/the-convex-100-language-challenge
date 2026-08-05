# Convex from Lua

This folder demonstrates a deliberately small native Lua client calling Convex
queries, mutations, and actions through the documented JSON HTTP API.

This is educational, unofficial, and not a production SDK. It is an honest
work in progress: no capability badges are earned until the coordinator runs
the shared local and hosted conformance suites.

## Start here

The [basic example](examples/basics/main.lua) reads a counter room and applies
one idempotent increment. The client itself is in [client](client/). Its Docker
images contain Lua, dkjson, lua-http, and cqueues, with no delegated Convex
client or CLI.

## What works

| Surface | Repository state |
| --- | --- |
| JSON HTTP queries, mutations, actions, and bearer auth | Native candidate plus local fixtures; capability unearned |
| Live query subscriptions and reconnects | Native candidate plus deterministic fixtures; capability unearned |
| Canonical `0 -> 1` HTTP and Live journey | Exact runnable source is present; shared evidence pending |
| Earned capabilities | None until the coordinator runs local and hosted conformance |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.lua -->
```text
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
```
<!-- END GENERATED EXAMPLE -->

The block is projected from the runnable source above. Run `./run sync-examples`
after changing it so the README and website show the same code.

## Docker checks

`./run test lua` parses every Lua file, runs local tests, and exercises the
stdin adapter lifecycle inside Docker. `./run build lua` produces the minimal
amd64 adapter runtime image; the shared example verifier builds the separate
`example-runtime` target. The coordinator alone runs shared verification
against the approved test deployments.

## Conformance notes

The adapter speaks NDJSON protocol v1 over stdin/stdout or `ADAPTER_LISTEN`
TCP. HTTP and Live failures are serialized as `FunctionError`, `ProtocolError`,
or `TransportError`. One cqueues owner controls WebSocket reads, writes,
query-set versions, and reconnects. Each subscription keeps the newest 16
updates. The adapter output FIFO holds at most 64 complete events and 8 MiB of
encoded data, including the in-flight stdout write and a conservative per-entry
overhead allowance. A controller that stops reading gets a structured, bounded
adapter transport failure instead of blocking the Live owner. Lua-http supplies
the low-level RFC 6455 framing, fragmented UTF-8,
control-frame, and bounded-close implementation; Convex-specific transitions,
metadata, hydration suppression, and query recovery stay in this Lua client.

The image pins Debian bookworm-slim and BusyBox 1.37.0-musl by digest, Lua
5.1.5, lua-http 0.4-1, cqueues 20200726-1+b1, dkjson 2.6-2, and StyLua 2.5.2.
The final shell is built from checksum-pinned BusyBox source with only the
required shell and text applets compiled in. The Live
wire profile is pinned to `convex-rs-0.10.4-unversioned-sync` at source commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

## Limitations

Values currently cover Convex's JSON-safe subset. Live authentication,
`TransitionChunk` assembly, optimistic updates, and WebSocket mutation replay
are deliberately deferred. This demonstration is tied to the pinned,
undocumented Live profile and should treat protocol drift as an error.
