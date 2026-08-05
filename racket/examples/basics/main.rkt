#lang racket/base

(require racket/random
         "../../client/client.rkt")

;; Convex's JSON format represents the demo counter as a number. Reject a
;; fractional or inexact value instead of printing a misleading success line.
(define (verified-whole-count value operation)
  (unless (exact-integer? value)
    (error operation "count was ~e, expected an exact whole number" value))
  value)

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
