# Convex from Odin

This folder is a native Odin client for Convex's documented JSON HTTP endpoints and the repository's pinned Live WebSocket profile. It is an educational implementation, not an official SDK or a package I would ship to production unchanged.

## Start here

Read [`examples/basics/main.odin`](examples/basics/main.odin). It queries a fresh room, subscribes before writing, applies one idempotent mutation, and proves the HTTP and Live paths agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, and structured errors | Implemented locally, no earned badge |
| Live initial values, updates, reconnect, unsubscribe, and clean close | Implemented locally, no earned badge |
| Shared HTTP and Live conformance | Not yet run or earned |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.odin -->
```odin
package main

import convex "convex:."
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

fail :: proc(message: string) -> ! {
	fmt.eprintln(message)
	os.exit(1)
}

// quote lets the verifier's unique room ID become JSON without trusting it as
// syntax. The same helper protects the mutation's idempotency key.
quote :: proc(text: string) -> string {
	encoded, err := json.marshal(text, {spec = .JSON})
	if err != nil { fail("could not encode example arguments") }
	return string(encoded)
}

// whole_count accepts Convex's 0 and 0.0 representations, but rejects quoted,
// fractional, non-finite, negative, and overflowing values.
whole_count :: proc(value: json.Value) -> (int, bool) {
	#partial switch number in value {
	case json.Integer:
		if number >= 0 && number <= i64(max(int)) { return int(number), true }
	case json.Float:
		if number == number && number >= 0 && number <= f64(max(int)) && math.trunc(f64(number)) == f64(number) {
			return int(number), true
		}
	}
	return 0, false
}

count_from_state :: proc(source: string) -> int {
	root, err := convex.parse_json(source, "example state")
	if err.kind != .None { fail(err.message) }
	defer json.destroy_value(root)
	object, ok := convex.as_object(root)
	if !ok { fail("example state is not an object") }
	value, exists := convex.member(object, "count")
	if !exists { fail("example state omitted count") }
	count, count_ok := whole_count(value)
	if !count_ok { fail("example count is not a whole in-range number") }
	return count
}

mutation_result :: proc(source: string) -> (applied: bool, count: int) {
	root, err := convex.parse_json(source, "example mutation result")
	if err.kind != .None { fail(err.message) }
	defer json.destroy_value(root)
	object, ok := convex.as_object(root)
	if !ok { fail("example mutation result is not an object") }
	applied_value, exists := convex.member(object, "applied")
	if !exists { fail("example mutation omitted applied") }
	#partial switch flag in applied_value {
	case json.Boolean: applied = bool(flag)
	case: fail("example mutation applied is not boolean")
	}
	state_value, state_exists := convex.member(object, "state")
	if !state_exists { fail("example mutation omitted state") }
	state_json, encode_err := convex.value_json(state_value)
	if encode_err.kind != .None { fail(encode_err.message) }
	defer delete(state_json)
	return applied, count_from_state(state_json)
}

main :: proc() {
	// Read the deployment at runtime, so neither credentials nor an environment
	// URL can be baked into the image.
	deployment_url := os.get_env_alloc("CONVEX_URL", context.allocator)
	defer delete(deployment_url)
	if deployment_url == "" { fail("CONVEX_URL is required") }
	room := "odin-example"
	if len(os.args) > 1 { room = os.args[1] }

	// Create one native Odin client. destroy closes Live networking even when a
	// later assertion exits this example early.
	client, create_err := convex.create(deployment_url)
	if create_err.kind != .None { fail(create_err.message) }
	defer convex.destroy(client)

	room_json := quote(room)
	defer delete(room_json)
	args := fmt.aprintf(`{{"room":%s}}`, room_json)
	defer delete(args)

	// The documented HTTP query gives us the starting state.
	initial, query_err := convex.query(client, "demo:state", args)
	if query_err.kind != .None { fail(query_err.message) }
	defer convex.destroy_result(&initial)
	initial_count := count_from_state(initial.value_json)
	if initial_count != 0 { fail("expected initial HTTP count 0") }
	fmt.printf("current count: %d\n", initial_count)

	// Start Live before mutating. This guarantees that the initial snapshot and
	// the later transition belong to one reactive query.
	subscription, subscribe_err := convex.subscribe(client, "demo:state", args)
	if subscribe_err.kind != .None { fail(subscribe_err.message) }
	defer convex.subscription_destroy(subscription)
	first_update, received := convex.subscription_recv(subscription, 20 * time.Second)
	if !received || first_update.error.kind != .None { fail("did not receive the initial Live value") }
	first_live_count := count_from_state(first_update.value_json)
	convex.destroy_update(&first_update)
	if first_live_count != 0 { fail("expected initial Live count 0") }
	fmt.printf("live initial count: %d\n", first_live_count)

	// The run ID makes this mutation idempotent if an operator retries the exact
	// example invocation after an uncertain network result.
	run_id := fmt.aprintf("%s-odin-once", room)
	defer delete(run_id)
	run_id_json := quote(run_id)
	defer delete(run_id_json)
	mutation_args := fmt.aprintf(`{{"room":%s,"language":"Odin","runId":%s}}`, room_json, run_id_json)
	defer delete(mutation_args)
	mutated, mutation_err := convex.mutation(client, "demo:increment", mutation_args)
	if mutation_err.kind != .None { fail(mutation_err.message) }
	defer convex.destroy_result(&mutated)
	applied, mutation_count := mutation_result(mutated.value_json)
	if !applied || mutation_count != 1 { fail("mutation did not produce the expected applied count 1") }
	fmt.printf("mutation applied: %v\n", applied)
	fmt.printf("mutation count: %d\n", mutation_count)

	// Live should now publish the committed state without another HTTP poll.
	second_update, updated := convex.subscription_recv(subscription, 20 * time.Second)
	if !updated || second_update.error.kind != .None { fail("did not receive the updated Live value") }
	live_count := count_from_state(second_update.value_json)
	convex.destroy_update(&second_update)
	if live_count != 1 { fail("expected updated Live count 1") }
	fmt.printf("live updated count: %d\n", live_count)

	// Print the shared verifier's final line only after every demonstrated value
	// agrees on the complete 0 -> 1 journey.
	fmt.printf("verified count: %d -> %d\n", initial_count, live_count)
}
```
<!-- END GENERATED EXAMPLE -->

