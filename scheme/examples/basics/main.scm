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
