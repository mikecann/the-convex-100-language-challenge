note
	description: "[
		A minimal RFC 6455 WebSocket client used only to carry the pinned
		`convex-rs' sync profile's JSON messages (see docs/protocol-profiles
		in the repository root). It implements exactly what that profile
		needs: the HTTP Upgrade handshake, masked text frames outbound,
		fragmented-message reassembly and control frames (ping/pong/close)
		inbound, and a bounded read so a stalled or hostile peer cannot
		block the adapter's single I/O owner. It is not a general-purpose
		WebSocket library: binary frames and extensions are out of scope.
	]"

class
	CONVEX_WEBSOCKET

create
	make

feature {NONE} -- Initialization

	make (a_host: STRING; a_port: INTEGER; a_path: STRING; a_use_tls: BOOLEAN)
			-- Open a TCP (or TLS) connection to `a_host':`a_port' and
			-- complete the WebSocket handshake against `a_path'. Check
			-- `is_open' and `last_error' afterwards.
		require
			a_host_attached: a_host /= Void
			a_path_attached: a_path /= Void
		local
			key: STRING
			request: STRING
			status_line: detachable STRING
		do
			create buffer.make_empty
			create last_payload.make_empty
			last_close_reason := "InitialConnect"
			create socket.make (a_host, a_port, a_use_tls)
			if not socket.is_open then
				last_error := socket.last_error
			else
				key := websocket_key
				request := "GET " + a_path + " HTTP/1.1%R%N"
				request := request + "Host: " + a_host + "%R%N"
				request := request + "Upgrade: websocket%R%N"
				request := request + "Connection: Upgrade%R%N"
				request := request + "Sec-WebSocket-Key: " + key + "%R%N"
				request := request + "Sec-WebSocket-Version: 13%R%N%R%N"
				if not socket.write_all (request) then
					last_error := "handshake request failed: " + handshake_error
					socket.close
				else
					status_line := read_line (handshake_timeout_ms)
					if status_line = Void then
						last_error := "no handshake response"
						socket.close
					elseif not status_line.has_substring ("101") then
						last_error := "unexpected handshake status: " + status_line
						socket.close
					else
						drain_handshake_headers
						is_open := True
					end
				end
			end
		end

feature -- Access

	is_open: BOOLEAN
			-- Is the WebSocket connection open?

	last_error: detachable STRING
			-- A short diagnostic for the most recent failure, if any.

	last_close_reason: STRING
			-- The most recently observed reason a connection ended: a peer
			-- close frame's reason text, "timeout", "transport error", or
			-- "InitialConnect" before any connection has ended yet.

	descriptor: INTEGER
			-- The raw file descriptor, exposed so CONVEX_POLL can `select'
			-- on it alongside the adapter's control stream.
		do
			Result := socket.descriptor
		end

	has_pending_bytes: BOOLEAN
			-- Does the transport already hold decoded bytes (or does our
			-- own buffer already hold a complete frame) that a `select'
			-- loop must drain before waiting on the descriptor again?
		do
			Result := socket.pending_tls_bytes or else buffer.count > 0
		end

feature -- Output

	send_text (a_text: STRING): BOOLEAN
			-- Send `a_text' as one unfragmented, masked WebSocket text
			-- frame. Returns False (with `last_error' set) on failure.
		require
			is_open: is_open
			a_text_attached: a_text /= Void
		local
			frame: STRING
		do
			frame := encode_frame (Opcode_text, a_text)
			Result := socket.write_all (frame)
			if not Result then
				last_error := socket.last_error
				is_open := False
			end
		end

