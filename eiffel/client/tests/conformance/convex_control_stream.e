note
	description: "[
		The adapter's NDJSON control channel: either the process's own
		stdin/stdout, or (when `ADAPTER_LISTEN' is set) one accepted TCP
		connection, so the isolated Docker harness can drive the adapter
		from a separate controller container without sharing a pipe. Once
		a TCP connection is accepted, its raw file descriptor is read and
		written through the same C helpers CONVEX_SOCKET already uses for
		the plain (non-TLS) case, so both transports share one code path
		here.
	]"

class
	CONVEX_CONTROL_STREAM

create
	make_stdio, make_listening

feature {NONE} -- Initialization

	make_stdio
			-- Use the process's own stdin (fd 0) and stdout (fd 1).
		do
			read_fd := 0
			write_fd := 1
			create buffer.make_empty
			is_ready := True
		end

	make_listening (a_bind_spec: STRING)
			-- Listen on `a_bind_spec' ("host:port"), accept exactly one
			-- connection, and use it for both reading and writing. Check
			-- `is_ready' afterwards.
		require
			a_bind_spec_attached: a_bind_spec /= Void
		local
			colon_index: INTEGER
			port: INTEGER
			listener: NETWORK_STREAM_SOCKET
		do
			create buffer.make_empty
			colon_index := a_bind_spec.index_of (':', 1)
			if colon_index > 0 then
				port := a_bind_spec.substring (colon_index + 1, a_bind_spec.count).to_integer
			end
			if port > 0 then
				create listener.make_server_by_port (port)
				listener.listen (1)
				listener.accept
				if attached listener.accepted as l_accepted then
					read_fd := l_accepted.descriptor
					write_fd := read_fd
					is_ready := True
				end
			end
		end

feature -- Access

	is_ready: BOOLEAN
			-- Did setup succeed? False leaves the adapter nothing to serve.

	descriptor: INTEGER
			-- The readable descriptor, exposed so CONVEX_POLL can `select'
			-- on it alongside any open Live connection.
		do
			Result := read_fd
		end

	has_buffered_line: BOOLEAN
			-- Does a complete NDJSON line already sit in the read buffer,
			-- so the next `read_line' would not need to touch the
			-- descriptor at all?
		do
			Result := buffer.index_of ('%N', 1) > 0
		end

feature -- Input

	read_line (a_timeout_ms: INTEGER): detachable STRING
			-- Read one newline-terminated NDJSON command, waiting up to
			-- `a_timeout_ms' for the first new byte if none is already
			-- buffered. Void on timeout or end of stream.
		require
			is_ready: is_ready
			a_timeout_non_negative: a_timeout_ms >= 0
		local
			newline_index: INTEGER
			out_buffer: MANAGED_POINTER
			rc: INTEGER
			poll: CONVEX_POLL
			done: BOOLEAN
		do
			from until done
			loop
				newline_index := buffer.index_of ('%N', 1)
				if newline_index > 0 then
					Result := buffer.substring (1, newline_index - 1)
					if Result.count > 0 and then Result.item (Result.count) = '%R' then
						Result.remove_tail (1)
					end
					buffer.remove_head (newline_index)
					done := True
				else
					create poll
					if poll.wait_readable (read_fd, a_timeout_ms) then
						create out_buffer.make (4096)
						rc := c_generic_read (read_fd, out_buffer.item, 4096)
						if rc > 0 then
							buffer.append (string_from_buffer (out_buffer, rc))
						else
							done := True
						end
					else
						done := True
					end
				end
			end
		end

feature -- Output

	write_line (a_text: STRING): BOOLEAN
			-- Write `a_text' followed by a newline. NDJSON events are
			-- small, so this uses one best-effort write rather than the
			-- retrying loop CONVEX_SOCKET needs for arbitrarily large HTTP
			-- and WebSocket payloads.
		require
			is_ready: is_ready
			a_text_attached: a_text /= Void
		local
			payload: STRING
			buffer_c: C_STRING
			rc: INTEGER
		do
			payload := a_text + "%N"
			create buffer_c.make (payload)
			rc := c_generic_write (write_fd, buffer_c.item, payload.count)
			Result := rc = payload.count
		end

feature {NONE} -- Implementation

	read_fd: INTEGER
	write_fd: INTEGER
	buffer: STRING

	string_from_buffer (a_buffer: MANAGED_POINTER; a_count: INTEGER): STRING
		local
			i: INTEGER
		do
			create Result.make (a_count)
			from i := 0 until i = a_count
			loop
				Result.append_character (a_buffer.read_natural_8 (i).to_integer_32.to_character_8)
				i := i + 1
			end
		end

feature {NONE} -- Externals

	c_generic_write (a_fd: INTEGER; a_data: POINTER; a_count: INTEGER): INTEGER
		external
			"C signature (int, void *, int): int use %"convex_native.h%""
		alias
			"convex_generic_write"
		end

	c_generic_read (a_fd: INTEGER; a_buffer: POINTER; a_max: INTEGER): INTEGER
		external
			"C signature (int, void *, int): int use %"convex_native.h%""
		alias
			"convex_generic_read"
		end

end
