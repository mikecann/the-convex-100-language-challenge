// A small hand-written HTTP/1.1 client, just capable enough for Convex's
// documented JSON `/api/query`, `/api/mutation`, and `/api/action` endpoints
// and the WebSocket upgrade handshake `/api/sync` needs. Hare's standard
// library has no HTTP client, so request framing, status line and header
// parsing, and both Content-Length and chunked body decoding are implemented
// here in Hare rather than delegated to a C library.
use fmt;
use io;
use memio;
use net;
use net::dial;
use net::ip;
use net::uri;
use strconv;
use strings;

export type http_error = !str;

export type endpoint = struct {
	tls: bool,
	host: str,
	port: u16,
	// The URI's own path, with any trailing slash trimmed. Convex
	// deployment URLs ordinarily have no path, but this keeps a
	// self-hosted deployment mounted under a path prefix working too.
	base_path: str,
};

// Parses a Convex deployment URL into its connection parameters. Only
// `http` and `https` (equivalently `ws` and `wss`, since the sync endpoint
// is dialed with the same connection logic) are accepted.
export fn parse_endpoint(deployment_url: str) (endpoint | http_error) = {
	let u = match (uri::parse(deployment_url)) {
	case let u: uri::uri =>
		yield u;
	case uri::invalid =>
		return "invalid deployment URL";
	};
	defer uri::finish(&u);
	const tls = if (strings::compare(u.scheme, "https") == 0 || strings::compare(u.scheme, "wss") == 0) true
		else if (strings::compare(u.scheme, "http") == 0 || strings::compare(u.scheme, "ws") == 0) false
		else return "deployment URL must use http, https, ws, or wss";
	const host = match (u.host) {
	case let h: str =>
		yield strings::dup(h);
	case let a: ip::addr =>
		// ip::string's return value is statically allocated and reused on
		// the next call, so it must be duplicated before it can be stored
		// or later freed.
		yield strings::dup(ip::string(a));
	};
	const port = if (u.port != 0) u.port else if (tls) 443u16 else 80u16;
	let path = strings::dup(u.path);
	// Trim a lone trailing slash so concatenating "/api/query" never
	// produces a doubled separator.
	if (len(path) > 0 && strings::hassuffix(path, "/")) {
		const trimmed = strings::dup(strings::sub(path, 0, len(path) - 1));
		free(path);
		path = trimmed;
	};
	return endpoint {
		tls = tls,
		host = host,
		port = port,
		base_path = path,
	};
};

export fn endpoint_finish(e: *endpoint) void = {
	free(e.host);
	free(e.base_path);
};

// Dials and, for an `https`/`wss` endpoint, completes the TLS handshake.
// `d` bounds the whole operation.
export fn endpoint_connect(e: *endpoint, d: *deadline) (transport | http_error) = {
	const port_text = strconv::u16tos(e.port);
	const sock = match (dial::dial("tcp", e.host, port_text)) {
	case let s: net::socket =>
		yield s;
	case =>
		return "could not connect to the deployment";
	};
	if (!e.tls) return sock: transport;
	match (tls_connect(sock, e.host, d)) {
	case let c: *tls_conn =>
		return c: transport;
	case let err: tls_error =>
		net::close(sock)!;
		return err: str: http_error;
	};
};

export type http_response = struct {
	status: u32,
	body: []u8,
};

const max_http_headers: size = 64 * 1024;
const max_http_body: size = 2 * 1024 * 1024;

// Adapts a [[transport_error]] to this file's own [[http_error]] so the `?`
// operator can propagate it out of functions whose result type only lists
// http_error; Hare does not coerce between distinct named error types.
fn hread(t: transport, buf: []u8, d: *deadline) (size | http_error) = {
	match (transport_read(t, buf, d)) {
	case let n: size =>
		return n;
	case let e: transport_error =>
		return e: str: http_error;
	};
};

fn hwrite(t: transport, buf: []u8, d: *deadline) (void | http_error) = {
	match (transport_write_all(t, buf, d)) {
	case void =>
		return;
	case let e: transport_error =>
		return e: str: http_error;
	};
};

