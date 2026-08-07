note
	description: "[
		A minimal HTTP/1.1 client used only to reach Convex's documented
		public HTTP API (`/api/query', `/api/mutation', `/api/action').
		Every call opens a fresh connection and sends `Connection: close':
		this project's HTTP suite is a handful of short-lived request/reply
		calls, not a long-running client that benefits from keep-alive, and
		a fresh connection keeps the response-reading state machine simple
		and easy to reason about.
	]"

class
	CONVEX_HTTP_CLIENT

create
	make

feature {NONE} -- Initialization

	make (a_host: STRING; a_port: INTEGER; a_use_tls: BOOLEAN)
		require
			a_host_attached: a_host /= Void
			a_port_valid: a_port > 0 and a_port <= 65535
		do
			host := a_host
			port := a_port
			use_tls := a_use_tls
		end

feature -- Access

	last_error: detachable STRING

	last_status_code: INTEGER

feature -- Requests

	post (a_path: STRING; a_body: STRING; a_auth_token: detachable STRING): detachable STRING
			-- POST `a_body' (JSON) to `a_path' with an optional bearer
			-- token, and return the response body. Void (with `last_error'
			-- set) on any transport or protocol failure.
		require
			a_path_attached: a_path /= Void
			a_body_attached: a_body /= Void
		local
			socket: CONVEX_SOCKET
			request: STRING
			buffer: STRING
			status_line: detachable STRING
			content_length: INTEGER
			body: detachable STRING
		do
			create socket.make (host, port, use_tls)
			if not socket.is_open then
				last_error := "connect failed: " + socket_error (socket)
			else
				request := "POST " + a_path + " HTTP/1.1%R%N"
				request := request + "Host: " + host + "%R%N"
				request := request + "Content-Type: application/json%R%N"
				request := request + "Content-Length: " + a_body.count.out + "%R%N"
				request := request + "Connection: close%R%N"
				if attached a_auth_token as l_token and then not l_token.is_empty then
					request := request + "Authorization: Bearer " + l_token + "%R%N"
				end
				request := request + "%R%N" + a_body
				if not socket.write_all (request) then
					last_error := "write failed: " + socket_error (socket)
				else
					create buffer.make_empty
					status_line := read_line (socket, buffer, request_timeout_ms)
					if status_line = Void then
						last_error := "no response"
					else
						last_status_code := status_code_from_line (status_line)
						content_length := read_headers_for_content_length (socket, buffer)
						if content_length < 0 then
							last_error := "response had no Content-Length"
						else
							body := read_exact_from_buffer (socket, buffer, content_length, request_timeout_ms)
							if body = Void then
								last_error := "incomplete response body"
							else
								Result := body
							end
						end
					end
				end
				socket.close
			end
		end

feature {NONE} -- Response parsing

	request_timeout_ms: INTEGER = 15000

	socket_error (a_socket: CONVEX_SOCKET): STRING
		do
			if attached a_socket.last_error as l_error then
				Result := l_error
			else
				Result := "unknown error"
			end
		end

	status_code_from_line (a_status_line: STRING): INTEGER
			-- Parse "HTTP/1.1 200 OK" style status lines by locating the
			-- three-digit status code between the first two spaces.
		local
			first_space, second_space: INTEGER
		do
			first_space := a_status_line.index_of (' ', 1)
			if first_space > 0 then
				second_space := a_status_line.index_of (' ', first_space + 1)
				if second_space = 0 then
					second_space := a_status_line.count + 1
				end
				if second_space > first_space + 1 then
					Result := a_status_line.substring (first_space + 1, second_space - 1).to_integer
				end
			end
		end

	read_line (a_socket: CONVEX_SOCKET; a_buffer: STRING; a_timeout_ms: INTEGER): detachable STRING
			-- Read one CRLF-terminated line, consuming buffered bytes
			-- first and refilling `a_buffer' from `a_socket' as needed.
		local
			newline_index: INTEGER
			chunk: detachable STRING
			done: BOOLEAN
		do
			from until done
			loop
				newline_index := a_buffer.index_of ('%N', 1)
				if newline_index > 0 then
					Result := a_buffer.substring (1, newline_index - 1)
					if Result.count > 0 and then Result.item (Result.count) = '%R' then
						Result.remove_tail (1)
					end
					a_buffer.remove_head (newline_index)
					done := True
				else
					chunk := a_socket.read_some (4096, a_timeout_ms)
					if chunk = Void then
						done := True
					else
						a_buffer.append (chunk)
					end
				end
			end
		end

	read_headers_for_content_length (a_socket: CONVEX_SOCKET; a_buffer: STRING): INTEGER
			-- Consume header lines up to the blank line ending the
			-- response header block, returning the declared body length or
			-- -1 if none was present.
		local
			line: detachable STRING
			done: BOOLEAN
			lower: STRING
			value_text: STRING
		do
			Result := -1
			from until done
			loop
				line := read_line (a_socket, a_buffer, request_timeout_ms)
				if line = Void or else line.is_empty then
					done := True
				else
					lower := line.as_lower
					if lower.starts_with ("content-length:") then
						value_text := line.substring (17, line.count)
						value_text.left_adjust
						value_text.right_adjust
						Result := value_text.to_integer
					end
				end
			end
		end

	read_exact_from_buffer (a_socket: CONVEX_SOCKET; a_buffer: STRING; a_count: INTEGER; a_timeout_ms: INTEGER): detachable STRING
			-- Return exactly `a_count' bytes, taking any already-buffered
			-- bytes first and reading the remainder from `a_socket'.
		local
			chunk: detachable STRING
			deadline_exceeded: BOOLEAN
		do
			from until a_buffer.count >= a_count or deadline_exceeded
			loop
				chunk := a_socket.read_some (a_count - a_buffer.count, a_timeout_ms)
				if chunk = Void then
					deadline_exceeded := True
				else
					a_buffer.append (chunk)
				end
			end
			if a_buffer.count >= a_count then
				Result := a_buffer.substring (1, a_count)
			end
		end

feature {NONE} -- Implementation

	host: STRING
	port: INTEGER
	use_tls: BOOLEAN

end
