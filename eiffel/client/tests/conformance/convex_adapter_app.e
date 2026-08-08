note
	description: "[
		The test-only executable that exposes CONVEX_CLIENT through NDJSON
		adapter protocol v1 (see docs/conformance.md in the repository
		root) for the shared black-box controller. It is not part of the
		public client API: `client/tests/conformance/' code is test
		infrastructure the educational client never imports.

		This process is CONVEX_SYNC's one I/O owner (see that class's
		header comment): the loop below is the single thread that ever
		touches the control stream or the Live WebSocket, alternating
		between them with one bounded `select' per iteration so neither a
		silent controller nor a stalled server can block the other.
	]"

class
	CONVEX_ADAPTER_APP

create
	make

feature {NONE} -- Initialization

	make
		local
			deployment_url: detachable STRING
			listen_spec: detachable STRING
		do
			ignore_sigpipe
			deployment_url := environment_variable ("CONVEX_URL")
			listen_spec := environment_variable ("ADAPTER_LISTEN")
			if listen_spec = Void then
				create control.make_stdio
			else
				create control.make_listening (listen_spec)
			end
			if deployment_url = Void then
				create client.make ("http://127.0.0.1:1")
				io.error.put_string ("CONVEX_URL is required%N")
			else
				create client.make (deployment_url)
				if control.is_ready then
					run_loop
				end
			end
		end

feature {NONE} -- Main loop

	client: CONVEX_CLIENT
	control: CONVEX_CONTROL_STREAM
	closed: BOOLEAN

	run_loop
		local
			poll: CONVEX_POLL
			readiness: INTEGER
			live_fd: INTEGER
			line: detachable STRING
		do
			from until closed
			loop
				maybe_ensure_live_connected
				live_fd := -1
				if live_open then
					live_fd := client.live.descriptor
				end
				if control.has_buffered_line or else (live_open and then client.live.has_pending_bytes) then
					readiness := 3
				else
					create poll
					readiness := poll.wait_readable_two (control.descriptor, live_fd, poll_interval_ms)
				end
				if readiness.bit_and (1) /= 0 or else control.has_buffered_line then
					line := control.read_line (0)
					if line /= Void then
						handle_line (line)
					end
				end
				if live_open and then (readiness.bit_and (2) /= 0 or else client.live.has_pending_bytes) then
					client.live.poll (0)
					drain_live_events
				end
			end
		end

	poll_interval_ms: INTEGER = 200

	live_open: BOOLEAN
		do
			Result := live_created and then client.live.is_connected
		end

	live_created: BOOLEAN
			-- Has `subscribe' ever been requested? Kept separate from
			-- `client.live.is_connected' so a client that never subscribed
			-- does not needlessly open (or keep retrying) a sync socket.

	maybe_ensure_live_connected
		do
			if live_created and then not client.live.is_connected then
				client.live.ensure_connected
			end
		end

	drain_live_events
		local
			i: INTEGER
			event: CONVEX_SYNC_EVENT
		do
			from i := 1 until i > client.live.pending_events.count
			loop
				event := client.live.pending_events.i_th (i)
				if event.is_error then
					send_subscription_error (event.subscription_id, event.error_message, event.error_data)
				else
					send_subscription_value (event.subscription_id, event.value)
				end
				i := i + 1
			end
			client.live.pending_events.wipe_out
		end

