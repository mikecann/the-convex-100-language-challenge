#lang racket/base

(require "errors.rkt"
         "http.rkt"
         "live.rkt")

(provide (all-from-out "errors.rkt")
         (all-from-out "http.rkt")
         (all-from-out "live.rkt")
         convex-client-subscribe
         convex-client-debug-disconnect!)

;; HTTP client records deliberately contain no Live protocol state. This weak
;; table attaches at most one Live owner to each public client without keeping
;; an otherwise unreachable client alive.
(define managers (make-weak-hasheq))
(define managers-lock (make-semaphore 1))

(define (client-live-manager client #:create? [create? #t])
  (call-with-semaphore
   managers-lock
   (lambda ()
     (when (convex-client-closed? client)
       (raise
        (exn:fail:convex:closed "Convex client is closed"
                                (current-continuation-marks))))
     (define existing (hash-ref managers client #f))
     (cond
       [existing existing]
       [(not create?) #f]
       [else
        (define manager
          (make-live-manager (convex-client-deployment-url client)
                             (convex-client-client-version client)))
        (hash-set! managers client manager)
        (convex-client-register-close-hook!
         client
         (lambda ()
           ;; Registration can synchronously invoke this hook if close won the
           ;; race. Do not reacquire managers-lock here. The table has weak
           ;; client keys, and a closed client rejects every future lookup.
           (live-manager-close! manager)))
        manager]))))

(define (convex-client-subscribe client path [args (hasheq)])
  (live-subscribe (client-live-manager client) path args))

;; Deliberately named for the conformance adapter. Educational programs should
;; not break healthy transports to influence ordinary reconnect behaviour.
(define (convex-client-debug-disconnect! client)
  (define manager (client-live-manager client #:create? #f))
  (unless manager
    (raise
     (exn:fail:convex:transport
      "Live WebSocket has not been started"
      (current-continuation-marks)
      "live"
      #f)))
  (live-debug-disconnect! manager))
