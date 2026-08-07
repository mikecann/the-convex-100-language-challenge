note
	description: "Temporary smoke-test root used only while bringing up the toolchain; replaced by CONVEX_JSON_TESTS once the ECF plumbing is verified."

class
	CONVEX_TEST_APP

create
	make

feature {NONE} -- Initialization

	make
		do
			check_json
			check_socket
			check_websocket
			check_client_against_local_backend
			print ("SMOKE_OK%N")
		end

	check_json
		local
			parser: CONVEX_JSON_PARSER
			value: CONVEX_JSON_VALUE
			obj: CONVEX_JSON_VALUE
		do
			create parser.make
			parser.parse ("{%"a%":1.0,%"b%":[true,false,null],%"c%":%"hi \%"quoted\%" text%"}")
			check parsed: parser.successful end
			if attached parser.last_value as l_value then
				value := l_value
				check has_a: value.has_field ("a") end
				check number_ok: value.field ("a").number_item = 1.0 end
				check array_len: value.field ("b").array_item.count = 3 end
				print (value.to_json)
				print ("%N")
			else
				print ("PARSE_FAILED_UNEXPECTEDLY%N")
			end

			create obj.make_object
			obj.put_field ("room", create {CONVEX_JSON_VALUE}.make_string ("demo"))
			print (obj.to_json)
			print ("%N")
		end

	check_socket
			-- Exercise CONVEX_SOCKET against a real TLS host to prove the
			-- transport layer, not just the JSON layer, actually works.
		local
			sock: CONVEX_SOCKET
			request: STRING
			response: detachable STRING
		do
			create sock.make ("example.com", 443, True)
			if not sock.is_open then
				print ("SOCKET_CONNECT_FAILED: ")
				if attached sock.last_error as l_error then
					print (l_error)
				end
				print ("%N")
			else
				request := "GET / HTTP/1.1%R%NHost: example.com%R%NConnection: close%R%N%R%N"
				if sock.write_all (request) then
					response := sock.read_some (256, 5000)
					if attached response as l_response and then l_response.starts_with ("HTTP/1.1 200") then
						print ("SOCKET_OK%N")
					else
						print ("SOCKET_UNEXPECTED_RESPONSE%N")
					end
				else
					print ("SOCKET_WRITE_FAILED%N")
				end
				sock.close
			end
		end

	check_websocket
			-- Exercise CONVEX_WEBSOCKET against a real public echo server
			-- to prove the handshake and text-frame round trip actually
			-- work, not just compile.
		local
			ws: CONVEX_WEBSOCKET
			reply: detachable STRING
		do
			create ws.make ("echo.websocket.org", 443, "/", True)
			if not ws.is_open then
				print ("WS_CONNECT_FAILED: ")
				if attached ws.last_error as l_error then
					print (l_error)
				end
				print ("%N")
			else
				if ws.send_text ("hello-from-eiffel") then
					reply := ws.try_receive_message (5000)
					if attached reply as l_reply then
						print ("WS_REPLY: " + l_reply + "%N")
					else
						print ("WS_NO_REPLY%N")
					end
				else
					print ("WS_SEND_FAILED%N")
				end
				ws.close ("done")
			end
		end

	check_client_against_local_backend
			-- End-to-end proof against the project's real local Convex
			-- backend: an HTTP query and mutation, then a Live subscription
			-- that observes the mutation's effect without polling.
		local
			client: CONVEX_CLIENT
			args, mutation_args: CONVEX_JSON_VALUE
			room: STRING
			query_result, mutation_result: detachable CONVEX_RESULT
			deadline_ms: INTEGER
			poll: CONVEX_POLL
			got_update: BOOLEAN
			ignored: BOOLEAN
		do
			room := "eiffel-smoke-test-room-" + fresh_suffix_number.out
			create client.make ("http://127.0.0.1:3210")

			create args.make_object
			args.put_field ("room", create {CONVEX_JSON_VALUE}.make_string (room))
			query_result := client.query ("demo:state", args)
			if query_result = Void then
				print ("CLIENT_QUERY_TRANSPORT_FAILED: ")
				if attached client.last_error as l_error then print (l_error) end
				print ("%N")
			elseif not query_result.is_success then
				print ("CLIENT_QUERY_APP_ERROR: " + query_result.error_message + "%N")
			else
				print ("CLIENT_QUERY_OK count=" + query_result.value.field ("count").number_item.out + "%N")
			end

			client.live.ensure_connected
			ignored := client.live.add_subscription ("sub-room", "demo:state", args)
			print ("LIVE_CONNECTED=" + client.live.is_connected.out + "%N")

			-- Drain the initial subscription value before mutating, mirroring
			-- the canonical example's "subscribe before mutate" sequencing.
			deadline_ms := 5000
			from until got_update or deadline_ms <= 0
			loop
				create poll
				if client.live.is_connected and then poll.wait_readable (client.live.descriptor, 200) then
					client.live.poll (200)
				end
				if not client.live.pending_events.is_empty then
					got_update := True
				end
				deadline_ms := deadline_ms - 200
			end
			if got_update then
				print ("LIVE_INITIAL: " + client.live.pending_events.first.value.field ("count").number_item.out + "%N")
				client.live.pending_events.wipe_out
			else
				print ("LIVE_INITIAL_TIMEOUT%N")
			end

			create mutation_args.make_object
			mutation_args.put_field ("room", create {CONVEX_JSON_VALUE}.make_string (room))
			mutation_args.put_field ("language", create {CONVEX_JSON_VALUE}.make_string ("Eiffel"))
			mutation_args.put_field ("runId", create {CONVEX_JSON_VALUE}.make_string (room + "-once"))
			mutation_result := client.mutation ("demo:increment", mutation_args)
			if mutation_result /= Void and then mutation_result.is_success then
				print ("CLIENT_MUTATION_OK applied=" + mutation_result.value.field ("applied").boolean_item.out + "%N")
			else
				print ("CLIENT_MUTATION_FAILED%N")
			end

			got_update := False
			deadline_ms := 8000
			from until got_update or deadline_ms <= 0
			loop
				create poll
				if client.live.is_connected and then poll.wait_readable (client.live.descriptor, 200) then
					client.live.poll (200)
				end
				if not client.live.pending_events.is_empty then
					got_update := True
				end
				deadline_ms := deadline_ms - 200
			end
			if got_update then
				print ("LIVE_UPDATED: " + client.live.pending_events.first.value.field ("count").number_item.out + "%N")
			else
				print ("LIVE_UPDATE_TIMEOUT%N")
			end
		end

	fresh_suffix_number: INTEGER
		external
			"C signature (): unsigned int use %"convex_native.h%""
		alias
			"convex_random_seed"
		end

end
