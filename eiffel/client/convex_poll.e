note
	description: "[
		A thin wrapper around POSIX `select' used to give the adapter's
		single I/O owner a bounded wait across the control stream and, when
		a Live subscription is open, the sync WebSocket's file descriptor.
		Every wait carries an explicit deadline so neither a silent peer
		nor a stalled TLS read can block the process forever.
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
			-- 1 if `a_fd' is readable before the deadline, 0 on timeout,
			-- -1 on a `select' error (treated as "not ready" by callers).
		external
			"C inline use %"<sys/select.h>%""
		alias
			"{
				fd_set readfds;
				struct timeval tv;
				int rc;

				FD_ZERO(&readfds);
				FD_SET((int) $a_fd, &readfds);
				tv.tv_sec = ((long) $a_timeout_ms) / 1000;
				tv.tv_usec = (((long) $a_timeout_ms) % 1000) * 1000;

				rc = select((int) $a_fd + 1, &readfds, NULL, NULL, &tv);
				if (rc <= 0) {
					return 0;
				}
				return FD_ISSET((int) $a_fd, &readfds) ? 1 : 0;
			}"
		end

	c_select_two (a_fd_one, a_fd_two: INTEGER; a_timeout_ms: INTEGER): INTEGER
		external
			"C inline use %"<sys/select.h>%""
		alias
			"{
				fd_set readfds;
				struct timeval tv;
				int max_fd;
				int rc;
				int result;
				int fd1 = (int) $a_fd_one;
				int fd2 = (int) $a_fd_two;

				FD_ZERO(&readfds);
				max_fd = 0;
				if (fd1 >= 0) {
					FD_SET(fd1, &readfds);
					if (fd1 > max_fd) max_fd = fd1;
				}
				if (fd2 >= 0) {
					FD_SET(fd2, &readfds);
					if (fd2 > max_fd) max_fd = fd2;
				}
				tv.tv_sec = ((long) $a_timeout_ms) / 1000;
				tv.tv_usec = (((long) $a_timeout_ms) % 1000) * 1000;

				rc = select(max_fd + 1, &readfds, NULL, NULL, &tv);
				if (rc <= 0) {
					return 0;
				}
				result = 0;
				if (fd1 >= 0 && FD_ISSET(fd1, &readfds)) result |= 1;
				if (fd2 >= 0 && FD_ISSET(fd2, &readfds)) result |= 2;
				return result;
			}"
		end

end
