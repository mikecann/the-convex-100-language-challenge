module convex

import time

#include <sys/socket.h>
#include <sys/time.h>

fn C.setsockopt(sockfd int, level int, optname int, optval voidptr, optlen u32) int

// TcpConn.set_read_timeout/set_write_timeout only ever store a V-level
// Duration field, consulted by V's own TcpConn.read_ptr/write_ptr wrapper.
// OpenSSL's SSL_read and SSL_write, called directly as C functions from
// net.openssl.SSLConn, read and write the raw file descriptor themselves and
// never go through that wrapper, so none of this client's absolute deadline
// bounds them - confirmed with strace: a read() past this client's own
// 20-second http_call_budget sits blocked until an external timeout kills
// the process, because the socket itself carries no receive timeout at the
// OS level. This sets SO_RCVTIMEO and SO_SNDTIMEO on the file descriptor
// directly, which the kernel enforces on every read(2)/write(2) against it
// regardless of which layer - V's own wrapper or OpenSSL's BIO - issues the
// call.
//
// SO_RCVTIMEO/SO_SNDTIMEO of exactly zero means "no timeout" (block
// forever), so an already-elapsed or otherwise non-positive deadline is
// clamped to one microsecond rather than passed through as zero: a read or
// write is still attempted, and any blocking phase is bounded to the
// shortest interval the kernel accepts, rather than becoming unbounded again
// at the one moment a deadline actually matters most.
fn set_socket_deadline(handle int, remaining time.Duration) {
	microseconds := if remaining <= 0 { i64(1) } else { i64(remaining) / 1000 }
	seconds := microseconds / 1_000_000
	tv := C.timeval{
		tv_sec:  u64(seconds)
		tv_usec: u64(microseconds % 1_000_000)
	}
	C.setsockopt(handle, C.SOL_SOCKET, C.SO_RCVTIMEO, voidptr(&tv), sizeof(C.timeval))
	C.setsockopt(handle, C.SOL_SOCKET, C.SO_SNDTIMEO, voidptr(&tv), sizeof(C.timeval))
}
