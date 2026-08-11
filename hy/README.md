# Convex from Hy

[Hy](https://hylang.org/) is a Lisp dialect embedded in Python. This
educational, unofficial client uses Hy's Lisp syntax while Python 3 runs the
transpiled program.

## Getting Started

[`examples/basics/main.hy`](examples/basics/main.hy) queries a counter, starts
Live, applies an idempotent increment, and checks the resulting update. Run it
through the root Docker command: `./run verify-example hy`.

## Interesting Parts

Hy keeps the Lisp call shape while using the same named Convex arguments a
React client would pass:

```typescript
const value = await client.query("demo:state", { room });
```

```hy
(setv value (.query client "demo:state" {"room" room}))
```

Starting Live before the mutation is explicit in both versions. The Hy
subscription returns structured updates so query failures stay distinct from
successful values:

```typescript
const unsubscribe = client.onUpdate("demo:state", { room }, handleUpdate);
```

```hy
(setv subscription (.subscribe client "demo:state" {"room" room}))
(setv update (.next-update subscription 10))
```

## Status

| Capability | Status |
| --- | --- |
| HTTP | Pending shared conformance |
| Live | Pending shared conformance |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.hy -->
```hy
(import math os secrets sys)
(sys.path.insert 0 (os.environ.get "CONVEX_CLIENT_PATH" "/work/client"))
(import convex [Client])

(defn whole [value operation]
  ;; Convex may spell a whole number as 1.0. Accept it, but refuse fractions.
  (if (or (isinstance value bool) (not (isinstance value #(int float))) (and (isinstance value float) (or (not (math.isfinite value)) (not (.is_integer value)))))
    (raise (RuntimeError (+ operation " count was not a finite whole number"))) None)
  (int value))

(defn main []
  ;; Read the dedicated deployment and unique room supplied by the verifier.
  (setv deployment-url (.get os.environ "CONVEX_URL")
        room (if (> (len sys.argv) 1) (get sys.argv 1) "hy-example"))
  ;; Create this unofficial Hy client. This example does not use authentication.
  (setv client (Client deployment-url))
  (try
    ;; Query over HTTP and decode Convex's JSON number as a whole count.
    (setv current (whole (get (. (.query client "demo:state" {"room" room}) value) "count") "current query"))
    (print (+ "current count: " (str current)))
    ;; Start Live before mutating so the subscription cannot miss the change.
    (setv subscription (.subscribe client "demo:state" {"room" room}))
    (try
      ;; The first Live value is the current result and must agree with HTTP.
      (setv initial (.next-update subscription 10))
      (if initial.error (raise initial.error) None)
      (if (!= (whole (get initial.value "count") "initial Live value") current) (raise (RuntimeError "initial Live value disagreed with HTTP")) None)
      (print (+ "live initial count: " (str current)))
      ;; runId makes the logical increment safe if this example is retried.
      (setv mutation (. (.mutation client "demo:increment" {"room" room "language" "hy" "runId" (secrets.token_hex 8)}) value))
      (if (is-not (get mutation "applied") True) (raise (RuntimeError "mutation was not applied")) None)
      (print "mutation applied: true")
      (setv expected (+ current 1))
      (if (!= (whole (get (get mutation "state") "count") "mutation") expected) (raise (RuntimeError "mutation count disagreed")) None)
      (print (+ "mutation count: " (str expected)))
      (setv changed (.next-update subscription 10))
      (if changed.error (raise changed.error) None)
      (if (!= (whole (get changed.value "count") "updated Live value") expected) (raise (RuntimeError "updated Live count disagreed")) None)
      (print (+ "live updated count: " (str expected)))
      (print (+ "verified count: " (str current) " -> " (str expected)))
      ;; Unsubscribe even if decoding or verification raises an exception.
      (finally (.close subscription)))
    ;; Closing the client retires the WebSocket owner and HTTP state.
    (finally (.close client))))

(if (and (= __name__ "__main__") (.get os.environ "CONVEX_URL")) (main) None)
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

From the repository root:

```sh
./run test hy
./run verify-example hy
./run verify hy
./run verify-hosted hy
./run verify-all hy
```

`test` transpiles and compiles the Hy sources and runs deterministic HTTP,
Live, reconnect, recovery, buffering, adapter, and example-decoding fixtures.
The verification commands then exercise the exact minimal images against the
approved local and hosted deployments. Only the shared evaluator may award the
HTTP and Live capabilities shown above.

HTTP, JSON handling, Live query-set ownership, reconnects, and adapter protocol
events are all in Hy. Python's standard library supplies HTTPS and JSON;
`websockets` supplies only RFC 6455 transport. Each subscription uses a bounded
16-message, 8 MiB queue, dropping the oldest pending value when necessary. One
Live worker exclusively owns WebSocket I/O, reconnects, and query-set versions.

The Docker build transpiles Hy 1.3.1 to Python ahead of time. The final pinned
non-scratch image contains Python 3.13.5, CA certificates, the `websockets`
transport dependency, `/bin/sh`, and basic policy tools. It does not contain Hy,
`hy2py`, pip, a compiler, or another delegated runtime.

## Known Issues

1. This client awaits shared local and hosted conformance before it earns a badge.
2. Live authentication, TransitionChunk assembly, mutation replay, optimistic
   updates, journals, and full Convex value support are deferred.
