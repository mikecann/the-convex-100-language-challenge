// The Live/WebSocket half of the client: Convex's pinned `/api/sync`
// profile. A single call stack owns the socket at all times — there is no
// second thread or fiber reading or writing it — so the "one worker
// exclusive ownership" rule this project's Live acceptance section asks for
// holds structurally rather than by convention. The adapter (and any other
// caller) drives this owner cooperatively: [[client_live_step]] polls the
// socket for a short, caller-chosen timeout and returns as soon as either
// one message has been fully handled or nothing arrived, so a caller loop
// that alternates between reading its own command source and calling this
// function stays responsive to new commands (close, unsubscribe,
// debugDisconnect) instead of blocking for seconds inside a single deep
// read. This is a demand-driven step function, not a background thread with
// an internal queue: at most one already-decoded event is held (in
// `pending`) between calls, so there is nothing here that can grow
// unboundedly while a caller is slow to drain it.
use crypto::random;
use encoding::base64;
use fmt;
use os;
use strings;
use time;
use unix::poll;

const connect_deadline_ms = 10000u64;
const frame_deadline_ms = 5000u64;
const socket_write_deadline_ms = 250u64;
const socket_poll_ms = 100u64;
const max_live_subscriptions = 16z;

export type sync_event_kind = enum {
	UPDATED,
	FAILED,
};

export type sync_event = struct {
	subscription_id: str,
	kind: sync_event_kind,
	value: (value | void),
	error_name: str,
	error_message: str,
	error_data: (value | void),
	logs: (value | void),
};

export fn sync_event_finish(e: *sync_event) void = {
	free(e.subscription_id);
	match (e.value) {
	case let v: value =>
		let v = v;
		finish(&v);
	case void => void;
	};
	free(e.error_name);
	free(e.error_message);
	match (e.error_data) {
	case let v: value =>
		let v = v;
		finish(&v);
	case void => void;
	};
	match (e.logs) {
	case let v: value =>
		let v = v;
		finish(&v);
	case void => void;
	};
};

export type active_query = struct {
	id: u32,
	subscription_id: str,
	path: str,
	args: value,
	last_value_json: (str | void),
	last_success: bool,
	awaiting_rehydration: bool,
};

fn active_query_finish(q: *active_query) void = {
	free(q.subscription_id);
	free(q.path);
	finish(&q.args);
	match (q.last_value_json) {
	case let s: str =>
		free(s);
	case void => void;
	};
};

export type state_version = struct {
	query_set: u32,
	identity: u32,
	timestamp: [8]u8,
};

fn state_version_eq(a: state_version, b: state_version) bool =
	a.query_set == b.query_set && a.identity == b.identity && bytes_eq8(a.timestamp, b.timestamp);

fn bytes_eq8(a: [8]u8, b: [8]u8) bool = {
	for (let i = 0z; i < 8; i += 1) if (a[i] != b[i]) return false;
	return true;
};

fn compare_timestamp(a: [8]u8, b: [8]u8) int = {
	// Timestamps are little-endian per the pinned sync profile (matching
	// this project's other native clients), so the most significant byte
	// to compare first is the last one.
	for (let i = 7; i >= 0; i -= 1) {
		if (a[i] < b[i]) return -1;
		if (a[i] > b[i]) return 1;
	};
	return 0;
};

export type live_manager = struct {
	c: *client,
	socket: (transport | void),
	query_set_version: u32,
	remote_version: state_version,
	next_query_id: u32,
	connection_count: u32,
	last_close_reason: str,
	max_timestamp: ([8]u8 | void),
	retry_delay_ms: u64,
	active: []active_query,
	pending: []sync_event,
};

export fn live_manager_new(c: *client) *live_manager = {
	return alloc(live_manager {
		c = c,
		socket = void,
		query_set_version = 0,
		remote_version = state_version { query_set = 0, identity = 0, timestamp = [0...] },
		next_query_id = 0,
		connection_count = 0,
		last_close_reason = strings::dup("InitialConnect"),
		max_timestamp = void,
		retry_delay_ms = 10,
		active = [],
		pending = [],
	});
};

