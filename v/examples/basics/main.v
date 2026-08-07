module main

import os
import time
import x.json2
import convex

// How long to wait for one Live delivery. Convex normally answers a
// subscription in milliseconds; this budget only exists so a broken deployment
// fails the example instead of hanging the verifier.
const live_budget = 20 * time.second

// Convex JSON numbers may arrive in an integral decimal form such as 0.0 or
// 1.0, so the example accepts any mathematically integral number in range and
// rejects fractional, quoted, non-finite, or overflowing values.
fn state_count(value json2.Any, where string) !i64 {
	if value !is map[string]json2.Any {
		return error('${where} was not a Convex object')
	}
	state := value as map[string]json2.Any
	count := state['count'] or { return error('${where} did not include a count') }
	return convex.integral_number(count) or {
		return error('${where} count was not an integral JSON number')
	}
}

// The counter must actually change. Waiting for a *different* value, rather
// than for the next delivery of any kind, keeps the example honest if Convex
// re-sends the value the subscription already had.
fn next_changed_count(mut updates convex.Relay, previous i64, where string) !i64 {
	deadline := time.sys_mono_now() + u64(live_budget)
	for time.sys_mono_now() < deadline {
		update := updates.next(live_budget)!
		if update.is_error() {
			return error('${where} failed: ${update.error_message}')
		}
		count := state_count(update.value, where)!
		if count != previous {
			return count
		}
	}
	return error('${where} never changed')
}

fn run() ! {
	// The deployment URL identifies the Convex backend. The verifier supplies a
	// dedicated test deployment; nothing here is specific to one.
	url := os.getenv('CONVEX_URL')
	if url.len == 0 {
		return error('CONVEX_URL is required')
	}
	// The first argument is the room this run owns, so two runs never share a
	// counter. The default only exists for running the image by hand.
	room := if os.args.len > 1 && os.args[1].len > 0 { os.args[1] } else { 'v-example' }

	// Creating the client parses and validates the deployment origin. No socket
	// is opened yet, and no Live worker is started until the first subscribe.
	mut client := convex.new_client(url)!
	defer {
		// Closing retires the Live worker and its socket, including on failure.
		client.close()
	}

	// Read the counter over Convex's documented JSON HTTP query API.
	current := client.query('demo:state', {
		'room': json2.Any(room)
	})!
	before := state_count(current.value, 'the initial HTTP query')!
	println('current count: ${before}')

	// Subscribe *before* writing. Starting Live afterwards would race the
	// mutation and could miss the very update this example is about to prove.
	mut updates := client.subscribe('counter', 'demo:state', {
		'room': json2.Any(room)
	})!
	defer {
		// Unsubscribing invalidates this subscription's bounded relay before
		// the client tears the connection down.
		client.unsubscribe('counter') or {}
	}

	// The first Live delivery is the query's current value, so it must agree
	// with the HTTP read above before anything is written.
	initial := updates.next(live_budget)!
	if initial.is_error() {
		return error('the initial Live value failed: ${initial.error_message}')
	}
	initial_count := state_count(initial.value, 'the initial Live value')!
	if initial_count != before {
		return error('the initial Live value disagreed with the HTTP query')
	}
	println('live initial count: ${initial_count}')

	// Apply one increment. `runId` is the idempotency key: Convex applies this
	// mutation once, so a retry of the same run cannot double-count.
	mutation := client.mutation('demo:increment', {
		'room':     json2.Any(room)
		'language': json2.Any('V')
		'runId':    json2.Any('v-${os.getpid()}-${time.sys_mono_now()}')
	})!
	if mutation.value !is map[string]json2.Any {
		return error('the mutation did not return a Convex object')
	}
	outcome := mutation.value as map[string]json2.Any
	applied := outcome['applied'] or { return error('the mutation omitted applied') }
	if applied !is bool || !(applied as bool) {
		return error('the mutation was not applied')
	}
	after := state_count(outcome['state'] or { json2.Any(json2.null) }, 'the mutation')!
	if after != before + 1 {
		return error('the mutation moved the counter by more than one')
	}
	println('mutation applied: true')
	println('mutation count: ${after}')

	// Convex pushes the new value to the existing subscription. Nothing is
	// re-read over HTTP, so this line is evidence that Live really delivered.
	updated := next_changed_count(mut updates, before, 'the updated Live value')!
	if updated != after {
		return error('the Live update disagreed with the mutation')
	}
	println('live updated count: ${updated}')

	// Only now, with every stage agreeing, is the journey reported.
	println('verified count: ${before} -> ${updated}')
}

fn main() {
	run() or {
		// Diagnostics belong on stderr: stdout is the shared happy-path
		// transcript the verifier compares byte for byte.
		eprintln(err.msg())
		exit(1)
	}
}
