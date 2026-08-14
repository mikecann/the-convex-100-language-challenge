<img src="logo.png" alt="Janet logo" width="140">
<!-- Logo source: https://janet-lang.org/assets/janet-big.png -->

# Janet

[Janet](https://janet-lang.org/) is a small, dynamic Lisp created by Calvin Rose, with public roots going back to 2017. It mixes functional and imperative programming, compiles to its own bytecode VM, and is implemented mostly in C99. If Lua and Clojure are familiar reference points, Janet sits somewhere nearby: it has Lisp syntax and macros, but is designed for system scripting, automation, and embedding in C or C++ programs. It remains a compact specialist language rather than a mainstream application platform.

This repository uses Janet to make real Convex HTTP calls and follow a reactive query over WebSockets. It is an educational, unofficial demonstration, not a production SDK and not a package intended for publication.

## Getting Started

Start with [`examples/basics/main.janet`](examples/basics/main.janet). It reads a fresh counter over HTTP, subscribes before changing it, applies one idempotent increment, then checks that the mutation result and the next Live value both show `0 -> 1`.

From the repository root, Docker builds the pinned Janet toolchain and runs that exact example against an approved test deployment:

```sh
./run verify-example janet
```

You do not need Janet, OpenSSL development headers, or a C compiler installed on your machine.

## Interesting Parts

### The `@` sigil separates what you build from what you get back

Janet gives its data structures immutable and mutable twins, and one character tells them apart: `{...}` is a frozen struct, `@{...}` is a mutable table. The examples build Convex argument objects as tables with string keys, and the client answers with an immutable struct keyed by Janet keywords like `:value` — so decoded JSON and the client's own wrapper stay visibly distinct:

```janet
(def args @{"room" room}) # mutable table, string keys: the JSON argument object
# TypeScript: const state = useQuery(api.demo.state, { room })
(def result (convex/query client "demo:state" args))
(get-in result [:value "count"]) # :value is the client's frozen result wrapper
```

One glance at a literal tells you whether anyone can change it.

### `defer` retires the socket, success or panic

Janet's `defer` will look familiar to Go programmers, but it is scoped to a block: the cleanup form runs when the body exits, including when it exits by raising an error. The basics example wraps its whole session in one, so the subscription and the WebSocket are retired on every path:

```janet
(defer (do
         (when subscription (convex/unsubscribe! client subscription))
         (convex/close! client)) # runs even if anything below raises
  (def current (convex/query client "demo:state" @{"room" room}))
  # ... subscribe, mutate, verify ...
  )
```

### The bang means it changes something

Following Lisp and Scheme tradition, every function that mutates state ends in `!` — and Convex's reactive side is all bangs. `subscribe!` only records intent; `next-update!` cooperatively pumps the client's single socket owner until the next value lands. A mutation made mid-subscription then arrives as ordinary data:

```janet
(def subscription (convex/subscribe! client "demo:state" @{"room" room}))
(convex/next-update! client subscription 15000) # the initial Live value

(convex/mutation client "demo:increment"
                 @{"room" room "language" "Janet" "runId" (convex/random-hex 16)})

# TypeScript: React just rerenders; here the update is a value you wait for.
(def updated (convex/next-update! client subscription 15000))
(get-in updated [:value "count"]) # 0 -> 1, delivered over the socket
```

### Errors are signals; a failed Live query is data

Janet's error handling rides on fibers, its built-in coroutines: `error` raises a signal a parent fiber can trap, and `try`'s catch clause is a binding pattern, `([problem] ...)`. This client raises signals for transport trouble, but a Live query that fails server-side arrives as a normal update carrying `:error` instead of `:value`:

```janet
(def update (convex/next-update! client subscription 15000))
(when (has-key? update :error) # a failed reactive query is just data
  (example-failed (get-in update [:error :message])))

(try
  (run-example)
  ([problem] (example-failed (convex/describe-failure problem)))) # trapped signal
```

Signals for the unexpected, data for the expected — the generated example below leans on both.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified locally and hosted |
| Bearer authentication and structured function errors | Verified locally and hosted |
| TLS chain and host-name verification | Verified locally and hosted |
| Live initial values, external updates, and query-error recovery | Verified locally and hosted |
| Unsubscribe barriers, five reconnects, and bounded delivery | Verified locally and hosted |
| Live authentication, WebSocket mutations, and `TransitionChunk` assembly | Not implemented |

The repository's recorded clean, exact-head evidence passed 31 of 31 shared conformance checks against both the local backend and the hosted deployment, earning HTTP and Live.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.janet -->
```janet
# Convex from Janet: the shared counter, start to finish.
#
# This program is the canonical example. It is what the README shows, what the
# website shows, and what the `example-runtime` image runs against a real
# deployment. It follows one room's counter from 0 to 1 and proves that the
# HTTP query, the mutation's own result, and the Live subscription all agree.
#
# The order matters. Live is started before the mutation, because a reactive
# subscription that begins after a change cannot prove it saw the change.

(import ../../client/convex :as convex)

(defn example-failed
  "Report on stderr and stop.

  Stdout is the shared happy-path transcript that every language in this
  repository must produce byte for byte, so nothing diagnostic may go there."
  [message]
  (flush)
  (eprint (string "Janet example failed: " message))
  (eflush)
  (os/exit 1))

(defn whole-count
  "Read a non-negative whole `count` out of a Convex value.

  Convex JSON may spell a whole number as `0` or as `0.0`, and both are the
  same number in Janet. What this has to reject is everything that is *not* a
  count: a fraction, a quoted number, a missing field, or a value so large it
  could not be a counter."
  [value label]
  (unless (and (dictionary? value) (not (convex/json-null? value)))
    (example-failed (string label " did not return an object")))
  (def count (get value "count"))
  (unless (and (number? count)
               (not (nan? count))
               (not= count math/inf)
               (not= count math/-inf)
               (= count (math/floor count))
               (>= count 0)
               (<= count 9007199254740992))
    (example-failed (string label " returned a value that is not a whole count")))
  count)

(defn run-id
  "A fresh idempotency key for the mutation.

  Convex uses this to make a retry safe: sending the same `runId` twice applies
  the increment once. It is generated from the local CSPRNG rather than by
  shelling out to another program."
  []
  (convex/random-hex 16))

(defn next-live-value
  "Wait for the subscription's next update and unwrap it.

  A Live update carries either a value or a structured error. Treating an error
  as data is the mistake this guard exists to prevent."
  [client subscription label]
  (def update (convex/next-update! client subscription 15000))
  (unless update (example-failed (string label " did not arrive in time")))
  (when (has-key? update :error)
    (example-failed (string label " failed: " (get-in update [:error :message]))))
  (get update :value))

(defn example-room
  "The room to use: the verifier's unique id, an environment override, or a default.

  Janet reports the script path alongside the arguments, so the first real
  argument is whatever follows the last `.janet` entry."
  []
  (def arguments (or (dyn :args) @[]))
  (var start 0)
  (var index 0)
  (while (< index (length arguments))
    (when (string/has-suffix? ".janet" (get arguments index))
      (set start (+ index 1)))
    (set index (+ index 1)))
  (or (get arguments start)
      (os/getenv "EXAMPLE_ROOM")
      "janet-basic-example"))

(defn run-example []
  # The deployment URL is supplied by the container that runs this image.
  (def deployment (os/getenv "CONVEX_URL"))
  (unless (and deployment (> (length deployment) 0))
    (example-failed "CONVEX_URL is required"))
  (def room (example-room))

  # One client serves both the HTTP calls and the Live subscription. Nothing
  # connects yet; the first call opens what it needs.
  (def client (convex/new-client deployment (os/getenv "CONVEX_AUTH_TOKEN")))
  (var subscription nil)
  (defer (do
           # Cleanup is bounded: unsubscribing is local state plus one queued
           # owner command, and closing never waits for the peer to answer.
           (when subscription (convex/unsubscribe! client subscription))
           (convex/close! client))

    # Read the room's current state through Convex's documented HTTP API.
    (def current (whole-count (get (convex/query client "demo:state" @{"room" room})
                                   :value)
                              "the initial query"))
    (unless (= current 0)
      (example-failed "this room was expected to be a fresh, empty counter"))
    (print (string/format "current count: %d" current))

    # Subscribe before changing anything. The Live socket opens on the next
    # client step, replays this query, and delivers the current value first.
    (set subscription (convex/subscribe! client "demo:state" @{"room" room}))
    (def initial (whole-count (next-live-value client subscription "the initial Live value")
                              "the initial Live value"))
    (unless (= initial current)
      (example-failed "the initial Live value disagreed with the HTTP query"))
    (print (string/format "live initial count: %d" initial))

    # Apply exactly one increment. `runId` is the idempotency key: replaying
    # this same mutation returns the previous result instead of counting twice.
    (def result (convex/mutation client "demo:increment"
                                 @{"room" room "language" "Janet" "runId" (run-id)}))
    (def applied (get-in result [:value "applied"]))
    (unless (= applied true)
      (example-failed "the mutation reported that it was not applied"))
    (def mutated (whole-count (get-in result [:value "state"]) "the mutation"))
    (unless (= mutated (+ current 1))
      (example-failed "the mutation did not move the counter by exactly one"))
    (print "mutation applied: true")
    (print (string/format "mutation count: %d" mutated))

    # The same change now has to arrive over Live, without polling HTTP again.
    (def updated (whole-count (next-live-value client subscription "the updated Live value")
                              "the updated Live value"))
    (unless (= updated mutated)
      (example-failed "the Live value disagreed with the mutation's own result"))
    (print (string/format "live updated count: %d" updated))

    # Only now, with HTTP, the mutation, and Live all agreeing, is the journey
    # proven. This final line is the shared cross-language transcript.
    (print (string/format "verified count: %d -> %d" current updated))
    (flush)))

(try
  (run-example)
  ([problem] (example-failed (convex/describe-failure problem))))
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

```sh
./run sync-examples
./run validate
./run test janet
./run verify-example janet
./run verify janet
./run verify-hosted janet
./run verify-all janet
```

`test` builds Janet from source, compiles the native byte transport, and then runs the style and syntax check, the codec and JSON regressions, real-socket HTTP and Live tests, a TLS verification test against a throwaway certificate authority, both adapter transports, and the stopped-reader memory proof. `verify-example` runs the exact example above from its minimal image against a unique room and compares its six stdout lines to the shared transcript. `verify` adds shared black-box conformance against the approved local backend, and `verify-hosted` repeats it against the hosted drift target.

### How the client is built

**What is Janet and what is not.** Janet's core library deliberately ships TCP sockets without TLS, HTTP, or WebSockets. This client therefore includes one small native module, [`client/transport.c`](client/transport.c), which provides exactly one thing: a bounded, deadline-driven stream of bytes, optionally wrapped in a TLS session that OpenSSL verifies against both the trusted chain and the requested host name. It also exposes a CSPRNG and SHA-1, because RFC 6455 defines its handshake in terms of SHA-1. That module knows nothing about HTTP, WebSockets, or Convex.

Everything above bytes is Janet: HTTP/1.1 request building and bounded response reading including chunked framing, the RFC 6455 opening handshake and its `Sec-WebSocket-Accept` check, client-side masking, fragmentation and control frames, close-code validation, JSON, base64, and the whole `convex-rs-0.10.4-unversioned-sync` profile. Because a C module is still foreign code, the manifest declares this a `binding` rather than a `native` implementation. No request invokes another Convex client, the Convex CLI, `curl`, Node.js, or Python.

**Running it outside Docker.** Janet resolves the native transport by name, so `JANET_PATH` must point at this `client/` directory. Every image here sets it. Importing that module by name rather than by relative path is deliberate: Janet caches a module under the path it was imported by, and two copies of a native module would register two distinct abstract types, making a connection opened by one unrecognisable to the other.

**One owner, one writer.** `step!` in [`client/convex.janet`](client/convex.janet) is the only code that opens, reads, writes, retires, or reconnects the Live socket, and the only code that advances a query-set version. `subscribe!` and `unsubscribe!` record intent and queue an owner command. `step!` is cooperative and non-blocking, so the adapter serves its controller and the Live socket from one thread with no locks and no event loop. The adapter's events all pass through a single queue drained by a single writer, so acknowledgements, results, errors, relayed values, and the close event can never interleave.

**Staleness barriers.** `unsubscribe!` moves a subscription's generation and drops its queue synchronously, before anything is acknowledged. Every queued update carries the generation it was created under, and the adapter re-checks it at publication. Relaying is split into a dequeue step and a publish step so a test can pause a relay in between and prove that an update already taken off the queue still cannot cross an unsubscribe or a same-id replacement.

**Reconnects.** `debugDisconnect` retires the socket and schedules the retry before it returns, so its acknowledgement cannot race a stale read. Each new connection sends `Connect` carrying `connectionCount`, `lastCloseReason`, and `maxObservedTimestamp`, then replays every active query in one `ModifyQuerySet` at `baseVersion 0`. The value the server resends on rehydration is suppressed when it is unchanged, so a disconnect never looks like a duplicate update. Backoff starts at 100 ms, doubles to a 15 second ceiling, and resets after a completed handshake or a valid transition, so a healthy connection never inherits an old delay. The language-local test repeats this five times and checks every one of those properties.

**Framing rules.** Reserved bits, masked server frames, unknown opcodes, fragmented or oversized control frames, non-minimal length encodings, binary messages, one-byte close payloads, and reserved close codes are all rejected. Text is validated as UTF-8 after reassembly, not per fragment, so a message split inside a code point decodes correctly. Once any byte of a message has been consumed, the parser keeps its state across polls and measures a five second absolute deadline from that first byte; expiry abandons the connection rather than resynchronizing at a guessed boundary.

**Bounds.** HTTP responses and WebSocket messages stop at 2 MiB. JSON stops at 2 MiB, 64 levels of nesting, and 200,000 values, and rejects duplicate object keys, non-finite numbers, lone surrogates, and raw control characters in strings. A client holds at most 64 subscriptions, at most 16 updates per subscription, and at most 4 MiB of encoded update payload in total. The adapter holds at most 16 events and 4 MiB of output including the write currently in flight. Under pressure a subscription value may be coalesced, because it describes current state; an acknowledgement, result, error, or close never is, and an adapter that cannot queue one fails the connection instead of pretending it was sent. The stopped-reader test drives the real adapter with values close to the 2 MiB frame ceiling while nothing reads its output, and asserts both budgets and the process's own resident set size.

**Images.** The final images start from `scratch` and contain the Janet interpreter, the client sources, the compiled transport, OpenSSL with its configuration and provider modules, the CA bundle, glibc's name-resolution modules, `/bin/sh`, and the thirteen POSIX text tools the shared image policy and example verifier need. There is no multicall binary, so the file inventory is the complete command surface, and the build asserts that inventory exactly. Both images run as `65532:65532` under the repository's read-only, capability-drop, no-new-privileges, 128 MiB policy. Janet is a Lisp, so `compile` and `eval` are part of its runtime and cannot be removed without removing the language; no compiler *command* is present, and the build probes for one.

## Known Issues

1. **Binding, not pure Janet.** TCP and TLS come from a local C module over OpenSSL because Janet's core has no TLS. Everything above the byte stream is Janet.
2. **Live has a focused scope.** Live authentication, mutations and actions over the WebSocket, optimistic updates, journals, read-your-own-write commit timestamps, and `TransitionChunk` assembly are deferred. A `TransitionChunk` retires the socket and reconnects rather than being partially interpreted.
3. **Values stay JSON-shaped.** The JSON-safe Convex subset is supported, but tagged Convex values are not converted into richer Janet types.
4. **HTTP calls do not share connections.** Each call opens its own connection and requests `Connection: close`; persistent connections and pipelining are deferred.
5. **Transient Live failures are quiet.** The client reconnects after a dropped connection. It publishes a structured `TransportError` only after three consecutive failed attempts, then can still recover.
6. **DNS uses the platform timeout.** `getaddrinfo` is the one transport operation not governed by the client's own deadline.
7. **Formatting is checked locally.** Janet core ships no formatter, so the Docker build parses every source file and checks line length, tabs, trailing whitespace, and final newlines.