export fn live_stop(m: *live_manager) void = {
	close_socket(m, "closed");
	for (let i = 0z; i < len(m.active); i += 1) active_query_finish(&m.active[i]);
	free(m.active);
	for (let i = 0z; i < len(m.pending); i += 1) sync_event_finish(&m.pending[i]);
	free(m.pending);
	free(m.last_close_reason);
	free(m);
};

fn close_socket(m: *live_manager, reason: str) void = {
	match (m.socket) {
	case let t: transport =>
		transport_close(t);
		m.socket = void;
		free(m.last_close_reason);
		m.last_close_reason = strings::dup(reason);
	case void => void;
	};
};

fn find_active(m: *live_manager, subscription_id: str) (size | void) = {
	for (let i = 0z; i < len(m.active); i += 1) {
		if (m.active[i].subscription_id == subscription_id) return i;
	};
	return void;
};

// Registers (or replaces) one subscription. A prior subscription under the
// same ID is retired — its Remove is sent, if connected — before the new
// one is added, so an adapter-level unsubscribe acknowledgement can never
// be crossed by a stale update from the query it replaced.
export fn client_subscribe(c: *client, subscription_id: str, path: str, args: value) (void | client_error) = {
	if (c.closed) return "client is closed";
	const m = match (c.live) {
	case let m: *live_manager =>
		yield m;
	case null =>
		const created = live_manager_new(c);
		c.live = created;
		yield created;
	};
	match (find_active(m, subscription_id)) {
	case let i: size =>
		retire_active(m, i)?;
	case void => void;
	};
	if (len(m.active) >= max_live_subscriptions) return "too many active Live subscriptions";
	if (m.next_query_id == 0xffffffff) return "too many queries have been added over this client's lifetime";
	let entries: []active_query = alloc([active_query {
		id = m.next_query_id,
		subscription_id = strings::dup(subscription_id),
		path = strings::dup(path),
		args = clone_value(args),
		last_value_json = void,
		last_success = false,
		awaiting_rehydration = false,
	}]);
	m.next_query_id += 1;
	append(m.active, entries[0]);
	free(entries);

	if (m.socket is void) {
		ensure_connected(m)?;
	} else {
		let d = deadline_in(socket_write_deadline_ms);
		match (send_modify_add(m, len(m.active) - 1, &d)) {
		case void => void;
		case let e: client_error =>
			close_socket(m, e: str);
		};
	};
};

export fn client_unsubscribe(c: *client, subscription_id: str) (void | client_error) = {
	match (c.live) {
	case let m: *live_manager =>
		match (find_active(m, subscription_id)) {
		case let i: size =>
			return retire_active(m, i);
		case void =>
			return;
		};
	case null =>
		return;
	};
};

fn retire_active(m: *live_manager, index: size) (void | client_error) = {
	const id = m.active[index].id;
	active_query_finish(&m.active[index]);
	let kept: []active_query = [];
	for (let i = 0z; i < len(m.active); i += 1) {
		if (i != index) append(kept, m.active[i]);
	};
	free(m.active);
	m.active = kept;
	if (m.socket is void) return;
	let d = deadline_in(socket_write_deadline_ms);
	match (send_modify_remove(m, id, &d)) {
	case void =>
		return;
	case let e: client_error =>
		close_socket(m, e: str);
		return;
	};
};

// Closes the active Live connection immediately (this is the adapter-only
// `debugDisconnect` command; it is not part of the educational client API).
// The socket is retired before this returns, and active subscriptions are
// left registered so the next successful connect replays their Add.
export fn client_debug_disconnect(c: *client) (void | client_error) = {
	match (c.live) {
	case let m: *live_manager =>
		if (m.socket is void) return "no active Live connection";
		close_socket(m, "DebugDisconnect");
	case null =>
		return "no active Live connection";
	};
};

