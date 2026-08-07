# Convex from Eiffel

This Eiffel demonstration queries a Convex counter over HTTP, follows it over
a Live WebSocket subscription, applies one idempotent mutation, and checks
that every view agrees on the move from 0 to 1. Eiffel's design-by-contract
is used where it genuinely expresses this protocol's own invariants — the
`module:function` shape of every call path, the JSON value's own shape
constraints, and the sync engine's subscription bookkeeping — rather than
decorating routines with contracts for their own sake.

It is unofficial educational material, not a production SDK.

## Start here

[`examples/basics/convex_example_app.e`](examples/basics/convex_example_app.e)
follows a counter from 0 to 1: an HTTP query, a Live subscription started
before the mutation so it cannot race past it, the idempotent mutation, and
the resulting Live update arriving without polling again.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action, bearer-token auth, logs, structured errors | Implemented; validated end to end against the project's local Convex backend during development |
| Live subscribe/unsubscribe, initial value, external updates, reconnect after `debugDisconnect` with correct resubscribe and no stale/duplicate events | Implemented; validated end to end against the project's local Convex backend, including a real forced-reconnect scenario |
| NDJSON adapter over stdin or one TCP controller (`ADAPTER_LISTEN`) | Implemented for `hello`, `query`, `mutation`, `action`, `subscribe`, `unsubscribe`, `setAuth`, `debugDisconnect`, `close` |
| Capability badges | Not claimed; the manifest's `capabilities` list is empty until the root integration owner records shared local and hosted conformance evidence |

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

## Docker verification

```sh
./run sync-examples eiffel
./run validate
./run test eiffel
./run build eiffel
```

`sync-examples` proves this displayed source is the runnable source. `validate`
checks the public layout and manifest. `test` builds the toolchain stage,
runs the network-free JSON regression suite, compiles the exact example and
adapter for `linux/amd64`, and smoke-tests the adapter's clean-close path.
`build` produces the final adapter image. The root integration owner
separately runs `verify-example`, local conformance, and hosted conformance
after review.

During development (outside the committed test suite, since it needs a live
deployment) the client, sync engine, WebSocket, and TLS/HTTP transport were
each additionally proven against the project's real local Convex backend and
a real public TLS host: a full HTTP query → Live subscribe → mutation → Live
update round trip, and a genuine forced-reconnect scenario (`debugDisconnect`
followed by an external mutation) that confirms the resubscribed connection
delivers exactly the new value with no stale rehydration event in between.

## Protocol notes and limits

Eiffel owns Convex request encoding and JSON decoding (`convex_json_value.e`,
`convex_json_parser.e`), HTTP/1.1 framing (`convex_http_client.e`), the
`Connect`/`ModifyQuerySet`/`Transition` sync protocol
(`convex_sync.e`), and RFC 6455 WebSocket framing (`convex_websocket.e`).
Mutations and actions always run over HTTP, even while a Live connection is
open, matching this project's other Live-capable native clients: the pinned
`convex-rs-0.10.4-unversioned-sync` profile's `Mutation`/`Action` client
messages are not implemented.

`convex_native.c`/`convex_native.h` are a small ordinary C translation unit
for TCP sockets, TLS (OpenSSL, with certificate and hostname verification),
and `select(2)`, called through Eiffel's plain (non-inline) `"C signature"`
external declarations. This is not the usual way EiffelStudio programs reach
C: its own `"C inline"` feature bodies are the normal, documented mechanism.
This project's toolchain (EiffelStudio 25.02.9.8732) reliably miscompiles a
project once enough classes' inline C bodies get bundled into one
translation unit ("`big_file`"): gcc reports the last bundled class's
functions redeclared with conflicting linkage, because the generated
`big_file_C*_c.c` is one `#include` short of what its own per-class header
promised. Moving TLS, raw sockets, and `select` into an ordinary, separately
compiled `.c` file and declaring plain externals for it sidesteps that
bundling path entirely; `Dockerfile` documents the same finding next to the
build steps it changed. A second, unrelated toolchain finding: EiffelStudio's
incremental `-freeze` ("workbench") runtime reports an ordinary EINTR from a
GC or scheduling signal interrupting `select(2)` as a fatal "operating
system signal" exception and kills the process, instead of the syscall
simply returning to its caller; every target that actually runs is therefore
built with `-finalize` instead (see `convex_native.c`'s `EINTR` retry loops
for the C-side half of the same fix).

The adapter (`client/tests/conformance/`) is a single-threaded event loop:
one `select(2)` call per iteration watches the control stream and, once a
subscription exists, the Live WebSocket's descriptor, so exactly one owner
ever touches either transport (see `convex_sync.e`'s header comment). A
reconnected sync connection resends every active subscription in one
`ModifyQuerySet`, and suppresses delivering that rehydration as a
"subscription" event unless the decoded value or error actually differs from
what was last reported, so a forced reconnect's observable sequence is
exactly initial value, disconnect acknowledgement, external mutation, then
the new value — never a stale duplicate in between.

The build is pinned to EiffelStudio 25.02.9.8732 (the free GPL edition; no
license key, no account) on the digest-pinned Ubuntu 22.04 build image.
Production uses digest-pinned Debian 12 slim with OpenSSL 3.0.20-1~deb12u2
and CA certificates 20230311+deb12u1.

## Limitations

Live authentication, WebSocket mutations, WebSocket actions, optimistic
updates, journals, and `TransitionChunk` assembly are deferred, matching this
project's other Live-capable native clients. The client decodes Convex's
documented JSON-safe value subset only, not the richer tagged
`convex_encoded_json` encoding. The HTTP client requires a `Content-Length`
response header (chunked transfer encoding is not implemented); Convex's own
JSON API always sends one, so this has not been a practical limit in
testing, but it means this client cannot talk to an arbitrary HTTP server.
`Sec-WebSocket-Accept` is not verified against the sent key during the
handshake; only the HTTP `101` status is checked, since this client never
reuses a connection across origins.

No explicit byte or event-count bound is yet enforced on adapter output or
Live delivery queues beyond ordinary process memory; a conservative budget
and a stopped-reader regression (see the Ada and Fortran clients for the
shape of that test) are follow-up work before hosted conformance. The
language-local test suite currently covers the JSON value and parser only;
CONVEX_SOCKET, CONVEX_WEBSOCKET, CONVEX_SYNC, and CONVEX_CLIENT were
validated by hand against a live deployment during development (see "Docker
verification" above) but do not yet have an automated, network-free
regression suite of their own.

The runtime images retain Debian's `/bin/sh` and the small POSIX text-tool
set the shared verifier requires. They contain the compiled Eiffel
executable, its dynamic-library closure (`libc`, `libm`, `libssl`,
`libcrypto`; EiffelStudio's own runtime is statically linked in `-finalize`
mode), CA certificates, and OpenSSL configuration — no compiler, package
manager, Convex CLI, Node.js, Python, or `curl`. Capabilities remain empty in
the manifest until the separate root-owned shared evidence run passes from a
clean reviewed commit.
