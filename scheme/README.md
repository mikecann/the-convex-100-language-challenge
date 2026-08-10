# Convex from Scheme

This is a small native CHICKEN Scheme client that calls Convex functions over HTTP and keeps a query current over Live WebSockets.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.scm`](examples/basics/main.scm). It queries a fresh counter, starts Live before changing it, applies one idempotent mutation, and checks that HTTP, the mutation result, and Live all agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Bearer authentication and structured function errors | Verified by shared local and hosted conformance |
| Live initial values, updates, and query-error recovery | Verified by shared local and hosted conformance |
| Remove, five reconnects, generation barriers, and bounded delivery | Verified by shared local and hosted conformance |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.scm -->
```scheme
(import scheme
        (chicken base)
        (chicken condition)
        (chicken io)
        (chicken port)
        (chicken process-context)
        srfi-4
        convex)

(define (example-count value operation)
  ;; Generic JSON becomes a Scheme vector of key/value pairs. This program
  ;; narrows the count to the non-negative integer its output contract needs.
  (let ((count (and (json-object? value) (json-get value "count" #f))))
    ;; Convex may encode an integral number as 0.0. Scheme still recognizes
    ;; that as an integer, and the range comparisons reject NaN and infinity.
    (unless (and (number? count) (real? count) (integer? count)
                 (<= 0 count 9223372036854775807))
      (error 'example operation "returned a non-integral or out-of-range count"))
    (inexact->exact count)))

(define (random-hex-id)
  ;; A fresh runId makes the mutation idempotent without delegating randomness
  ;; to a CLI or another runtime.
  (call-with-input-file
   "/dev/urandom"
   (lambda (input)
     (let ((bytes (read-u8vector 16 input))
           (digits "0123456789abcdef"))
       (unless (= (u8vector-length bytes) 16)
         (error 'example "could not read /dev/urandom"))
       (let ((text (make-string 32 #\0)))
         (let loop ((index 0))
           (when (< index 16)
             (let ((byte (u8vector-ref bytes index)))
               (string-set! text (* index 2)
                            (string-ref digits (quotient byte 16)))
               (string-set! text (+ (* index 2) 1)
                            (string-ref digits (modulo byte 16)))
               (loop (+ index 1)))))
         text)))))

(define (next-example-value subscription operation)
  (let ((update (subscription-next subscription 10.0)))
    (unless update (error 'example operation "timed out"))
    (when (update-error update) (raise (update-error update)))
    (update-value update)))

(define (example-condition-text condition)
  (cond
    ((convex-error? condition) (convex-error-message condition))
    ((and (condition? condition)
          ((condition-predicate 'exn) condition))
     (let ((message (get-condition-property condition 'exn 'message #f)))
       (if message
           (with-output-to-string (lambda () (display message)))
           "Scheme exception")))
    (else (with-output-to-string (lambda () (write condition))))))

(define (example-main)
  (let ((deployment (get-environment-variable "CONVEX_URL")))
    (unless (and deployment (> (string-length deployment) 0))
      (error 'example "CONVEX_URL is required"))
    (let* ((arguments (command-line-arguments))
           (room (if (pair? arguments)
                     (car arguments)
                     (or (get-environment-variable "EXAMPLE_ROOM")
                         "scheme-example")))
           ;; Configure one native Scheme client for the deployment supplied
           ;; by the runtime container.
           (client (make-client deployment client-version: "scheme-0.1.0"))
           (subscription #f))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          ;; Query the current state through Convex's documented HTTP endpoint.
          (let* ((query (client-query client "demo:state"
                                      (json-object "room" room)))
                 (current (example-count (result-value query) "current query")))
            (print "current count: " current)

            ;; Start Live before mutating, so no reactive update is missed.
            (set! subscription
                  (client-subscribe client "demo:state"
                                    (json-object "room" room)))

            ;; The first Live value hydrates the same current query.
            (let ((initial
                    (example-count
                     (next-example-value subscription "initial Live value")
                     "initial Live value")))
              (unless (= initial current)
                (error 'example "initial Live count disagreed with HTTP"))
              (print "live initial count: " initial))

            ;; runId is the mutation's idempotency key. Reusing it returns the
            ;; prior result rather than incrementing twice.
            (let* ((mutation
                     (client-mutation
                      client "demo:increment"
                      (json-object "room" room "language" "scheme"
                                   "runId" (random-hex-id))))
                   (mutation-value (result-value mutation))
                   (applied (json-get mutation-value "applied" #f))
                   (mutation-count
                     (example-count (json-get mutation-value "state" #f)
                                    "mutation"))
                   (expected (+ current 1)))
              (unless (eq? applied #t)
                (error 'example "mutation was not applied"))
              (unless (= mutation-count expected)
                (error 'example "mutation returned an unexpected count"))
              (print "mutation applied: true")
              (print "mutation count: " mutation-count)

              ;; Receive the mutation through Live without polling HTTP.
              (let ((updated
                      (example-count
                       (next-example-value subscription "updated Live value")
                       "updated Live value")))
                (unless (= updated expected)
                  (error 'example "updated Live count disagreed with mutation"))
                (print "live updated count: " updated)

                ;; All three operations agreed before this proof line prints.
                (print "verified count: " current " -> " updated)))))
        (lambda ()
          ;; Cleanup uses acknowledged, bounded owner commands.
          (when subscription
            (handle-exceptions condition #f
              (subscription-close! subscription 2.0)))
          (handle-exceptions condition #f (client-close! client 2.0)))))))

(handle-exceptions condition
  (begin
    (display "Scheme example failed: " (current-error-port))
    (display (example-condition-text condition) (current-error-port))
    (newline (current-error-port))
    (flush-output (current-error-port))
    (exit 1))
  (example-main)
  (exit 0))
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test scheme
./run verify-example scheme
./run verify scheme
./run verify-hosted scheme
./run verify-all scheme
```

`test` builds the pinned CHICKEN dependency graph from source, then runs strict JSON, real HTTP, real-socket Live, stdin/TCP adapter, and canonical example tests. It saves the exact adapter and example as native `linux/amd64` executables. `verify-example` runs the example from its minimal image against a unique room. The remaining shared commands add local and hosted black-box conformance. Those runs passed, and the root result evaluator awarded HTTP and Live.

## Conformance and protocol notes

The public client implements Convex's documented JSON HTTP endpoints and the repository's pinned `/api/sync` profile directly in Scheme. HTTP request/response handling and RFC6455 framing are native Scheme code over CHICKEN's TCP and OpenSSL bindings. JSON, SHA-1, base64, and SRFI eggs provide ordinary language facilities only. One pinned patch makes OpenSSL 2.2.6 verify the requested DNS name or IP address as well as the certificate chain. No request invokes another Convex client, the Convex CLI, `curl`, Node.js, or Python.

One owner thread exclusively opens, reads, writes, retires, and reconnects the Live socket. Controllers queue Add, Remove, reconnect, and close commands to that owner and wait for acknowledgements. Complete transitions are validated, coalesced per query, and committed atomically. Unchanged reconnect hydration is suppressed with a fixed-size FNV-1a signature rather than a retained JSON copy. Every delivered update carries its socket generation, which lets the adapter reject an update that was dequeued before a replacement, unsubscribe, or debug barrier.

The manager retains the newest 16 updates within a conservative 20 MiB global budget, including four times the exact encoded event length and a fixed record allowance. Active subscriptions have a separate 64-count and 8 MiB path/argument budget. JSON decoding stops at 2 MiB, 128 levels, or 8,192 structural nodes before malformed or dense input can exhaust the runtime. Reconnect backoff starts at 100 ms, caps at 15 seconds, and resets after a valid connection or transition.

The adapter speaks bounded UTF-8 NDJSON protocol v1 over stdin/stdout or one `ADAPTER_LISTEN` TCP connection. Its independent output queue retains at most the newest 16 encoded events within 6 MiB, including a TCP write currently in flight. Subscription values may be coalesced under pressure, while acknowledgements and errors wait for bounded room or fail the connection. Replacement, unsubscribe, reconnect, and close acknowledgements share the same publication lock as relay events.

The final images contain the native executable, OpenSSL 3, zlib, certificate roots, `/bin/sh`, and the individual POSIX tools required by the verifier. They do not contain CHICKEN, a C compiler, package or network tools, delegated runtimes, services, or a multicall binary. Both run as `65532:65532` under the repository's read-only, capability-drop, no-new-privileges, 128 MiB policy.

## Limitations

Live authentication, optimistic updates, mutation and action messages over the WebSocket, journals, and `TransitionChunk` assembly are deferred. HTTP currently uses a bounded connection-close response exchange; chunked and persistent response framing are deferred. A `TransitionChunk` is treated as recoverable protocol drift and retires the socket rather than publishing partial state. Values cover Convex's JSON-safe subset; tagged Convex value encodings are not converted into richer Scheme types. Inputs beyond the documented line, JSON, subscription, delivery, or output bounds are rejected or coalesced instead of risking unbounded memory. Shared local and hosted conformance earned HTTP and Live from a clean reviewed commit.
