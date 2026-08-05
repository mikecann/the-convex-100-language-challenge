#lang racket/base

(require json
         rackunit
         rackunit/text-ui
         racket/async-channel
         racket/port
         racket/string
         racket/tcp
         "../errors.rkt"
         "../http.rkt")

(struct observed-request (line headers body) #:transparent)
(struct fixture (listener worker requests port) #:transparent)

(define (read-request input)
  (define request-line (read-line input 'any))
  (when (eof-object? request-line)
    (error 'fixture "peer closed before its HTTP request"))
  (define headers (make-hash))
  (let loop ()
    (define line (read-line input 'any))
    (cond
      [(eof-object? line) (error 'fixture "peer closed during HTTP headers")]
      [(string=? line "") (void)]
      [else
       (define colon
         (for/first ([character (in-string line)]
                     [index (in-naturals)]
                     #:when (char=? character #\:))
           index))
       (unless colon (error 'fixture "malformed request header ~v" line))
       (hash-set! headers
                  (string-downcase (substring line 0 colon))
                  (string-trim (substring line (add1 colon))))
       (loop)]))
  (define content-length
    (string->number (hash-ref headers "content-length" "0")))
  (unless (exact-nonnegative-integer? content-length)
    (error 'fixture "invalid request content length"))
  (define body (read-bytes content-length input))
  (unless (and (bytes? body) (= (bytes-length body) content-length))
    (error 'fixture "peer closed during HTTP body"))
  (observed-request request-line headers body))

(define (write-response output body [status "200 OK"])
  (fprintf output "HTTP/1.1 ~a\r\n" status)
  (fprintf output "Content-Type: application/json\r\n")
  (fprintf output "Content-Length: ~a\r\n" (bytes-length body))
  (fprintf output "Connection: close\r\n\r\n")
  (write-bytes body output)
  (flush-output output))

(define (json-response value [status "200 OK"])
  (lambda (_request output)
    (write-response
     output
     (string->bytes/utf-8 (jsexpr->string value))
     status)))

(define (raw-response body [status "200 OK"])
  (lambda (_request output) (write-response output body status)))

(define (start-fixture responders)
  (define listener (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_local-host port _remote-host _remote-port)
    (tcp-addresses listener #t))
  (define requests (make-async-channel))
  (define worker
    (thread
     (lambda ()
       (for ([responder (in-list responders)])
         (define-values (input output) (tcp-accept listener))
         (dynamic-wind
          void
          (lambda ()
            (define request (read-request input))
            (async-channel-put requests request)
            (responder request output))
          (lambda ()
            (close-input-port input)
            (close-output-port output)))))))
  (fixture listener worker requests port))

(define (stop-fixture! server)
  (with-handlers ([exn? void])
    (tcp-close (fixture-listener server)))
  (unless (thread-dead? (fixture-worker server))
    (kill-thread (fixture-worker server)))
  (void))

(define (fixture-url server [path ""])
  (format "http://127.0.0.1:~a~a" (fixture-port server) path))

(define (next-request server)
  (define request (sync/timeout 2 (fixture-requests server)))
  (unless request (error 'fixture "timed out waiting for HTTP request"))
  request)

(define (captured-error predicate thunk)
  (with-handlers ([predicate values])
    (thunk)
    #f))

(define http-tests
  (test-suite
   "native Racket Convex HTTP client"

   (test-case
    "query, mutation, and action use native Convex envelopes and auth lifecycle"
    (define server
      (start-fixture
       (list
        (json-response
         (hasheq 'status "success"
                 'value (hasheq 'count 1)
                 'logLines '("query log")))
        (json-response
         (hasheq 'status "success" 'value #t 'logLines '()))
        (json-response
         (hasheq 'status "success" 'value "done")))))
    (define client
      (make-convex-client
       (fixture-url server "/deployment/")
       #:auth-token "old-token"
       #:client-version "racket-test"))
    (dynamic-wind
     void
     (lambda ()
       (define query-result
         (convex-client-query client "counter:get" (hasheq 'room "room-a")))
       (check-equal? (convex-result-value query-result) (hasheq 'count 1))
       (check-equal? (convex-result-logs query-result) '("query log"))
       (convex-client-set-auth! client "new-token")
       (check-true
        (convex-result-value
         (convex-client-mutation client "counter:increment" (hasheq 'amount 1))))
       (convex-client-clear-auth! client)
       (check-equal?
        (convex-result-value
         (convex-client-action client "counter:action" (hasheq)))
        "done")

       (define query-request (next-request server))
       (define mutation-request (next-request server))
       (define action-request (next-request server))
       (check-equal? (observed-request-line query-request)
                     "POST /deployment/api/query HTTP/1.1")
       (check-equal? (observed-request-line mutation-request)
                     "POST /deployment/api/mutation HTTP/1.1")
       (check-equal? (observed-request-line action-request)
                     "POST /deployment/api/action HTTP/1.1")
       (check-equal?
        (hash-ref (observed-request-headers query-request) "convex-client")
        "racket-test")
       (check-equal?
        (hash-ref (observed-request-headers query-request) "authorization")
        "Bearer old-token")
       (check-equal?
        (hash-ref (observed-request-headers mutation-request) "authorization")
        "Bearer new-token")
       (check-false
        (hash-ref (observed-request-headers action-request) "authorization" #f))
       (check-equal?
        (string->jsexpr
         (bytes->string/utf-8 (observed-request-body query-request)))
        (hasheq 'path "counter:get"
                'args (hasheq 'room "room-a")
                'format "json")))
     (lambda ()
       (convex-client-close! client)
       (stop-fixture! server))))

   (test-case
    "auth hooks receive an ordered generation and clearing is explicit"
    (define client
      (make-convex-client "http://127.0.0.1:1" #:auth-token "first"))
    (define notices (make-async-channel))
    (convex-client-register-auth-hook!
     client
     (lambda (token generation)
       (async-channel-put notices (list token generation))))
    (convex-client-set-auth! client "second")
    (convex-client-clear-auth! client)
    (check-equal? (async-channel-get notices) '("first" 0))
    (check-equal? (async-channel-get notices) '("second" 1))
    (check-equal? (async-channel-get notices) '(#f 2))
    (convex-client-close! client))

   (test-case
    "function errors preserve logs and absent, false, and null data"
    (define server
      (start-fixture
       (list
        (json-response
         (hasheq 'status "error"
                 'errorMessage "nope"
                 'logLines '("before failure"))
         "560 Convex Error")
        (json-response
         (hasheq 'status "error" 'errorMessage "false data" 'errorData #f))
        (json-response
         (hasheq 'status "error" 'errorMessage "null data" 'errorData 'null)))))
    (define client (make-convex-client (fixture-url server)))
    (dynamic-wind
     void
     (lambda ()
       (define absent
         (captured-error
          exn:fail:convex:function?
          (lambda () (convex-client-query client "counter:fail"))))
       (check-true (exn:fail:convex:function? absent))
       (check-equal? (exn:fail:convex:function-operation absent) 'query)
       (check-equal? (exn:fail:convex:function-logs absent) '("before failure"))
       (check-true
        (convex-missing? (exn:fail:convex:function-data absent)))
       (define false-data
         (captured-error
          exn:fail:convex:function?
          (lambda () (convex-client-mutation client "counter:fail"))))
       (check-false (exn:fail:convex:function-data false-data))
       (define null-data
         (captured-error
          exn:fail:convex:function?
          (lambda () (convex-client-action client "counter:fail"))))
       (check-equal? (exn:fail:convex:function-data null-data) 'null))
     (lambda ()
       (convex-client-close! client)
       (stop-fixture! server))))

   (test-case
    "malformed HTTP payloads become protocol errors"
    (define server
      (start-fixture
       (list
        (raw-response #"not json")
        (raw-response #"\377")
        (json-response '(1 2 3))
        (json-response (hasheq 'status "success"))
        (json-response
         (hasheq 'status "success" 'value 1 'logLines '("ok" 2)))
        (json-response
         (hasheq 'status "error" 'errorMessage 42))
        (json-response (hasheq 'status "mystery" 'value 1)))))
    (define client (make-convex-client (fixture-url server)))
    (dynamic-wind
     void
     (lambda ()
       (for ([index (in-range 7)])
         (check-exn
          exn:fail:convex:protocol?
          (lambda ()
            (convex-client-query client (format "bad:~a" index))))))
     (lambda ()
       (convex-client-close! client)
       (stop-fixture! server))))

   (test-case
    "the response byte limit is enforced before JSON parsing"
    (define server
      (start-fixture (list (raw-response (make-bytes 65 65)))))
    (define client
      (make-convex-client (fixture-url server) #:max-response-bytes 64))
    (dynamic-wind
     void
     (lambda ()
       (define error
         (captured-error
          exn:fail:convex:transport?
          (lambda () (convex-client-query client "large:response"))))
       (check-true (exn:fail:convex:transport? error))
       (check-equal? (exn:fail:convex:transport-operation error) 'query)
       (check-regexp-match #rx"exceeds 64 bytes" (exn-message error)))
     (lambda ()
       (convex-client-close! client)
       (stop-fixture! server))))

   (test-case
    "validation rejects unsafe state before networking"
    (for ([url (in-list '("ftp://example.com"
                          "http://"
                          "http://user@example.com"
                          "http://example.com/path?q=1"
                          "http://example.com/path#fragment"
                          "http://example.com/has space"))])
      (check-exn exn:fail:contract?
                 (lambda () (make-convex-client url))))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (make-convex-client "http://example.com" #:client-version "bad\r\nheader")))
    (define client (make-convex-client "http://127.0.0.1:1"))
    (check-exn exn:fail:contract?
               (lambda () (convex-client-query client "")))
    (check-exn exn:fail:contract?
               (lambda () (convex-client-query client "path" '(not an object))))
    (check-exn exn:fail:contract?
               (lambda () (convex-client-call client 'other "path")))
    (check-exn exn:fail:contract?
               (lambda () (convex-client-set-auth! client "bad\nheader")))
    (convex-client-close! client))

   (test-case
    "connection failures retain the operation as TransportError"
    (define listener (tcp-listen 0 1 #t "127.0.0.1"))
    (define-values (_host port _remote-host _remote-port)
      (tcp-addresses listener #t))
    (tcp-close listener)
    (define client
      (make-convex-client
       (format "http://127.0.0.1:~a" port)
       #:request-timeout-seconds 2))
    (define error
      (captured-error
       exn:fail:convex:transport?
       (lambda () (convex-client-action client "unreachable:action"))))
    (check-true (exn:fail:convex:transport? error))
    (check-equal? (exn:fail:convex:transport-operation error) 'action)
    (check-true (exn? (exn:fail:convex:transport-cause error)))
    (convex-client-close! client))

   (test-case
    "close is idempotent, retires hooks once, and interrupts a stalled HTTP peer"
    (define server
      (start-fixture
       (list
        (lambda (_request _output)
          ;; This peer never sends even the first response byte. Client close
          ;; must still interrupt its HTTP worker without waiting for timeout.
          (sync never-evt)))))
    (define client
      (make-convex-client
       (fixture-url server)
       #:request-timeout-seconds 10))
    (define close-count (box 0))
    (convex-client-register-close-hook!
     client
     (lambda () (set-box! close-count (add1 (unbox close-count)))))
    (define result (make-channel))
    (thread
     (lambda ()
       (channel-put
        result
        (with-handlers ([exn? values])
          (convex-client-query client "stalled:query")
          'unexpected-success))))
    (void (next-request server))
    (define started (current-inexact-monotonic-milliseconds))
    (convex-client-close! client)
    (convex-client-close! client)
    (define elapsed
      (- (current-inexact-monotonic-milliseconds) started))
    (check-true (< elapsed 2000))
    (check-equal? (unbox close-count) 1)
    (define query-result (sync/timeout 2 result))
    (check-true (exn:fail:convex:closed? query-result))
    (check-false (convex-client-open? client))
    (check-exn exn:fail:convex:closed?
               (lambda () (convex-client-query client "after:close")))
    (check-exn exn:fail:convex:closed?
               (lambda () (convex-client-set-auth! client "later")))
    (check-exn
     exn:fail:convex:closed?
     (lambda ()
       (convex-client-register-close-hook! client void)))
    (stop-fixture! server))

   (test-case
    "concurrent close callers share the same completion barrier"
    (define client (make-convex-client "http://127.0.0.1:1"))
    (define hook-entered (make-semaphore 0))
    (define release-hook (make-semaphore 0))
    (define first-done (make-semaphore 0))
    (define second-done (make-semaphore 0))
    (convex-client-register-close-hook!
     client
     (lambda ()
       (semaphore-post hook-entered)
       (semaphore-wait release-hook)))
    (thread
     (lambda ()
       (convex-client-close! client)
       (semaphore-post first-done)))
    (check-not-false (sync/timeout 2 hook-entered))
    (thread
     (lambda ()
       (convex-client-close! client)
       (semaphore-post second-done)))
    (check-false (sync/timeout 0.1 second-done))
    (semaphore-post release-hook)
    (check-not-false (sync/timeout 2 first-done))
    (check-not-false (sync/timeout 2 second-done)))))

(module+ test
  (define failures (run-tests http-tests))
  (unless (zero? failures) (exit 1)))