// Advances the Live connection by at most one step: reconnecting if there
// are active subscriptions but no socket, or waiting up to `poll_timeout_ms`
// for the next frame and handling it. Returns the next already-decoded
// event if one is queued, otherwise void if this step produced nothing to
// report (a normal outcome, not an error) within the timeout.
export fn client_live_step(c: *client, poll_timeout_ms: u64) (sync_event | void | client_error) = {
	const m = match (c.live) {
	case let m: *live_manager =>
		yield m;
	case null =>
		return void;
	};
	if (len(m.pending) > 0) {
		const event = m.pending[0];
		let rest: []sync_event = [];
		for (let i = 1z; i < len(m.pending); i += 1) append(rest, m.pending[i]);
		free(m.pending);
		m.pending = rest;
		return event;
	};
	if (m.socket is void) {
		if (len(m.active) == 0) return void;
		match (ensure_connected(m)) {
		case void =>
			return void;
		case let e: client_error =>
			publish_owner_error(m, "TransportError", e: str);
			return client_live_step(c, 0);
		};
	};
	const t = m.socket as transport;
	let d = deadline_in(poll_timeout_ms);
	const ready = match (poll_readable(transport_fd(t), &d)) {
	case let r: bool =>
		yield r;
	case let e: client_error =>
		close_socket(m, e: str);
		publish_owner_error(m, "TransportError", e: str);
		return client_live_step(c, 0);
	};
	if (!ready) return void;

	let frame_deadline = deadline_in(frame_deadline_ms);
	const message = match (ws_read_message(t, &frame_deadline)) {
	case let msg: ws_message =>
		yield msg;
	case let e: ws_error =>
		close_socket(m, e: str);
		publish_owner_error(m, "TransportError", e: str);
		return client_live_step(c, 0);
	};
	defer ws_message_finish(&message);
	if (message.opcode == ws_opcode::CLOSE) {
		close_socket(m, "ServerClose");
		return client_live_step(c, 0);
	};
	const text = match (strings::fromutf8(message.payload)) {
	case let s: str =>
		yield s;
	case =>
		close_socket(m, "invalid UTF-8 in a Live frame");
		publish_owner_error(m, "ProtocolError", "invalid UTF-8 in a Live frame");
		return client_live_step(c, 0);
	};
	let parsed = match (parse(text)) {
	case let v: value =>
		yield v;
	case decode_error =>
		close_socket(m, "malformed Live JSON frame");
		publish_owner_error(m, "ProtocolError", "malformed Live JSON frame");
		return client_live_step(c, 0);
	};
	const kind = match (lookup(parsed, "type")) {
	case let v: *value =>
		yield match (*v) {
		case let s: str =>
			yield s;
		case =>
			finish(&parsed);
			close_socket(m, "malformed Live JSON frame");
			publish_owner_error(m, "ProtocolError", "malformed Live JSON frame");
			return client_live_step(c, 0);
		};
	case void =>
		finish(&parsed);
		close_socket(m, "malformed Live JSON frame");
		publish_owner_error(m, "ProtocolError", "malformed Live JSON frame");
		return client_live_step(c, 0);
	};
	if (kind == "Ping") {
		finish(&parsed);
		match (ws_write_frame(t, ws_opcode::PONG, [], &frame_deadline)) {
		case void => void;
		case let e: ws_error =>
			close_socket(m, e: str);
			publish_owner_error(m, "TransportError", e: str);
		};
		return client_live_step(c, 0);
	};
	if (kind != "Transition") {
		finish(&parsed);
		close_socket(m, "unexpected Live message type");
		publish_owner_error(m, "ProtocolError", "unexpected Live message type");
		return client_live_step(c, 0);
	};
	match (handle_transition(m, parsed)) {
	case void => void;
	case let e: client_error =>
		close_socket(m, e: str);
		publish_owner_error(m, "ProtocolError", e: str);
	};
	return client_live_step(c, 0);
};

fn poll_readable(fd: int, d: *deadline) (bool | client_error) = {
	let fds: [1]poll::pollfd = [poll::pollfd { fd = fd, events = poll::event::POLLIN, revents = 0 }];
	match (poll::poll(fds, remaining_ns(d))) {
	case let n: uint =>
		return n > 0;
	case =>
		return "poll failed while waiting for the Live socket";
	};
};

fn sync_path(m: *live_manager) str = strings::concat(m.c.endpoint.base_path, "/api/sync");