// Sends one HTTP/1.1 request over an already-connected transport and reads
// the whole response. The connection is always closed afterward (this
// client never keeps an HTTP connection alive across calls, since Convex
// query/mutation/action calls are infrequent enough that reconnecting is
// simpler and cannot leak a connection across two unrelated calls).
fn http_roundtrip(
	t: transport,
	method: str,
	e: *endpoint,
	path: str,
	extra_headers: [](str, str),
	body: []u8,
	d: *deadline,
) (http_response | http_error) = {
	let request = memio::dynamic();
	defer io::close(&request)!;
	fmt::fprintf(&request, "{} {}{} HTTP/1.1\r\n", method, e.base_path, path)!;
	fmt::fprintf(&request, "Host: {}\r\n", e.host)!;
	fmt::fprint(&request, "Connection: close\r\n")!;
	fmt::fprint(&request, "Accept-Encoding: identity\r\n")!;
	for (let i = 0z; i < len(extra_headers); i += 1) {
		fmt::fprintf(&request, "{}: {}\r\n", extra_headers[i].0, extra_headers[i].1)!;
	};
	if (len(body) > 0) {
		fmt::fprintf(&request, "Content-Length: {}\r\n", len(body))!;
	};
	fmt::fprint(&request, "\r\n")!;
	hwrite(t, memio::buffer(&request), d)?;
	if (len(body) > 0) hwrite(t, body, d)?;

	return read_http_response(t, d);
};

fn read_http_response(t: transport, d: *deadline) (http_response | http_error) = {
	let raw = memio::dynamic();
	defer io::close(&raw)!;
	let header_end = 0z;
	let buf: [4096]u8 = [0...];
	for (true) {
		const n = hread(t, buf, d)?;
		if (n == 0) return "connection closed before headers completed";
		io::writeall(&raw, buf[..n])!;
		const have = memio::buffer(&raw);
		header_end = find_header_end(have);
		if (header_end > 0) break;
		if (len(have) > max_http_headers) return "response headers too large";
	};
	const have = memio::buffer(&raw);
	const header_text = strings::fromutf8(have[..header_end])!;
	const status = parse_status_line(header_text)?;
	const content_length = header_value(header_text, "content-length");
	const chunked = match (header_value(header_text, "transfer-encoding")) {
	case let v: str =>
		yield strings::contains(v, "chunked");
	case void =>
		yield false;
	};

	let body_so_far = have[header_end..];
	let body: []u8 = [];
	defer free(body);
	if (chunked) {
		body = read_chunked_body(t, body_so_far, d)?;
	} else {
		const want = match (content_length) {
		case let v: str =>
			yield match (strconv::stoz(v)) {
			case let n: size =>
				yield n;
			case =>
				return "invalid Content-Length header";
			};
		case void =>
			yield 0z;
		};
		if (want > max_http_body) return "response body too large";
		body = if (want == 0) [] else alloc([0u8...], want);
		let filled = if (len(body_so_far) < want) len(body_so_far) else want;
		body[..filled] = body_so_far[..filled];
		for (filled < want) {
			const n = hread(t, body[filled..], d)?;
			if (n == 0) return "connection closed before body completed";
			filled += n;
		};
	};
	const owned: []u8 = if (len(body) == 0) [] else alloc([0u8...], len(body));
	owned[..] = body[..];
	return http_response { status = status, body = owned };
};

fn read_chunked_body(t: transport, seed: []u8, d: *deadline) ([]u8 | http_error) = {
	let pending = memio::dynamic();
	io::writeall(&pending, seed)!;
	let out = memio::dynamic();
	defer io::close(&pending)!;
	for (true) {
		let line = read_line(t, &pending, d)?;
		defer free(line);
		const size_text = match (strings::index(line, ";")) {
		case let i: size =>
			yield strings::sub(line, 0, i);
		case void =>
			yield line;
		};
		const chunk_size = match (strconv::stoz(size_text, strconv::base::HEX)) {
		case let n: size =>
			yield n;
		case =>
			io::close(&out)!;
			return "invalid chunk size";
		};
		if (chunk_size == 0) {
			// A trailing CRLF terminates the chunked body; trailers are not
			// expected from Convex's own API and are discarded if present.
			read_line(t, &pending, d)?;
			break;
		};
		if (len(memio::buffer(&out)) + chunk_size > max_http_body) {
			io::close(&out)!;
			return "chunked response body too large";
		};
		const chunk = read_exact(t, &pending, chunk_size, d)?;
		defer free(chunk);
		io::writeall(&out, chunk)!;
		read_line(t, &pending, d)?; // trailing CRLF after each chunk
	};
	return memio::buffer(&out);
};

