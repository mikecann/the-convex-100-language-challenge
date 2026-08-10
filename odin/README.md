<img src="logo.png" alt="Odin programming language logo" width="240">
<!-- Logo source: https://github.com/odin-lang/odin-lang.org/blob/master/static/images/logo-slim.png -->

# Odin

[Odin](https://odin-lang.org/) is a general-purpose systems programming language built around explicitness, high performance, and data-oriented programming. Ginger Bill started it in July 2016 after trying to improve C with a preprocessor; an early Pascal-like design soon became a new language influenced by Pascal, C, Go, Oberon-2, Newsqueak, and GLSL. Today it remains a specialist choice rather than a mainstream web language, with active use across games and graphics as well as applications, servers, kernels, and command-line tools. The project's [official FAQ](https://odin-lang.org/docs/faq/) has the fuller history and design rationale.

This repository's Convex client is an educational, unofficial demonstration. It is not a production SDK or an officially supported Convex package.

## Getting Started

Start with [`examples/basics/main.odin`](examples/basics/main.odin). It queries a fresh room, opens a Live subscription before writing, applies one idempotent mutation, and checks that both paths observe the same `0 -> 1` journey.

From the repository root, run the canonical example in its pinned Docker environment:

```console
./run verify-example odin
```

That command builds and runs the exact example shown below against a unique room. You do not need to install Odin on your host.

## Interesting Parts

### A query returns owned JSON, not a generated application type

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Count() {
  const state = useQuery(api.demo.state, { room: "readme-odin" });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**Odin**

```odin
package main

import convex "convex:."
import "core:encoding/json"
import "core:fmt"
import "core:os"

main :: proc() {
	// Read the real deployment at runtime, just like the canonical example.
	deployment_url := os.get_env_alloc("CONVEX_URL", context.allocator)
	defer delete(deployment_url)
	if deployment_url == "" { fmt.eprintln("CONVEX_URL is required"); return }

	client, create_err := convex.create(deployment_url)
	if create_err.kind != .None { fmt.eprintln(create_err.message); return }
	defer convex.destroy(client) // The caller owns and releases the client.

	args := `{"room":"readme-odin"}` // This client accepts named arguments as JSON text.
	result, query_err := convex.query(client, "demo:state", args)
	if query_err.kind != .None { fmt.eprintln(query_err.message); return }
	defer convex.destroy_result(&result) // The returned JSON and logs are owned too.

	root, parse_err := convex.parse_json(result.value_json, "demo state")
	if parse_err.kind != .None { fmt.eprintln(parse_err.message); return }
	defer json.destroy_value(root)

	object, ok := convex.as_object(root)
	if !ok { return }
	count_value, exists := convex.member(object, "count")
	if !exists { return }

	// Odin's tagged union makes the runtime JSON case explicit.
	#partial switch count in count_value {
	case json.Integer: fmt.println(count)
	case json.Float:   fmt.println(count) // Convex may encode a whole number as 0.0.
	case:              return
	}
}
```

React's `useQuery` is reactive and manages its subscription lifecycle. `convex.query` is deliberately a one-off HTTP snapshot. The Odin language can model richer application types, but this small client intentionally returns bounded JSON text so each application chooses its own decoding layer.

### Live updates are a resource the program owns

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const room = "readme-odin-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={() => {
        const runId = crypto.randomUUID(); // Every click is a fresh increment.
        void increment({ room, language: "TypeScript", runId });
      }}
    >
      Count: {state?.count ?? "loading"} {/* React rerenders after the mutation. */}
    </button>
  );
}
```

**Odin**

```odin
package main

import convex "convex:."
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

quote :: proc(text: string) -> string {
	encoded, err := json.marshal(text, {spec = .JSON})
	if err != nil { fmt.eprintln("could not encode arguments"); os.exit(1) }
	return string(encoded)
}

