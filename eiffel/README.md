<img src="logo.png" alt="Eiffel" width="226">
<!-- Logo source: https://www.eiffel.org/theme/responsive-eiffel-org/images/logo.png -->

# Eiffel

Eiffel is a statically typed, object-oriented language built around classes and
Design by Contract: routines can state preconditions and postconditions, while
classes can state invariants. Bertrand Meyer designed it at ISE in 1985 and
introduced it publicly at OOPSLA in 1986. It has been used for industrial
software and teaching, and today occupies a specialist niche around software
correctness, long-lived systems, and EiffelStudio. The [official Eiffel
site](https://www.eiffel.org/) has the language reference and current tools.

This repository uses Eiffel to make a native Convex client with HTTP calls and
Live WebSocket subscriptions. It is unofficial educational material, not a
production SDK.

## Getting Started

The canonical [`examples/basics/convex_example_app.e`](examples/basics/convex_example_app.e)
walkthrough queries a new counter room, subscribes before changing it, applies
one idempotent increment, and receives the new value through the open Live
connection.

From the repository root, run:

```sh
./run verify-example eiffel
```

That command builds the Eiffel example in Docker and runs the exact source shown
later in this README against the project's approved test deployment. You do not
need EiffelStudio installed on your machine.

## Interesting Parts

### The API's one rule is written once, as a contract

Bertrand Meyer designed Eiffel around Design by Contract: a routine states what
it `require`s of its caller, and a violation stops the program at the guilty
call site, naming the broken clause. Convex has exactly one shape rule that
every call shares -- the path must look like `module:function` -- so this
client writes it once as a precondition instead of re-checking it in three
routine bodies.

```eiffel
query (a_path: STRING; a_args: CONVEX_JSON_VALUE): detachable CONVEX_RESULT
		-- TypeScript: the generated `api.demo.state' reference checks this shape at compile time.
	require
		a_path_is_module_colon_function: is_module_colon_function (a_path)
		a_args_attached: a_args /= Void
		a_args_is_object: a_args.is_object
	do
		Result := call_http ("query", a_path, a_args)
	end
```

Pass `"demo/state"` by mistake and the run halts citing
`a_path_is_module_colon_function` -- not a puzzling HTTP error three layers later.

### `detachable` makes the failure branch unskippable

Eiffel is void-safe: a `detachable` type admits `Void` (Eiffel's `null`), and
the compiler refuses to touch such a value until an `attached` test has bound a
provably non-Void name. `query` returns `detachable CONVEX_RESULT` -- Void only
on a transport failure -- so reading the count forces both checks:

```eiffel
state := client.query ("demo:state", args)
	-- TypeScript: const state = await client.query("demo:state", { room })
check attached state as l_state and then l_state.is_success then
	print (l_state.value.field ("count").number_item)
end
```

And `value` carries its own precondition, `require is_success`, so a failed
result refuses to even answer -- the success/failure split is enforced twice.

### Objects are born through named creation procedures

There is no `new ClassName(...)` in Eiffel. A class publishes named creation
procedures -- `CONVEX_JSON_VALUE` lists six, from `make_null` to `make_object`
-- and `create x.make_object` or the inline `create {TYPE}.make_string (...)`
form picks one by name. Building a mutation's arguments reads like a little
bill of materials:

```eiffel
create args.make_object
args.put_field ("room", create {CONVEX_JSON_VALUE}.make_string (room))
args.put_field ("runId", create {CONVEX_JSON_VALUE}.make_string (room + "-once"))
	-- TypeScript: await client.mutation("demo:increment", { room, runId })
mutation_result := client.mutation ("demo:increment", args)
```

`CONVEX_RESULT` goes further: its only creation procedures are `make_success`
and `make_failure`, so a half-initialized result cannot exist.

### The Live loop: commands act, queries answer

Meyer's command-query separation runs through the Live (WebSocket) side:
`ensure_connected` and `poll` are commands that return nothing, while
`pending_events` and `descriptor` are queries -- and since Eiffel will not let
a function's answer be silently discarded, `add_subscription`'s BOOLEAN must be
handled:

```eiffel
if not client.live.add_subscription ("basics", "demo:state", args) then
	fail ("could not start the Live subscription")
end
client.live.ensure_connected
create poll
if poll.wait_readable (client.live.descriptor, 200) then
	client.live.poll (200) -- Appends any pushed update to `pending_events'.
end
	-- TypeScript: useQuery(api.demo.state, { room }) re-renders on the same push
if not client.live.pending_events.is_empty then
	print (client.live.pending_events.first.value.field ("count").number_item)
end
```

The example subscribes before it mutates, so the new count arrives through the
open socket as a genuine server push -- Convex's reactivity, with no re-query.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action, bearer-token auth, logs, structured errors | Implemented; validated end to end against the project's local Convex backend during development |
| Live subscribe/unsubscribe, initial value, external updates, reconnect after `debugDisconnect` with correct resubscribe and no stale/duplicate events | Implemented; validated end to end against the project's local Convex backend, including a real forced-reconnect scenario |
| NDJSON adapter over stdin or one TCP controller (`ADAPTER_LISTEN`) | Implemented for `hello`, `query`, `mutation`, `action`, `subscribe`, `unsubscribe`, `setAuth`, `debugDisconnect`, `close` |
| Capability badges | `http` and `live`, awarded from a 31/31 pass of the shared conformance suite against both the local and hosted deployments |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/convex_example_app.e -->
```eiffel
note
	description: "[
		Convex from Eiffel: the counter-room walkthrough shown in the
		README and on the project website. It queries the current count
		over HTTP, opens a Live subscription before mutating so the
		mutation cannot race past it, applies one idempotent increment,
		and shows the resulting update arriving over the open WebSocket
		without polling again.
	]"

class
	CONVEX_EXAMPLE_APP

create
	make

feature {NONE} -- Initialization

	make
			-- Configuration: read the deployment URL the Docker
			-- verification step supplies, and the room name (the
			-- verifier's unique room id when running under `./run
			-- verify-example', or a friendly default when run by hand).
		local
			deployment_url: detachable STRING
			room: STRING
			client: CONVEX_CLIENT
		do
			ignore_sigpipe
			deployment_url := environment_variable ("CONVEX_URL")
			if deployment_url = Void then
				fail ("CONVEX_URL is required")
			else
				room := room_argument
				-- Client creation: parses the deployment URL and prepares
				-- (without yet connecting) both the HTTP transport and the
				-- Live WebSocket transport this walkthrough uses below.
				create client.make (deployment_url)
				run (client, room)
			end
		end

feature {NONE} -- Walkthrough

	run (client: CONVEX_CLIENT; room: STRING)
		local
			args, mutation_args: CONVEX_JSON_VALUE
			state, mutation_result: detachable CONVEX_RESULT
			initial_count, updated_count: INTEGER
		do
			-- The public test functions this walkthrough calls need no
			-- authentication token, so `set_auth' is not used here; see
			-- CONVEX_CLIENT.set_auth for how a real application would
			-- attach a signed-in user's token.

			-- The initial HTTP query: read the room's current count before
			-- opening the Live subscription, so the printed "current
			-- count" line is provably independent of the WebSocket path
			-- below.
			create args.make_object
			args.put_field ("room", create {CONVEX_JSON_VALUE}.make_string (room))
			state := client.query ("demo:state", args)
			if state = Void or else not state.is_success then
				fail ("unexpected initial HTTP value")
			end
			check attached state as l_state then
				initial_count := decoded_count (l_state.value)
			end
			if initial_count /= 0 then
				fail ("unexpected initial HTTP value")
			end
			print ("current count: 0%N")

			-- Start the Live subscription before mutating: opening
			-- `/api/sync' and receiving this query's first value here,
			-- ahead of the mutation below, is what makes the later
			-- "live updated count" line a genuine reactive update rather
			-- than a second poll.
			if not client.live.add_subscription ("basics", "demo:state", args) then
				fail ("could not start the Live subscription")
			end
			client.live.ensure_connected
			if not wait_for_subscription_value (client, initial_count) then
				fail ("unexpected initial Live value")
			end
			print ("live initial count: 0%N")

			-- The mutation: `runId' is this room's idempotency key, built
			-- from the room name so retrying the exact same mutation call
			-- never double-counts. A fresh room always starts at count 0,
			-- so this is the run that takes it to 1.
			create mutation_args.make_object
			mutation_args.put_field ("room", create {CONVEX_JSON_VALUE}.make_string (room))
			mutation_args.put_field ("language", create {CONVEX_JSON_VALUE}.make_string ("Eiffel"))
			mutation_args.put_field ("runId", create {CONVEX_JSON_VALUE}.make_string (room + "-once"))
			mutation_result := client.mutation ("demo:increment", mutation_args)
			if mutation_result = Void or else not mutation_result.is_success
				or else not mutation_result.value.field ("applied").boolean_item
			then
				fail ("unexpected mutation result")
			end
			print ("mutation applied: true%N")
			check attached mutation_result as l_mutation then
				updated_count := decoded_count (l_mutation.value.field ("state"))
			end
			if updated_count /= 1 then
				fail ("unexpected mutation result")
			end
			print ("mutation count: 1%N")

			-- Wait for the server transition carrying the same updated
			-- counter: this is Convex pushing the change to every open
			-- subscription, not this client asking again.
			if not wait_for_subscription_value (client, updated_count) then
				fail ("unexpected updated Live value")
			end
			print ("live updated count: 1%N")

			-- Unsubscribe first, then close the client so its sole
			-- transport owner stops cleanly and releases the socket.
			if not client.live.remove_subscription ("basics") then
				fail ("could not stop the Live subscription")
			end

			-- Stdout is deliberately just this one final line plus the
			-- five step lines above: the shared verifier compares the
			-- whole transcript, so nothing else may print to stdout.
			print ("verified count: 0 -> 1%N")
		end

	wait_for_subscription_value (client: CONVEX_CLIENT; a_expected_count: INTEGER): BOOLEAN
			-- Poll the Live connection until the "basics" subscription
			-- reports `a_expected_count', or five seconds pass. A single
			-- CONVEX_CLIENT has one Live connection and this example holds
			-- only one subscription on it, so waiting for the very next
			-- value is unambiguous.
		local
			poll: CONVEX_POLL
			deadline_ms: INTEGER
			seen: BOOLEAN
		do
			from deadline_ms := 5000 until seen or deadline_ms <= 0
			loop
				if not client.live.is_connected then
					client.live.ensure_connected
				end
				create poll
				if client.live.is_connected and then poll.wait_readable (client.live.descriptor, 200) then
					client.live.poll (200)
				end
				if not client.live.pending_events.is_empty then
					if not client.live.pending_events.first.is_error
						and then decoded_count (client.live.pending_events.first.value) = a_expected_count
					then
						seen := True
					end
					client.live.pending_events.wipe_out
				end
				deadline_ms := deadline_ms - 200
			end
			Result := seen
		end

feature {NONE} -- Value decoding

	decoded_count (a_state: CONVEX_JSON_VALUE): INTEGER
			-- Decode the room state's `count' field into an ordinary
			-- Eiffel integer. Convex's JSON transport may render a whole
			-- number as "0.0" rather than "0", so this checks the value is
			-- actually integral and in range instead of truncating a
			-- fractional or out-of-range number silently.
		local
			count_field: CONVEX_JSON_VALUE
		do
			count_field := a_state.field ("count")
			if not count_field.is_number or else not count_field.is_integral_in_range (0, 1_000_000) then
				fail ("count was not a small whole number")
			end
			Result := count_field.integer_item.to_integer_32
		end

feature {NONE} -- Helpers

	room_argument: STRING
			-- The room name: the verifier's unique room id when given as
			-- the first command-line argument, or a friendly default for
			-- someone running the image by hand.
		local
			arguments: ARGUMENTS_32
		do
			create arguments
			if arguments.argument_count >= 1 then
				Result := arguments.argument (1).to_string_8
			else
				Result := "eiffel-basic-example"
			end
		end

	environment_variable (a_name: STRING): detachable STRING
		local
			env: EXECUTION_ENVIRONMENT
			wide_value: detachable STRING_32
		do
			create env
			wide_value := env.item (a_name)
			if wide_value /= Void then
				Result := wide_value.to_string_8
			end
		end

	fail (a_message: STRING)
			-- Report `a_message' on stderr and stop with a non-zero exit
			-- status: an unexpected value anywhere in this walkthrough must
			-- fail the run, not print a misleading transcript.
		do
			io.error.put_string (a_message)
			io.error.put_string ("%N")
			(create {EXCEPTIONS}).die (1)
		end

feature {NONE} -- Externals

	ignore_sigpipe
			-- See convex_native.h: a hosted deployment's connection can
			-- reset mid-stream in ordinary operation, and the default
			-- SIGPIPE disposition would otherwise kill this whole process
			-- the moment a write lands on it.
		external
			"C signature () use %"convex_native.h%""
		alias
			"convex_ignore_sigpipe"
		end

end
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native implementation. Eiffel code owns the Convex request envelopes,
JSON parser and encoder, HTTP/1.1 calls, sync state, and WebSocket frames. It does
not call another Convex SDK. A small C support file supplies raw socket I/O,
OpenSSL TLS with certificate and hostname verification, and `select(2)` through
Eiffel's documented external-call mechanism.

The C support file is also a practical EiffelStudio workaround. Version
25.02.9.8732 miscompiled this project's larger inline-C arrangement when it
combined generated classes into a `big_file`, so the native functions are built
as one ordinary translation unit instead. Runnable targets use EiffelStudio's
ahead-of-time `-finalize` mode because the incremental workbench runtime treated
an interrupted blocking call as a fatal signal in this workload.

One owner advances the Live connection. On reconnect it resends every active
subscription and suppresses an unchanged first value, so callers do not mistake
rehydration for a new update. Mutations and actions still use HTTP while that
WebSocket is open. JSON numbers are stored as `REAL_64`; callers that expect a
counter use `is_integral_in_range` before converting values such as `1.0` to an
integer.

The build pins EiffelStudio 25.02.9.8732 and produces `linux/amd64` example and
adapter images. The final images run as user `65532:65532` and retain only the
compiled program, its runtime library closure, CA and OpenSSL data, `/bin/sh`,
and the small POSIX tool set required by the shared verifier.

## Known Issues

1. Live authentication, WebSocket mutations and actions, optimistic updates,
   journals, and `TransitionChunk` assembly are deferred. Mutations and actions
   use HTTP even when Live is connected.
2. Values are limited to Convex's documented JSON-safe subset. The tagged
   `convex_encoded_json` format is not implemented.
3. WebSocket support covers the text-frame subset used by the pinned sync
   profile. Binary frames and extensions are out of scope, and the upgrade
   checks HTTP status `101` without verifying `Sec-WebSocket-Accept`.
4. Live delivery and adapter output have no explicit event-count or byte budget
   beyond process memory. The language-local tests cover JSON behavior, but the
   socket, HTTP, WebSocket, and sync classes do not yet have network-free unit
   fixtures.
5. The HTTP reader requires a `Content-Length` response and does not implement
   chunked transfer encoding.
