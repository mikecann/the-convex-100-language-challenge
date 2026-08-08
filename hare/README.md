# Convex from Hare

This folder is a native [Hare](https://harelang.org) client for Convex's
documented JSON HTTP endpoints and the project's pinned `/api/sync` Live
WebSocket profile. Hare is a small, self-hosted systems language with no
runtime and, deliberately, almost no standard library beyond the operating
system and a small core: there is no JSON, HTTP, TLS, or WebSocket support to
reach for, so all four are written here in Hare itself. The one place this
client leaves Hare is OpenSSL's `libssl`, reached through Hare's own C ABI for
the TLS record layer — the same kind of foreign-function boundary every other
native client in this project uses for its language's TLS story.

This is unofficial, educational teaching material, not an official Convex SDK
and not a package meant for publication.

## Start here

Read [`examples/basics/main.ha`](examples/basics/main.ha). It configures the
deployment from `CONVEX_URL`, performs an HTTP query, starts a Live
subscription before the mutation so the initial snapshot cannot be missed,
applies an idempotent mutation, and checks that both the HTTP and Live paths
agree on the resulting `0 -> 1` count.

## What works

| Capability | Status |
| --- | --- |
| Native implementation | Verified by shared local and hosted conformance at this exact head (31/31 both profiles) |
| HTTP query, mutation, and action | Verified by shared local and hosted conformance |
| Bearer-token lifecycle | Verified by shared local and hosted conformance |
| Live initial values, updates, unsubscribe, and error recovery | Verified by shared local and hosted conformance |
| Live reconnect | Verified by shared local and hosted conformance, including five real `debugDisconnect`-driven reconnects that each resend the active subscription and correctly suppress a duplicate event for an unchanged rehydrated value |
| Convex tagged values | Deferred, JSON-safe values only |
| Live authentication, optimistic writes, WebSocket mutations/actions | Deferred |

The full teaching example below is generated directly from the runnable
source.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ha -->
```hare
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
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test hare           # hare test (offline), and compiles both static binaries
./run verify-example hare # runs the canonical example against a unique room
./run verify hare         # adds shared local black-box conformance
./run verify-hosted hare  # repeats example and conformance against the hosted target
./run verify-all hare     # builds once, then runs both deployment profiles
```

`./run test hare` proves the client compiles, its offline unit tests pass
(JSON encode/decode, and every regression that does not need a live
deployment), and both `convex-adapter` and `convex-example` build as
statically linked `linux/amd64` binaries. The three regressions in this
suite that do need a live deployment — a real TLS handshake, an HTTP
query/mutation round trip, and a full Live subscribe/reconnect sequence —
each check for an opt-in environment variable (`HARE_TEST_NETWORK` or
`CONVEX_URL`) and are a silent no-op without it, so `./run test` stays
entirely offline while still being real code a developer can run against a
live deployment locally.

## Conformance and protocol notes

- `client/tests/conformance/main.ha` is the NDJSON adapter protocol v1
  executable. It is test infrastructure, not part of the educational API: it
  decodes one command per input line, calls the real client in `client/`, and
  encodes one event per output line, in both stdin/stdout mode and the
  `ADAPTER_LISTEN` TCP mode the shared harness uses.
- The Live layer (`client/live.ha`) is single-threaded and poll-driven by
  design: Hare has no threads or async runtime in its standard library, so
  one call stack owns the WebSocket at all times rather than handing it to a
  background worker. `client_live_step` advances the connection by at most
  one step — reconnecting if there are active subscriptions but no socket, or
  waiting up to a caller-chosen timeout for the next frame — so a caller loop
  that alternates between reading its own command source and calling this
  function stays responsive to `close`, `unsubscribe`, and `debugDisconnect`
  instead of blocking for seconds inside one deep read. Delivery buffering
  is a direct consequence of this: at most one already-decoded event is held
  between calls, so the step function itself is the backpressure.
- TLS (`client/tls.ha`) is the one C-ABI boundary in this client. It
  verifies the peer certificate against the system CA bundle, drives the
  handshake and encrypted read/write through non-blocking `SSL_get_error`
  retries polled with Hare's own `unix::poll`, and is exercised against a
  real TLS server as part of the test suite (see above).
- Static linking is a Dockerfile-level workaround, not a Hare feature: Hare's
  build driver always shells out to the platform toolchain's `cc` to link,
  but exposes no flag of its own to request `-static`. The Docker image
  installs a thin `cc` wrapper earlier on `PATH` that adds it, so both
  shipped binaries are fully static musl executables whose only runtime
  dependency is the CA certificate bundle a TLS deployment needs.
- This client does not use `net::dial::dial` for hostname resolution
  (`http.ha`'s `resolve_host` instead). Hare 0.24.2's `net::ip::parse`
  rejects a bare trailing `::` — valid IPv6 shorthand for an all-zero
  remainder, as in `fe00::` or `ff00::` — and `unix::hosts::next` propagates
  that as a hard error instead of skipping the unparseable line. Docker's
  container networking generates an `/etc/hosts` containing exactly those
  lines (`ip6-localnet`, `ip6-mcastprefix`), so `net::dial::dial` failed to
  resolve any hostname at all inside this project's own backend network,
  including a host with a perfectly valid entry earlier in the same file.
  `resolve_host` re-implements a tolerant `/etc/hosts` scan that skips a
  line it cannot parse, then falls back to a real DNS query.

## Honest limitations

- Hare 0.24 (current when this client was written) has no `hare fmt` or
  other blessed formatter in its toolchain. Source here is hand-formatted
  against the tabs-for-indentation style Hare's own standard library uses,
  not machine-checked.
- Reconnection has no exponential backoff yet: a Live bring-up that keeps
  failing is retried on the very next step call rather than after a growing
  delay.
- Convex tagged values, Live authentication, optimistic writes, WebSocket
  mutations and actions, and `TransitionChunk` assembly are all deferred.
- Fragmented incoming WebSocket messages and interleaved control frames are
  implemented in `client/ws.ha`, but exercised only against the real Convex
  backend so far, not yet against an adversarial local fixture peer the way
  this project's other native clients test hostile-peer behavior.