This generated block is also the source shown on the evidence site. Edit the source file, then run `./run sync-examples` to refresh this projection.

## How it is built

The pinned Docker build fetches Odin `dev-2026-08` at commit `ea5175d865c2034b033ebf5653d83638f10bba54` and WebSocket-enabled libcurl `8.21.0` through checked SHA-256 archives. It compiles and tests on `linux/amd64`, proves the linked libcurl exposes both `ws` and `wss` through `curl_version_info`, and replaces a pinned Debian runtime filesystem with only the two executables, their dynamic-library closure, CA certificates, TLS provider files, `dash` as `/bin/sh`, and individual `id` and `grep` binaries required by the shared verifier. The final process runs as numeric UID/GID `65532:65532`. There is no multicall binary, compiler, package manager, downloader, Convex CLI, or Docker client in that image. The Docker build allowlists every executable in the runtime `PATH`, directly rejects forbidden commands, and exercises the exact assembled root filesystem through `chroot`, including an HTTPS connection probe that proves its copied TLS closure reaches the adapter rather than relying on the build image's library paths.

The language-local libcurl build carries one narrow source patch. In connect-only WebSocket mode, stock libcurl can consume the prefix of a second frame into its private decoder and then return `CURLE_AGAIN`, which otherwise looks identical to a genuinely idle socket. The patch extends the already-linked `curl_ws_meta` function only inside this private image so the client can distinguish those states without adding or exporting an ABI symbol. The build asserts the exact upstream source context before applying it, asserts the replacement context afterwards, and runs a C regression covering both partial-successor and true-idle `CURLE_AGAIN` behavior. The final runtime copies this patched library, not the Debian libcurl.

