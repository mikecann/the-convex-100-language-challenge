// A transport is either a plain TCP socket (for a local `http://` backend
// used in development and in this project's own local conformance target)
// or a TLS connection (for a hosted `https://` deployment). Everything above
// this layer — HTTP framing, the WebSocket handshake and frames, and the
// Convex protocol itself — is written once against this small interface
// instead of being duplicated per scheme.
use io;
use net;
use unix::poll;

export type transport = (net::socket | *tls_conn);
export type transport_error = !str;

export fn transport_fd(t: transport) int = {
	match (t) {
	case let s: net::socket =>
		return s: int;
	case let c: *tls_conn =>
		return tls_fd(c);
	};
};

export fn transport_read(t: transport, buf: []u8, d: *deadline) (size | transport_error) = {
	match (t) {
	case let s: net::socket =>
		return plain_read(s, buf, d);
	case let c: *tls_conn =>
		match (tls_read(c, buf, d)) {
		case let n: size =>
			return n;
		case let e: tls_error =>
			return e: str: transport_error;
		};
	};
};

export fn transport_write_all(t: transport, buf: []u8, d: *deadline) (void | transport_error) = {
	match (t) {
	case let s: net::socket =>
		return plain_write_all(s, buf, d);
	case let c: *tls_conn =>
		match (tls_write_all(c, buf, d)) {
		case void =>
			return;
		case let e: tls_error =>
			return e: str: transport_error;
		};
	};
};

export fn transport_close(t: transport) void = {
	match (t) {
	case let s: net::socket =>
		net::close(s)!;
	case let c: *tls_conn =>
		tls_close(c);
	};
};

fn wait_plain(fd: int, want_write: bool, d: *deadline) (void | transport_error) = {
	let fds: [1]poll::pollfd = [poll::pollfd {
		fd = fd,
		events = if (want_write) poll::event::POLLOUT else poll::event::POLLIN,
		revents = 0,
	}];
	const n = match (poll::poll(fds, remaining_ns(d))) {
	case let n: uint =>
		yield n;
	case =>
		return "poll failed while waiting for the socket";
	};
	if (n == 0) return "socket wait timed out";
};

fn plain_read(s: net::socket, buf: []u8, d: *deadline) (size | transport_error) = {
	if (len(buf) == 0) return 0z;
	if (expired(d)) return "read timed out";
	wait_plain(s: int, false, d)?;
	match (io::read(s, buf)) {
	case let n: size =>
		return n;
	case io::EOF =>
		return 0z;
	case =>
		return "read failed";
	};
};

fn plain_write_all(s: net::socket, buf: []u8, d: *deadline) (void | transport_error) = {
	let sent = 0z;
	for (sent < len(buf)) {
		if (expired(d)) return "write timed out";
		wait_plain(s: int, true, d)?;
		match (io::write(s, buf[sent..])) {
		case let n: size =>
			sent += n;
		case =>
			return "write failed";
		};
	};
};
