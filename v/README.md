<img src="logo.png" alt="V logo" width="120">
<!-- Logo source: https://github.com/vlang/v-logo/blob/eec050c901ed3afefce8cbe56092d55ed6770706/dist/v-logo.svg -->

# V

V is a young, statically typed compiled language whose [public
repository](https://github.com/vlang/v) began in 2019. It was designed around
Go-like simplicity and C-like reach. Its main backend emits human-readable C,
while the official project also targets JavaScript and highlights command-line
tools, web applications, graphics, games, and low-level systems work. V is
still a pre-1.0 beta with a much smaller ecosystem than Go, C#, or TypeScript,
but it has an active project and a distinctive niche for people who want one
compact language across application and systems code. See the [official V
website](https://vlang.io/) and [documentation](https://docs.vlang.io/).

This repository's Convex client is an educational, unofficial demonstration.
It is not a production SDK and is not sanctioned by Convex or the V project.

## Getting Started

Start with [the canonical V example](examples/basics/main.v). From the
repository root, run:

```sh
./run verify-example v
```

Docker builds the pinned V toolchain and minimal `linux/amd64` example image,
then runs the real program against an approved local Convex test deployment.
The example reads a room's counter, subscribes before changing it, performs one
idempotent increment, and confirms that Live delivers the new value.

## Interesting Parts

### Failure is a return type, not an exception

V has no exceptions. A function that can fail says so in its own signature
with a leading `!`, and every call site either unwraps the failure with
`or { }` or re-raises it with a trailing `!` — which only compiles if the
caller's function is itself declared `!`. It is Go's "check every error"
discipline, except the compiler refuses to build code that skips it.

```v
fn run() ! {
	mut client := convex.new_client(url)!
	defer {
		client.close()
	}

	// The trailing `!` re-raises query's failure into run()'s own `!` return.
	current := client.query('demo:state', {
		'room': json2.Any(room)
	})! // TypeScript: const state = await client.query("demo:state", { room })
	println(current.value)
}
```

### Multi-line literals skip the commas

Convex arguments are ordinary V maps of `json2.Any`, but V's literal syntax
drops a habit carried over from C: once each entry gets its own line, the
commas between them disappear. Whitespace does the separating, so a call's
argument list ends up reading like a small aligned table.

```v
mutation := client.mutation('demo:increment', {
	'room':     json2.Any(room)
	'language': json2.Any('V')
	'runId':    json2.Any('v-${os.getpid()}-${time.sys_mono_now()}')
})! // TypeScript: await mutation({ room, language: "V", runId })
```

### A subscription is a queue you poll, not a hook that reruns

Convex's Live protocol pushes a fresh value whenever a subscribed query's
result changes; React's `useQuery` hides that push behind a hook that reruns
your component for you. V's client hands back a `Relay` instead — a bounded,
deadline-aware queue the caller reads from by hand, with nothing unsubscribing
on your behalf once you stop caring.

```v
mut updates := client.subscribe('counter', 'demo:state', {
	'room': json2.Any(room)
})!
defer {
	client.unsubscribe('counter') or {} // Nothing does this automatically.
}

// next blocks until Convex pushes a value, or the deadline passes.
initial := updates.next(20 * time.second)!
if initial.is_error() {
	return error(initial.error_message)
}
println(initial.value) // TypeScript: useQuery reruns the component instead.
```

## Status

| Area | Current state |
| --- | --- |
| HTTP client | Native V implementation. Shared conformance passed on the local and hosted profiles. |
| Live client | Native V implementation with a bounded, client-owned WebSocket transport. Shared conformance passed on the local and hosted profiles. |
| Conformance adapter | Supports stdin/stdout and `ADAPTER_LISTEN` TCP modes. Its language-local fixtures cover strict command and event shapes, ordering, and subscription invalidation. |
| Docker images | V 0.4.9 and its bootstrap compiler are pinned to exact commits. The final images target `linux/amd64`. |
| Earned capabilities | `http`, `live`. Both are evidence-backed. |

The coordinator's clean exact-head evidence recorded 31 of 31 checks passing
against the approved local backend and another 31 of 31 against the dedicated
hosted deployment over TLS. These are separate from compilation and from the
canonical example check.

## Example

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

## Implementation Notes

This is a native V client. The Convex-specific request envelopes, response
decoding, Live state machine, reconnect behavior, and WebSocket framing all
live under [client/](client/). It uses V's standard sockets, JSON, SHA-1, and
base64 support, plus OpenSSL for TLS. It does not call another Convex SDK,
`curl`, Node.js, Python, or the Convex CLI.

The HTTP path opens one connection per call and limits the request, status
line, headers, and response body independently. Function failures keep their
structured data rather than being mistaken for generic HTTP failures. Once V
returns a socket, one absolute deadline covers the TLS handshake and all reads
and writes. The small C helpers in
[client/socket_deadline.c.v](client/socket_deadline.c.v) set kernel socket
deadlines because the pinned V OpenSSL wrapper bypasses `TcpConn`'s own timeout
fields.

Live uses one worker as the sole owner of connection, read, write, reconnect,
and active-query state. Public calls send commands to that worker. Each
subscription relay is bounded by both update count and estimated bytes, with a
second process-wide budget, so a slow consumer fails instead of growing memory
without limit. The tests cover initial and changed values, query failure and
recovery, five reconnects, stale-delivery invalidation, fragmented UTF-8,
oversized frames, slow peers, and stopped readers.

The Docker build pins V 0.4.9 at commit
`39534459885e916e2765b5b0c0ed66ce15f0ab86` and pins the separate bootstrap
compiler source too. The final example and adapter images contain the compiled
V binaries, their runtime library closure, OpenSSL configuration and CA
certificates, and the small POSIX tool surface required by the shared verifier.
They run as user `65532:65532` with no compiler or package manager.

## Known Issues

1. Live authentication, WebSocket mutations and actions, optimistic updates,
   journals, and `TransitionChunk` assembly are not implemented.
2. Values cover Convex's JSON-safe subset only. Tagged Convex value conversions
   are deferred, and JSON input is capped at 2 MiB, 128 nesting levels, and
   8,192 structural nodes.
3. HTTP opens a new connection for every call. Persistent connections and
   request compression are deferred.
4. V 0.4.9's synchronous `net.dial_tcp` does not expose a caller-owned
   DNS/TCP-connect deadline. This client bounds the TLS handshake and all I/O
   after a socket exists, but the pre-socket connect phase remains outside its
   deadline.
5. The client API's Live relay is deliberately blocking and manually managed.
   A caller must unsubscribe or close the client, and a slow consumer is failed
   when the relay's count or byte budget is exhausted.
