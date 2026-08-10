# Convex from Fennel

This demonstration compiles a genuine Fennel client ahead of time, then uses it
from Lua 5.1 to query, mutate, and subscribe to a shared Convex counter.

It is educational, unofficial, and not a production SDK.

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

The client implements Convex's HTTP API and `/api/sync` protocol in Fennel. One
cqueues worker owns the WebSocket connection, so reconnects, query-set changes,
and incoming transitions cannot race with controller commands. Subscription and
adapter-output queues have separate count and byte limits.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, and action | Implemented; shared verification pending |
| Live query subscriptions | Implemented; shared verification pending |
| Authentication for HTTP calls | Implemented |
| Live authentication | Deferred |

## Example

```fennel
#!/usr/local/bin/fennel
;; This canonical example demonstrates one complete Convex HTTP and Live journey.
(local Convex (require :convex))

(fn checked [result err]
  (if result result
      (error (.. (or (and err err.name) :Error) ": "
                 (or (and err err.message) "unknown failure")))))

(fn checked-count [value operation]
  (if (not (and (= (type value) :number) (= (% value 1) 0)))
      (error (.. operation " count must be a whole number")))
  value)

(fn main []
  (let [deployment-url (assert (os.getenv :CONVEX_URL) "CONVEX_URL is required")
        ;; Create the Fennel client for the approved test deployment.
        client (checked (Convex.new deployment-url))
        ;; The verifier supplies a unique room so parallel runs never collide.
        room (or (. arg 1) :fennel-example)
        ;; Read the starting state through Convex's HTTP query API.
        current (checked (: client :query "demo:state" {: room}))
        initial (checked-count current.value.count "current query")]
    (print (.. "current count: " initial))
    ;; Subscribe before mutating so no reactive update can be missed.
    (let [subscription (checked (: client :subscribe "demo:state" {: room}))
          live-initial (checked (: subscription :next-update 10))
          live-initial-count (checked-count live-initial.value.count
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
            changed (checked-count mutation.value.state.count :mutation)]
        (assert (= mutation.value.applied true) "mutation was not applied")
        (assert (= changed (+ initial 1))
                "mutation count did not advance by one")
        (print "mutation applied: true")
        (print (.. "mutation count: " changed))
        ;; Receive the resulting value from Live, without HTTP polling.
        (let [live-changed (checked (: subscription :next-update 10))
              live-changed-count (checked-count live-changed.value.count
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

## Implementation Notes

The test-only adapter implements NDJSON protocol v1 over stdin/stdout and TCP.
One cqueues worker exclusively owns WebSocket reads, writes, reconnects, and
query-set versions. Subscription delivery keeps the newest 16 updates. Adapter
output is separately bounded to 64 pending events and 8 MiB including a
conservative per-entry overhead.

The implementation pins Fennel 1.6.1, Lua 5.1.5, lua-http 0.4, cqueues, dkjson,
and the repository's `convex-rs-0.10.4-unversioned-sync` profile. Fennel owns all
Convex-specific HTTP and Live behaviour; the Lua libraries provide only ordinary
TLS, HTTP, WebSocket, scheduling, randomness, and JSON primitives.

## Known Issues

Shared local and hosted conformance remain pending, so this branch does not award
itself HTTP or Live capabilities. The educational client supports the JSON-safe
Convex value subset. Live authentication, TransitionChunk assembly, optimistic
updates, and mutation replay are deferred.
