// The NDJSON adapter protocol v1 executable. This is test infrastructure
// for the shared conformance harness, not part of the educational convex::client
// API: it decodes one command per input line, calls the real convex::client in
// convex::client/, and encodes one event per output line. Everything Convex-specific
// (HTTP calls, the Live/WebSocket sync protocol, reconnects) is delegated to
// the convex::client; this file only speaks the adapter's own wire protocol.
use bufio;
use convex;
use fmt;
use io;
use net;
use net::ip;
use net::tcp;
use os;
use strconv;
use strings;
use unix::poll;

const adapter_language = "hare";
const adapter_implementation = "native-hare-openssl-c-abi";
const adapter_runtime = "hare-0.24.2";

type adapter = struct {
	c: nullable *convex::client,
};

export fn main() void = {
	const listen = os::getenv("ADAPTER_LISTEN");
	match (listen) {
	case void =>
		serve(os::stdin_file, os::stdout_file);
	case let addr: str =>
		serve_tcp(addr);
	};
};

fn serve_tcp(addr: str) void = {
	const colon = match (strings::rindex(addr, ":")) {
	case let i: size =>
		yield i;
	case void =>
		fmt::fatal("ADAPTER_LISTEN must be host:port");
	};
	const host = strings::sub(addr, 0, colon);
	const port_text = strings::sub(addr, colon + 1, strings::end);
	const port = match (strconv::stou16(port_text)) {
	case let p: u16 =>
		yield p;
	case =>
		fmt::fatal("ADAPTER_LISTEN has an invalid port");
	};
	const addr_parsed = match (ip::parse(host)) {
	case let a: ip::addr =>
		yield a;
	case =>
		fmt::fatal("ADAPTER_LISTEN host must be an IPv4 or IPv6 address");
	};
	const listener = match (tcp::listen(addr_parsed, port)) {
	case let l: net::socket =>
		yield l;
	case =>
		fmt::fatal("could not listen on ADAPTER_LISTEN");
	};
	defer net::close(listener)!;
	const conn = match (tcp::accept(listener)) {
	case let c: net::socket =>
		yield c;
	case =>
		fmt::fatal("could not accept a connection on ADAPTER_LISTEN");
	};
	serve(conn: io::file, conn: io::file);
};

fn serve(input: io::file, output: io::file) void = {
	let a = adapter { c = null };
	defer match (a.c) {
	case let c: *convex::client =>
		convex::client_close(c);
	case null => void;
	};

	let reader = bufio::newscanner(input, 4 * 1024 * 1024);
	defer bufio::finish(&reader);
	let closed = false;
	for (!closed) {
		const live_fd = match (a.c) {
		case let c: *convex::client =>
			yield match (c.live) {
			case let m: *convex::live_manager =>
				yield match (m.socket) {
				case let t: convex::transport =>
					yield convex::transport_fd(t): (int | void);
				case void =>
					yield void;
				};
			case null =>
				yield void;
			};
		case null =>
			yield void;
		};
		const input_ready = poll_line_ready(input, live_fd, 100);
		if (input_ready) {
			match (bufio::scan_line(&reader)) {
			case let line: const str =>
				closed = handle_line(&a, output, line);
			case io::EOF =>
				closed = true;
			case =>
				emit_error(output, "", "", "ProtocolError", "failed to read adapter input");
				closed = true;
			};
		};
		match (a.c) {
		case let c: *convex::client =>
			drain_live_events(c, output);
		case null => void;
		};
	};
};

// Polls stdin (or the accepted TCP socket) and, if connected, the Live
// socket together so a caller can decide whether a command line is worth
// reading this iteration. The Live socket itself is drained separately by
// [[drain_live_events]] via [[convex::client_live_step]]'s own short poll; this
// combined wait just keeps the loop from spinning at 100% CPU while idle.
fn poll_line_ready(input: io::file, live_fd: (int | void), timeout_ms: i64) bool = {
	let fds: []poll::pollfd = alloc([poll::pollfd { fd = input, events = poll::event::POLLIN, revents = 0 }]);
	defer free(fds);
	match (live_fd) {
	case let fd: int =>
		append(fds, poll::pollfd { fd = fd, events = poll::event::POLLIN, revents = 0 });
	case void => void;
	};
	match (poll::poll(fds, timeout_ms * 1000000)) {
	case let n: uint =>
		void;
	case => void;
	};
	return fds[0].revents != 0;
};