feature -- Input

	try_receive_message (a_timeout_ms: INTEGER): detachable STRING
			-- Wait up to `a_timeout_ms' for one complete text message,
			-- reassembling fragments and transparently answering pings and
			-- the peer's close handshake. Void on timeout, close, or error;
			-- see `is_open' and `last_error' to distinguish those.
		require
			is_open: is_open
			a_timeout_non_negative: a_timeout_ms >= 0
		local
			message: STRING
			fin: BOOLEAN
			opcode, first_opcode: INTEGER
			payload: STRING
			done: BOOLEAN
			deadline_ms: INTEGER
		do
			create message.make_empty
			first_opcode := -1
			deadline_ms := a_timeout_ms
			from until done
			loop
				if not try_parse_frame (deadline_ms) then
					done := True
				else
					fin := last_frame_fin
					opcode := last_frame_opcode
					payload := last_payload
					inspect opcode
					when Opcode_ping then
						if not socket.write_all (encode_frame (Opcode_pong, payload)) then
							last_error := socket.last_error
							is_open := False
							done := True
						end
					when Opcode_pong then
						-- Nothing to do; a pong on its own is not a message.
					when Opcode_close then
						last_close_reason := close_reason_from_payload (payload)
						send_close_ack
						is_open := False
						socket.close
						done := True
					else
						if first_opcode = -1 then
							first_opcode := opcode
						end
						message.append (payload)
						if fin then
							done := True
							if first_opcode = Opcode_text then
								Result := message
							end
						end
					end
				end
			end
		end

	close (a_reason: STRING)
			-- Send a close frame carrying `a_reason' and shut the
			-- connection down. Idempotent; safe to call after the peer has
			-- already closed.
		require
			a_reason_attached: a_reason /= Void
		local
			ignored_result: BOOLEAN
		do
			if is_open then
				ignored_result := socket.write_all (encode_frame (Opcode_close, close_payload (a_reason)))
				is_open := False
			end
			socket.close
		end

feature {NONE} -- Handshake

	handshake_timeout_ms: INTEGER = 10000

	handshake_error: STRING = "transport failure"

	websocket_key: STRING
			-- A base64-encoded 16-byte `Sec-WebSocket-Key'. RFC 6455 does not
			-- require cryptographic randomness here: the server only hashes it
			-- to prove it understood the request, and this client does not
			-- reuse the connection across origins, so it has nothing to defend
			-- by varying the key between handshakes.
		once
			Result := base64_encode ("ConvexEiffelWS16")
		end

	read_line (a_timeout_ms: INTEGER): detachable STRING
			-- Read one CRLF-terminated line from the handshake response,
			-- consuming any bytes already buffered first.
		local
			newline_index: INTEGER
			chunk: detachable STRING
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
					chunk := socket.read_some (4096, a_timeout_ms)
					if chunk = Void then
						done := True
					else
						buffer.append (chunk)
					end
				end
			end
		end

	drain_handshake_headers
			-- Consume header lines up to and including the blank line that
			-- ends the HTTP Upgrade response.
		local
			line: detachable STRING
			done: BOOLEAN
		do
			from until done
			loop
				line := read_line (handshake_timeout_ms)
				if line = Void or else line.is_empty then
					done := True
				end
			end
		end

