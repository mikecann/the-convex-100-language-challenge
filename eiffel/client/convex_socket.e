note
	description: "[
		A minimal TCP socket, optionally wrapped in TLS, used by both the
		HTTP transport (query/mutation/action) and the WebSocket transport
		(Live subscriptions). It opens the TCP connection through EiffelNet
		(library `net'), then, when TLS is requested, hands the connected
		file descriptor to OpenSSL through Eiffel's C external interface
		for the handshake and all later reads and writes: EiffelStudio does
		not bundle a byte-stream API over its own OpenSSL wrapper library,
		so this class talks to libssl directly, the same "normal HTTP, TLS"
		allowance every native client in this project relies on.

		Every read carries an explicit millisecond deadline so a stalled or
		malicious peer cannot block the adapter's single I/O owner forever;
		see `read_some' and `read_exact'.
	]"

class
	CONVEX_SOCKET

create
	make

feature {NONE} -- Initialization

	make (a_host: STRING; a_port: INTEGER; a_use_tls: BOOLEAN)
			-- Open a TCP connection to `a_host':`a_port', then complete a
			-- TLS handshake (with SNI and certificate verification) when
			-- `a_use_tls'. Check `is_open' and `last_error' afterwards.
		require
			a_host_attached: a_host /= Void
			a_host_not_empty: not a_host.is_empty
			a_port_valid: a_port > 0 and a_port <= 65535
		local
			raw: NETWORK_STREAM_SOCKET
			host_c: C_STRING
		do
			use_tls := a_use_tls
			create raw.make_client_by_port (a_port, a_host)
			raw.set_connect_timeout (connect_timeout_ms)
			raw.connect
			if raw.is_open_write then
				descriptor := raw.descriptor
				underlying_socket := raw
				if a_use_tls then
					create host_c.make (a_host)
					ssl_ptr := c_tls_connect (descriptor, host_c.item)
					if not ssl_ptr.is_default_pointer then
						is_open := True
					else
						last_error := "TLS handshake failed: " + c_tls_last_error
					end
				else
					is_open := True
				end
			else
				last_error := "TCP connect to " + a_host + ":" + a_port.out + " failed"
			end
		end

feature -- Access

	is_open: BOOLEAN
			-- Did the connection (and TLS handshake, when requested)
			-- succeed? False after `close' or a fatal I/O error.

	last_error: detachable STRING
			-- A short diagnostic for the most recent failure, if any.

	descriptor: INTEGER
			-- The raw file descriptor, exposed only so CONVEX_POLL can
			-- `select' on it alongside the adapter's control stream.

	use_tls: BOOLEAN
			-- Is this connection wrapped in TLS?

feature -- Output

	write_all (a_data: STRING): BOOLEAN
			-- Write every byte of `a_data', blocking as needed. Sets
			-- `last_error' and returns False on any failure.
		require
			is_open: is_open
			a_data_attached: a_data /= Void
		local
			buffer: C_STRING
			sent, total: INTEGER
			rc: INTEGER
		do
			create buffer.make (a_data)
			total := a_data.count
			Result := True
			from
				sent := 0
			until
				sent >= total or not Result
			loop
				if use_tls then
					rc := c_tls_write (ssl_ptr, buffer.item + sent, total - sent)
				else
					rc := c_raw_write (descriptor, buffer.item + sent, total - sent)
				end
				if rc <= 0 then
					last_error := "write failed"
					is_open := False
					Result := False
				else
					sent := sent + rc
				end
			end
		end

feature -- Input

	pending_tls_bytes: BOOLEAN
			-- Does OpenSSL already hold decoded bytes from a previous read,
			-- even though the socket itself has nothing new? A `select'
			-- loop must drain this before waiting on the file descriptor
			-- again, or it can stall with a full frame already in memory.
		do
			Result := use_tls and then is_open and then c_tls_pending (ssl_ptr) > 0
		end

	read_some (a_max_bytes: INTEGER; a_timeout_ms: INTEGER): detachable STRING
			-- Read between 1 and `a_max_bytes' bytes, waiting up to
			-- `a_timeout_ms' for the first byte. Void on timeout or error
			-- (see `last_error' and `is_open' to distinguish them); an
			-- empty non-Void result never occurs.
		require
			is_open: is_open
			a_max_bytes_positive: a_max_bytes > 0
		local
			poll: CONVEX_POLL
			out_buffer: MANAGED_POINTER
			rc: INTEGER
		do
			create poll
			if pending_tls_bytes or else poll.wait_readable (descriptor, a_timeout_ms) then
				create out_buffer.make (a_max_bytes)
				if use_tls then
					rc := c_tls_read (ssl_ptr, out_buffer.item, a_max_bytes)
				else
					rc := c_raw_read (descriptor, out_buffer.item, a_max_bytes)
				end
				if rc > 0 then
					Result := string_from_buffer (out_buffer, rc)
				elseif rc = 0 then
					last_error := "connection closed by peer"
					is_open := False
				else
					last_error := "read failed"
					is_open := False
				end
			end
		end

	read_exact (a_count: INTEGER; a_timeout_ms: INTEGER): detachable STRING
			-- Read exactly `a_count' bytes, applying `a_timeout_ms' to each
			-- underlying read. Void if the deadline or the connection ends
			-- first.
		require
			is_open: is_open
			a_count_non_negative: a_count >= 0
		local
			buffer: STRING
			chunk: detachable STRING
			deadline_exceeded: BOOLEAN
		do
			create buffer.make (a_count)
			from until buffer.count >= a_count or deadline_exceeded
			loop
				chunk := read_some (a_count - buffer.count, a_timeout_ms)
				if chunk = Void then
					deadline_exceeded := True
				else
					buffer.append (chunk)
				end
			end
			if buffer.count = a_count then
				Result := buffer
			end
		end

