# Convex from Racket

This demonstration uses ordinary Racket to query and mutate a Convex deployment
over its documented HTTP API, then listens to the same query over a native
Racket RFC 6455 WebSocket implementation.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.rkt`](examples/basics/main.rkt) is the canonical example.
It reads a fresh counter room over HTTP, subscribes before changing the room,
applies one idempotent mutation, and proves Live observed the same `0 -> 1`
journey. The source below is generated directly from that runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared verification | Native Racket query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Awaiting shared verification | One native Racket Live owner handles subscriptions, replacement barriers, reconnects, reactive errors, and clean close against the pinned profile. |

No capability badge is earned until the shared local and hosted black-box tests
pass. A successful Docker build or language-local socket test does not count.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.rkt -->
```racket
#lang racket/base

(require racket/random
         "../../client/client.rkt")

;; Convex's JSON format represents the demo counter as a number. Accept an
;; integral decimal such as 0.0, but normalize it before counter arithmetic.
(define (verified-whole-count value operation)
  (unless (integer? value)
    (error operation "count was ~e, expected a whole number" value))
  (if (exact? value) value (inexact->exact value)))

(define (random-run-id)
  (apply string-append
         (for/list ([byte (in-bytes (crypto-random-bytes 8))])
           (define digits (number->string byte 16))
           (if (= (string-length digits) 1) (string-append "0" digits) digits))))