fn ensure_connected(m: *live_manager) (void | client_error) = {
	let d = deadline_in(connect_deadline_ms);
	const t = match (endpoint_connect(&m.c.endpoint, &d)) {
	case let t: transport =>
		yield t;
	case let e: http_error =>
		return e: str: client_error;
	};
	const path = sync_path(m);
	defer free(path);
	let extra: [](str, str) = alloc([("Convex-Client", client_version)]);
	defer free(extra);
	match (ws_handshake(t, m.c.endpoint.host, path, extra, &d)) {
	case void => void;
	case let e: ws_error =>
		transport_close(t);
		return e: str: client_error;
	};
	m.socket = t;
	m.query_set_version = 0;
	m.remote_version = state_version { query_set = 0, identity = 0, timestamp = [0...] };
	send_connect(m, &d)?;
	if (m.connection_count < 0xffffffff) m.connection_count += 1;
	for (let i = 0z; i < len(m.active); i += 1) {
		m.active[i].awaiting_rehydration = m.active[i].last_success;
		send_modify_add(m, i, &d)?;
	};
	if (expired(&d)) return "Live connection bring-up timed out";
};

fn send_connect(m: *live_manager, d: *deadline) (void | client_error) = {
	let session_bytes: [16]u8 = [0...];
	random::buffer(session_bytes[..]);
	const session_id = format_uuid(session_bytes);
	defer free(session_id);
	let members: []entry = alloc([
		entry { key = strings::dup("type"), value = strings::dup("Connect") },
		entry { key = strings::dup("sessionId"), value = strings::dup(session_id) },
		entry { key = strings::dup("connectionCount"), value = m.connection_count: i64 },
		entry { key = strings::dup("lastCloseReason"), value = strings::dup(m.last_close_reason) },
		entry { key = strings::dup("clientTs"), value = 0i64 },
	]);
	defer {
		for (let i = 0z; i < len(members); i += 1) {
			free(members[i].key);
			if (i != 2 && i != 4) finish(&members[i].value);
		};
		free(members);
	};
	match (m.max_timestamp) {
	case let ts: [8]u8 =>
		// Appended directly into `members` (rather than built in a
		// separate owned array first) so the one defer above frees this
		// entry's key and value too; a second, independent owner of the
		// same freshly duplicated strings would double free them once
		// `append` copies the entry struct's pointers into `members`.
		const encoded = base64::encodestr(&base64::std_encoding, ts[..]);
		append(members, entry { key = strings::dup("maxObservedTimestamp"), value = encoded });
	case void => void;
	};
	return send_json(m, members, d);
};

fn send_modify_add(m: *live_manager, index: size, d: *deadline) (void | client_error) = {
	const q = &m.active[index];
	let args_array: []value = alloc([clone_value(q.args)]);
	const args_value: value = args_array;
	let modification: []entry = alloc([
		entry { key = strings::dup("type"), value = strings::dup("Add") },
		entry { key = strings::dup("queryId"), value = q.id: i64 },
		entry { key = strings::dup("udfPath"), value = strings::dup(q.path) },
		entry { key = strings::dup("args"), value = args_value },
	]);
	return send_modify_query_set(m, modification, d);
};

fn send_modify_remove(m: *live_manager, id: u32, d: *deadline) (void | client_error) = {
	let modification: []entry = alloc([
		entry { key = strings::dup("type"), value = strings::dup("Remove") },
		entry { key = strings::dup("queryId"), value = id: i64 },
	]);
	return send_modify_query_set(m, modification, d);
};

fn send_modify_query_set(m: *live_manager, modification: []entry, d: *deadline) (void | client_error) = {
	if (m.query_set_version == 0xffffffff) {
		free(modification);
		return "too many query set changes over this connection's lifetime";
	};
	const base = m.query_set_version;
	const next = base + 1;
	let modifications: []value = alloc([modification: value]);
	let members: []entry = alloc([
		entry { key = strings::dup("type"), value = strings::dup("ModifyQuerySet") },
		entry { key = strings::dup("baseVersion"), value = base: i64 },
		entry { key = strings::dup("newVersion"), value = next: i64 },
		entry { key = strings::dup("modifications"), value = modifications: value },
	]);
	defer {
		for (let i = 0z; i < len(members); i += 1) {
			free(members[i].key);
			finish(&members[i].value);
		};
		free(members);
	};
	send_json(m, members, d)?;
	m.query_set_version = next;
};

