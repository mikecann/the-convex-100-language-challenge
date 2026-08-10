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

### A Lua table becomes both the arguments and the returned state

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function RoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-lua" });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**Lua**

```lua
package.path = (os.getenv("CONVEX_CLIENT_PATH") or "./client") .. "/?.lua;" .. package.path
local Convex = require("convex")

local deployment_url = assert(os.getenv("CONVEX_URL"), "CONVEX_URL is required")
local client = assert(Convex.new(deployment_url)) -- Create the HTTP and Live client.

-- Named table fields encode as the Convex function's argument object.
local result, err = client:query("demo:state", { room = "readme-lua" })
assert(result, err and err.message or "query failed")
print(result.value.count) -- Decoded JSON objects are Lua tables too.

client:close()
```

Lua has one general-purpose table type where TypeScript distinguishes object
shapes and arrays. This client uses JSON metatables when an empty `{}` must be
distinguished from an empty `[]`. Also, the Lua `query` above is a one-off HTTP
read. React's `useQuery` stays subscribed and rerenders the component.

### Live updates have an explicit lifetime

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const room = "readme-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function handleIncrement() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The mutation returns the new state.
  }

  if (state === undefined) return <p>Loading...</p>;
  return <button onClick={handleIncrement}>Count: {state.count}</button>;
}
```

**Lua**

```lua
package.path = (os.getenv("CONVEX_CLIENT_PATH") or "./client") .. "/?.lua;" .. package.path
local Convex = require("convex")

local function checked(result, err)
	return assert(result, err and err.message or "Convex call failed")
end

local deployment_url = assert(os.getenv("CONVEX_URL"), "CONVEX_URL is required")
local client = assert(Convex.new(deployment_url))
local room = "readme-live"

-- Subscribe before writing so the update cannot be missed.
local subscription = checked(client:subscribe("demo:state", { room = room }))
local initial = checked(subscription:next_update(10)) -- Wait for hydration.
print(initial.value.count)

local run_id = table.concat({ "lua", room, tostring(os.time()), tostring(math.random()) }, ":")
local mutation = checked(client:mutation("demo:increment", {
	room = room,
	language = "lua",
	runId = run_id,
}))
print(mutation.value.state.count) -- Decode the mutation's returned state.

local updated = checked(subscription:next_update(10)) -- Wait for the reactive value.
print(updated.value.count)

checked(subscription:close()) -- Stop this query explicitly.
client:close() -- Retire the shared Live worker and its socket.
```

React owns the subscription while the component is mounted. The Lua client
instead exposes a blocking `next_update` call and explicit cleanup, an API
choice that suits a command-line example rather than a limitation of Lua.

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