// Reads one CRLF-terminated line, first draining anything already buffered
// in `pending` and topping it up from the transport as needed. The consumed
// prefix is removed from `pending`, and the returned line excludes the CRLF.
fn read_line(t: transport, pending: *memio::stream, d: *deadline) (str | http_error) = {
	for (true) {
		const have = memio::buffer(pending);
		const found = find_crlf(have);
		if (found is size) {
			const at = found as size;
			const line = strings::fromutf8(have[..at])!;
			const owned = strings::dup(line);
			const rest_len = len(have) - at - 2;
			const rest: []u8 = if (rest_len == 0) [] else alloc([0u8...], rest_len);
			rest[..] = have[at + 2..];
			memio::reset(pending);
			io::writeall(pending, rest)!;
			free(rest);
			return owned;
		};
		let buf: [1024]u8 = [0...];
		const n = hread(t, buf, d)?;
		if (n == 0) return "connection closed while reading a chunk header";
		io::writeall(pending, buf[..n])!;
	};
};

fn read_exact(t: transport, pending: *memio::stream, want: size, d: *deadline) ([]u8 | http_error) = {
	for (len(memio::buffer(pending)) < want) {
		let buf: [4096]u8 = [0...];
		const n = hread(t, buf, d)?;
		if (n == 0) return "connection closed mid-chunk";
		io::writeall(pending, buf[..n])!;
	};
	const have = memio::buffer(pending);
	const chunk: []u8 = if (want == 0) [] else alloc([0u8...], want);
	chunk[..] = have[..want];
	const rest_len = len(have) - want;
	const rest: []u8 = if (rest_len == 0) [] else alloc([0u8...], rest_len);
	rest[..] = have[want..];
	memio::reset(pending);
	io::writeall(pending, rest)!;
	free(rest);
	return chunk;
};

fn find_crlf(buf: []u8) (size | void) = {
	if (len(buf) < 2) return void;
	for (let i = 0z; i + 1 < len(buf); i += 1) {
		if (buf[i] == '\r' && buf[i + 1] == '\n') return i;
	};
	return void;
};

fn find_header_end(buf: []u8) size = {
	if (len(buf) < 4) return 0z;
	for (let i = 0z; i + 3 < len(buf); i += 1) {
		if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n') {
			return i + 4;
		};
	};
	return 0z;
};

fn parse_status_line(headers: str) (u32 | http_error) = {
	const line_end = match (strings::index(headers, "\r\n")) {
	case let i: size =>
		yield i;
	case void =>
		return "malformed status line";
	};
	const line = strings::sub(headers, 0, line_end);
	const parts = strings::split(line, " ");
	defer free(parts);
	if (len(parts) < 2) return "malformed status line";
	match (strconv::stou32(parts[1])) {
	case let code: u32 =>
		return code;
	case =>
		return "malformed status code";
	};
};

// Looks up one header's value, case-insensitively. Only the first matching
// header is returned, which is sufficient for the single-valued headers this
// client reads.
fn header_value(headers: str, name: str) (str | void) = {
	const lines = strings::split(headers, "\r\n");
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		const colon = match (strings::index(lines[i], ":")) {
		case let c: size =>
			yield c;
		case void =>
			continue;
		};
		const key = strings::trim(strings::sub(lines[i], 0, colon));
		if (len(key) != len(name)) continue;
		if (!ascii_ieq(key, name)) continue;
		return strings::trim(strings::sub(lines[i], colon + 1, strings::end));
	};
	return void;
};

fn ascii_ieq(a: str, b: str) bool = {
	const ab = strings::toutf8(a);
	const bb = strings::toutf8(b);
	if (len(ab) != len(bb)) return false;
	for (let i = 0z; i < len(ab); i += 1) {
		let x = ab[i];
		let y = bb[i];
		if (x >= 'A' && x <= 'Z') x += 32;
		if (y >= 'A' && y <= 'Z') y += 32;
		if (x != y) return false;
	};
	return true;
};