feature -- Shutdown

	close
			-- Close the connection. Idempotent.
		do
			if is_open then
				if use_tls then
					c_tls_close (ssl_ptr)
				end
				if attached underlying_socket as l_socket then
					l_socket.close
				end
			end
			is_open := False
		end

feature {NONE} -- Implementation

	connect_timeout_ms: INTEGER = 10000

	string_from_buffer (a_buffer: MANAGED_POINTER; a_count: INTEGER): STRING
			-- Copy the first `a_count' bytes of `a_buffer' into a fresh STRING.
		require
			a_buffer_attached: a_buffer /= Void
			a_count_in_range: a_count >= 0 and a_count <= a_buffer.count
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

	underlying_socket: detachable NETWORK_STREAM_SOCKET

	ssl_ptr: POINTER
			-- The OpenSSL `SSL *' handle for this connection. Meaningful only
			-- when `use_tls' and `is_open'.

feature {NONE} -- Native externals
		-- Plain (non-inline) declarations against `convex_native.c', compiled
		-- and linked as an ordinary external object. See convex_native.h for
		-- why this project avoids EiffelStudio's inline-C feature bodies here.

	c_tls_connect (a_fd: INTEGER; a_hostname: POINTER): POINTER
			-- Complete a TLS client handshake over already-connected `a_fd',
			-- sending `a_hostname' as SNI and verifying the peer certificate
			-- against the system trust store for that name. Returns the
			-- OpenSSL `SSL *' handle, or a default (null) pointer on failure;
			-- see `c_tls_last_error' for the reason.
		external
			"C signature (int, void *): void * use %"convex_native.h%""
		alias
			"convex_tls_connect"
		end

	c_tls_last_error_pointer: POINTER
			-- The most recent entry in OpenSSL's per-thread error queue, as a
			-- raw `const char *'. Call immediately after a failing TLS
			-- operation, before any other OpenSSL call disturbs the queue.
		external
			"C signature (): void * use %"convex_native.h%""
		alias
			"convex_tls_last_error"
		end

	c_tls_last_error: STRING
			-- `c_tls_last_error_pointer' copied into an Eiffel STRING.
		do
			create Result.make_from_c (c_tls_last_error_pointer)
		end

	c_tls_write (a_ssl: POINTER; a_data: POINTER; a_count: INTEGER): INTEGER
		external
			"C signature (void *, void *, int): int use %"convex_native.h%""
		alias
			"convex_tls_write"
		end

	c_tls_read (a_ssl: POINTER; a_buffer: POINTER; a_max: INTEGER): INTEGER
		external
			"C signature (void *, void *, int): int use %"convex_native.h%""
		alias
			"convex_tls_read"
		end

	c_tls_pending (a_ssl: POINTER): INTEGER
		external
			"C signature (void *): int use %"convex_native.h%""
		alias
			"convex_tls_pending"
		end

	c_tls_close (a_ssl: POINTER)
		external
			"C signature (void *) use %"convex_native.h%""
		alias
			"convex_tls_close"
		end

	c_raw_write (a_fd: INTEGER; a_data: POINTER; a_count: INTEGER): INTEGER
		external
			"C signature (int, void *, int): int use %"convex_native.h%""
		alias
			"convex_raw_write"
		end

	c_raw_read (a_fd: INTEGER; a_buffer: POINTER; a_max: INTEGER): INTEGER
		external
			"C signature (int, void *, int): int use %"convex_native.h%""
		alias
			"convex_raw_read"
		end


invariant
	descriptor_set_when_open: is_open implies descriptor > 0

end
