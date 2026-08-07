note
	description: "Temporary smoke-test root used only while bringing up the toolchain; replaced by CONVEX_JSON_TESTS once the ECF plumbing is verified."

class
	CONVEX_TEST_APP

create
	make

feature {NONE} -- Initialization

	make
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

			print ("SMOKE_OK%N")
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

end
