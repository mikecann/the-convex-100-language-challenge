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

feature {NONE} -- TLS externals

	c_tls_connect (a_fd: INTEGER; a_hostname: POINTER): POINTER
			-- Complete a TLS client handshake over already-connected `a_fd',
			-- sending `a_hostname' as SNI and verifying the peer certificate
			-- against the system trust store for that name. Returns the
			-- OpenSSL `SSL *' handle, or a default (null) pointer on failure;
			-- see `c_tls_last_error' for the reason.
		external
			"C inline use %"eif_openssl.h%""
		alias
			"{
				const SSL_METHOD *method;
				SSL_CTX *ctx;
				SSL *ssl;
				long verify_result;
				int rc;

				OPENSSL_init_ssl(0, NULL);
				method = TLS_client_method();
				ctx = SSL_CTX_new(method);
				if (ctx == NULL) {
					return (EIF_POINTER) NULL;
				}
				SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
				SSL_CTX_set_default_verify_paths(ctx);
				SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

				ssl = SSL_new(ctx);
				/* SSL_new bumps ctx's refcount; drop ours immediately so the
				   context is freed automatically when SSL_free later drops the
				   last reference. Eiffel only ever needs to hold the SSL *. */
				SSL_CTX_free(ctx);
				if (ssl == NULL) {
					return (EIF_POINTER) NULL;
				}
				SSL_set_fd(ssl, (int) $a_fd);
				SSL_set_tlsext_host_name(ssl, (const char *) $a_hostname);
				SSL_set1_host(ssl, (const char *) $a_hostname);

				rc = SSL_connect(ssl);
				if (rc != 1) {
					SSL_free(ssl);
					return (EIF_POINTER) NULL;
				}

				verify_result = SSL_get_verify_result(ssl);
				if (verify_result != X509_V_OK) {
					SSL_shutdown(ssl);
					SSL_free(ssl);
					return (EIF_POINTER) NULL;
				}

				return (EIF_POINTER) ssl;
			}"
		end

	c_tls_last_error: STRING
			-- The most recent entry in OpenSSL's per-thread error queue,
			-- rendered as text. Call immediately after a failing TLS
			-- operation, before any other OpenSSL call disturbs the queue.
		external
			"C inline use %"eif_openssl.h%""
		alias
			"{
				unsigned long code = ERR_get_error();
				char buf[256];
				if (code == 0) {
					return eif_string(\"no TLS error recorded\");
				}
				ERR_error_string_n(code, buf, sizeof(buf));
				return eif_string(buf);
			}"
		end

	c_tls_write (a_ssl: POINTER; a_data: POINTER; a_count: INTEGER): INTEGER
		external
			"C inline use %"eif_openssl.h%""
		alias
			"return (EIF_INTEGER) SSL_write((SSL *) $a_ssl, (const void *) $a_data, (int) $a_count);"
		end

	c_tls_read (a_ssl: POINTER; a_buffer: POINTER; a_max: INTEGER): INTEGER
		external
			"C inline use %"eif_openssl.h%""
		alias
			"return (EIF_INTEGER) SSL_read((SSL *) $a_ssl, (void *) $a_buffer, (int) $a_max);"
		end

	c_tls_pending (a_ssl: POINTER): INTEGER
		external
			"C inline use %"eif_openssl.h%""
		alias
			"return (EIF_INTEGER) SSL_pending((SSL *) $a_ssl);"
		end

	c_tls_close (a_ssl: POINTER)
		external
			"C inline use %"eif_openssl.h%""
		alias
			"{
				SSL_shutdown((SSL *) $a_ssl);
				SSL_free((SSL *) $a_ssl);
			}"
		end

feature {NONE} -- Plain TCP externals

	c_raw_write (a_fd: INTEGER; a_data: POINTER; a_count: INTEGER): INTEGER
		external
			"C inline use %"sys/socket.h%""
		alias
			"return (EIF_INTEGER) send((int) $a_fd, (const void *) $a_data, (size_t) $a_count, 0);"
		end

	c_raw_read (a_fd: INTEGER; a_buffer: POINTER; a_max: INTEGER): INTEGER
		external
			"C inline use %"sys/socket.h%""
		alias
			"return (EIF_INTEGER) recv((int) $a_fd, (void *) $a_buffer, (size_t) $a_max, 0);"
		end

invariant
	descriptor_set_when_open: is_open implies descriptor > 0

end
