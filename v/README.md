# Convex from V

This demonstration reads a shared counter from Convex over HTTP, subscribes to
that same query through Convex's live sync protocol, increments the counter
once, and then checks that both paths agree the value moved from 0 to 1.

It is educational and unofficial. It is not a production SDK, not a sanctioned
Convex client, and not something to depend on.

## Start here

[examples/basics/main.v](examples/basics/main.v) is the one runnable teaching
source. It reads the counter, starts listening *before* it writes, applies one
idempotent increment, receives the new value over the live connection, and
prints the six-line transcript every language in this repository shares.

## What works

| Area | Current state |
| --- | --- |
| HTTP client source | Written in V, with unit fixtures for framing, envelopes, and bounds. Verified by shared conformance on both profiles. |
| Live client source | Written against the pinned sync profile with a V-owned bounded RFC 6455 transport and real raw-peer fixtures. Verified by shared conformance on both profiles. |
| Conformance adapter | Written for both stdin/stdout and `ADAPTER_LISTEN` TCP, with fixtures for command strictness, ordering, and invalidation. Built and verified. |
| Docker images | Built with V 0.4.9 pinned to an exact commit, verified on both profiles. |
| Capability badges | http, live. Both earned. |

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.v -->
```v
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
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

    ./run test v
    ./run verify-example v
    ./run verify v
    ./run verify-hosted v

`./run test v` builds a `linux/amd64` image that checks formatting, lints,
runs the V unit fixtures, and compiles both the canonical example and the
conformance executable. `./run verify-example v` runs that exact example
binary, from its minimal read-only runtime image, against a unique room on the
approved local deployment and compares stdout byte for byte with the shared
transcript. `./run verify v` adds the shared black-box conformance run, and
`./run verify-hosted v` repeats both against the dedicated hosted target so
protocol drift shows up somewhere other than production.

The shared coordinator has run all of these against a clean exact-head build:
31 of 31 conformance checks passed against a local backend, and 31 of 31
passed again against the hosted deployment over real TLS.

## Conformance and protocol notes

**HTTP.** Requests are framed in V over `net` and `net.ssl`. Once V returns a
socket, one absolute deadline covers the TLS handshake, every partial write,
and every read. The status line, header block, header count, `Content-Length`
body, and chunked body each have their own ceiling, and the running total is
capped at 2 MiB regardless of what the peer claims. A non-2xx status is decoded
before it is judged, because a real Convex function rejection arrives with one
- but a success-shaped envelope on a non-2xx status is refused. `TcpConn`'s own
read/write timeouts only bound V's own socket wrapper, not OpenSSL's `SSL_read`
and `SSL_write`, which read and write the file descriptor directly; this client
also sets `SO_RCVTIMEO`/`SO_SNDTIMEO` on the descriptor itself (see
[client/socket_deadline.c.v](client/socket_deadline.c.v)), which is what
actually bounds a TLS peer that stops answering mid-exchange.

**Live.** The pinned profile in `manifest.yaml` is implemented in V:
`Connect`, `ModifyQuerySet` with monotonic base/new versions, and `Transition`
with a start version that must match local state, a timestamp that may not move
backwards, and per-query coalescing before anything is published. One worker
owns the socket outright - connecting, reading, writing, changing the query set,
and retiring connections. Callers reach it through a command channel, so no
second thread can interleave a write with a partially written frame.

**Delivery bounds.** Each subscription reserves both a count slot and a
conservative charge covering twice the encoded size plus every decoded JSON
node, and the client reserves a process-wide count and byte budget on top. A
stopped consumer fails its own subscription instead of growing memory. The
adapter's terminal writer applies the same idea to output, holding an event's
charge while its write is in flight.

**Reconnects.** `debugDisconnect` is adapter-only and is declared in
`manifest.yaml`; it is not part of the client API this README teaches. Its
acknowledgement is published only after the old connection is retired, a new
delivery generation is in effect, and reconnect work is scheduled, so an update
a relay is still holding from the retired connection is dropped rather than
published across the boundary. Every connection resends the full active query
set, and an unchanged rehydration is suppressed.

**Frames.** Exact V 0.4.9 source review found that `net.websocket` allocates a
peer-declared payload before callers can apply a ceiling and retries timed-out
writes internally, so this client does not use it. The V-owned transport checks
the declared length before allocation, applies one cumulative deadline across
headers, fragments, controls and payload bytes, masks client frames, validates
the upgrade challenge and token headers, and bounds cumulative writes. The
loopback fixtures are real raw RFC 6455 peers, including a 1 GiB declared
length with no body, continuous byte dribble, and a peer that stops reading.
The frame budget is five seconds, intentionally below the eight-second command
budget, so a close or unsubscribe cannot sit behind a longer in-progress frame
read once a socket exists.

## Limitations

Deferred protocol behaviour: Live authentication, WebSocket mutations and
actions, optimistic updates, journals, and `TransitionChunk` assembly. Convex
values are handled as their JSON-safe subset; tagged value conversions are not
implemented. HTTP uses one connection per call.

V's current `net.dial_tcp` surface does not expose a caller-owned DNS/TCP-connect
deadline: it is one call that blocks internally until it has either connected
or failed, with no timeout parameter and no socket to attach one to until it
returns. Everything from the moment `dial_tcp` returns onward - the TLS
handshake, every write, every read - is bounded by this client's own absolute
deadline, enforced at the kernel level via `SO_RCVTIMEO`/`SO_SNDTIMEO` (see
[client/socket_deadline.c.v](client/socket_deadline.c.v)) because `TcpConn`'s
own timeout fields never reach OpenSSL's direct `SSL_read`/`SSL_write` calls.
The pre-connect phase itself remains unbounded by this client; it is a
standing constraint of the V standard library, not a build-status caveat.
