<img src="logo.png" alt="Common Lisp logo" width="128">
<!-- Logo source: https://common-lisp.net/static/imgs/lisplogo_flag2_128.png -->

# Common Lisp

Common Lisp is the standardized, multi-paradigm member of the Lisp family. Work on the language began in 1981 by bringing several Lisp dialects together, and it became ANSI standard X3.226-1994. Its parenthesized forms are both code and ordinary list-shaped data, while the language also includes an object system, conditions, macros, native compilation, and interactive development. The [Common Lisp HyperSpec history](https://www.lispworks.com/documentation/HyperSpec/Front/Help.htm) explains that path from the wider Lisp family to the portable standard.

Today Common Lisp is a specialist language with an active ecosystem rather than a mainstream default. It is still used where interactive development, long-running processes, native performance, or building a language tailored to the problem are useful. This client runs on [SBCL](https://www.sbcl.org/), a native Common Lisp compiler with a debugger and profiler. [Common-Lisp.net](https://common-lisp.net/) is a community-maintained starting point for implementations, libraries, tools, and current events.

This repository's client is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Getting Started

Start with [`examples/basics/main.lisp`](examples/basics/main.lisp). It queries a new counter, subscribes before changing it, applies one idempotent mutation, and checks that HTTP, the mutation result, and Live all agree on `0 -> 1`.

From the repository root, run the exact example in its Docker image against a unique test room:

```sh
./run verify-example common-lisp
```

No Common Lisp toolchain is installed on the host.

## Interesting Parts

### False gets its own symbol, because `nil` is already three things

Since the very first Lisps of the late 1950s, `nil` has punned as false, the empty list, and "nothing here". JSON refuses to play along: `false`, `null`, and `[]` are three different values, and a Convex result cares which one came back. So this client decodes JSON's awkward pair into dedicated sentinel symbols, `+json-false+` and `+json-null+`, that can never collide with real data.

```common-lisp
(let* ((result (client-mutation client "demo:increment"
                                (json-object "room" "common-lisp-readme"
                                             "language" "common-lisp"
                                             "runId" (random-hex-id))))
       ;; TypeScript: result.applied is just a boolean
       (applied (json-get (result-value result) "applied" +json-false+)))
  ;; ~:[false~;true~] is FORMAT's inline if/else -- a tiny language of its own.
  (format t "applied: ~:[false~;true~]~%" (eq applied t)))
```

One `eq` test settles what Convex meant by `false`, and `format` prints the verdict with a directive instead of an `if`.

### A Convex error is a condition you can interrogate

Common Lisp's condition system, standardized in the 1980s, treats an error as a full object with named slots — it can even offer restarts that resume a computation instead of unwinding it. Here `function-error`, `protocol-error`, and `transport-error` are distinct condition types, each carrying Convex's error name, message, data, and log lines behind reader functions.

```common-lisp
(handler-case
    (client-query client "demo:state" (json-object "room" room))
  ;; TypeScript: catch (error) { if (error instanceof ConvexError) ... }
  (function-error (condition)
    (format t "Convex rejected the call ~A: ~A~%"
            (error-name condition) (error-message condition)))
  (transport-error ()
    (format t "The network flaked; safe to retry.~%")))
```

The canonical example uses exactly this split to wait through a recoverable socket retirement while failing fast on real query errors.

### LOOP reads the Live stream almost in English

`loop` is Common Lisp's famously controversial iteration macro: a whole mini-language of English-ish keywords that compiles away at macroexpansion time. Paired with keyword arguments like `:timeout`, it makes consuming Convex's reactive Live protocol read almost like the sentence describing it.

```common-lisp
(let ((subscription (client-subscribe client "demo:state"
                                      (json-object "room" room))))
  ;; TypeScript: const state = useQuery(api.demo.state, { room })
  (loop repeat 2
        for update = (subscription-next subscription :timeout 10.0)
        do (format t "count: ~D~%"
                   (json-get (update-value update) "count")))
  (subscription-close subscription))
```

The first delivery hydrates the current value; the second arrives when someone increments the counter, with no polling. Where React hides the subscription inside `useQuery`, this program holds it as a value it can wait on and close.

### UNWIND-PROTECT is `finally`, decades early

Lisp had guaranteed-cleanup control flow long before `try`/`finally` reached the mainstream: `unwind-protect` runs its cleanup forms however the protected body exits — normal return, error, or a non-local jump. It is how every program in this directory makes sure the client and its Live socket are retired.

```common-lisp
(let ((client (make-client (sb-ext:posix-getenv "CONVEX_URL"))))
  (unwind-protect
       (client-query client "demo:state" (json-object "room" room))
    ;; TypeScript: the finally block after await client.query(...)
    (client-close client)))
```

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Bearer authentication and structured function errors | Verified by shared local and hosted conformance |
| Live initial values, updates, and query-error recovery | Verified by shared local and hosted conformance |
| Remove, five reconnects, generation barriers, and bounded delivery | Verified by shared local and hosted conformance |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.lisp -->
```common-lisp
(in-package #:convex)

(defun example-count (value operation)
  "Accept Convex's integral decimal JSON numbers without accepting fractions."
  (let ((count (and (hash-table-p value) (json-get value "count"))))
    (unless (and (realp count)
                 (= count (truncate count))
                 (<= 0 count #x7fffffffffffffff))
      (error "~A returned a non-integral or out-of-range count" operation))
    (truncate count)))

(defun next-example-update (subscription operation)
  "Wait through recoverable transport events, but fail on query/protocol errors."
  (let ((deadline (deadline-after 10.0)))
    (loop
      for remaining = (- deadline (monotonic-seconds))
      do (when (<= remaining 0) (error "Timed out waiting for ~A" operation))
         (let ((update (subscription-next subscription :timeout remaining)))
           (unless update (error "Timed out waiting for ~A" operation))
           ;; Live reports a real socket retirement, then reconnects the same
           ;; subscription. The example waits for that recovery value.
           (when (and (update-error update)
                      (not (typep (update-error update) 'transport-error)))
             (error (update-error update)))
           (unless (update-error update) (return (update-value update)))))))

(defun example-main ()
  (handler-case
      (let ((deployment (sb-ext:posix-getenv "CONVEX_URL")))
        (unless (and deployment (plusp (length deployment)))
          (error "CONVEX_URL is required"))
        (let* ((arguments (rest sb-ext:*posix-argv*))
               (room (or (first arguments)
                         (sb-ext:posix-getenv "EXAMPLE_ROOM")
                         "common-lisp-example"))
               ;; Configure one client for the deployment supplied by Docker.
               (client (make-client deployment))
               (subscription nil))
          (unwind-protect
               (progn
                 ;; Query the room through Convex's documented HTTP endpoint.
                 (let* ((query (client-query client "demo:state"
                                             (json-object "room" room)))
                        ;; Decode the generic JSON object into the integer this
                        ;; counter program actually needs.
                        (current (example-count (result-value query) "current query")))
                   (format t "current count: ~D~%" current)

                   ;; Start Live before mutating so no reactive update is missed.
                   (setf subscription
                         (client-subscribe client "demo:state"
                                           (json-object "room" room)))

                   ;; The first Live value hydrates the same current query.
                   (let ((initial
                           (example-count
                            (next-example-update subscription "initial Live value")
                            "initial Live value")))
                     (unless (= initial current)
                       (error "Initial Live count disagreed with HTTP"))
                     (format t "live initial count: ~D~%" initial))

                   ;; A random runId is the mutation's idempotency key. Reusing
                   ;; it would return the prior result instead of incrementing twice.
                   (let* ((mutation
                            (client-mutation
                             client "demo:increment"
                             (json-object "room" room
                                          "language" "common-lisp"
                                          "runId" (random-hex-id))))
                          (mutation-value (result-value mutation))
                          (applied (json-get mutation-value "applied" +json-false+))
                          (mutation-count
                            (example-count (json-get mutation-value "state") "mutation"))
                          (expected (1+ current)))
                     (unless (eq applied t) (error "Mutation was not applied"))
                     (unless (= mutation-count expected)
                       (error "Mutation returned an unexpected count"))
                     (format t "mutation applied: true~%")
                     (format t "mutation count: ~D~%" mutation-count)

                     ;; Receive the mutation through Live, without polling HTTP.
                     (let ((updated
                             (example-count
                              (next-example-update subscription "updated Live value")
                              "updated Live value")))
                       (unless (= updated expected)
                         (error "Updated Live count disagreed with the mutation"))
                       (format t "live updated count: ~D~%" updated)

                       ;; All three operations agreed before this proof line prints.
                       (format t "verified count: ~D -> ~D~%" current updated)))))
            ;; Cleanup retires the subscription and bounds socket shutdown.
            (when subscription (ignore-errors (subscription-close subscription)))
            (ignore-errors (client-close client)))))
    (error (condition)
      (format *error-output* "Common Lisp example failed: ~A~%" condition)
      (finish-output *error-output*)
      (sb-ext:exit :code 1)))
  (sb-ext:exit :code 0))
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The client is native Common Lisp running on SBCL 2.2.9. It implements Convex's documented JSON HTTP calls and the repository's pinned `/api/sync` Live profile itself. SBCL sockets provide TCP, while direct OpenSSL 3 calls provide TLS, certificate and hostname checks, hashing, and the WebSocket transport. It does not delegate Convex behavior to another SDK, the Convex CLI, `curl`, Node.js, or Python.

HTTP calls return a `result` containing a generic JSON value and log lines. Function failures, malformed protocol data, and transport failures are separate Common Lisp condition types, so callers can handle them differently. The JSON layer rejects excessive depth and structure, and it preserves JSON false and null with dedicated sentinels.

One owner thread has exclusive control of the Live socket. Other threads queue subscribe, unsubscribe, reconnect, and close requests to it. The client validates each complete transition before publishing any part of it, suppresses unchanged reconnect hydration with a fixed-size hash, and keeps delivery memory bounded. The public queue holds at most 16 newest updates within a conservative 20 MiB budget; active subscriptions have separate 64-item and 8 MiB bounds.

Docker saves the example and adapter as native `linux/amd64` SBCL executables. The minimal runtime keeps only their library closure, TLS material, and the shell tools required by the shared verifier. It runs as `65532:65532` and contains no `sbcl` command or package manager.

## Known Issues

1. Live authentication, optimistic updates, mutations and actions over Live, and journals are not implemented.
2. `TransitionChunk` assembly is not implemented. Receiving one produces a recoverable protocol error and reconnect.
3. Values cover Convex's JSON-safe subset. Tagged Convex encodings are not converted into richer Common Lisp types.
4. Very deep, highly structured, or oversized Live data is rejected at the documented bounds rather than allowed to grow memory without limit.
