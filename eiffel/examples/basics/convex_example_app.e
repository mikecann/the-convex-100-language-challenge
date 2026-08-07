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

end