feature {NONE} -- Command dispatch

	handle_line (a_line: STRING)
		local
			parser: CONVEX_JSON_PARSER
			command: CONVEX_JSON_VALUE
			op: detachable STRING
			id: detachable STRING
		do
			create parser.make
			parser.parse (a_line)
			if not parser.successful or else not attached parser.last_value as l_command or else not l_command.is_object then
				send_protocol_error (Void, "malformed request")
			else
				command := l_command
				op := string_field (command, "op")
				id := string_field (command, "id")
				if op = Void then
					send_protocol_error (id, "missing op")
				elseif id = Void or else id.is_empty or else id.count > 128 then
					send_protocol_error (Void, "id must contain 1 to 128 Unicode characters")
				elseif op.is_equal ("hello") then
					handle_hello (command, id)
				elseif op.is_equal ("query") or op.is_equal ("mutation") or op.is_equal ("action") then
					handle_call (op, command, id)
				elseif op.is_equal ("subscribe") then
					handle_subscribe (command, id)
				elseif op.is_equal ("unsubscribe") then
					handle_unsubscribe (command, id)
				elseif op.is_equal ("setAuth") then
					handle_set_auth (command, id)
				elseif op.is_equal ("debugDisconnect") then
					handle_debug_disconnect (id)
				elseif op.is_equal ("close") then
					handle_close (id)
				else
					send_protocol_error (id, "unknown operation: " + op)
				end
			end
		end

	handle_hello (a_command: CONVEX_JSON_VALUE; a_id: STRING)
		local
			version: detachable CONVEX_JSON_VALUE
		do
			if a_command.has_field ("protocolVersion") then
				version := a_command.field ("protocolVersion")
			end
			if version /= Void and then version.is_number and then version.is_integral_in_range (1, 1) then
				send_ready (a_id)
			else
				send_protocol_error (a_id, "unsupported protocol version")
			end
		end

	handle_call (a_op: STRING; a_command: CONVEX_JSON_VALUE; a_id: STRING)
		local
			path: detachable STRING
			args: detachable CONVEX_JSON_VALUE
			call_result: detachable CONVEX_RESULT
		do
			path := string_field (a_command, "path")
			if a_command.has_field ("args") and then a_command.field ("args").is_object then
				args := a_command.field ("args")
			end
			if path = Void or else args = Void or else not client.is_module_colon_function (path) then
				send_protocol_error (a_id, "invalid call request")
			else
				if a_op.is_equal ("query") then
					call_result := client.query (path, args)
				elseif a_op.is_equal ("mutation") then
					call_result := client.mutation (path, args)
				else
					call_result := client.action (path, args)
				end
				if call_result = Void then
					send_transport_error (a_id, debug_string (client.last_error))
				elseif call_result.is_success then
					send_result (a_id, call_result.value, call_result.logs)
				else
					send_call_error (a_id, call_result.error_message, call_result.error_data)
				end
			end
		end

	handle_subscribe (a_command: CONVEX_JSON_VALUE; a_id: STRING)
		local
			subscription_id: detachable STRING
			path: detachable STRING
			args: detachable CONVEX_JSON_VALUE
			ignored: BOOLEAN
		do
			subscription_id := string_field (a_command, "subscriptionId")
			path := string_field (a_command, "path")
			if a_command.has_field ("args") and then a_command.field ("args").is_object then
				args := a_command.field ("args")
			end
			if subscription_id = Void or else path = Void or else args = Void then
				send_protocol_error (a_id, "invalid subscribe request")
			else
				live_created := True
				maybe_ensure_live_connected
				if client.live.is_subscribed (subscription_id) then
					send_protocol_error (a_id, "duplicate subscriptionId")
				else
					ignored := client.live.add_subscription (subscription_id, path, args)
					send_ack (a_id)
				end
			end
		end

	handle_unsubscribe (a_command: CONVEX_JSON_VALUE; a_id: STRING)
		local
			subscription_id: detachable STRING
			ignored: BOOLEAN
		do
			subscription_id := string_field (a_command, "subscriptionId")
			if subscription_id = Void or else not live_created or else not client.live.is_subscribed (subscription_id) then
				send_protocol_error (a_id, "unknown subscriptionId")
			else
				ignored := client.live.remove_subscription (subscription_id)
				send_ack (a_id)
			end
		end

	handle_set_auth (a_command: CONVEX_JSON_VALUE; a_id: STRING)
		local
			token: detachable STRING
		do
			token := string_field (a_command, "token")
			client.set_auth (token)
			send_ack (a_id)
		end

	handle_debug_disconnect (a_id: STRING)
		do
			if live_created then
				client.live.force_disconnect
			end
			send_ack (a_id)
		end

	handle_close (a_id: STRING)
		do
			send_closed (a_id)
			closed := True
		end

