# Convex from Hy

[Hy](https://hylang.org/) is a Lisp dialect embedded in Python. This
educational, unofficial client uses Hy's Lisp syntax while Python 3 runs the
transpiled program.

## Getting Started

[`examples/basics/main.hy`](examples/basics/main.hy) queries a counter, starts
Live, applies an idempotent increment, and checks the resulting update. Run it
through the root Docker command: `./run verify-example hy`.

## Interesting Parts

Hy has been around since 2013, its mascot is a cuttlefish named Cuddles, and
its trick is compiling s-expressions straight into Python's own abstract
syntax tree. Every parenthesis below runs as ordinary Python 3 — this repo
even transpiles ahead of time, so the shipped image contains no Hy at all.

### The method dot walks to the front

A Python method call becomes a Lisp form whose head starts with a dot:
`(.query client …)` is `client.query(…)`. Braces build a dict with no colons
or commas — pairs are simply adjacent — and `(. result value)` is attribute
access on the `Result` the client hands back.

```hy
;; TypeScript: const state = await client.query("demo:state", { room });
(setv result (.query client "demo:state" {"room" room}))
(setv current (get (. result value) "count"))
(print (+ "current count: " (str current)))
```

Read aloud, the first call really does say "query the client".

### Kebab-case on the page, snake_case underneath

Hy "mangles" identifiers so Lisp-style names survive as valid Python:
`deployment-url` compiles to `deployment_url`. The client's API is written
this way too — `set-auth` in Hy is `set_auth` to any Python caller.

```hy
;; deployment-url is deployment_url by the time Python runs it.
(setv deployment-url (.get os.environ "CONVEX_URL")
      room (if (> (len sys.argv) 1) (get sys.argv 1) "hy-example"))
(setv client (Client deployment-url))
```

One `setv` binds several names, and `if` is an expression, so the fallback
room name needs no extra scaffolding.

### Python's batteries, Lisp's parentheses

Because Hy *is* Python underneath, there is no FFI story: the example calls
`secrets.token_hex` mid-expression to mint the `runId` that makes the
increment mutation safe to retry.

```hy
;; TypeScript: await client.mutation("demo:increment", { room, language, runId })
(setv mutation (. (.mutation client "demo:increment"
                             {"room" room "language" "hy"
                              "runId" (secrets.token_hex 8)})
                  value))
(print (get (get mutation "state") "count"))
```

### A Convex error type in four s-expressions

`defclass` is Python's class machinery in prefix notation. The client uses it
to keep a failed Convex function distinct from transport trouble:
`FunctionError` carries the server's structured `data` and `logs`, much like
`ConvexError` in the official TypeScript SDK. Square-bracket parameters like
`[data None]` declare defaults, and `#(message)` is Hy's tuple literal.

```hy
(defclass FunctionError [ConvexError]
  (defn __init__ [self message [data None] [logs None]]
    (setv self.args #(message))
    (setv self.data data self.logs (or logs []))))
```

Catching it puts the application data your Convex function threw one
`except` clause away.

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
16-message, 8 MiB queue, and all subscriptions share a 16 MiB manager budget,
dropping pending values when necessary. One Live worker exclusively owns
WebSocket I/O, reconnects, and query-set versions, with a 1 MiB Live message
limit. The adapter's test-only stopped-reader mode lets Docker measure that
aggregate policy in the exact final image; ordinary adapter commands cannot
activate it.

The Docker build transpiles Hy 1.3.1 to Python ahead of time. The final pinned
non-scratch image contains Python 3.13.5, CA certificates, the `websockets`
transport dependency, `/bin/sh`, and basic policy tools. It does not contain Hy,
`hy2py`, pip, a compiler, or another delegated runtime.

## Known Issues

1. This client awaits shared local and hosted conformance before it earns a badge.
2. Live authentication, TransitionChunk assembly, mutation replay, optimistic
   updates, journals, and full Convex value support are deferred.