fn drain_live_events(c: *convex::client, output: io::file) void = {
	match (convex::client_live_step(c, 0)) {
	case void =>
		return;
	case let e: convex::sync_event =>
		let e = e;
		defer convex::sync_event_finish(&e);
		if (e.kind == convex::sync_event_kind::UPDATED) {
			emit_subscription_value(output, e.subscription_id, e.value as convex::value, e.logs);
		} else {
			emit_subscription_error(output, e.subscription_id, e.error_name, e.error_message, e.error_data, e.logs);
		};
	case let err: convex::client_error =>
		emit_error(output, "", "", "TransportError", err: str);
	};
};

// Handles one decoded command line. Returns true once `close` has been
// processed, so the caller's loop can stop.
fn handle_line(a: *adapter, output: io::file, line: str) bool = {
	let parsed = match (convex::parse(line)) {
	case let v: convex::value =>
		yield v;
	case convex::decode_error =>
		emit_error(output, "", "", "ProtocolError", "malformed adapter command");
		return false;
	};
	defer convex::finish(&parsed);

	const id = string_field(parsed, "id", "");
	const op = string_field(parsed, "op", "");

	switch (op) {
	case "hello" =>
		const version = match (convex::lookup(parsed, "protocolVersion")) {
		case let v: *convex::value =>
			yield match (*v) {
			case let n: i64 =>
				yield n;
			case =>
				yield -1i64;
			};
		case void =>
			yield -1i64;
		};
		if (version != 1) {
			emit_error(output, id, "", "ProtocolError", "unsupported adapter protocol version");
			return false;
		};
		emit_ready(output, id);
	case "query", "mutation", "action" =>
		handle_call(a, output, id, op, parsed);
	case "setAuth" =>
		handle_set_auth(a, output, id, parsed);
	case "subscribe" =>
		handle_subscribe(a, output, id, parsed);
	case "unsubscribe" =>
		handle_unsubscribe(a, output, id, parsed);
	case "debugDisconnect" =>
		handle_debug_disconnect(a, output, id);
	case "close" =>
		match (a.c) {
		case let c: *convex::client =>
			convex::client_close(c);
			a.c = null;
		case null => void;
		};
		emit_simple(output, id, "closed");
		return true;
	case =>
		emit_error(output, id, "", "ProtocolError", "unknown adapter operation");
	};
	return false;
};

fn ensure_client(a: *adapter, output: io::file, id: str) (*convex::client | void) = {
	match (a.c) {
	case let c: *convex::client =>
		return c;
	case null => void;
	};
	const url = match (os::getenv("CONVEX_URL")) {
	case let u: str =>
		yield u;
	case void =>
		emit_error(output, id, "", "ProtocolError", "CONVEX_URL is required");
		return void;
	};
	const c = match (convex::client_init(url)) {
	case let c: *convex::client =>
		yield c;
	case let e: convex::client_error =>
		emit_error(output, id, "", "ProtocolError", e: str);
		return void;
	};
	match (os::getenv("CONVEX_AUTH_TOKEN")) {
	case let token: str =>
		convex::client_set_auth(c, token)!;
	case void => void;
	};
	a.c = c;
	return c;
};

fn handle_call(a: *adapter, output: io::file, id: str, op: str, parsed: convex::value) void = {
	const c = match (ensure_client(a, output, id)) {
	case let c: *convex::client =>
		yield c;
	case void =>
		return;
	};
	const path = string_field(parsed, "path", "");
	const args = match (convex::lookup(parsed, "args")) {
	case let v: *convex::value =>
		yield convex::clone_value(*v);
	case void =>
		yield ([]: []convex::entry): convex::value;
	};
	let result = match (convex::client_call(c, op, path, args)) {
	case let r: convex::call_result =>
		yield r;
	case let e: convex::client_error =>
		let e = e;
		convex::finish(&args);
		emit_error(output, id, "", classify_client_error(e), e: str);
		return;
	};
	defer convex::call_result_finish(&result);
	match (result.failure) {
	case let f: convex::function_error =>
		emit_call_function_error(output, id, f);
	case void =>
		emit_result(output, id, result.value, result.logs);
	};
};

