;; The environment sets ADAPTER_LIBRARY_ONLY=1 so including the production
;; source exposes its real loop without starting a second top-level adapter.
(include "conformance/adapter.scm")

(define checks 0)
(define (check truth label)
  (set! checks (+ checks 1))
  (unless truth (error 'adapter-test label)))

(define (read-events text)
  (call-with-input-string
   text
   (lambda (input)
     (let loop ((events '()))
       (let ((line (read-line input)))
         (if (eof-object? line)
             (reverse events)
             (loop (cons (json-decode line) events))))))))

(define (run-memory-adapter input-text)
  (let ((output (open-output-string)))
    (adapter-loop (open-input-string input-text) output #f)
    (read-events (get-output-string output))))

(let* ((bad-utf8 (string (integer->char #xff)))
       (input
         (string-append
          "\n"
          "{\n"
          bad-utf8 "\n"
          "{\"id\":\"early\",\"op\":\"query\",\"path\":\"demo:get\"}\n"
          "{\"id\":\"hello\",\"op\":\"hello\",\"protocolVersion\":1}\n"
          "{\"id\":\"unknown\",\"op\":\"wat\"}\n"
          "{\"id\":\"close\",\"op\":\"close\"}\n"))
       (events (run-memory-adapter input)))
  (check (= (length events) 7) "every NDJSON record produced one event")
  (check (every (lambda (item) (json-object? item)) events)
         "adapter output remained NDJSON objects")
  (check (every (lambda (item) (string? (json-get item "type" #f))) events)
         "every adapter event has a type")
  (check (every (lambda (item) (string=? (json-get item "type") "error"))
                (take events 4))
         "empty, malformed, UTF-8, and pre-hello commands recover")
  (check (string=? (json-get (list-ref events 4) "type") "ready")
         "hello emits ready after malformed input")
  (check (string=? (json-get (list-ref events 5) "id") "unknown")
         "well-formed command errors retain their id")
  (check (string=? (json-get (list-ref events 6) "type") "closed")
         "close emits closed")
  (check (not (json-has? (car events) "id"))
         "malformed input does not invent an id"))

(let* ((too-long (make-string (+ +adapter-line-limit+ 8) #\x))
       (events
         (run-memory-adapter
          (string-append
           too-long "\n"
           "{\"id\":\"hello\",\"op\":\"hello\",\"protocolVersion\":1}\n"
           "{\"id\":\"close\",\"op\":\"close\"}\n"))))
  (check (= (length events) 3) "overlong line drains exactly once")
  (check (string=? (json-get (car events) "type") "error")
         "overlong line emits structured error")
  (check (string=? (json-get (cadr events) "type") "ready")
         "valid command after overlong line is recovered"))

;; Hold the real queue without starting its writer. This makes coalescing fully
;; deterministic and proves that the separate adapter budget includes an
;; output already in flight.
(let* ((sink
         (%make-output-sink (open-output-string)
                            (make-mutex 'adapter-budget-test)
                            (make-condition-variable 'adapter-budget-test)
                            (make-mutex 'adapter-encoder-test)
                            '() 0 0 #f #f #f #f))
       (large (make-string 350000 #\x)))
  (let loop ((index 0))
    (when (< index 40)
      (output-publish!
       sink
       (event "type" "subscription" "subscriptionId" "budget"
              "value" (event "index" index "text" large))
       droppable?: #t)
      (loop (+ index 1))))
  (check (<= (sink-count sink) +output-count-limit+)
         "adapter output retains at most newest 16")
  (check (<= (sink-total-bytes sink) +output-byte-limit+)
         "adapter output respects encoded byte budget")
  (output-sink-in-flight-bytes-set! sink (* 5900 1024))
  (check
   (not (output-publish!
         sink
         (event "type" "subscription" "subscriptionId" "budget"
                "value" (event "text" large))
         droppable?: #t))
   "in-flight output participates in global byte bound")
  (check (= (sink-count sink) 1)
         "backpressure drops queued values before the new value"))

;; Use real kernel TCP sockets, not string ports, for the adapter's alternate
;; transport. The listener exists before the client connects, so this remains
;; deterministic inside the isolated Docker test container.
(let* ((port 19049)
       (listener (tcp-listen port 1 "127.0.0.1"))
       (server
         (thread-start!
          (make-thread
           (lambda ()
             (call-with-values
               (lambda () (tcp-accept listener))
               (lambda (input output)
                 (tcp-close listener)
                 (adapter-loop input output #t)
                 (tcp-abandon-port output))))
           'adapter-test-server))))
  (call-with-values
    (lambda () (tcp-connect "127.0.0.1" port))
    (lambda (input output)
      (display
       "{\"id\":\"tcp-hello\",\"op\":\"hello\",\"protocolVersion\":1}\n"
       output)
      (display "{\"id\":\"tcp-close\",\"op\":\"close\"}\n" output)
      (flush-output output)
      (let ((ready (json-decode (read-line input)))
            (closed (json-decode (read-line input))))
        (check (string=? (json-get ready "id") "tcp-hello")
               "TCP hello response")
        (check (string=? (json-get closed "type") "closed")
               "TCP close response"))
      (tcp-abandon-port output)))
  (check (not (eq? (thread-join! server 2.0 'timed-out) 'timed-out))
         "TCP adapter terminates within bound"))

(print "adapter-test: " checks " checks")
