// The public native Hare client for Convex. HTTP query/mutation/action
// calls and the pinned `/api/sync` Live WebSocket profile are implemented
// directly in this module and the files beside it (json.ha, http.ha,
// tls.ha, transport.ha, ws.ha, live.ha); OpenSSL is reached only for the
// TLS record layer through Hare's C ABI, and no other Convex client,
// runtime, or command-line tool is ever shelled out to.
use fmt;
use os;
use strings;
use time;

export type client_error = !str;

export type function_error = struct {
	message: str,
	data: (value | void),
	logs: value,
};

export type call_result = struct {
	value: value,
	logs: value,
	failure: (function_error | void),
};

export fn call_result_finish(r: *call_result) void = {
	finish(&r.value);
	finish(&r.logs);
	match (r.failure) {
	case let f: function_error =>
		let f = f;
		match (f.data) {
		case let d: value =>
			let d = d;
			finish(&d);
		case void => void;
		};
		finish(&f.logs);
		free(f.message);
	case void => void;
	};
};

export type client = struct {
	deployment_url: str,
	endpoint: endpoint,
	auth_token: (str | void),
	live: nullable *live_manager,
	closed: bool,
};

const client_version = "hare-0.1.0";
const http_deadline_ms = 10000u64;

// Creates a client for one Convex deployment URL. The URL's scheme selects
// plain or TLS transport for both the HTTP calls below and any later Live
// subscription.
export fn client_init(deployment_url: str) (*client | client_error) = {
	const e = parse_endpoint(deployment_url)?;
	return alloc(client {
		deployment_url = strings::dup(deployment_url),
		endpoint = e,
		auth_token = void,
		live = null,
		closed = false,
	});
};

export fn client_close(c: *client) void = {
	if (c.closed) return;
	c.closed = true;
	match (c.live) {
	case let m: *live_manager =>
		live_stop(m);
		c.live = null;
	case null => void;
	};
	match (c.auth_token) {
	case let t: str =>
		free(t);
	case void => void;
	};
	endpoint_finish(&c.endpoint);
	free(c.deployment_url);
	free(c);
};

export fn client_set_auth(c: *client, token: str) (void | client_error) = {
	if (c.closed) return "client is closed";
	match (c.auth_token) {
	case let t: str =>
		free(t);
	case void => void;
	};
	c.auth_token = if (len(token) == 0) void else strings::dup(token);
};

// Calls one Convex query, mutation, or action over the documented JSON HTTP
// API. `args` must be a JSON object; ownership stays with the caller.
export fn client_call(c: *client, operation: str, path: str, args: value) (call_result | client_error) = {
	if (c.closed) return "client is closed";
	if (operation != "query" && operation != "mutation" && operation != "action") {
		return "operation must be query, mutation, or action";
	};
	if (len(path) < 3) return "function path is too short";

	// A slice literal like `[a, b, c]` assigned straight to a `[]T` binding
	// is not itself heap-allocated in Hare; only `alloc([...])`, or a slice
	// grown from an empty one through `append`, produces memory `free` may
	// later reclaim. Every owned slice built in this file goes through one
	// of those two paths.
	let body_entries: []entry = alloc([
		entry { key = strings::dup("path"), value = strings::dup(path) },
		entry { key = strings::dup("args"), value = args },
		entry { key = strings::dup("format"), value = strings::dup("json") },
	]);
	const body_value: value = body_entries;
	const payload = encode(body_value);
	defer free(payload);
	// Entry 1 ("args") borrows the caller's value and must not be freed
	// here; entries 0 and 2 own both the key and a freshly duplicated
	// string value.
	free(body_entries[0].key);
	finish(&body_entries[0].value);
	free(body_entries[1].key);
	free(body_entries[2].key);
	finish(&body_entries[2].value);
	free(body_entries);

	let headers: [](str, str) = alloc([("Accept", "application/json"), ("Convex-Client", client_version), ("Content-Type", "application/json")]);
	let auth_header = "";
	defer if (len(auth_header) > 0) free(auth_header);
	match (c.auth_token) {
	case let token: str =>
		auth_header = strings::concat("Bearer ", token);
		append(headers, ("Authorization", auth_header));
	case void => void;
	};
	defer free(headers);

	let d = deadline_in(http_deadline_ms);
	const t = endpoint_connect(&c.endpoint, &d)?;
	defer transport_close(t);
	const call_path = strings::concat("/api/", operation);
	defer free(call_path);
	const response = match (http_roundtrip(t, "POST", &c.endpoint, call_path, headers, strings::toutf8(payload), &d)) {
	case let r: http_response =>
		yield r;
	case let e: http_error =>
		return e: str: client_error;
	};
	defer free(response.body);
	if (response.status != 200) return "unexpected HTTP status from the deployment";

	const text = strings::fromutf8(response.body);
	const text = match (text) {
	case let s: str =>
		yield s;
	case =>
		return "response body was not valid UTF-8";
	};
	let parsed = match (parse(text)) {
	case let v: value =>
		yield v;
	case decode_error =>
		return "response body was not valid JSON";
	};
	return decode_call_result(parsed);
};

