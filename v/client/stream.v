module convex

import net
import net.ssl
import os
import time

// Deadline is an absolute monotonic budget. Every network operation in this
// client is measured against one of these rather than against a per-read
// timeout, because a peer that trickles one byte before each timeout would
// otherwise keep a "timed out" connection alive indefinitely.
struct Deadline {
	expires_at u64
}

fn deadline_in(budget time.Duration) Deadline {
	return Deadline{
		expires_at: time.sys_mono_now() + u64(budget)
	}
}

fn (deadline Deadline) remaining() time.Duration {
	now := time.sys_mono_now()
	if now >= deadline.expires_at {
		return time.Duration(0)
	}
	return time.Duration(i64(deadline.expires_at - now))
}

fn (deadline Deadline) expired() bool {
	return time.sys_mono_now() >= deadline.expires_at
}

// Stream is the only place ordinary V socket and TLS mechanics are used. Every
// Convex decision above it - framing, envelopes, the Live state machine - is
// implemented in V, so keeping this surface small also keeps the amount of
// standard-library behaviour the Docker pass must confirm small.
interface Stream {
mut:
	read_some(mut buffer []u8) !int
	write_some(data []u8) !int
	shutdown()
}

struct TcpStream {
mut:
	conn &net.TcpConn = unsafe { nil }
}

// TlsStream keeps the plaintext socket alongside the TLS session on purpose.
// The deadline machinery, and the Live worker's readiness wait, both operate on
// the socket, so wrapping an existing TcpConn is what lets one absolute budget
// cover a TLS connection as well as a plaintext one.
struct TlsStream {
mut:
	tcp  &net.TcpConn = unsafe { nil }
	conn &ssl.SSLConn = unsafe { nil }
}

// dial_stream applies the remaining absolute budget to the TLS handshake and
// every operation after V returns a TCP socket. V's synchronous dial surface
// does not let this source own a DNS/TCP-connect deadline, so that pre-socket
// phase is explicitly left as a Docker behavioural gate rather than claimed as
// an already-proven absolute timeout.
fn dial_stream(endpoint Endpoint, deadline Deadline) !Stream {
	// `Stream` is itself an interface, so `return` of a `ConvexError` here
	// needs an explicit `IError` cast: V resolves a bare `return` against
	// the success type first, and a struct that does not implement `Stream`
	// - which no error type should - is rejected as if it were an attempt
	// to satisfy that interface, rather than recognised as the error path.
	if deadline.expired() {
		return IError(transport_error('connect', 'connect deadline elapsed before dialling'))
	}
	mut tcp := net.dial_tcp(endpoint.authority) or {
		return IError(transport_error('connect', 'connect to ${endpoint.authority} failed: ${err.msg()}'))
	}
	tcp.set_read_timeout(deadline.remaining())
	tcp.set_write_timeout(deadline.remaining())
	if !endpoint.secure {
		return &TcpStream{
			conn: tcp
		}
	}
	// `validate: true` on its own is not enough to verify anything. V's
	// `net.ssl` calls SSL_CTX_load_verify_locations only when `verify` names a
	// bundle, and it never calls SSL_CTX_set_default_verify_paths, so the
	// context is left with an empty trust store and every handshake fails with
	// verify result 20 — including against a certificate the system trusts.
	// The bundle is therefore named here, honouring SSL_CERT_FILE so a caller
	// can point at its own CA, as the TLS closure probe does.
	ca_bundle := os.getenv_opt('SSL_CERT_FILE') or { '/etc/ssl/certs/ca-certificates.crt' }
	mut conn := ssl.new_ssl_conn(ssl.SSLConnectConfig{
		validate: true
		verify:   ca_bundle
	}) or {
		tcp.close() or {}
		return IError(transport_error('connect', 'could not create a TLS context: ${err.msg()}'))
	}
	// The handshake shares the connect budget, so a peer that completes the TCP
	// connect and then stalls the handshake cannot extend the total wait.
	conn.connect(mut tcp, endpoint.host) or {
		tcp.close() or {}
		return IError(transport_error('connect', 'TLS handshake with ${endpoint.host} failed: ${err.msg()}'))
	}
	return &TlsStream{
		tcp:  tcp
		conn: conn
	}
}

