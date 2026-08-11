# Convex from Fennel

[Fennel](https://fennel-lang.org/) is a Lisp created by Calvin Rose that
compiles to Lua. It gives Lua programs macros and expression-oriented syntax
while retaining Lua's small runtime and straightforward interoperation. People
use it anywhere Lua fits, including embedded tools, games, and configuration.

This educational, unofficial demonstration compiles a genuine Fennel Convex
client ahead of time, then runs the generated program on Lua 5.1. It is not a
production SDK.

## Getting Started

[`examples/basics/main.fnl`](examples/basics/main.fnl) is the canonical example.
It reads a unique room over HTTP, starts Live before writing, applies one
idempotent mutation, and proves that the resulting Live value agrees.

```sh
./run test fennel
./run verify-example fennel
./run verify fennel
./run verify-hosted fennel
./run verify-all fennel
```

`test` compiles every checked-in Fennel source to Lua 5.1 and runs deterministic
HTTP, Live-owner, transition, buffering, TCP-output, and adapter lifecycle
fixtures. The remaining commands run the exact canonical example and shared
black-box conformance against local, hosted, or both deployment profiles.

## Interesting Parts

Fennel's keyword call syntax keeps the three HTTP operations close to the
TypeScript shape:

```ts
const state = await client.query(api.demo.state, { room });
```

```fennel
(local state (checked (: client :query "demo:state" {: room})))
```

Both versions start Live before the mutation. In TypeScript, a browser client
returns an unsubscribe callback:

```ts
const unsubscribe = client.onUpdate(api.demo.state, { room }, handleState);
```

The Fennel client returns a subscription with a bounded update stream:

```fennel
(local subscription (checked (: client :subscribe "demo:state" {: room})))
(local update (checked (: subscription :next-update 10)))
```

One cqueues worker owns the WebSocket, query-set versions, and reconnects. That
is the same single-owner idea as an event loop, expressed with Fennel tables and
coroutines rather than JavaScript promises.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, and action | Passing locally and hosted |
| Live query subscriptions | Passing locally and hosted |
| Authentication for HTTP calls | Implemented |
| Live authentication | Deferred |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.fnl -->
```fennel
#!/usr/local/bin/fennel
;; This canonical example demonstrates one complete Convex HTTP and Live journey.
(local Convex (require :convex))
(local Integer (require :integer))

(fn checked [result err]
  (if result result
      (error (.. (or (and err err.name) :Error) ": "
                 (or (and err err.message) "unknown failure")))))

(fn main []
  (let [deployment-url (assert (os.getenv :CONVEX_URL) "CONVEX_URL is required")
        ;; Create the Fennel client for the approved test deployment.
        client (checked (Convex.new deployment-url))
        ;; The verifier supplies a unique room so parallel runs never collide.
        room (or (. arg 1) :fennel-example)
        ;; Read the starting state through Convex's HTTP query API.
        current (checked (: client :query "demo:state" {: room}))
        initial (Integer.checked current.value.count "current query")]
    (print (.. "current count: " initial))
    ;; Subscribe before mutating so no reactive update can be missed.
    (let [subscription (checked (: client :subscribe "demo:state" {: room}))
          live-initial (checked (: subscription :next-update 10))
          live-initial-count (Integer.checked live-initial.value.count
                                             "initial Live value")]
      (assert (= live-initial-count initial)
              "initial Live value disagreed with HTTP")
      (print (.. "live initial count: " live-initial-count))
      ;; runId is the mutation's idempotency key.
      (let [run-id (table.concat [:fennel
                                  room
                                  (tostring (os.time))
                                  (tostring (math.random 1 2147483646))]
                                 ":")
            mutation (checked (: client :mutation "demo:increment"
                                 {: room :language :fennel :runId run-id}))
            changed (Integer.checked mutation.value.state.count :mutation)]
        (assert (= mutation.value.applied true) "mutation was not applied")
        (assert (= changed (+ initial 1))
                "mutation count did not advance by one")
        (print "mutation applied: true")
        (print (.. "mutation count: " changed))
        ;; Receive the resulting value from Live, without HTTP polling.
        (let [live-changed (checked (: subscription :next-update 10))
              live-changed-count (Integer.checked live-changed.value.count
                                                 "updated Live value")]
          (assert (= live-changed-count changed)
                  "updated Live value disagreed with mutation")
          (print (.. "live updated count: " live-changed-count))
          (print (.. "verified count: " initial " -> " live-changed-count))))
      ;; Unsubscribe before shutting down the single shared Live owner.
      (checked (: subscription :close))
      (: client :close))))

(main)
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The test-only adapter implements NDJSON protocol v1 over stdin/stdout and TCP.
One cqueues worker exclusively owns WebSocket reads, writes, reconnects, and
query-set versions. It keeps one logical session ID across reconnects and never
sends a second `ModifyQuerySet` before the preceding Transition acknowledges
the first. Subscription delivery keeps the newest 16 updates within a 3 MiB
budget. Adapter output is separately bounded to 64 pending events and 8 MiB,
including a conservative per-entry overhead.

The implementation pins Fennel 1.6.1, Lua 5.1.5, lua-http 0.4, cqueues, dkjson,
and the repository's `convex-rs-0.10.4-unversioned-sync` profile. Fennel owns all
Convex-specific HTTP and Live behaviour; the Lua libraries provide only ordinary
TLS, HTTP, WebSocket, scheduling, randomness, and JSON primitives.

## Known Issues

1. The educational client supports the JSON-safe Convex value subset.
2. Live authentication, `TransitionChunk` assembly, optimistic updates, and
   mutation replay are deferred.