fn decode_call_result(parsed: value) (call_result | client_error) = {
	const status = match (lookup(parsed, "status")) {
	case let s: *value =>
		yield match (*s) {
		case let text: str =>
			yield text;
		case =>
			finish(&parsed);
			return "malformed response: status was not a string";
		};
	case void =>
		finish(&parsed);
		return "malformed response: missing status";
	};
	if (status != "success" && status != "error") {
		finish(&parsed);
		return "malformed response: unrecognized status";
	};

	const logs = match (lookup(parsed, "logLines")) {
	case let l: *value =>
		yield clone_value(*l);
	case void =>
		yield ([]: []value): value;
	};

	if (status == "error") {
		const message = match (lookup(parsed, "errorMessage")) {
		case let m: *value =>
			yield match (*m) {
			case let text: str =>
				yield strings::dup(text);
			case =>
				finish(&parsed);
				finish(&logs);
				return "malformed error response: errorMessage was not a string";
			};
		case void =>
			finish(&parsed);
			finish(&logs);
			return "malformed error response: missing errorMessage";
		};
		const data = match (lookup(parsed, "errorData")) {
		case let d: *value =>
			yield clone_value(*d): (value | void);
		case void =>
			yield void;
		};
		finish(&parsed);
		return call_result {
			value = void: value,
			logs = logs,
			failure = function_error { message = message, data = data, logs = clone_value(logs) },
		};
	};

	const result_value = match (lookup(parsed, "value")) {
	case let v: *value =>
		yield clone_value(*v);
	case void =>
		finish(&parsed);
		finish(&logs);
		return "malformed response: missing value";
	};
	finish(&parsed);
	return call_result { value = result_value, logs = logs, failure = void };
};

// value has no built-in deep copy, so lifting a member out of a parsed
// document (which will itself be freed) makes an independent owned copy by
// round-tripping it through the encoder. Convex payloads in this client's
// scope are small, so the extra pass is not a meaningful cost.
export fn clone_value(v: value) value = {
	const text = encode(v);
	defer free(text);
	return parse(text)!;
};

@test fn http_query_and_mutation_against_the_local_backend() void = {
	// A real end-to-end regression against a live Convex backend. It proves
	// the whole HTTP stack (URL parsing, plain-socket or TLS transport,
	// request framing, response parsing, and the Convex envelope) against
	// the real server, not a mock. Per this project's test-layer split,
	// `hare test` (the Docker `test` stage) runs entirely offline; this
	// regression only runs when CONVEX_URL is explicitly set, which is how
	// this repository's `./run verify` and `./run verify-hosted` invoke it.
	const url = match (os::getenv("CONVEX_URL")) {
	case let u: str =>
		yield u;
	case void =>
		return;
	};
	const c = client_init(url)!;
	defer client_close(c);

	// A fresh room name per run keeps this regression idempotent across
	// repeat local runs against the same persistent backend: demo:increment
	// is itself idempotent per (room, runId), so a fixed room would only
	// apply the mutation once and this assertion would fail on every run
	// after the first.
	const now = time::now(time::clock::REALTIME);
	const room = fmt::asprintf("hare-client-unit-test-{}-{}", now.sec, now.nsec);
	defer free(room);

	let args: []entry = alloc([entry { key = strings::dup("room"), value = strings::dup(room) }]);
	defer {
		free(args[0].key);
		finish(&args[0].value);
		free(args);
	};
	const query_args: value = args;
	// client_call never frees its `args` parameter (ownership stays with
	// the caller), so this test retains and frees `args` itself above.
	let result = client_call(c, "query", "demo:state", query_args)!;
	defer call_result_finish(&result);
	const count = lookup(result.value, "count") as *value;
	const before: i64 = match (*count) {
	case let i: i64 =>
		yield i;
	case let f: f64 =>
		yield f: i64;
	case =>
		abort("count was not numeric");
	};

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
	defer call_result_finish(&mutation_result);
	const applied = lookup(mutation_result.value, "applied") as *value;
	assert(*applied as bool);
	const new_state = lookup(mutation_result.value, "state") as *value;
	const new_count = lookup(*new_state, "count") as *value;
	const after: i64 = match (*new_count) {
	case let i: i64 =>
		yield i;
	case let f: f64 =>
		yield f: i64;
	case =>
		abort("count was not numeric");
	};
	assert(after == before + 1);
};