I have deliberately left `capabilities: []` in the manifest. Source being present is not the same thing as passing root-owned shared verification.

## Client design

Ordinary queries, mutations, and actions use Odin's checked-in libcurl binding for HTTP or HTTPS. Responses are streamed into a two MiB limit under one absolute cURL deadline, then parsed as strict UTF-8 JSON. Convex function failures retain `errorMessage`, optional structured `errorData`, and bounded `logLines`; malformed envelopes, transport failures, closed-client calls, and deadlines remain distinct error classes.

Live uses a real `ws://` or `wss://` connection to `/api/sync`. One owner thread alone opens, reads, writes, retires, and reconnects that socket. It owns the query-set version, validates each Transition atomically before publication, orders eight-byte timestamps as little-endian numbers, carries `connectionCount`, `lastCloseReason`, and `maxObservedTimestamp` across reconnects, replays sorted Adds, and suppresses an unchanged rehydration value once. A failed query is a delivered `FunctionError`, so a later `QueryUpdated` can recover the same subscription.

Every untrusted wire document is capped at two MiB, depth 64, and 65,536 JSON nodes before Odin allocates the parsed tree. There are at most 16 active subscriptions and 64 queued owner commands. Each subscription keeps only its newest update in a one-record channel. Partial WebSocket messages have an absolute five-second frame deadline, inactivity has a 30-second deadline, all writes have absolute deadlines, and reconnect backoff is capped at 15 seconds.

## Conformance adapter

`client/tests/conformance/` builds a strict NDJSON protocol v1 adapter. It reserves stdout for protocol events and accepts either stdin/stdout or one TCP `ADAPTER_LISTEN` controller (the shared harness binds it to `0.0.0.0:8080` so sibling containers on the pilot's Docker network can reach it). It supports `hello`, `query`, `mutation`, `action`, `subscribe`, `unsubscribe`, `setAuth`, `debugDisconnect`, and `close`.

Subscription IDs have generation barriers. Replacing or removing an ID invalidates the old generation before its relay is joined, so no stale event can cross the acknowledgement boundary. The output owner caps its queue at 16 records or eight MiB and uses a bounded close. `debugDisconnect` is adapter-only and retires the current socket before acknowledging, which lets the shared harness test genuine reconnection without host network tricks.

The language-local hostile peers cover dense and deeply nested JSON, malformed and oversized HTTP responses, non-2xx success-shaped bodies with later recovery, a stalled HTTP body, a valid WebSocket upgrade followed by a permanently partial frame, atomic transition rejection, failed-query recovery, little-endian timestamp order across `255 -> 256`, newest-only delivery, abandoned Add rollback, Unicode-scalar ID limits, strict command shapes, optional-field omission, and stale generation rejection. A separate checked-in process fixture drives the built adapter over its real TCP controller through malformed input, a structured HTTP error and recovery, same-ID replacement, unsubscribe, and genuine reconnect.

The `memory-probe` Docker target is deliberately not an ordinary build check. Run it with `--memory=128m --memory-swap=128m --pids-limit=64`; its entrypoint refuses an uncapped cgroup, drives near-limit HTTP values into a stopped TCP controller, and checks `memory.peak` or `memory.current` stayed below the cgroup ceiling. Passing a build without running that capped container is not memory evidence.

## Limitations

Live authentication lifecycle, optimistic updates, mutations and actions over WebSocket, mutation replay, journals, and `TransitionChunk` assembly are deferred. A server `TransitionChunk` is treated as protocol drift and retires the connection. Public values remain bounded JSON text so an application can choose its own Odin types. These limits are explicit and are not claimed as earned capabilities.
