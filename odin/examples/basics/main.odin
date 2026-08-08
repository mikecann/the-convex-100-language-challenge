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
