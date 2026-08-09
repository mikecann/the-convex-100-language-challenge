# Convex from Janet

This is a small Convex client written in [Janet](https://janet-lang.org). It calls Convex functions over the documented JSON HTTP API and keeps a query current over a Live WebSocket subscription, so a Janet program can follow a shared counter without polling.

It is educational and unofficial. It is not a production Convex SDK, it is not published to any package registry, and it is not supported by Convex.

## Start here

Read [`examples/basics/main.janet`](examples/basics/main.janet). It queries a fresh room's counter over HTTP, starts a Live subscription *before* changing anything, applies one idempotent increment, and then waits for that same change to arrive over Live. It prints its verification line only once the HTTP query, the mutation's own result, and the Live update all agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Implemented, verified |
| Bearer authentication and structured function errors | Implemented, verified |
| TLS with chain and host-name verification | Implemented, verified |
| Live initial values, external updates, and query-error recovery | Implemented, verified |
| Unsubscribe, five reconnects, and bounded delivery | Implemented, verified |
| Live authentication, WebSocket mutations, `TransitionChunk` | Not implemented, see Limitations |

The shared result evaluator awarded the `http` and `live` badges from a clean, exact-head build: 31 of 31 conformance checks against a local backend and 31 of 31 against the hosted deployment over real TLS.

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

## Docker verification

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

## Conformance and protocol notes

**What is Janet and what is not.** Janet's core library deliberately ships TCP sockets without TLS, HTTP, or WebSockets. This client therefore includes one small native module, [`client/transport.c`](client/transport.c), which provides exactly one thing: a bounded, deadline-driven stream of bytes, optionally wrapped in a TLS session that OpenSSL verifies against both the trusted chain and the requested host name. It also exposes a CSPRNG and SHA-1, because RFC 6455 defines its handshake in terms of SHA-1. That module knows nothing about HTTP, WebSockets, or Convex.

Everything above bytes is Janet: HTTP/1.1 request building and bounded response reading including chunked framing, the RFC 6455 opening handshake and its `Sec-WebSocket-Accept` check, client-side masking, fragmentation and control frames, close-code validation, JSON, base64, and the whole `convex-rs-0.10.4-unversioned-sync` profile. Because a C module is still foreign code, the manifest declares this a `binding` rather than a `native` implementation. No request invokes another Convex client, the Convex CLI, `curl`, Node.js, or Python.

**Running it outside Docker.** Janet resolves the native transport by name, so `JANET_PATH` must point at this `client/` directory. Every image here sets it. Importing that module by name rather than by relative path is deliberate: Janet caches a module under the path it was imported by, and two copies of a native module would register two distinct abstract types, making a connection opened by one unrecognisable to the other.

**One owner, one writer.** `step!` in [`client/convex.janet`](client/convex.janet) is the only code that opens, reads, writes, retires, or reconnects the Live socket, and the only code that advances a query-set version. `subscribe!` and `unsubscribe!` record intent and queue an owner command. `step!` is cooperative and non-blocking, so the adapter serves its controller and the Live socket from one thread with no locks and no event loop. The adapter's events all pass through a single queue drained by a single writer, so acknowledgements, results, errors, relayed values, and the close event can never interleave.

**Staleness barriers.** `unsubscribe!` moves a subscription's generation and drops its queue synchronously, before anything is acknowledged. Every queued update carries the generation it was created under, and the adapter re-checks it at publication. Relaying is split into a dequeue step and a publish step so a test can pause a relay in between and prove that an update already taken off the queue still cannot cross an unsubscribe or a same-id replacement.

**Reconnects.** `debugDisconnect` retires the socket and schedules the retry before it returns, so its acknowledgement cannot race a stale read. Each new connection sends `Connect` carrying `connectionCount`, `lastCloseReason`, and `maxObservedTimestamp`, then replays every active query in one `ModifyQuerySet` at `baseVersion 0`. The value the server resends on rehydration is suppressed when it is unchanged, so a disconnect never looks like a duplicate update. Backoff starts at 100 ms, doubles to a 15 second ceiling, and resets after a completed handshake or a valid transition, so a healthy connection never inherits an old delay. The language-local test repeats this five times and checks every one of those properties.

**Framing rules.** Reserved bits, masked server frames, unknown opcodes, fragmented or oversized control frames, non-minimal length encodings, binary messages, one-byte close payloads, and reserved close codes are all rejected. Text is validated as UTF-8 after reassembly, not per fragment, so a message split inside a code point decodes correctly. Once any byte of a message has been consumed, the parser keeps its state across polls and measures a five second absolute deadline from that first byte; expiry abandons the connection rather than resynchronizing at a guessed boundary.

**Bounds.** HTTP responses and WebSocket messages stop at 2 MiB. JSON stops at 2 MiB, 64 levels of nesting, and 200,000 values, and rejects duplicate object keys, non-finite numbers, lone surrogates, and raw control characters in strings. A client holds at most 64 subscriptions, at most 16 updates per subscription, and at most 4 MiB of encoded update payload in total. The adapter holds at most 16 events and 4 MiB of output including the write currently in flight. Under pressure a subscription value may be coalesced, because it describes current state; an acknowledgement, result, error, or close never is, and an adapter that cannot queue one fails the connection instead of pretending it was sent. The stopped-reader test drives the real adapter with values close to the 2 MiB frame ceiling while nothing reads its output, and asserts both budgets and the process's own resident set size.

**Images.** The final images start from `scratch` and contain the Janet interpreter, the client sources, the compiled transport, OpenSSL with its configuration and provider modules, the CA bundle, glibc's name-resolution modules, `/bin/sh`, and the thirteen POSIX text tools the shared image policy and example verifier need. There is no multicall binary, so the file inventory is the complete command surface, and the build asserts that inventory exactly. Both images run as `65532:65532` under the repository's read-only, capability-drop, no-new-privileges, 128 MiB policy. Janet is a Lisp, so `compile` and `eval` are part of its runtime and cannot be removed without removing the language; no compiler *command* is present, and the build probes for one.

## Limitations

- **Verification completed.** Docker tests plus shared local and hosted conformance earned HTTP and Live.
- **Binding, not pure Janet.** TCP and TLS come from a local C module over OpenSSL, because Janet's core has no TLS. Everything else is Janet.
- **Live scope.** Live covers query subscriptions. Live authentication, mutations and actions over the WebSocket, optimistic updates, journals, read-your-own-write commit timestamps, and `TransitionChunk` assembly are deferred. A `TransitionChunk` is treated as profile drift: the socket is retired and the subscription recovers on the next connection rather than guessing at the reassembly.
- **Values.** Convex's JSON-safe subset is supported. Tagged Convex value encodings are not converted into richer Janet types.
- **HTTP framing.** Each call opens its own connection and asks the server to close it. Persistent connections and pipelining are deferred.
- **Transport blips are quiet.** A dropped Live connection is reconnected transparently rather than surfaced to the subscriber, because a reactive query's contract is current state. A transport that stays broken across three consecutive attempts does publish one structured `TransportError`, and the subscription still recovers afterwards.
- **Name resolution.** `getaddrinfo` is the one call in the transport that is not governed by the client's own deadline; the resolver's timeout bounds it.
- **Formatting.** Janet's core distribution ships no formatter. Rather than vendor one, the build runs a local style and syntax check over every checked-in source file: it must parse, avoid tabs and trailing whitespace, stay within 100 columns, and end with a newline.
- **One test seam.** `convex/live-socket-dynamic` is a dynamic binding a test may set to supply an already-open Live socket, which is how the language-local tests drive a real RFC 6455 peer over a loopback pair. It holds no state, defaults to unset, and nothing in the shipped code path assigns it.