fn handle_set_auth(a: *adapter, output: io::file, id: str, parsed: convex::value) void = {
	const c = match (ensure_client(a, output, id)) {
	case let c: *convex::client =>
		yield c;
	case void =>
		return;
	};
	const token = string_field(parsed, "token", "");
	match (convex::client_set_auth(c, token)) {
	case void =>
		emit_simple(output, id, "ack");
	case let e: convex::client_error =>
		emit_error(output, id, "", "ProtocolError", e: str);
	};
};

fn handle_subscribe(a: *adapter, output: io::file, id: str, parsed: convex::value) void = {
	const c = match (ensure_client(a, output, id)) {
	case let c: *convex::client =>
		yield c;
	case void =>
		return;
	};
	const subscription_id = string_field(parsed, "subscriptionId", "");
	const path = string_field(parsed, "path", "");
	const args = match (convex::lookup(parsed, "args")) {
	case let v: *convex::value =>
		yield convex::clone_value(*v);
	case void =>
		yield ([]: []convex::entry): convex::value;
	};
	defer convex::finish(&args);
	match (convex::client_subscribe(c, subscription_id, path, args)) {
	case void =>
		emit_simple(output, id, "ack");
	case let e: convex::client_error =>
		emit_error(output, id, "", classify_client_error(e), e: str);
	};
};

fn handle_unsubscribe(a: *adapter, output: io::file, id: str, parsed: convex::value) void = {
	const c = match (ensure_client(a, output, id)) {
	case let c: *convex::client =>
		yield c;
	case void =>
		return;
	};
	const subscription_id = string_field(parsed, "subscriptionId", "");
	match (convex::client_unsubscribe(c, subscription_id)) {
	case void =>
		emit_simple(output, id, "ack");
	case let e: convex::client_error =>
		emit_error(output, id, "", "ProtocolError", e: str);
	};
};

fn handle_debug_disconnect(a: *adapter, output: io::file, id: str) void = {
	const c = match (ensure_client(a, output, id)) {
	case let c: *convex::client =>
		yield c;
	case void =>
		return;
	};
	match (convex::client_debug_disconnect(c)) {
	case void =>
		emit_simple(output, id, "ack");
	case let e: convex::client_error =>
		emit_error(output, id, "", "ProtocolError", e: str);
	};
};

fn classify_client_error(e: convex::client_error) str = "TransportError";

fn string_field(v: convex::value, key: str, default_: str) str = {
	match (convex::lookup(v, key)) {
	case let p: *convex::value =>
		return match (*p) {
		case let s: str =>
			yield s;
		case =>
			yield default_;
		};
	case void =>
		return default_;
	};
};

// --- event encoding -------------------------------------------------------

fn emit(output: io::file, v: convex::value) void = {
	const text = convex::encode(v);
	defer free(text);
	io::writeall(output, strings::toutf8(text))!;
	io::writeall(output, ['\n'])!;
};

fn emit_ready(output: io::file, id: str) void = {
	let members: []convex::entry = alloc([
		convex::entry { key = strings::dup("protocolVersion"), value = 1i64 },
		convex::entry { key = strings::dup("id"), value = strings::dup(id) },
		convex::entry { key = strings::dup("type"), value = strings::dup("ready") },
		convex::entry { key = strings::dup("language"), value = strings::dup(adapter_language) },
		convex::entry { key = strings::dup("implementation"), value = strings::dup(adapter_implementation) },
		convex::entry { key = strings::dup("runtime"), value = strings::dup(adapter_runtime) },
	]);
	emit_and_finish_entries(output, members);
};

fn emit_simple(output: io::file, id: str, kind: str) void = {
	let members: []convex::entry = alloc([
		convex::entry { key = strings::dup("id"), value = strings::dup(id) },
		convex::entry { key = strings::dup("type"), value = strings::dup(kind) },
	]);
	emit_and_finish_entries(output, members);
};

