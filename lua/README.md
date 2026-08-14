<img src="logo.png" alt="Lua logo" width="128" height="128">
<!-- Logo source: https://www.lua.org/images/lua-logo.gif -->

# Lua

Lua is a small, dynamically typed scripting language created at PUC-Rio in
Brazil in 1993. Its tables act as both arrays and key-value records, while its
C API and compact runtime make it especially useful for embedding in games,
networking tools, and larger applications. The [official Lua site](https://www.lua.org/)
describes it as lightweight, portable, and suited to configuration, scripting,
and rapid prototyping.

This repository contains an educational, unofficial Convex client. It is a
demonstration, not a production SDK or an officially supported Convex package.

## Getting Started

The [canonical basic example](examples/basics/main.lua) reads a counter, starts
a Live subscription, increments the counter, and receives the reactive update.
From the repository root, run:

```sh
./run verify-example lua
```

The command builds the example in Docker and runs that exact Lua file against
a unique test room. You do not need Lua installed on your host.

## Interesting Parts

### Errors ride the second return value

Lua functions can return several values at once, and ever since the standard
`io` library the convention for fallible calls has been `value, err` — no
exceptions, no wrapper type. Every call in this client speaks that protocol:

```lua
-- TypeScript: await client.query("demo:state", { room }) throws on failure.
local current, err = client:query("demo:state", { room = room })
assert(current, err and err.message or "query failed")
print("current count: " .. current.value.count)
```

`assert` collapses the pair back into "crash with a message" — right for a
command-line example, while an embedding app could branch on `err.name`
(`FunctionError`, `TransportError`, ...) and recover instead.

### A class is two lines of metatable

Lua ships no `class` keyword. Objects are plain tables, and a metatable's
`__index` field says where lookups go when a key is missing — that is the
entire object system this client is built on:

```lua
local Convex = {}
Convex.__index = Convex -- missing keys fall through to the Convex table

function Convex.new(deployment_url, options)
	-- ...validate the URL, then bless an ordinary table as a client...
	return setmetatable({ deployment_url = deployment_url, closed = false }, Convex)
end

-- The colon is sugar: client:query(...) passes client as a hidden `self`.
function Convex:query(path, args)
	return self:call("query", path, args)
end
```

Lua's designers kept the core tiny on purpose; you assemble exactly as much
OOP as you need from tables and metatables.

### One table type, so a metatable tells `{}` from `[]`

Lua's single data structure, the table, plays both JSON roles: array and
object. Delightfully economical — until a table is empty and the wire format
must pick `[]` or `{}`. The client settles it with metatable identity:

```lua
-- client/json.lua: dkjson stamps every decoded JSON array with this metatable.
Json.array_mt = { __jsontype = "array" }

function Json.is_array(value)
	return type(value) == "table" and getmetatable(value) == Json.array_mt
end

-- Outbound, hand-written calls pick a side when a table is empty:
local tags = Convex.array({})   -- encodes as []
local extra = Convex.object({}) -- encodes as {}
```

The `{ room = room }` you send and the response you read `.value.count` from
are the same species of value: one table, tagged at the boundary.

### Live updates arrive when you step the loop

One `cqueues` worker — cqueues being Lua's coroutine-based event loop — owns
the Live WebSocket. `next_update` adapts to its caller: inside a running
coroutine it waits on a condition variable; from plain top-level code it steps
the event loop itself until the update lands.

```lua
-- Subscribe before writing so the reactive update cannot be missed.
local subscription = client:subscribe("demo:state", { room = room })
local initial = subscription:next_update(10) -- hydration delivers today's value
print(initial.value.count)

client:mutation("demo:increment", { room = room, language = "lua", runId = run_id })

-- TypeScript: useQuery(api.demo.state, { room }) rerenders on this same push.
local updated = subscription:next_update(10)
print(updated.value.count) -- the write comes back over the socket, no polling
subscription:close() -- Stop this query; client:close() retires the shared worker.
```

React hides subscription lifetime inside the component tree; here it is a
value you hold, wait on, and close.

## Status

| Capability | Evidence-backed status |
| --- | --- |
| HTTP queries, mutations, actions, and bearer authentication | Verified locally and hosted |
| Live subscriptions and reconnects | Verified locally and hosted |
| Canonical `0 -> 1` HTTP and Live journey | Verified against self-hosted and hosted deployments |
| Earned capabilities | HTTP and Live |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.lua -->
```lua
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

## Implementation Notes

- The client targets Lua 5.1.5. `lua-http` provides HTTP, TLS, and WebSocket
  transport, `cqueues` schedules the Live worker, and `dkjson` handles JSON.
  Convex request shapes, errors, subscriptions, reconnects, and result handling
  are implemented in Lua rather than delegated to another Convex client.
- Lua's `client:query(...)` colon syntax passes `client` as the method's first
  argument. Calls return `result, err`, so the example checks errors before
  reading the response wrapper's `value` field.
- One `cqueues` worker owns the Live socket and query set. A subscription keeps
  at most the newest 16 updates, while the conformance adapter separately caps
  output at 64 events and 8 MiB so a stalled reader cannot grow memory without
  bound.
- The Docker build pins Lua and every runtime dependency, then copies only the
  interpreter, required modules, TLS material, the client, and a restricted
  shell into the final `linux/amd64` images. Both final entrypoints run as user
  `65532:65532`.

The repository's Docker gates keep different claims separate: `./run test lua`
checks formatting, parsing, local tests, and adapter startup; `./run
verify-example lua` executes the canonical example. Shared local and hosted
conformance are coordinator-owned checks.

## Known Issues

1. Values are limited to Convex's JSON-safe subset rather than the complete
   Convex value model.
2. Live authentication, `TransitionChunk` assembly, optimistic updates, and
   WebSocket mutation replay are not implemented.
3. Live support follows the pinned, undocumented
   `convex-rs-0.10.4-unversioned-sync` profile at source commit
   `6f1df8a8ba1665084ec001e307ca841ca17074d7`, so protocol drift is treated as
   an error rather than guessed around.
