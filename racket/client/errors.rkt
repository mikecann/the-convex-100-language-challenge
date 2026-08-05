#lang racket/base

(provide
 (struct-out exn:fail:convex)
 (struct-out exn:fail:convex:function)
 (struct-out exn:fail:convex:protocol)
 (struct-out exn:fail:convex:transport)
 (struct-out exn:fail:convex:closed)
 convex-missing?
 missing-error-data
 raise-convex-function
 raise-convex-protocol
 raise-convex-transport
 raise-convex-closed)

;; Every public client failure shares this base type, so applications can either
;; handle Convex failures together or inspect the more useful subtype below.
(struct exn:fail:convex exn:fail () #:transparent)

;; Convex ran the requested function and returned a structured application or
;; developer error. `data` is the JSON errorData value, when one was supplied.
(struct exn:fail:convex:function exn:fail:convex
  (operation data logs)
  #:transparent)

;; A peer response did not match the HTTP or Live protocol this demonstration
;; implements. This is deliberately distinct from a function failure.
(struct exn:fail:convex:protocol exn:fail:convex () #:transparent)

;; Networking failed before Convex produced a valid function result. `cause`
;; retains the original Racket exception for diagnostics without flattening it.
(struct exn:fail:convex:transport exn:fail:convex
  (operation cause)
  #:transparent)

;; The client was closed before an operation could complete.
(struct exn:fail:convex:closed exn:fail:convex () #:transparent)

;; JSON false is #f and JSON null is 'null in Racket's JSON library, so neither
;; can also mean that errorData was absent. This opaque singleton preserves the
;; distinction the adapter needs when deciding whether to omit its data field.
(struct convex-missing ())
(define missing-error-data (convex-missing))

(define (continuation-marks)
  (current-continuation-marks))

(define (raise-convex-function message operation data logs)
  (raise
   (exn:fail:convex:function
    (format "Convex ~a failed: ~a" operation message)
    (continuation-marks)
    operation
    data
    logs)))

(define (raise-convex-protocol message)
  (raise
   (exn:fail:convex:protocol
    (format "Convex protocol error: ~a" message)
    (continuation-marks))))

(define (raise-convex-transport message operation [cause #f])
  (raise
   (exn:fail:convex:transport
    (format "Convex ~a transport error: ~a" operation message)
    (continuation-marks)
    operation
    cause)))

(define (raise-convex-closed)
  (raise
   (exn:fail:convex:closed
    "Convex client is closed"
    (continuation-marks))))