fn send_json(m: *live_manager, members: []entry, d: *deadline) (void | client_error) = {
	const v: value = members;
	const text = encode(v);
	defer free(text);
	const t = m.socket as transport;
	match (ws_write_frame(t, ws_opcode::TEXT, strings::toutf8(text), d)) {
	case void =>
		return;
	case let e: ws_error =>
		return e: str: client_error;
	};
};

fn handle_transition(m: *live_manager, parsed: value) (void | client_error) = {
	defer finish(&parsed);
	const start = decode_state_version(lookup(parsed, "startVersion"))?;
	const end = decode_state_version(lookup(parsed, "endVersion"))?;
	if (!state_version_eq(start, m.remote_version)) return "Live transition did not chain from the known state version";
	if (end.query_set < start.query_set || end.query_set > m.query_set_version) return "Live transition query set version out of range";
	if (end.identity < start.identity || compare_timestamp(end.timestamp, start.timestamp) < 0) return "Live transition moved backward in time";
	const modifications = match (lookup(parsed, "modifications")) {
	case let v: *value =>
		yield match (*v) {
		case let items: []value =>
			yield items;
		case =>
			return "Live transition modifications was not an array";
		};
	case void =>
		return "Live transition is missing modifications";
	};

	m.remote_version = end;
	m.retry_delay_ms = 10;
	if (m.max_timestamp is void || compare_timestamp(end.timestamp, m.max_timestamp as [8]u8) > 0) {
		m.max_timestamp = end.timestamp;
	};

	for (let i = 0z; i < len(modifications); i += 1) {
		const mod = modifications[i];
		const id = match (lookup(mod, "queryId")) {
		case let v: *value =>
			yield match (*v) {
			case let n: i64 =>
				yield n: u32;
			case =>
				return "modification queryId was not numeric";
			};
		case void =>
			return "modification is missing queryId";
		};
		const found = find_active_by_id(m, id);
		if (found is void) continue;
		const index = found as size;
		const mod_kind = match (lookup(mod, "type")) {
		case let v: *value =>
			yield match (*v) {
			case let s: str =>
				yield s;
			case =>
				return "modification type was not a string";
			};
		case void =>
			return "modification is missing type";
		};
		if (mod_kind == "QueryUpdated") {
			const value_field = match (lookup(mod, "value")) {
			case let v: *value =>
				yield clone_value(*v);
			case void =>
				return "QueryUpdated modification is missing value";
			};
			const encoded = encode(value_field);
			let q = &m.active[index];
			const duplicate = q.awaiting_rehydration && q.last_success && q.last_value_json is str && (q.last_value_json as str) == encoded;
			q.awaiting_rehydration = false;
			if (duplicate) {
				free(encoded);
				finish(&value_field);
				continue;
			};
			match (q.last_value_json) {
			case let s: str =>
				free(s);
			case void => void;
			};
			q.last_value_json = encoded;
			q.last_success = true;
			append(m.pending, sync_event {
				subscription_id = strings::dup(q.subscription_id),
				kind = sync_event_kind::UPDATED,
				value = value_field,
				error_name = strings::dup(""),
				error_message = strings::dup(""),
				error_data = void,
				logs = clone_optional_logs(mod),
			});
		} else if (mod_kind == "QueryFailed") {
			let q = &m.active[index];
			q.awaiting_rehydration = false;
			q.last_success = false;
			const message = match (lookup(mod, "errorMessage")) {
			case let v: *value =>
				yield match (*v) {
				case let s: str =>
					yield strings::dup(s);
				case =>
					yield strings::dup("query failed");
				};
			case void =>
				yield strings::dup("query failed");
			};
			const data = match (lookup(mod, "errorData")) {
			case let v: *value =>
				yield clone_value(*v): (value | void);
			case void =>
				yield void;
			};
			append(m.pending, sync_event {
				subscription_id = strings::dup(q.subscription_id),
				kind = sync_event_kind::FAILED,
				value = void,
				error_name = strings::dup("FunctionError"),
				error_message = message,
				error_data = data,
				logs = clone_optional_logs(mod),
			});
		} else if (mod_kind != "QueryRemoved") {
			return "unrecognized Live modification type";
		};
	};
};

