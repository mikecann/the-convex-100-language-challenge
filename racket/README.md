<img src="logo.png" alt="Racket logo" width="160">
<!-- Logo source: https://racket-lang.org/img/racket-logo.svg -->

# Racket

[Racket](https://racket-lang.org/) is a Lisp dialect descended from Scheme and
a toolkit for building new languages. It grew out of PLT Scheme before the
project adopted the Racket name, and it is now best known for language-oriented
programming, programming-language research, education, and practical work from
web applications to desktop tools. The [official guide](https://docs.racket-lang.org/guide/intro.html)
describes Racket as a language, a family of languages, and a set of tools. The
[rename history](https://racket-lang.org/new-name.html) explains how that wider
scope outgrew the old PLT Scheme name.

This repository's client is an educational, unofficial experiment. It is not a
production SDK, an officially sanctioned Convex client, or a package intended
for publication.

## Getting Started

Start with [`examples/basics/main.rkt`](examples/basics/main.rkt). It queries a
fresh counter room, starts a Live subscription before changing the room, applies
one idempotent mutation, and checks that HTTP and Live both observed `0 -> 1`.

From the repository root, run the exact example in its minimal Docker image:

```sh
./run verify-example racket
```

Docker supplies the pinned Racket toolchain and an approved test deployment, so
you do not need to install Racket or configure Convex on the host.

## Interesting Parts

### Convex objects become immutable symbol-keyed hashes

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function RoomCount() {
  const state = useQuery(api.demo.state, { room: "comparison-room" });
  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // Generated types know the result shape.
}
```

**Racket**

```racket
#lang racket/base

(require "client/client.rkt")

(define deployment-url
  (or (getenv "CONVEX_URL") (error 'readme "CONVEX_URL is required")))
(define client (make-convex-client deployment-url))

;; `hasheq` creates an immutable object whose keys are symbols such as 'room.
(define arguments (hasheq 'room "comparison-room"))

;; This is one HTTP request, not a reactive subscription like useQuery.
(define result (convex-client-query client "demo:state" arguments))
(define state (convex-result-value result))
(displayln (hash-ref state 'count)) ; The returned hash is dynamically typed.

(convex-client-close! client)
```

Racket's quote in `'room` creates a symbol, which its JSON library maps to the
object key `room`. Unlike the generated TypeScript API, this demonstration uses
the string path `"demo:state"` and checks returned shapes at runtime. See the
[HTTP client](client/http.rkt) for the JSON request and result handling.

### A command-line program owns its Live subscription

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function LiveCounter() {
  const room = "live-comparison-room";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  return (
    <button
      onClick={() =>
        increment({ room, language: "typescript", runId: crypto.randomUUID() })
      }
    >
      Count: {state?.count ?? "loading"} {/* React rerenders on each update. */}
    </button>
  );
}
```

**Racket**

```racket
#lang racket/base

(require "client/client.rkt")

(define deployment-url
  (or (getenv "CONVEX_URL") (error 'readme "CONVEX_URL is required")))
(define client (make-convex-client deployment-url))
(define room "live-comparison-room")
(define run-id (format "readme-~a" (current-inexact-milliseconds)))
(define subscription
  (convex-client-subscribe client "demo:state" (hasheq 'room room)))

(dynamic-wind
  void
  (lambda ()
    ;; The client publishes the initial query value through the subscription.
    (define initial (subscription-next-update subscription #:timeout 10))
    (when (convex-update-error initial) (raise (convex-update-error initial)))

    ;; Starting Live first means this mutation cannot slip between query setup
    ;; and the subscription becoming active.
    (convex-client-mutation
     client
     "demo:increment"
     ;; runId makes retrying this logical write idempotent.
     (hasheq 'room room 'language "racket" 'runId run-id))

    ;; `next-update` blocks until Live supplies the changed value.
    (define changed (subscription-next-update subscription #:timeout 10))
    (when (convex-update-error changed) (raise (convex-update-error changed)))
    (displayln (hash-ref (convex-update-value changed) 'count)))
  (lambda ()
    ;; `dynamic-wind` runs cleanup even when the body raises an exception.
    (subscription-close! subscription)
    (convex-client-close! client)))
```

React owns the `useQuery` subscription and component rerenders. This client
instead exposes a blocking `subscription-next-update`, so a script owns the
subscription, reads each value, and closes it. That is a deliberate API choice,
not a limitation of Racket's threads, events, or callbacks. The complete
[canonical example](examples/basics/main.rkt) also validates every returned
counter value.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native Racket query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | One native Racket Live owner handles subscriptions, replacement barriers, reconnects, reactive errors, and clean close against the pinned profile. |

The shared local and hosted black-box tests earned both HTTP and Live. A Docker
build or language-local socket test alone would not earn either capability.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.rkt -->
```racket
#lang racket/base

(require racket/random
         "../../client/client.rkt")

;; Convex's JSON format represents the demo counter as a number. Accept an
;; integral decimal such as 0.0, but normalize it before counter arithmetic.
(define maximum-safe-count #x7fffffffffffffff)

(define (verified-whole-count value operation)
  (define normalized
    (cond
      [(exact-integer? value) value]
      [(and (inexact-real? value)
            ;; `rational?` excludes +nan.0 and infinities on the pinned
            ;; Racket base runtime while retaining ordinary decimal values.
            (rational? value)
            (integer? value))
       (inexact->exact value)]
      [else #f]))
  (unless (and normalized (<= 0 normalized maximum-safe-count))
    (error operation
           "count was ~e, expected a finite whole number in 0..~a"
           value maximum-safe-count))
  normalized)

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
  (check-equal? (verified-whole-count maximum-safe-count 'test)
                maximum-safe-count)
  (for ([invalid (in-list (list -1 1.5 "1" +inf.0 +nan.0
                                (add1 maximum-safe-count)))])
    (check-exn exn:fail?
               (lambda () (verified-whole-count invalid 'test)))))
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public client is native Racket. HTTP calls use Racket's `net/http-client`
and `json` libraries, while [`client/websocket.rkt`](client/websocket.rkt)
implements RFC 6455 framing directly. No JavaScript Convex client, Convex CLI,
`curl`, or other language runtime performs the Convex work.

HTTP uses Convex's documented JSON query, mutation, and action endpoints. A
successful call returns a `convex-result` containing both the decoded value and
Convex log lines. Function, protocol, transport, and closed-client failures have
separate Racket exception structures, so an application can distinguish a
function error from a broken connection.

Live is managed by one owner thread. Public operations send it commands rather
than changing the WebSocket concurrently. Each subscription keeps the newest 16
updates, and all subscriptions share a 3 MiB encoded publication budget. A slow
consumer therefore loses older state snapshots instead of growing memory without
a bound. Live pins the internal profile `convex-rs-0.10.4-unversioned-sync` at
commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`, so hosted verification remains
important because that protocol can drift.

The Docker build pins official Racket 8.10 source commit
`b10ecfb8311fca2d42636eea2ca12aff0b76b208`. On the required translated
`linux/amd64` build path, packaged CS and precise-GC runtimes aborted before the
client source ran. The working target is Racket BC with conservative GC, JIT,
futures, and GUI support disabled. It produces standalone x86-64 executables;
the final images contain the embedded runtime and TLS libraries, but no Racket
command, compiler, package manager, or source tree. This is a Docker host
compatibility choice, not a general limitation of Racket on x86-64 Linux.

For the separate evidence layers, run these commands from the repository root:

```sh
./run test racket
./run verify racket
./run verify-hosted racket
./run verify-all racket
```

`test` covers formatting, compilation, and language-local behavior. The shared
verification commands exercise the canonical example and client adapter against
approved local and hosted deployments.

## Known Issues

1. Bearer-token replacement and clearing apply to HTTP only. Live
   authentication is deferred.
2. Live supports the JSON-safe values used by this experiment, not lossless
   Convex Int64 values, bytes, special floating-point values, or negative zero.
3. Mutations and actions use HTTP. WebSocket mutation replay and
   read-your-own-write timestamps are not implemented.
4. `TransitionChunk` assembly is not implemented. Receiving one is treated as
   protocol drift, reported as a structured error, and followed by a reconnect.
5. Mutation journals and optimistic updates are outside this demonstration.
