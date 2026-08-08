// A short tour of the native Hare Convex client: an HTTP query, a Live
// subscription started before a mutation so the initial snapshot cannot be
// missed, an idempotent mutation, and the resulting Live update. Every
// printed line is checked against the value Convex actually returned; this
// program exits non-zero if any of them disagree.
use convex;
use fmt;
use os;
use strings;

// Convex's JSON-safe profile may represent a whole number as either an
// integer or a float (for example the literal `0.0`), so the demo counter
// must accept both shapes. A float is only accepted when it is finite,
// mathematically integral, and inside i64's range; NaN, infinities,
// fractional values, and magnitudes that would round when converted are all
// rejected rather than silently truncated.
fn whole_counter(v: convex::value) i64 = {
	match (v) {
	case let i: i64 =>
		return i;
	case let f: f64 =>
		// f64 cannot represent every i64 exactly once magnitudes approach
		// 2^63, so the upper bound below is exclusive: it is the largest
		// power of two that both types can represent, and comparing against
		// it (rather than i64's true maximum) avoids a rounding surprise at
		// the boundary.
		const in_range = f == f && f >= -9223372036854775808.0 && f < 9223372036854775808.0 && f == (f: i64: f64);
		if (!in_range) fmt::fatal("demo count was a non-integral or out-of-range number");
		return f: i64;
	case =>
		fmt::fatal("demo count was not numeric");
	};
};

fn count_of(v: convex::value) i64 = {
	const field = match (convex::lookup(v, "count")) {
	case let p: *convex::value =>
		yield p;
	case void =>
		fmt::fatal("demo state was missing count");
	};
	return whole_counter(*field);
};

// Builds the `{"room": room}` argument object every demo call in this
// example shares.
fn room_args(room: str) convex::value = {
	let entries: []convex::entry = alloc([convex::entry { key = strings::dup("room"), value = strings::dup(room) }]);
	return entries;
};

export fn main() void = {
	// Configure the deployment: the client reads the URL from CONVEX_URL,
	// same as this project's other native clients, and accepts a room name
	// as its first argument so the shared verifier can target a unique room
	// per run.
	const url = match (os::getenv("CONVEX_URL")) {
	case let u: str =>
		yield u;
	case void =>
		fmt::fatal("CONVEX_URL is required");
	};
	const room = if (len(os::args) > 1) os::args[1] else "hare-basic-example";

	// Create the native Hare client.
	const client = match (convex::client_init(url)) {
	case let c: *convex::client =>
		yield c;
	case let e: convex::client_error =>
		fmt::fatal("could not create the client: {}", e: str);
	};
	defer convex::client_close(client);

	// Query the counter through Convex's documented HTTP endpoint.
	let query_args = room_args(room);
	let query_result = match (convex::client_call(client, "query", "demo:state", query_args)) {
	case let r: convex::call_result =>
		yield r;
	case let e: convex::client_error =>
		fmt::fatal("query failed: {}", e: str);
	};
	defer convex::call_result_finish(&query_result);
	const before = count_of(query_result.value);
	fmt::printfln("current count: {}", before)!;

	// Start Live before the mutation so the initial snapshot cannot be
	// missed: subscribing after the mutation could race the server and
	// deliver the post-mutation value as if it were the starting point.
	let subscribe_args = room_args(room);
	match (convex::client_subscribe(client, "example", "demo:state", subscribe_args)) {
	case void => void;
	case let e: convex::client_error =>
		fmt::fatal("subscribe failed: {}", e: str);
	};
	defer convex::client_unsubscribe(client, "example")!;

	// Wait for the actual initial Live value from the bounded event stream.
	const initial_live = wait_for_update(client, "example");
	let initial_live = initial_live;
	defer convex::finish(&initial_live);
	if (count_of(initial_live) != before) {
		fmt::fatal("live initial count did not match the query count");
	};
	fmt::printfln("live initial count: {}", before)!;

	// Apply the mutation with a stable idempotency key, so retrying this
	// example against the same room is always safe.
	let mutation_args: []convex::entry = alloc([
		convex::entry { key = strings::dup("room"), value = strings::dup(room) },
		convex::entry { key = strings::dup("language"), value = strings::dup("Hare") },
		convex::entry { key = strings::dup("runId"), value = strings::dup(strings::concat(room, "-once")) },
	]);
	let mutation_result = match (convex::client_call(client, "mutation", "demo:increment", mutation_args)) {
	case let r: convex::call_result =>
		yield r;
	case let e: convex::client_error =>
		fmt::fatal("mutation failed: {}", e: str);
	};
	defer convex::call_result_finish(&mutation_result);
	const applied = match (convex::lookup(mutation_result.value, "applied")) {
	case let p: *convex::value =>
		yield match (*p) {
		case let b: bool =>
			yield b;
		case =>
			fmt::fatal("mutation response's applied field was not a boolean");
		};
	case void =>
		fmt::fatal("mutation response was missing applied");
	};
	if (!applied) fmt::fatal("mutation was not applied");
	const new_state = match (convex::lookup(mutation_result.value, "state")) {
	case let p: *convex::value =>
		yield *p;
	case void =>
		fmt::fatal("mutation response was missing state");
	};
	const after = count_of(new_state);
	if (after != before + 1) fmt::fatal("mutation count did not advance by exactly one");
	fmt::println("mutation applied: true")!;
	fmt::printfln("mutation count: {}", after)!;

	// Wait for the actual resulting Live value before printing the
	// verification line.
	const updated_live = wait_for_update(client, "example");
	let updated_live = updated_live;
	defer convex::finish(&updated_live);
	if (count_of(updated_live) != after) {
		fmt::fatal("live updated count did not match the mutation count");
	};
	fmt::printfln("live updated count: {}", after)!;
	fmt::printfln("verified count: {} -> {}", before, after)!;
};

// Steps the Live connection until an update arrives for the given
// subscription, or ten seconds pass without one.
fn wait_for_update(client: *convex::client, subscription_id: str) convex::value = {
	let d = convex::deadline_in(10000);
	for (true) {
		if (convex::expired(&d)) fmt::fatal("timed out waiting for a Live update");
		match (convex::client_live_step(client, 100)) {
		case void =>
			continue;
		case let e: convex::sync_event =>
			let e = e;
			if (e.subscription_id != subscription_id) {
				convex::sync_event_finish(&e);
				continue;
			};
			if (e.kind != convex::sync_event_kind::UPDATED) {
				fmt::fatal("subscription failed: {}", e.error_message);
			};
			const value = e.value as convex::value;
			free(e.subscription_id);
			free(e.error_name);
			free(e.error_message);
			match (e.error_data) {
			case let d: convex::value =>
				let d = d;
				convex::finish(&d);
			case void => void;
			};
			match (e.logs) {
			case let l: convex::value =>
				let l = l;
				convex::finish(&l);
			case void => void;
			};
			return value;
		case let err: convex::client_error =>
			fmt::fatal("Live step failed: {}", err: str);
		};
	};
};