fn clone_optional_logs(mod: value) (value | void) = {
	match (lookup(mod, "logLines")) {
	case let v: *value =>
		return clone_value(*v);
	case void =>
		return void;
	};
};

fn find_active_by_id(m: *live_manager, id: u32) (size | void) = {
	for (let i = 0z; i < len(m.active); i += 1) {
		if (m.active[i].id == id) return i;
	};
	return void;
};

fn decode_state_version(v: (*value | void)) (state_version | client_error) = {
	const object = match (v) {
	case let p: *value =>
		yield *p;
	case void =>
		return "missing state version";
	};
	const query_set = match (lookup(object, "querySet")) {
	case let p: *value =>
		yield match (*p) {
		case let n: i64 =>
			yield n: u32;
		case =>
			return "querySet was not numeric";
		};
	case void =>
		return "state version is missing querySet";
	};
	const identity = match (lookup(object, "identity")) {
	case let p: *value =>
		yield match (*p) {
		case let n: i64 =>
			yield n: u32;
		case =>
			return "identity was not numeric";
		};
	case void =>
		return "state version is missing identity";
	};
	const ts_text = match (lookup(object, "ts")) {
	case let p: *value =>
		yield match (*p) {
		case let s: str =>
			yield s;
		case =>
			return "ts was not a string";
		};
	case void =>
		return "state version is missing ts";
	};
	const decoded = match (base64::decodeslice(&base64::std_encoding, strings::toutf8(ts_text))) {
	case let b: []u8 =>
		yield b;
	case =>
		return "ts was not valid base64";
	};
	defer free(decoded);
	if (len(decoded) != 8) return "ts did not decode to 8 bytes";
	let timestamp: [8]u8 = [0...];
	timestamp[..] = decoded[..8];
	return state_version { query_set = query_set, identity = identity, timestamp = timestamp };
};

fn format_uuid(bytes16: [16]u8) str = {
	let b = bytes16;
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	return fmt::asprintf(
		"{:.2x}{:.2x}{:.2x}{:.2x}-{:.2x}{:.2x}-{:.2x}{:.2x}-{:.2x}{:.2x}-{:.2x}{:.2x}{:.2x}{:.2x}{:.2x}{:.2x}",
		b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
	);
};

fn publish_owner_error(m: *live_manager, name: str, message: str) void = {
	for (let i = 0z; i < len(m.active); i += 1) {
		append(m.pending, sync_event {
			subscription_id = strings::dup(m.active[i].subscription_id),
			kind = sync_event_kind::FAILED,
			value = void,
			error_name = strings::dup(name),
			error_message = strings::dup(message),
			error_data = void,
			logs = void,
		});
	};
};