feature {NONE} -- Event emission

	send_ready (a_id: STRING)
		local
			event: CONVEX_JSON_VALUE
		do
			create event.make_object
			event.put_field ("protocolVersion", integer_value (1))
			event.put_field ("id", string_value (a_id))
			event.put_field ("type", string_value ("ready"))
			event.put_field ("language", string_value ("eiffel"))
			event.put_field ("implementation", string_value ("native"))
			event.put_field ("runtime", string_value (runtime_version))
			write_event (event)
		end

	send_result (a_id: STRING; a_value: CONVEX_JSON_VALUE; a_logs: ARRAYED_LIST [STRING])
		local
			event: CONVEX_JSON_VALUE
		do
			create event.make_object
			event.put_field ("id", string_value (a_id))
			event.put_field ("type", string_value ("result"))
			event.put_field ("value", a_value)
			event.put_field ("logs", logs_value (a_logs))
			write_event (event)
		end

	send_call_error (a_id: STRING; a_message: STRING; a_data: detachable CONVEX_JSON_VALUE)
		do
			write_event (error_event (string_value (a_id), a_message, "Error", a_data))
		end

	send_protocol_error (a_id: detachable STRING; a_message: STRING)
		local
			id_value: detachable CONVEX_JSON_VALUE
		do
			if a_id /= Void then
				id_value := string_value (a_id)
			end
			write_event (error_event (id_value, a_message, "ProtocolError", Void))
		end

	send_transport_error (a_id: STRING; a_message: STRING)
		do
			write_event (error_event (string_value (a_id), a_message, "TransportError", Void))
		end

	error_event (a_id: detachable CONVEX_JSON_VALUE; a_message: STRING; a_name: STRING; a_data: detachable CONVEX_JSON_VALUE): CONVEX_JSON_VALUE
		local
			error_object: CONVEX_JSON_VALUE
		do
			create Result.make_object
			if a_id /= Void then
				Result.put_field ("id", a_id)
			end
			Result.put_field ("type", string_value ("error"))
			create error_object.make_object
			error_object.put_field ("name", string_value (a_name))
			error_object.put_field ("message", string_value (a_message))
			if a_data /= Void then
				error_object.put_field ("data", a_data)
			else
				error_object.put_field ("data", create {CONVEX_JSON_VALUE}.make_null)
			end
			Result.put_field ("error", error_object)
		end

	send_ack (a_id: STRING)
		local
			event: CONVEX_JSON_VALUE
		do
			create event.make_object
			event.put_field ("id", string_value (a_id))
			event.put_field ("type", string_value ("ack"))
			write_event (event)
		end

	send_closed (a_id: STRING)
		local
			event: CONVEX_JSON_VALUE
		do
			create event.make_object
			event.put_field ("id", string_value (a_id))
			event.put_field ("type", string_value ("closed"))
			write_event (event)
		end

	send_subscription_value (a_subscription_id: STRING; a_value: CONVEX_JSON_VALUE)
		local
			event: CONVEX_JSON_VALUE
		do
			create event.make_object
			event.put_field ("type", string_value ("subscription"))
			event.put_field ("subscriptionId", string_value (a_subscription_id))
			event.put_field ("value", a_value)
			event.put_field ("logs", logs_value (create {ARRAYED_LIST [STRING]}.make (0)))
			write_event (event)
		end

	send_subscription_error (a_subscription_id: STRING; a_message: STRING; a_data: detachable CONVEX_JSON_VALUE)
		local
			event, error_object: CONVEX_JSON_VALUE
		do
			create event.make_object
			event.put_field ("type", string_value ("subscription"))
			event.put_field ("subscriptionId", string_value (a_subscription_id))
			create error_object.make_object
			error_object.put_field ("name", string_value ("Error"))
			error_object.put_field ("message", string_value (a_message))
			if a_data /= Void then
				error_object.put_field ("data", a_data)
			else
				error_object.put_field ("data", create {CONVEX_JSON_VALUE}.make_null)
			end
			event.put_field ("error", error_object)
			write_event (event)
		end

	write_event (a_event: CONVEX_JSON_VALUE)
		local
			ignored: BOOLEAN
		do
			ignored := control.write_line (a_event.to_json)
		end

feature {NONE} -- JSON construction helpers

	string_value (a_text: STRING): CONVEX_JSON_VALUE
		do
			create Result.make_string (a_text)
		end

	integer_value (a_value: INTEGER): CONVEX_JSON_VALUE
		do
			create Result.make_number (a_value.to_double)
		end

	logs_value (a_logs: ARRAYED_LIST [STRING]): CONVEX_JSON_VALUE
		local
			i: INTEGER
		do
			create Result.make_array
			from i := 1 until i > a_logs.count
			loop
				Result.extend (string_value (a_logs.i_th (i)))
				i := i + 1
			end
		end

	string_field (a_object: CONVEX_JSON_VALUE; a_key: STRING): detachable STRING
		do
			if a_object.has_field (a_key) and then a_object.field (a_key).is_string then
				Result := a_object.field (a_key).string_item
			end
		end

	debug_string (a_text: detachable STRING): STRING
		do
			if a_text = Void then
				Result := "unknown transport error"
			else
				Result := a_text
			end
		end

	runtime_version: STRING = "EiffelStudio 25.02"

feature {NONE} -- Environment

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
