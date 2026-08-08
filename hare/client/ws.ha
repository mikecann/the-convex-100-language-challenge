// A hand-written RFC 6455 WebSocket client layer: the HTTP Upgrade
// handshake, and masked frame encode / unmasked frame decode with
// fragmentation and control-frame support. Hare's standard library has no
// WebSocket implementation, so this is written directly against the
// transport abstraction in transport.ha.
use bytes;
use crypto::random;
use crypto::sha1;
use encoding::base64;
use fmt;
use hash;
use io;
use memio;
use strings;

export type ws_error = !str;

def ws_guid: str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Performs the HTTP/1.1 Upgrade handshake for one WebSocket connection.
// `path` is the request target (Convex's sync endpoint is `/api/sync`).
export fn ws_handshake(t: transport, host: str, path: str, extra_headers: [](str, str), d: *deadline) (void | ws_error) = {
	let key_bytes: [16]u8 = [0...];
	random::buffer(key_bytes[..]);
	const key = base64::encodestr(&base64::std_encoding, key_bytes[..]);
	defer free(key);

	let request = memio::dynamic();
	defer io::close(&request)!;
	fmt::fprintf(&request, "GET {} HTTP/1.1\r\n", path)!;
	fmt::fprintf(&request, "Host: {}\r\n", host)!;
	fmt::fprint(&request, "Upgrade: websocket\r\n")!;
	fmt::fprint(&request, "Connection: Upgrade\r\n")!;
	fmt::fprintf(&request, "Sec-WebSocket-Key: {}\r\n", key)!;
	fmt::fprint(&request, "Sec-WebSocket-Version: 13\r\n")!;
	for (let i = 0z; i < len(extra_headers); i += 1) {
		fmt::fprintf(&request, "{}: {}\r\n", extra_headers[i].0, extra_headers[i].1)!;
	};
	fmt::fprint(&request, "\r\n")!;
	wwrite(t, memio::buffer(&request), d)?;

	let raw = memio::dynamic();
	defer io::close(&raw)!;
	let header_end = 0z;
	for (true) {
		let buf: [1024]u8 = [0...];
		const n = wread(t, buf, d)?;
		if (n == 0) return "connection closed during the WebSocket handshake";
		io::writeall(&raw, buf[..n])!;
		header_end = find_header_end_bytes(memio::buffer(&raw));
		if (header_end > 0) break;
		if (len(memio::buffer(&raw)) > 16384) return "handshake response headers too large";
	};
	const header_text = strings::fromutf8(memio::buffer(&raw)[..header_end])!;
	if (!strings::hasprefix(header_text, "HTTP/1.1 101") && !strings::hasprefix(header_text, "HTTP/1.0 101")) {
		return "deployment did not upgrade the connection to a WebSocket";
	};
	const expected_accept = accept_key(key);
	defer free(expected_accept);
	if (!header_contains_token(header_text, "sec-websocket-accept", expected_accept)) {
		return "WebSocket handshake accept key did not match";
	};
};

fn wwrite(t: transport, buf: []u8, d: *deadline) (void | ws_error) = {
	match (transport_write_all(t, buf, d)) {
	case void =>
		return;
	case let e: transport_error =>
		return e: str: ws_error;
	};
};

fn wread(t: transport, buf: []u8, d: *deadline) (size | ws_error) = {
	match (transport_read(t, buf, d)) {
	case let n: size =>
		return n;
	case let e: transport_error =>
		return e: str: ws_error;
	};
};

fn find_header_end_bytes(buf: []u8) size = {
	if (len(buf) < 4) return 0z;
	for (let i = 0z; i + 3 < len(buf); i += 1) {
		if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n') return i + 4;
	};
	return 0z;
};

fn header_contains_token(headers: str, name: str, value: str) bool = {
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
		if (!ascii_ieq(key, name)) continue;
		const v = strings::trim(strings::sub(lines[i], colon + 1, strings::end));
		return ascii_ieq(v, value);
	};
	return false;
};

fn accept_key(client_key: str) str = {
	const combined = strings::concat(client_key, ws_guid);
	defer free(combined);
	let hasher = sha1::sha1();
	hash::write(&hasher, strings::toutf8(combined));
	let digest: [20]u8 = [0...];
	hash::sum(&hasher, digest[..]);
	return base64::encodestr(&base64::std_encoding, digest[..]);
};

export type ws_opcode = enum u8 {
	CONTINUATION = 0x0,
	TEXT = 0x1,
	BINARY = 0x2,
	CLOSE = 0x8,
	PING = 0x9,
	PONG = 0xa,
};

