// A thin TLS wrapper over OpenSSL's libssl, reached through Hare's C ABI.
// Hare's standard library has no TLS implementation, so this file is the one
// place the client crosses into C: it performs the record-layer handshake
// and encrypted read/write, while every Convex-specific behaviour (the HTTP
// envelope, the WebSocket framing, and the sync protocol state machine)
// stays in Hare. This mirrors how this project's other native clients reach
// TLS through their own language's normal C interop, not through a second
// Convex client.
use net;
use net::tcp;
use os;
use rt;
use strings;
use types::c;
use unix::poll;

export type tls_error = !str;

// SSL_ERROR_WANT_READ/WRITE, from OpenSSL's headers. Non-blocking retries
// against a blocking-mode socket should not normally see these, but the FFI
// boundary reports them literally so a real one is never mistaken for a
// hard failure.
def ssl_error_want_read: int = 2;
def ssl_error_want_write: int = 3;
def ssl_error_zero_return: int = 6;

def ssl_ctrl_set_tlsext_hostname: int = 55;
def tlsext_nametype_host_name: i64 = 0;
def ssl_verify_peer: int = 1;

@symbol("TLS_client_method") fn TLS_client_method() *opaque;
@symbol("SSL_CTX_new") fn SSL_CTX_new(method: *opaque) nullable *opaque;
@symbol("SSL_CTX_free") fn SSL_CTX_free(ctx: *opaque) void;
@symbol("SSL_CTX_set_verify") fn SSL_CTX_set_verify(ctx: *opaque, mode: int, callback: nullable *opaque) void;
@symbol("SSL_CTX_set_default_verify_paths") fn SSL_CTX_set_default_verify_paths(ctx: *opaque) int;
@symbol("SSL_CTX_load_verify_locations") fn SSL_CTX_load_verify_locations(ctx: *opaque, file: *const c::char, path: nullable *const c::char) int;
@symbol("SSL_new") fn SSL_new(ctx: *opaque) nullable *opaque;
@symbol("SSL_free") fn SSL_free(ssl: *opaque) void;
@symbol("SSL_set_fd") fn SSL_set_fd(ssl: *opaque, fd: int) int;
@symbol("SSL_set1_host") fn SSL_set1_host(ssl: *opaque, name: *const c::char) int;
@symbol("SSL_ctrl") fn SSL_ctrl(ssl: *opaque, cmd: int, larg: i64, parg: *opaque) i64;
@symbol("SSL_connect") fn SSL_connect(ssl: *opaque) int;
@symbol("SSL_read") fn SSL_read(ssl: *opaque, buf: *u8, num: int) int;
@symbol("SSL_write") fn SSL_write(ssl: *opaque, buf: *const u8, num: int) int;
@symbol("SSL_get_error") fn SSL_get_error(ssl: *opaque, ret: int) int;
@symbol("SSL_shutdown") fn SSL_shutdown(ssl: *opaque) int;
@symbol("SSL_get_verify_result") fn SSL_get_verify_result(ssl: *opaque) i64;

// A TLS connection over an already-connected socket. The socket's lifetime
// is owned by this type once wrapped: [[tls_close]] shuts down the TLS
// session and closes the underlying file descriptor together.
export type tls_conn = struct {
	ctx: *opaque,
	ssl: *opaque,
	sock: net::socket,
};

// System CA bundle locations shipped by the common base images this
// project's runtime stages use. The first path that exists is loaded; a
// deployment without a working CA bundle fails the handshake rather than
// silently skipping verification.
const ca_bundle_paths: [_]str = [
	"/etc/ssl/certs/ca-certificates.crt",
	"/etc/ssl/cert.pem",
];

// Wraps an already-connected plain socket in a TLS session and performs the
// handshake, verifying the peer certificate against the system CA bundle and
// the given hostname. `d` bounds only this call.
export fn tls_connect(sock: net::socket, hostname: str, d: *deadline) (*tls_conn | tls_error) = {
	const method = TLS_client_method();
	const ctx = match (SSL_CTX_new(method)) {
	case let p: *opaque =>
		yield p;
	case null =>
		return "could not create TLS context";
	};
	SSL_CTX_set_verify(ctx, ssl_verify_peer, null);
	load_ca_bundle(ctx);
	const ssl = match (SSL_new(ctx)) {
	case let p: *opaque =>
		yield p;
	case null =>
		SSL_CTX_free(ctx);
		return "could not create TLS session";
	};
	const fd = sock: int;
	SSL_set_fd(ssl, fd);
	const chostname = c::fromstr(hostname);
	defer free(chostname);
	SSL_set1_host(ssl, chostname);
	SSL_ctrl(ssl, ssl_ctrl_set_tlsext_hostname, tlsext_nametype_host_name, chostname: *opaque);

	for (true) {
		const rc = SSL_connect(ssl);
		if (rc == 1) break;
		const code = SSL_get_error(ssl, rc);
		if (code == ssl_error_want_read || code == ssl_error_want_write) {
			if (expired(d)) {
				SSL_free(ssl);
				SSL_CTX_free(ctx);
				return "TLS handshake timed out";
			};
			wait_socket(fd, code == ssl_error_want_write, d)?;
			continue;
		};
		SSL_free(ssl);
		SSL_CTX_free(ctx);
		return "TLS handshake failed";
	};
	if (SSL_get_verify_result(ssl) != 0) {
		SSL_free(ssl);
		SSL_CTX_free(ctx);
		return "TLS peer certificate verification failed";
	};
	return alloc(tls_conn { ctx = ctx, ssl = ssl, sock = sock });
};