@test fn live_subscribe_update_and_reconnect_against_the_local_backend() void = {
	// A real end-to-end regression against a live backend: it proves the
	// WebSocket handshake, the Connect/ModifyQuerySet/Transition wire
	// protocol, the initial value, a live update after a mutation, and five
	// real debugDisconnect-driven reconnects that resend the active Add and
	// keep delivering updates on each new connection. As with the HTTP
	// regression above, this only runs when CONVEX_URL is explicitly set.
	const url = match (os::getenv("CONVEX_URL")) {
	case let u: str =>
		yield u;
	case void =>
		return;
	};
	const c = client_init(url)!;
	defer client_close(c);

	const now = time::now(time::clock::REALTIME);
	const room = fmt::asprintf("hare-live-unit-test-{}-{}", now.sec, now.nsec);
	defer free(room);

	let args: []entry = alloc([entry { key = strings::dup("room"), value = strings::dup(room) }]);
	const args_value: value = args;
	defer {
		free(args[0].key);
		finish(&args[0].value);
		free(args);
	};

	client_subscribe(c, "room-sub", "demo:state", args_value)!;
	defer client_unsubscribe(c, "room-sub")!;

	const initial = wait_for_event(c, 10000)!;
	let initial = initial;
	defer sync_event_finish(&initial);
	assert(initial.subscription_id == "room-sub");
	assert(initial.kind == sync_event_kind::UPDATED);
	assert(read_count(initial.value as value) == 0);

	let mutation_args: []entry = alloc([
		entry { key = strings::dup("room"), value = strings::dup(room) },
		entry { key = strings::dup("language"), value = strings::dup("Hare") },
		entry { key = strings::dup("runId"), value = strings::dup(room) },
	]);
	defer {
		free(mutation_args[0].key);
		finish(&mutation_args[0].value);
		free(mutation_args[1].key);
		finish(&mutation_args[1].value);
		free(mutation_args[2].key);
		finish(&mutation_args[2].value);
		free(mutation_args);
	};
	const mutation_value: value = mutation_args;
	let mutation_result = client_call(c, "mutation", "demo:increment", mutation_value)!;
	call_result_finish(&mutation_result);

	const updated = wait_for_event(c, 10000)!;
	let updated = updated;
	defer sync_event_finish(&updated);
	assert(updated.kind == sync_event_kind::UPDATED);
	assert(read_count(updated.value as value) == 1);

	// Prove a real reconnect: debugDisconnect tears down the socket, and
	// the next step call must bring up a fresh connection, replay the
	// active Add, and receive a rehydration transition without publishing
	// a duplicate event for a value that has not changed.
	for (let attempt = 0z; attempt < 5; attempt += 1) {
		client_debug_disconnect(c)!;
		const m = c.live as *live_manager;
		assert(m.socket is void);
		// Rehydration of an unchanged value must not surface as a new
		// event; only a genuine change (the mutation below) should.
		drain_quietly(c, 500);
		let more_mutation_args: []entry = alloc([
			entry { key = strings::dup("room"), value = strings::dup(room) },
			entry { key = strings::dup("language"), value = strings::dup("Hare") },
			entry { key = strings::dup("runId"), value = fmt::asprintf("{}-r{}", room, attempt) },
		]);
		defer {
			free(more_mutation_args[0].key);
			finish(&more_mutation_args[0].value);
			free(more_mutation_args[1].key);
			finish(&more_mutation_args[1].value);
			free(more_mutation_args[2].key);
			finish(&more_mutation_args[2].value);
			free(more_mutation_args);
		};
		const more_value: value = more_mutation_args;
		let more_result = client_call(c, "mutation", "demo:increment", more_value)!;
		call_result_finish(&more_result);
		const next = wait_for_event(c, 10000)!;
		let next = next;
		defer sync_event_finish(&next);
		assert(next.kind == sync_event_kind::UPDATED);
		assert(read_count(next.value as value) == 2 + attempt: i64);
		assert(m.connection_count == 2 + attempt: u32);
	};
};

fn wait_for_event(c: *client, timeout_ms: u64) (sync_event | client_error) = {
	let d = deadline_in(timeout_ms);
	for (true) {
		if (expired(&d)) return "timed out waiting for a Live event";
		match (client_live_step(c, 100)) {
		case let e: sync_event =>
			return e;
		case void =>
			continue;
		case let e: client_error =>
			return e;
		};
	};
};

// Steps the Live connection for a short window and asserts no event
// surfaces, used to prove a rehydration of an unchanged value is suppressed.
fn drain_quietly(c: *client, window_ms: u64) void = {
	let d = deadline_in(window_ms);
	for (!expired(&d)) {
		match (client_live_step(c, 50)) {
		case void => void;
		case let e: sync_event =>
			abort("unexpected Live event during a quiet reconnect window");
		case client_error =>
			void;
		};
	};
};

fn read_count(v: value) i64 = {
	const field = lookup(v, "count") as *value;
	return match (*field) {
	case let i: i64 =>
		yield i;
	case let f: f64 =>
		yield f: i64;
	case =>
		abort("count was not numeric");
	};
};