fn (mut stream TcpStream) read_some(mut buffer []u8) !int {
	return stream.conn.read(mut buffer)
}

fn (mut stream TcpStream) write_some(data []u8) !int {
	return stream.conn.write(data)
}

fn (mut stream TcpStream) shutdown() {
	stream.conn.close() or {}
}

fn (mut stream TlsStream) read_some(mut buffer []u8) !int {
	// The underlying socket carries the per-read timeout, and the caller
	// re-checks its own absolute deadline between reads, which is what bounds a
	// peer that trickles one byte before every timeout.
	return stream.conn.read(mut buffer)
}

fn (mut stream TlsStream) write_some(data []u8) !int {
	return stream.conn.write(data)
}

// write_stream_all is deliberately outside the concrete TCP/TLS wrappers. A
// partial TLS or TCP write must re-check the same absolute deadline before the
// next write, otherwise a peer that accepts one byte per relative timeout can
// turn a five-second request into an unbounded loop.
fn write_stream_all(mut stream Stream, data []u8, deadline Deadline, operation string) ! {
	mut written := 0
	for written < data.len {
		if deadline.expired() {
			return transport_error(operation, 'write deadline elapsed')
		}
		set_stream_timeout(mut stream, deadline)
		count := stream.write_some(data[written..]) or {
			return transport_error(operation, 'write failed: ${err.msg()}')
		}
		if count <= 0 || count > data.len - written {
			return transport_error(operation, 'socket accepted an invalid write count')
		}
		written += count
	}
	if deadline.expired() {
		return transport_error(operation, 'write deadline elapsed')
	}
}

fn (mut stream TlsStream) shutdown() {
	stream.conn.shutdown() or {}
	stream.tcp.close() or {}
}

// set_stream_timeout narrows the socket's per-read timeout to whatever remains
// of the absolute budget, for plaintext and TLS alike.
fn set_stream_timeout(mut stream Stream, deadline Deadline) {
	remaining := deadline.remaining()
	wall_deadline := time.now().add(remaining)
	if mut stream is TcpStream {
		stream.conn.set_read_timeout(remaining)
		stream.conn.set_write_timeout(remaining)
		stream.conn.set_read_deadline(wall_deadline)
		stream.conn.set_write_deadline(wall_deadline)
	} else if mut stream is TlsStream {
		stream.tcp.set_read_timeout(remaining)
		stream.tcp.set_write_timeout(remaining)
		stream.tcp.set_read_deadline(wall_deadline)
		stream.tcp.set_write_deadline(wall_deadline)
		// The pinned OpenSSL wrapper uses this duration to build one cumulative
		// deadline around all WANT_READ/WANT_WRITE retries in a call.
		stream.conn.duration = remaining
	}
}

// Readiness is checked on the underlying TCP socket for plaintext and TLS.
// It consumes no bytes, so the Live owner can continue servicing commands
// while an otherwise healthy WebSocket is idle.
fn stream_is_readable(mut stream Stream, slice time.Duration) bool {
	if mut stream is TcpStream {
		return socket_is_readable(mut stream.conn, slice)
	} else if mut stream is TlsStream {
		// SSL_read may have decrypted more than the caller requested. Those bytes
		// live in OpenSSL even when the underlying TCP socket is no longer
		// readable, so polling only the fd can strand an already-buffered frame.
		if openssl_has_pending(stream.conn) {
			return true
		}
		return socket_is_readable(mut stream.tcp, slice)
	}
	return false
}

// socket_is_readable is the one readiness primitive the Live worker uses so it can
// service controller commands while a healthy connection is simply idle. It
// consumes no bytes, so returning false is always safe to retry; anything that
// happens after a read has begun is handled by abandoning the connection.
fn socket_is_readable(mut conn net.TcpConn, slice time.Duration) bool {
	conn.set_read_timeout(slice)
	conn.set_read_deadline(time.now().add(slice))
	conn.wait_for_read() or { return false }
	return true
}