(define (run-example)
  (define deployment-url
    (or (getenv "CONVEX_URL") (error 'example "CONVEX_URL is required")))

  ;; Create one Convex client for the deployment supplied by the verifier.
  (define client (make-convex-client deployment-url))

  ;; A unique room keeps repeated and concurrent verifier runs independent.
  (define arguments (current-command-line-arguments))
  (define room (if (zero? (vector-length arguments))
                   "racket-example"
                   (vector-ref arguments 0)))

  (dynamic-wind
    void
    (lambda ()
      ;; Read the room over the documented HTTP query endpoint.
      (define current
        (convex-client-query client "demo:state" (hasheq 'room room)))
      (define current-count
        (verified-whole-count
         (hash-ref (convex-result-value current) 'count)
         'current-query))
      (printf "current count: ~a\n" current-count)

      ;; Subscribe before mutating so Live cannot miss the change between the
      ;; initial HTTP read and the reactive query becoming active.
      (define subscription
        (convex-client-subscribe client "demo:state" (hasheq 'room room)))
      (dynamic-wind
        void
        (lambda ()
          ;; Live first publishes its current value. It must agree with HTTP.
          (define initial (subscription-next-update subscription #:timeout 10))
          (when (convex-update-error initial) (raise (convex-update-error initial)))
          (define initial-count
            (verified-whole-count
             (hash-ref (convex-update-value initial) 'count)
             'initial-live-value))
          (unless (= initial-count current-count)
            (error 'example "initial Live count was ~a, expected ~a"
                   initial-count current-count))
          (printf "live initial count: ~a\n" initial-count)

          ;; runId is the mutation's idempotency key. Retrying this logical
          ;; write would return the existing result instead of incrementing twice.
          (define mutation
            (convex-client-mutation
             client
             "demo:increment"
             (hasheq 'room room 'language "racket" 'runId (random-run-id))))
          (define increment (convex-result-value mutation))
          (unless (eq? (hash-ref increment 'applied #f) #t)
            (error 'example "mutation was not applied"))
          (displayln "mutation applied: true")

          (define expected-count (add1 current-count))
          (define mutation-count
            (verified-whole-count
             (hash-ref (hash-ref increment 'state) 'count)
             'mutation))
          (unless (= mutation-count expected-count)
            (error 'example "mutation count was ~a, expected ~a"
                   mutation-count expected-count))
          (printf "mutation count: ~a\n" mutation-count)

          ;; Receive the changed room through Live, without another HTTP query.
          (define changed (subscription-next-update subscription #:timeout 10))
          (when (convex-update-error changed) (raise (convex-update-error changed)))
          (define changed-count
            (verified-whole-count
             (hash-ref (convex-update-value changed) 'count)
             'updated-live-value))
          (unless (= changed-count expected-count)
            (error 'example "updated Live count was ~a, expected ~a"
                   changed-count expected-count))
          (printf "live updated count: ~a\n" changed-count)

          ;; These values prove HTTP query, HTTP mutation, and Live agreed.
          (printf "verified count: ~a -> ~a\n" current-count changed-count))
        (lambda () (subscription-close! subscription))))
    (lambda () (convex-client-close! client))))

(module+ main (run-example))

(module+ test
  (require rackunit)
  (check-equal? (verified-whole-count 0.0 'test) 0)
  (check-equal? (verified-whole-count 1.0 'test) 1)
  (check-equal? (verified-whole-count 2 'test) 2)
  (check-exn exn:fail? (lambda () (verified-whole-count 1.5 'test))))
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

From the repository root:

```sh
./run test racket
./run verify-example racket
./run verify racket
./run verify-hosted racket
./run verify-all racket
```

`test` builds the pinned source toolchain and runs language-local tests in
Docker. `verify-example` executes the exact source shown above. The remaining
commands are root-owned gates that test the adapter against approved local and
hosted deployments. Language work does not run or claim those shared gates.

## Conformance and protocol notes

The test adapter under `client/tests/conformance/` speaks strict NDJSON adapter
protocol v1 over stdin/stdout or one TCP connection. It calls the Racket client
for every operation. Its serialized output gate owns subscription generations,
so a stale relay cannot cross a replacement, unsubscribe, or close
acknowledgement. `debugDisconnect` is adapter-only and proves genuine reconnects.
Each subscription keeps at most the newest sixteen updates. All subscriptions
also share a 3 MiB encoded publication budget, and the adapter holds an update's
reservation until its NDJSON write finishes. The real final-image stress fixture
stops its controller while near-limit updates arrive to check the 128 MiB gate.

HTTP uses Convex's documented `format: "json"` endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at upstream commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`. Realtime is an
internal protocol, so hosted compatibility can drift and must be tested.

The Docker toolchain builds official Racket 8.10 source commit
`b10ecfb8311fca2d42636eea2ca12aff0b76b208` as x86_64 BC conservative GC with
JIT, futures, and GUI support disabled. Packaged CS and precise-GC runtimes abort
under this host's amd64 translation, while the conservative-GC runtime and its
compiled ELF executables pass native architecture and execution checks.

## Toolchain investigation

This is a host-specific Docker translation result, not a claim that Racket is
generally broken on x86-64 Linux. The investigation ran on macOS 26.5.2 arm64
with Docker Desktop 29.6.2. The Docker server reported `aarch64` and LinuxKit
6.12.76. Every probe below used `--platform linux/amd64`.

Debian Bookworm's Racket 8.7 package works in an arm64 container:

```sh
docker run --rm --platform linux/arm64 debian:bookworm-slim \
  sh -lc 'apt-get update && apt-get install -y racket && racket -v && racket -e "(displayln 42)"'
# Welcome to Racket v8.7 [cs].
# 42
```

The same package under amd64 translation reports
`Error: error reading from ~a ("petite")` and exits 134 before version output.
Pinned official images fail before they can evaluate client source too:

```text
racket/racket:8.18-full@sha256:c9104a6ce9df82947c5753718606cca305aeaf80c0b79038546625656277f56d
  racket -v -> petite read error, exit 134

racket/racket:8.17-bc@sha256:f50290e1c1f6e431c5077fe59265ba88283a42bcb5ee9187ee97413baa3cb023
  racket -v -> abort, exit 134
```

Official BC tags 8.14, 8.10, and 7.9 also abort on this translation path.
Alpine's amd64 Racket 8.17 package fails with the same `petite` error. The
working source target is:

```sh
../../bc/configure \
  --disable-jit --disable-futures --disable-gracket \
  --enable-bcdefault --disable-useprefix --enable-origtree
make cgc
make install-cgc
/build/racket/racket/bin/racketcgc -v
# Welcome to Racket v8.10 [cgc].
/build/racket/racket/bin/racketcgc -e '(displayln (+ 40 2))'
# 42
```

Parallel `make -j4 cgc` reached nested libffi and then lost GNU make's jobserver
descriptor under translation. The serial build is the deterministic pinned
path. `racocgc exe --cgc --orig-exe` produces genuine ELF 64-bit x86-64
executables. The final adapter and example embed Racket and their module
closure, depend directly on glibc, and contain no interpreter, compiler,
package manager, source tree, or delegated runtime.

## Limitations

- Bearer-token replacement and clearing apply to HTTP. Live authentication is
  deferred.
- Live values cover this experiment's JSON-safe subset, not lossless Convex
  Int64, bytes, special floats, or negative zero.
- Mutations and actions use HTTP. WebSocket mutation replay, journals,
  optimistic updates, and read-your-own-write timestamps are outside this demo.
- `TransitionChunk` is not implemented. Receiving one is treated as protocol
  drift, published as a structured error, and followed by a reconnect.
- The source toolchain intentionally uses conservative GC and no JIT to remain
  runnable under the required Docker Desktop linux/amd64 translation path.