feature {NONE} -- Framing

	Opcode_text: INTEGER = 1
	Opcode_close: INTEGER = 8
	Opcode_ping: INTEGER = 9
	Opcode_pong: INTEGER = 10

	buffer: STRING
			-- Bytes read from the socket but not yet consumed as a
			-- complete frame.

	last_frame_fin: BOOLEAN
	last_frame_opcode: INTEGER
	last_frame_payload_length: INTEGER
	last_payload: STRING

	fill_buffer (a_min_bytes: INTEGER; a_timeout_ms: INTEGER): BOOLEAN
			-- Ensure `buffer' holds at least `a_min_bytes', reading more
			-- from the socket as needed, one read per still-missing
			-- fragment. False on timeout or transport error. A read that
			-- returns Void always ends this call rather than retrying: a
			-- message fragmented across several TCP segments (routine
			-- over a real network, rare on localhost) previously left
			-- this loop spinning on zero-timeout reads until every
			-- fragment had arrived, which could run for as long as the
			-- whole message took to arrive and made a rare interrupted
			-- syscall from the runtime's own signals far more likely to
			-- land badly than the single bounded wait below does.
		local
			chunk: detachable STRING
			done: BOOLEAN
		do
			from until buffer.count >= a_min_bytes or not is_open or done
			loop
				chunk := socket.read_some (4096, a_timeout_ms)
				if chunk = Void then
					done := True
					if socket.is_open then
						last_error := "read timed out"
					else
						last_error := socket.last_error
						is_open := False
					end
				else
					buffer.append (chunk)
				end
			end
			Result := buffer.count >= a_min_bytes
		end

	try_parse_frame (a_timeout_ms: INTEGER): BOOLEAN
			-- Parse one complete frame (header and payload together) from
			-- `buffer', reading more data as needed, and set
			-- `last_frame_fin', `last_frame_opcode',
			-- `last_frame_payload_length', and `last_payload'. Bytes are
			-- only ever removed from `buffer' once an entire frame is
			-- confirmed present, so a call that cannot complete within
			-- `a_timeout_ms' (a partially arrived frame is routine over a
			-- real network, rare on localhost) leaves `buffer' exactly as
			-- it found it: a later call safely resumes from those same
			-- bytes plus whatever has since arrived, rather than
			-- mistaking an already-consumed frame's leftover payload
			-- bytes for the start of a new header.
		local
			byte0, byte1: INTEGER
			base_length: INTEGER
			header_size: INTEGER
			payload_length: INTEGER
			ext_start: INTEGER
			total_size: INTEGER
		do
			if fill_buffer (2, a_timeout_ms) then
				byte0 := buffer.item (1).code
				byte1 := buffer.item (2).code
				base_length := byte1.bit_and (0x7F)
				-- Servers never mask frames sent to the client (RFC 6455 5.1).
				if base_length = 126 then
					header_size := 4
				elseif base_length = 127 then
					header_size := 10
				else
					header_size := 2
				end
				if fill_buffer (header_size, a_timeout_ms) then
					if base_length = 126 then
						payload_length := buffer.item (3).code * 256 + buffer.item (4).code
					elseif base_length = 127 then
						-- This client's frames never approach 2^31 bytes;
						-- treat the length as the low-order bytes only.
						from
							ext_start := 7
							payload_length := 0
						until
							ext_start > 10
						loop
							payload_length := payload_length * 256 + buffer.item (ext_start).code
							ext_start := ext_start + 1
						end
					else
						payload_length := base_length
					end
					total_size := header_size + payload_length
					if fill_buffer (total_size, a_timeout_ms) then
						last_frame_fin := byte0.bit_and (0x80) /= 0
						last_frame_opcode := byte0.bit_and (0x0F)
						last_frame_payload_length := payload_length
						last_payload := buffer.substring (header_size + 1, total_size)
						buffer.remove_head (total_size)
						Result := True
					end
				end
			end
		end

	encode_frame (a_opcode: INTEGER; a_payload: STRING): STRING
			-- Build one final, masked frame carrying `a_payload'. Every
			-- client-to-server frame must be masked (RFC 6455 5.1); the
			-- mask key does not need to be unpredictable, only present.
		local
			frame: STRING
			mask: ARRAY [INTEGER]
			length: INTEGER
			i: INTEGER
			masked_byte: INTEGER
		do
			length := a_payload.count
			create frame.make (length + 14)
			frame.append_character ((0x80 + a_opcode).to_character_8)
			if length <= 125 then
				frame.append_character ((0x80 + length).to_character_8)
			elseif length <= 65535 then
				frame.append_character ((0x80 + 126).to_character_8)
				frame.append_character ((length // 256).to_character_8)
				frame.append_character ((length \\ 256).to_character_8)
			else
				frame.append_character ((0x80 + 127).to_character_8)
				from i := 1 until i > 4
				loop
					frame.append_character ((0).to_character_8)
					i := i + 1
				end
				frame.append_character ((length.bit_shift_right (24).bit_and (0xFF)).to_character_8)
				frame.append_character ((length.bit_shift_right (16).bit_and (0xFF)).to_character_8)
				frame.append_character ((length.bit_shift_right (8).bit_and (0xFF)).to_character_8)
				frame.append_character ((length.bit_and (0xFF)).to_character_8)
			end
			mask := <<37, 111, 199, 251>>
			from i := 1 until i > 4
			loop
				frame.append_character (mask.item (i).to_character_8)
				i := i + 1
			end
			from i := 1 until i > length
			loop
				masked_byte := a_payload.item (i).code.bit_xor (mask.item (((i - 1) \\ 4) + 1))
				frame.append_character (masked_byte.to_character_8)
				i := i + 1
			end
			Result := frame
		end

	close_payload (a_reason: STRING): STRING
			-- A close-frame payload carrying status code 1000 (normal
			-- closure) and `a_reason' as UTF-8 text.
		local
			text: STRING
		do
			create text.make (2 + a_reason.count)
			text.append_character ((1000 // 256).to_character_8)
			text.append_character ((1000 \\ 256).to_character_8)
			text.append (a_reason)
			Result := text
		end

	close_reason_from_payload (a_payload: STRING): STRING
		do
			if a_payload.count > 2 then
				Result := a_payload.substring (3, a_payload.count)
			else
				Result := "closed by peer"
			end
		end

	send_close_ack
		local
			ignored_result: BOOLEAN
		do
			if socket.is_open then
				ignored_result := socket.write_all (encode_frame (Opcode_close, close_payload ("ack")))
			end
		end

feature {NONE} -- Encoding helpers

	base64_encode (a_bytes: STRING): STRING
			-- Standard (padded) base64 encoding of `a_bytes'.
		local
			alphabet: STRING
			i, b0, b1, b2, triple: INTEGER
		do
			alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
			create Result.make ((a_bytes.count + 2) // 3 * 4)
			from i := 1 until i > a_bytes.count
			loop
				b0 := a_bytes.item (i).code
				if i + 1 <= a_bytes.count then
					b1 := a_bytes.item (i + 1).code
				else
					b1 := 0
				end
				if i + 2 <= a_bytes.count then
					b2 := a_bytes.item (i + 2).code
				else
					b2 := 0
				end
				triple := b0 * 65536 + b1 * 256 + b2
				Result.append_character (alphabet.item ((triple.bit_shift_right (18).bit_and (0x3F)) + 1))
				Result.append_character (alphabet.item ((triple.bit_shift_right (12).bit_and (0x3F)) + 1))
				if i + 1 <= a_bytes.count then
					Result.append_character (alphabet.item ((triple.bit_shift_right (6).bit_and (0x3F)) + 1))
				else
					Result.append_character ('=')
				end
				if i + 2 <= a_bytes.count then
					Result.append_character (alphabet.item ((triple.bit_and (0x3F)) + 1))
				else
					Result.append_character ('=')
				end
				i := i + 3
			end
		end

feature {NONE} -- Implementation

	socket: CONVEX_SOCKET

end