fn load_ca_bundle(ctx: *opaque) void = {
	// SSL_CTX_set_default_verify_paths consults OpenSSL's own compiled-in
	// defaults (SSL_CERT_FILE/SSL_CERT_DIR or its build-time paths), which
	// are reliable in the full OpenSSL install used for `test`, but not
	// guaranteed to exist in a stripped-down runtime image. Loading one of
	// this project's own known bundle paths explicitly makes verification
	// work identically in both.
	SSL_CTX_set_default_verify_paths(ctx);
	for (let i = 0z; i < len(ca_bundle_paths); i += 1) {
		if (!path_exists(ca_bundle_paths[i])) continue;
		const cpath = c::fromstr(ca_bundle_paths[i]);
		defer free(cpath);
		SSL_CTX_load_verify_locations(ctx, cpath, null);
	};
};

fn path_exists(path: str) bool = {
	match (rt::access(path, rt::F_OK)) {
	case let ok: bool =>
		return ok;
	case rt::errno =>
		return false;
	};
};

// Blocks until the socket is ready for the requested direction, or `d`
// elapses.
fn wait_socket(fd: int, want_write: bool, d: *deadline) (void | tls_error) = {
	let fds: [1]poll::pollfd = [poll::pollfd {
		fd = fd,
		events = if (want_write) poll::event::POLLOUT else poll::event::POLLIN,
		revents = 0,
	}];
	const n = match (poll::poll(fds, remaining_ns(d))) {
	case let n: uint =>
		yield n;
	case =>
		return "poll failed while waiting for the TLS socket";
	};
	if (n == 0) return "TLS socket wait timed out";
};

// Reads up to len(buf) bytes, blocking (subject to `d`) until at least one
// byte is available or the connection ends.
export fn tls_read(conn: *tls_conn, buf: []u8, d: *deadline) (size | tls_error) = {
	if (len(buf) == 0) return 0z;
	const fd = conn.sock: int;
	for (true) {
		const rc = SSL_read(conn.ssl, &buf[0], len(buf): int);
		if (rc > 0) return rc: size;
		const code = SSL_get_error(conn.ssl, rc);
		if (code == ssl_error_zero_return) return 0z;
		if (code == ssl_error_want_read || code == ssl_error_want_write) {
			if (expired(d)) return "TLS read timed out";
			wait_socket(fd, code == ssl_error_want_write, d)?;
			continue;
		};
		return "TLS read failed";
	};
};

// Writes the entire buffer, blocking (subject to `d`) as needed.
export fn tls_write_all(conn: *tls_conn, buf: []u8, d: *deadline) (void | tls_error) = {
	const fd = conn.sock: int;
	let sent = 0z;
	for (sent < len(buf)) {
		const rc = SSL_write(conn.ssl, &buf[sent], (len(buf) - sent): int);
		if (rc > 0) {
			sent += rc: size;
			continue;
		};
		const code = SSL_get_error(conn.ssl, rc);
		if (code == ssl_error_want_read || code == ssl_error_want_write) {
			if (expired(d)) return "TLS write timed out";
			wait_socket(fd, code == ssl_error_want_write, d)?;
			continue;
		};
		return "TLS write failed";
	};
};

export fn tls_fd(conn: *tls_conn) int = conn.sock: int;

export fn tls_close(conn: *tls_conn) void = {
	SSL_shutdown(conn.ssl);
	SSL_free(conn.ssl);
	SSL_CTX_free(conn.ctx);
	net::close(conn.sock)!;
	free(conn);
};

@test fn real_tls_handshake_against_a_public_host() void = {
	// This is the one real-network regression in the suite: it proves the
	// FFI boundary and certificate verification actually work against a
	// live TLS server, the same way this project's other native clients
	// pin one real-TLS test rather than trusting mocked fixtures alone.
	// The Docker `test` stage runs entirely offline (per this project's
	// test-layer split: local and hosted network conformance belong to
	// `./run verify` and `./run verify-hosted`, not to `hare test`), so
	// this regression only runs when a developer opts in by setting
	// HARE_TEST_NETWORK, and is a silent no-op otherwise.
	if (os::getenv("HARE_TEST_NETWORK") is void) return;
	// resolve_host, not net::dial::dial: see its doc comment in http.ha for
	// why this client never uses Hare 0.24.2's own name resolution path.
	const resolved = resolve_host("example.com")!;
	const addr = tcp::connect(resolved, 443)!;
	let d = deadline_in(10000);
	const conn = tls_connect(addr, "example.com", &d)!;
	defer tls_close(conn);
	const request: []u8 = strings::toutf8("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
	tls_write_all(conn, request, &d)!;
	let buf: [256]u8 = [0...];
	const n = tls_read(conn, buf, &d)!;
	assert(n > 0);
	const text = strings::fromutf8(buf[..n])!;
	assert(strings::hasprefix(text, "HTTP/1.1 200"));
};