// Writes one complete, masked WebSocket frame (client-to-server frames must
// be masked per RFC 6455 5.3). `payload` is not fragmented by this client:
// Convex's own sync messages are small enough that single-frame messages are
// sufficient, matching the pinned sync profile this client targets.
export fn ws_write_frame(t: transport, opcode: ws_opcode, payload: []u8, d: *deadline) (void | ws_error) = {
	let header = memio::dynamic();
	defer io::close(&header)!;
	io::writeall(&header, [0x80 | opcode: u8])!; // FIN=1, no extensions
	if (len(payload) <= 125) {
		io::writeall(&header, [(len(payload): u8) | 0x80])!;
	} else if (len(payload) <= 65535) {
		io::writeall(&header, [126u8 | 0x80])!;
		let lenbuf: [2]u8 = [0...];
		lenbuf[0] = ((len(payload) >> 8) & 0xff): u8;
		lenbuf[1] = (len(payload) & 0xff): u8;
		io::writeall(&header, lenbuf)!;
	} else {
		io::writeall(&header, [127u8 | 0x80])!;
		let lenbuf: [8]u8 = [0...];
		let remaining = len(payload): u64;
		for (let i = 7; i >= 0; i -= 1) {
			lenbuf[i] = (remaining & 0xff): u8;
			remaining >>= 8;
		};
		io::writeall(&header, lenbuf)!;
	};
	let mask: [4]u8 = [0...];
	random::buffer(mask[..]);
	io::writeall(&header, mask)!;
	wwrite(t, memio::buffer(&header), d)?;

	if (len(payload) > 0) {
		let masked = alloc([0u8...], len(payload));
		defer free(masked);
		for (let i = 0z; i < len(payload); i += 1) masked[i] = payload[i] ^ mask[i % 4];
		wwrite(t, masked, d)?;
	};
};

export type ws_message = struct {
	opcode: ws_opcode,
	payload: []u8,
};

export fn ws_message_finish(m: *ws_message) void = free(m.payload);

const max_ws_message: size = 2 * 1024 * 1024;

// Reads one logical WebSocket message, transparently reassembling
// continuation frames and transparently answering an interleaved Ping with
// a Pong (Convex's server sends Pings as a liveness probe; this client
// always answers them itself rather than surfacing them to the caller,
// since a Ping carries no protocol state the sync layer needs to see).
// A Close frame is returned to the caller as-is so the owner can log the
// peer's stated reason.
export fn ws_read_message(t: transport, d: *deadline) (ws_message | ws_error) = {
	let assembled = memio::dynamic();
	let assembling = false;
	let final_opcode = ws_opcode::TEXT;
	for (true) {
		const frame = read_one_frame(t, d)?;
		defer free(frame.payload);
		switch (frame.opcode) {
		case ws_opcode::PING =>
			ws_write_frame(t, ws_opcode::PONG, frame.payload, d)?;
			continue;
		case ws_opcode::PONG =>
			continue;
		case ws_opcode::CLOSE =>
			io::close(&assembled)!;
			return ws_message { opcode = ws_opcode::CLOSE, payload = alloc(frame.payload...) };
		case => void;
		};
		if (!assembling) {
			final_opcode = if (frame.opcode == ws_opcode::CONTINUATION) ws_opcode::TEXT else frame.opcode;
			assembling = true;
		};
		if (len(memio::buffer(&assembled)) + len(frame.payload) > max_ws_message) {
			io::close(&assembled)!;
			return "WebSocket message exceeded the maximum size";
		};
		io::writeall(&assembled, frame.payload)!;
		if (frame.fin) {
			const out = alloc(memio::buffer(&assembled)...);
			io::close(&assembled)!;
			return ws_message { opcode = final_opcode, payload = out };
		};
	};
};

type raw_frame = struct {
	fin: bool,
	opcode: ws_opcode,
	payload: []u8,
};

fn read_one_frame(t: transport, d: *deadline) (raw_frame | ws_error) = {
	let head: [2]u8 = [0...];
	read_full(t, head, d)?;
	const fin = (head[0] & 0x80) != 0;
	const opcode = (head[0] & 0x0f): u8;
	const masked = (head[1] & 0x80) != 0;
	// Convex, like any conforming server, never masks frames it sends; a
	// masked server frame is a protocol violation this client refuses
	// rather than silently unmasking.
	if (masked) return "server frame was unexpectedly masked";
	let plen = (head[1] & 0x7f): u64;
	if (plen == 126) {
		let ext: [2]u8 = [0...];
		read_full(t, ext, d)?;
		plen = (ext[0]: u64 << 8) | ext[1]: u64;
	} else if (plen == 127) {
		let ext: [8]u8 = [0...];
		read_full(t, ext, d)?;
		plen = 0;
		for (let i = 0z; i < 8; i += 1) plen = (plen << 8) | ext[i]: u64;
	};
	if (plen: size > max_ws_message) return "WebSocket frame exceeded the maximum size";
	let payload: []u8 = if (plen == 0) [] else alloc([0u8...], plen: size);
	if (plen > 0) read_full(t, payload, d)?;
	const opcode_value = switch (opcode) {
	case 0x0 =>
		yield ws_opcode::CONTINUATION;
	case 0x1 =>
		yield ws_opcode::TEXT;
	case 0x2 =>
		yield ws_opcode::BINARY;
	case 0x8 =>
		yield ws_opcode::CLOSE;
	case 0x9 =>
		yield ws_opcode::PING;
	case 0xa =>
		yield ws_opcode::PONG;
	case =>
		free(payload);
		return "unknown WebSocket opcode";
	};
	return raw_frame { fin = fin, opcode = opcode_value, payload = payload };
};

fn read_full(t: transport, buf: []u8, d: *deadline) (void | ws_error) = {
	let got = 0z;
	for (got < len(buf)) {
		const n = wread(t, buf[got..], d)?;
		if (n == 0) return "connection closed mid-frame";
		got += n;
	};
};