fn emit_result(output: io::file, id: str, result_value: convex::value, logs: convex::value) void = {
	let members: []convex::entry = alloc([
		convex::entry { key = strings::dup("id"), value = strings::dup(id) },
		convex::entry { key = strings::dup("type"), value = strings::dup("result") },
		convex::entry { key = strings::dup("value"), value = convex::clone_value(result_value) },
		convex::entry { key = strings::dup("logs"), value = convex::clone_value(logs) },
	]);
	emit_and_finish_entries(output, members);
};

fn emit_call_function_error(output: io::file, id: str, f: convex::function_error) void = {
	let error_members: []convex::entry = alloc([
		convex::entry { key = strings::dup("name"), value = strings::dup("FunctionError") },
		convex::entry { key = strings::dup("message"), value = strings::dup(f.message) },
	]);
	match (f.data) {
	case let d: convex::value =>
		append(error_members, convex::entry { key = strings::dup("data"), value = convex::clone_value(d) });
	case void => void;
	};
	let members: []convex::entry = alloc([
		convex::entry { key = strings::dup("id"), value = strings::dup(id) },
		convex::entry { key = strings::dup("type"), value = strings::dup("error") },
		convex::entry { key = strings::dup("error"), value = error_members: convex::value },
		convex::entry { key = strings::dup("logs"), value = convex::clone_value(f.logs) },
	]);
	emit_and_finish_entries(output, members);
};

fn emit_error(output: io::file, id: str, subscription_id: str, name: str, message: str) void = {
	let error_members: []convex::entry = alloc([
		convex::entry { key = strings::dup("name"), value = strings::dup(name) },
		convex::entry { key = strings::dup("message"), value = strings::dup(message) },
	]);
	let members: []convex::entry = [];
	if (len(subscription_id) > 0) {
		append(members, convex::entry { key = strings::dup("type"), value = strings::dup("subscription") });
		append(members, convex::entry { key = strings::dup("subscriptionId"), value = strings::dup(subscription_id) });
	} else {
		append(members, convex::entry { key = strings::dup("type"), value = strings::dup("error") });
		if (len(id) > 0) append(members, convex::entry { key = strings::dup("id"), value = strings::dup(id) });
	};
	append(members, convex::entry { key = strings::dup("error"), value = error_members: convex::value });
	emit_and_finish_entries(output, members);
};

fn emit_subscription_value(output: io::file, subscription_id: str, v: convex::value, logs: (convex::value | void)) void = {
	let members: []convex::entry = alloc([
		convex::entry { key = strings::dup("type"), value = strings::dup("subscription") },
		convex::entry { key = strings::dup("subscriptionId"), value = strings::dup(subscription_id) },
		convex::entry { key = strings::dup("value"), value = convex::clone_value(v) },
	]);
	match (logs) {
	case let l: convex::value =>
		append(members, convex::entry { key = strings::dup("logs"), value = convex::clone_value(l) });
	case void => void;
	};
	emit_and_finish_entries(output, members);
};

fn emit_subscription_error(output: io::file, subscription_id: str, name: str, message: str, data: (convex::value | void), logs: (convex::value | void)) void = {
	let error_members: []convex::entry = alloc([
		convex::entry { key = strings::dup("name"), value = strings::dup(name) },
		convex::entry { key = strings::dup("message"), value = strings::dup(message) },
	]);
	match (data) {
	case let d: convex::value =>
		append(error_members, convex::entry { key = strings::dup("data"), value = convex::clone_value(d) });
	case void => void;
	};
	let members: []convex::entry = alloc([
		convex::entry { key = strings::dup("type"), value = strings::dup("subscription") },
		convex::entry { key = strings::dup("subscriptionId"), value = strings::dup(subscription_id) },
		convex::entry { key = strings::dup("error"), value = error_members: convex::value },
	]);
	match (logs) {
	case let l: convex::value =>
		append(members, convex::entry { key = strings::dup("logs"), value = convex::clone_value(l) });
	case void => void;
	};
	emit_and_finish_entries(output, members);
};

fn emit_and_finish_entries(output: io::file, members: []convex::entry) void = {
	const v: convex::value = members;
	emit(output, v);
	convex::finish(&v);
};