main :: proc() {
	deployment_url := os.get_env_alloc("CONVEX_URL", context.allocator)
	defer delete(deployment_url)
	if deployment_url == "" { fmt.eprintln("CONVEX_URL is required"); return }

	client, create_err := convex.create(deployment_url)
	if create_err.kind != .None { fmt.eprintln(create_err.message); return }
	defer convex.destroy(client) // Also closes Live networking.

	// The verifier supplies a unique room as the first argument.
	room := "odin-readme"
	if len(os.args) > 1 { room = os.args[1] }
	room_json := quote(room)
	defer delete(room_json)
	room_args := fmt.aprintf(`{{"room":%s}}`, room_json)
	defer delete(room_args)

	subscription, subscribe_err := convex.subscribe(client, "demo:state", room_args)
	if subscribe_err.kind != .None { fmt.eprintln(subscribe_err.message); return }
	defer convex.subscription_destroy(subscription) // Unsubscribe and release its queue.

	// The client exposes a blocking receive operation for the initial Live value.
	initial, received := convex.subscription_recv(subscription, 20 * time.Second)
	defer convex.destroy_update(&initial)
	if !received || initial.error.kind != .None { return }

	// This key is stable for a retry, while the verifier-unique room makes the run fresh.
	run_id := fmt.aprintf("%s-odin-once", room)
	defer delete(run_id)
	run_id_json := quote(run_id)
	defer delete(run_id_json)
	mutation_args := fmt.aprintf(
		`{{"room":%s,"language":"Odin","runId":%s}}`,
		room_json,
		run_id_json,
	)
	defer delete(mutation_args)
	mutation_result, mutation_err := convex.mutation(client, "demo:increment", mutation_args)
	if mutation_err.kind != .None { fmt.eprintln(mutation_err.message); return }
	defer convex.destroy_result(&mutation_result)

	// The next receive yields the reactive value published after the mutation.
	updated, received_update := convex.subscription_recv(subscription, 20 * time.Second)
	defer convex.destroy_update(&updated)
	if !received_update || updated.error.kind != .None { return }
}
```

The ordering is the same idea as `useQuery` plus `useMutation`: subscribe first, mutate, then observe the committed result. A blocking `subscription_recv` is this client's compact command-line API design, not a limitation of Odin. It makes ownership and timeouts visible where React normally handles them for a component.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, and structured errors | Verified by shared local and hosted conformance |
| Live initial values, updates, reconnect, unsubscribe, and clean close | Verified by shared local and hosted conformance |
| Shared HTTP and Live conformance | Passed; both capabilities earned |

The implementation is native Odin. It uses Odin's checked-in libcurl binding for ordinary HTTP, TLS, and WebSocket transport, while all Convex-specific request, response, and Live behavior is implemented in [`client/convex.odin`](client/convex.odin).

## Example

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

## Implementation Notes

The Docker build pins Odin `dev-2026-08` at commit `ea5175d865c2034b033ebf5653d83638f10bba54` and a WebSocket-enabled libcurl `8.21.0`, then produces `linux/amd64` executables. The minimal runtime contains those executables, their required dynamic libraries, CA and TLS files, and only the small shell and text-tool surface required by the repository verifier. It runs as UID/GID `65532:65532` and contains no Odin compiler or package manager.

Queries, mutations, and actions share one HTTP call path. Responses must be strict UTF-8 JSON and fit within a two MiB wire limit. `Error_Kind` keeps Convex function failures distinct from malformed protocol data, network failures, expired timeouts, and calls on a closed client. Since the public result is JSON text, the example explicitly decodes and validates the `count` field instead of pretending it already has a generated Odin type.

Live uses one owner thread for the WebSocket, reconnection state, and subscription changes. Callers send commands to that owner and receive updates through a one-record channel per subscription. Keeping only the newest update is a deliberate fit for reactive state: a slow consumer sees the latest value without growing an unbounded queue. Unsubscribe and replacement use generation barriers so an old relay cannot publish after acknowledgement.

This image carries a narrow, regression-tested patch to libcurl's connect-only WebSocket handling. It lets the owner distinguish a genuinely idle socket from a partially consumed successor frame, which matters because restarting from a false frame boundary would corrupt the Live stream. The client still uses Odin's checked-in libcurl binding; the patch does not delegate Convex behavior to another SDK.

## Known Issues

1. Live authentication changes, optimistic updates, mutations and actions over WebSocket, mutation replay, and journals are not implemented.
2. `TransitionChunk` assembly is deferred. Receiving one is treated as protocol drift and causes the Live connection to retire and reconnect.
3. Public query and update values are bounded JSON text rather than generated Odin application types, so callers must decode their own records.
4. The client allows at most 16 active subscriptions. Each subscription retains only its newest update, and the adapter output queue is capped at 16 records or eight MiB.
