# Convex from Common Lisp

This is a small native Common Lisp client that calls Convex functions over HTTP and keeps a query current over Live WebSockets.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.lisp`](examples/basics/main.lisp). It queries a fresh counter, starts Live before changing it, applies one idempotent mutation, and checks that HTTP, the mutation result, and Live all agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Bearer authentication and structured function errors | Verified by shared local and hosted conformance |
| Live initial values, updates, and query-error recovery | Verified by shared local and hosted conformance |
| Remove, five reconnects, generation barriers, and bounded delivery | Verified by shared local and hosted conformance |

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

## Docker verification

```sh
./run sync-examples
./run validate
./run test common-lisp
./run verify-example common-lisp
./run verify common-lisp
./run verify-hosted common-lisp
./run verify-all common-lisp
```

`test` runs strict JSON, HTTP, real-socket Live, and adapter tests before saving the exact example and adapter as native `linux/amd64` executables. `verify-example` runs the generated example from its minimal image against a unique room. The remaining shared commands add local and hosted black-box conformance; only their result evaluator can award HTTP or Live capability badges.

## Conformance and protocol notes

The public client implements Convex's documented JSON HTTP endpoints and the repository's pinned `/api/sync` profile directly in Common Lisp. It uses SBCL's ordinary socket support plus direct OpenSSL 3 calls for TLS, certificate-chain validation, hostname validation, and WebSocket transport. It does not invoke another Convex client, the Convex CLI, `curl`, Node.js, or Python.

One owner thread exclusively opens, reads, writes, retires, and reconnects the Live socket. Controllers queue Add, Remove, reconnect, and close commands to that owner. Complete transitions are validated, coalesced per query, and committed atomically; unchanged hydration is suppressed with a fixed-size incremental SHA-256 signature rather than a retained JSON copy. One manager-wide queue retains at most the newest 16 updates within a conservative 20 MiB budget. It charges four times the exact encoded event length, recursive SBCL container overhead, and a fixed envelope allowance. Active subscriptions have a separate 64-count and 8 MiB decoded path/argument budget. JSON decoding stops at 128 levels or 8,192 structural nodes before deeply nested or container-dense input can exhaust the runtime. Backoff starts at 100 ms, caps at 15 seconds, and resets after a valid connection or transition.

The test-only adapter speaks bounded UTF-8 NDJSON protocol v1 over stdin/stdout or one `ADAPTER_LISTEN` TCP connection. Its output has a separate newest-16, 6 MiB global bound that includes a kernel-blocked in-flight write. One global dispatcher owns dequeue through publication for every subscription, and its allocation-light UTF-8 encoder never creates a second full Common Lisp output string. `debugDisconnect` exists only in this adapter so the shared harness can prove real reconnects.

The final images contain saved SBCL executables, their runtime library closure, OpenSSL providers and roots, `/bin/sh`, and individual POSIX text tools required by the verifier. They do not contain the `sbcl` compiler command, package managers, network utilities, delegated runtimes, or a multicall binary. Both run as `65532:65532` with a read-only filesystem and all capabilities dropped.

## Limitations

Live authentication, optimistic updates, mutation and action messages over the WebSocket, journals, and `TransitionChunk` assembly are deferred. Receiving `TransitionChunk` is treated as protocol drift, emits a structured protocol error, and reconnects without permanently stranding the subscription. Values cover Convex's JSON-safe subset; tagged Convex value encodings are not yet converted into richer Common Lisp types. JSON values beyond the documented depth, node, active-subscription, or delivery budgets are rejected instead of risking unbounded runtime memory. Shared local and hosted conformance earned HTTP and Live from a clean reviewed commit.
