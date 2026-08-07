note
	description: "[
		A thin wrapper around POSIX `select' used to give the adapter's
		single I/O owner a bounded wait across the control stream and, when
		a Live subscription is open, the sync WebSocket's file descriptor.
		Every wait carries an explicit deadline so neither a silent peer
		nor a stalled TLS read can block the process forever. The actual
		`select' call lives in convex_native.c; see that file's header
		comment for why this project keeps such logic out of EiffelStudio's
		own inline-C feature bodies.
	]"

class
	CONVEX_POLL

feature -- Waiting

	wait_readable (a_fd: INTEGER; a_timeout_ms: INTEGER): BOOLEAN
			-- Does `a_fd' become readable within `a_timeout_ms'?
		require
			a_fd_valid: a_fd >= 0
			a_timeout_non_negative: a_timeout_ms >= 0
		do
			Result := c_select_one (a_fd, a_timeout_ms) > 0
		end

	wait_readable_two (a_fd_one, a_fd_two: INTEGER; a_timeout_ms: INTEGER): INTEGER
			-- Wait up to `a_timeout_ms' for either descriptor to become
			-- readable. Returns 0 (neither ready, deadline reached), 1
			-- (only `a_fd_one'), 2 (only `a_fd_two'), or 3 (both). Pass -1
			-- for a descriptor that should not be watched, for example
			-- while no Live subscription has an open socket yet.
		require
			a_fd_one_valid: a_fd_one >= -1
			a_fd_two_valid: a_fd_two >= -1
			a_timeout_non_negative: a_timeout_ms >= 0
		do
			Result := c_select_two (a_fd_one, a_fd_two, a_timeout_ms)
		end

feature {NONE} -- Externals

	c_select_one (a_fd: INTEGER; a_timeout_ms: INTEGER): INTEGER
		external
			"C signature (int, int): int use %"convex_native.h%""
		alias
			"convex_select_one"
		end

	c_select_two (a_fd_one, a_fd_two: INTEGER; a_timeout_ms: INTEGER): INTEGER
		external
			"C signature (int, int, int): int use %"convex_native.h%""
		alias
			"convex_select_two"
		end

end
