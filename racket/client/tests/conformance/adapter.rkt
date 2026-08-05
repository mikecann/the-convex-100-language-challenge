#lang racket/base

;; Adapter protocol v1 is test infrastructure. It serializes command responses,
;; subscription generations, and NDJSON writes behind one lock so stale output
;; can never cross a replacement, unsubscribe, or close acknowledgement.

(require json
         racket/list
         racket/match
         racket/port
         racket/string
         racket/tcp
         "../../client.rkt")

(define protocol-version 1)
(define maximum-command-bytes (* 2 1024 1024))
(define relay-delay-seconds
  (/ (or (string->number (or (getenv "ADAPTER_TEST_RELAY_DELAY_MS") "0")) 0)
     1000.0))

(struct output-gate (port lock generations active [closed? #:mutable]) #:transparent)
(struct relay-state (subscription thread) #:transparent)

(define (write-json-line! port value)
  (write-json value port)
  (newline port)
  (flush-output port))

(define (make-output-gate port)
  (output-gate port (make-semaphore 1) (make-hash) (make-hash) #f))

(define (gate-send! gate value)
  (call-with-semaphore
   (output-gate-lock gate)
   (lambda ()
     (unless (output-gate-closed? gate)
       ;; Serialize only after owning the writer. At most one encoded near-limit
       ;; event can be in flight, which makes the byte bound include output.
       (write-json-line! (output-gate-port gate) value)))))

(define (next-generation! gate subscription-id)
  (define next (add1 (hash-ref (output-gate-generations gate) subscription-id 0)))
  (hash-set! (output-gate-generations gate) subscription-id next)
  next)

(define (gate-activate-and-ack! gate subscription-id id)
  (call-with-semaphore
   (output-gate-lock gate)
   (lambda ()
     (define generation (next-generation! gate subscription-id))
     (hash-set! (output-gate-active gate) subscription-id generation)
     (unless (output-gate-closed? gate)
       (write-json-line! (output-gate-port gate)
                         (event "ack" #:id id)))
     generation)))

(define (gate-invalidate! gate subscription-id)
  (call-with-semaphore
   (output-gate-lock gate)
   (lambda ()
     (next-generation! gate subscription-id)
     (hash-remove! (output-gate-active gate) subscription-id))))

(define (gate-invalidate-and-ack! gate subscription-id id)
  (call-with-semaphore
   (output-gate-lock gate)
   (lambda ()
     (next-generation! gate subscription-id)
     (hash-remove! (output-gate-active gate) subscription-id)
     (unless (output-gate-closed? gate)
       (write-json-line! (output-gate-port gate) (event "ack" #:id id))))))

(define (gate-relay! gate subscription-id generation value)
  (call-with-semaphore
   (output-gate-lock gate)
   (lambda ()
     (cond
       [(or (output-gate-closed? gate)
            (not (= generation
                    (hash-ref (output-gate-active gate) subscription-id -1))))
        #f]
       [else
        (write-json-line! (output-gate-port gate) value)
        #t]))))

(define (gate-close! gate id)
  (call-with-semaphore
   (output-gate-lock gate)
   (lambda ()
     (unless (output-gate-closed? gate)
       (hash-clear! (output-gate-active gate))
       ;; closed itself belongs to the stream. Mark the gate closed only after
       ;; that final event has been written and flushed.
       (write-json-line! (output-gate-port gate) (event "closed" #:id id))
       (set-output-gate-closed?! gate #t)))))

(define (event type #:id [id #f])
  (if id (hasheq 'type type 'id id) (hasheq 'type type)))

(define (error-name error)
  (cond
    [(exn:fail:convex:function? error) "FunctionError"]
    [(exn:fail:convex:protocol? error) "ProtocolError"]
    [(exn:fail:convex:transport? error) "TransportError"]
    [(exn:fail:convex:closed? error) "ClosedError"]
    [else "Error"]))

(define (error-event error #:id [id #f] #:subscription-id [subscription-id #f])
  (define detail (hasheq 'name (error-name error) 'message (exn-message error)))
  (define with-data
    (if (and (exn:fail:convex:function? error)
             (not (convex-missing? (exn:fail:convex:function-data error))))
        (hash-set detail 'data (exn:fail:convex:function-data error))
        detail))
  (define base
    (if subscription-id
        (hasheq 'type "subscription" 'subscriptionId subscription-id 'error with-data)
        (hasheq 'type "error" 'error with-data)))
  (define identified (if (and id (not subscription-id)) (hash-set base 'id id) base))
  (if (and (exn:fail:convex:function? error)
           (pair? (exn:fail:convex:function-logs error)))
      (hash-set identified 'logs (exn:fail:convex:function-logs error))
      identified))

(define (result-event id result)
  (define base (hasheq 'type "result" 'id id 'value (convex-result-value result)))
  (if (pair? (convex-result-logs result))
      (hash-set base 'logs (convex-result-logs result))
      base))

(define (subscription-event subscription-id update)
  (cond
    [(convex-update-error update)
     (error-event (convex-update-error update) #:subscription-id subscription-id)]
    [else
     (define base
       (hasheq 'type "subscription" 'subscriptionId subscription-id
               'value (convex-update-value update)))
     (if (pair? (convex-update-logs update))
         (hash-set base 'logs (convex-update-logs update))
         base)]))

(define (start-relay! gate subscription-id generation subscription)
  (thread
   (lambda ()
     (let loop ()
       (with-handlers ([exn:fail:convex:closed? void]
                       [exn:fail?
                        (lambda (error)
                          ;; A TCP controller may disappear while an update is
                          ;; in flight. Its broken pipe is terminal for this
                          ;; relay, so do not recurse by trying to report the
                          ;; write failure on the same dead output port.
                          (with-handlers ([exn:fail? void])
                            (gate-relay!
                             gate subscription-id generation
                             (error-event error #:subscription-id subscription-id))))])
         (define relayed?
           (call-with-subscription-update
            subscription
            (lambda (update)
              ;; Tests can pause a relay after dequeue to reproduce the
              ;; late-output race without timing guesses. The client's byte
              ;; reservation remains held through the actual NDJSON write.
              (when (positive? relay-delay-seconds) (sleep relay-delay-seconds))
              (gate-relay! gate subscription-id generation
                           (subscription-event subscription-id update)))
            #:timeout 60))
         (when relayed? (loop)))))))

(define (strict-line->command line)
  (when (> (bytes-length (string->bytes/utf-8 line)) maximum-command-bytes)
    (raise
     (exn:fail:convex:protocol "adapter command exceeds 2 MiB"
                               (current-continuation-marks))))
  (define input (open-input-string line))
  (define value
    (with-handlers ([exn:fail?
                     (lambda (error)
                       (raise
                        (exn:fail:convex:protocol
                         (format "decode command: ~a" (exn-message error))
                         (current-continuation-marks))))])
      (read-json input)))
  (define remainder (port->string input))
  (unless (for/and ([character (in-string remainder)])
            (memv character '(#\space #\tab #\return #\newline)))
    (raise
     (exn:fail:convex:protocol "adapter command has trailing content"
                               (current-continuation-marks))))
  (unless (hash? value)
    (raise
     (exn:fail:convex:protocol "adapter command must be a JSON object"
                               (current-continuation-marks))))
  value)

(define (run-adapter input output)
  (define gate (make-output-gate output))
  (define client #f)
  (define subscriptions (make-hash))

  (define (ensure-client!)
    (unless client
      (define deployment-url
        (or (getenv "CONVEX_URL")
            (raise
             (exn:fail:convex:protocol "CONVEX_URL is required"
                                       (current-continuation-marks)))))
      (set! client
            (make-convex-client deployment-url
                                #:auth-token (or (getenv "CONVEX_AUTH_TOKEN") "")
                                #:client-version "racket-0.1.0")))
    client)

  (define (stop-relay! subscription-id #:invalidate? [invalidate? #t])
    (define state (hash-ref subscriptions subscription-id #f))
    (when state
      (hash-remove! subscriptions subscription-id)
      (subscription-close! (relay-state-subscription state)))
    (when invalidate? (gate-invalidate! gate subscription-id)))

  (dynamic-wind
    void
    (lambda ()
      (let loop ()
        (define line (read-line input 'any))
        (unless (eof-object? line)
          (define command-id #f)
          (with-handlers
              ([exn:fail?
                (lambda (error)
                  (gate-send! gate (error-event error #:id command-id))
                  (loop))])
            (define command (strict-line->command line))
            (set! command-id (hash-ref command 'id #f))
            (define operation (hash-ref command 'op ""))
            (case (string->symbol operation)
              [(hello)
               (unless (= (hash-ref command 'protocolVersion -1) protocol-version)
                 (raise
                  (exn:fail:convex:protocol "unsupported adapter protocol version"
                                            (current-continuation-marks))))
               (gate-send!
                gate
                (hasheq 'protocolVersion protocol-version 'id command-id 'type "ready"
                        'language "racket" 'implementation "native-racket-0.1.0"
                        'runtime "racket-8.10-cgc"))]
              [(query mutation action)
               (define path (hash-ref command 'path ""))
               (define args (hash-ref command 'args (hasheq)))
               (define result
                 (case (string->symbol operation)
                   [(query) (convex-client-query (ensure-client!) path args)]
                   [(mutation) (convex-client-mutation (ensure-client!) path args)]
                   [(action) (convex-client-action (ensure-client!) path args)]))
               (gate-send! gate (result-event command-id result))]
              [(setAuth)
               (convex-client-set-auth! (ensure-client!) (hash-ref command 'token ""))
               (gate-send! gate (event "ack" #:id command-id))]
              [(subscribe)
               (define subscription-id (hash-ref command 'subscriptionId))
               ;; Replacement first retires the old owner state and generation.
               ;; A failed replacement therefore cannot revive the old relay.
               (stop-relay! subscription-id)
               (define subscription
                 (convex-client-subscribe
                  (ensure-client!) (hash-ref command 'path "")
                  (hash-ref command 'args (hasheq))))
               (define generation
                 (gate-activate-and-ack! gate subscription-id command-id))
               (define worker (start-relay! gate subscription-id generation subscription))
               (hash-set! subscriptions subscription-id
                          (relay-state subscription worker))]
              [(unsubscribe)
               (define subscription-id (hash-ref command 'subscriptionId))
               (define state (hash-ref subscriptions subscription-id #f))
               (when state
                 (hash-remove! subscriptions subscription-id)
                 (subscription-close! (relay-state-subscription state)))
               (gate-invalidate-and-ack! gate subscription-id command-id)]
              [(debugDisconnect)
               (convex-client-debug-disconnect! (ensure-client!))
               (gate-send! gate (event "ack" #:id command-id))]
              [(close)
               (for ([subscription-id (in-list (hash-keys subscriptions))])
                 (stop-relay! subscription-id))
               (when client (convex-client-close! client))
               (gate-close! gate command-id)
               (void)]
              [else
               (raise
                (exn:fail:convex:protocol
                 (format "unknown adapter operation ~e" operation)
                 (current-continuation-marks)))])
            (unless (string=? operation "close") (loop))))))
    (lambda ()
      (for ([state (in-hash-values subscriptions)])
        (with-handlers ([exn:fail? void])
          (subscription-close! (relay-state-subscription state))))
      (when client (with-handlers ([exn:fail? void]) (convex-client-close! client))))))

(define listen-address (getenv "ADAPTER_LISTEN"))
(cond
  [(and listen-address (not (string=? listen-address "")))
   (define pieces (string-split listen-address ":"))
   (unless (= (length pieces) 2) (error 'adapter "invalid ADAPTER_LISTEN"))
   (define listener (tcp-listen (string->number (cadr pieces)) 4 #t (car pieces)))
   (define-values (input output) (tcp-accept listener))
   (dynamic-wind
     void
     (lambda () (run-adapter input output))
     (lambda ()
       (close-input-port input)
       (close-output-port output)
       (tcp-close listener)))]
  [else (run-adapter (current-input-port) (current-output-port))])

(module+ test
  (require rackunit)

  (test-case
   "generation and writer form one replacement acknowledgement barrier"
   (define bytes (open-output-bytes))
   (define gate (make-output-gate bytes))
   (define old (gate-activate-and-ack! gate "same" "first"))
   (gate-invalidate-and-ack! gate "same" "unsubscribe")
   (check-false
    (gate-relay! gate "same" old
                 (hasheq 'type "subscription" 'subscriptionId "same" 'value 99)))
   (define replacement (gate-activate-and-ack! gate "same" "replacement"))
   (check-true
    (gate-relay! gate "same" replacement
                 (hasheq 'type "subscription" 'subscriptionId "same" 'value 1)))
   (define events
     (for/list ([line (in-list (string-split
                                (bytes->string/utf-8 (get-output-bytes bytes))
                                "\n"))]
                #:unless (string=? line ""))
       (string->jsexpr line)))
   (check-equal? (map (lambda (value) (hash-ref value 'id #f)) events)
                 '("first" "unsubscribe" "replacement" #f))
   (check-equal? (hash-ref (last events) 'value) 1))

  (test-case
   "optional adapter fields are omitted while JSON false and null survive"
   (define transport
     (exn:fail:convex:transport "offline" (current-continuation-marks)
                                "query" #f))
   (define transport-event (error-event transport #:id "transport"))
   (check-false (hash-has-key? transport-event 'subscriptionId))
   (check-false (hash-has-key? (hash-ref transport-event 'error) 'data))
   (check-false (hash-has-key? transport-event 'logs))
   (for ([data (in-list (list #f 'null))])
     (define failure
       (exn:fail:convex:function "failed" (current-continuation-marks)
                                 "query" data '("kept")))
     (define failure-event
       (error-event failure #:subscription-id "live"))
     (check-equal? (hash-ref (hash-ref failure-event 'error) 'data) data)
     (check-equal? (hash-ref failure-event 'logs) '("kept"))))

  (test-case
   "each NDJSON line contains exactly one strict JSON object"
   (check-equal? (strict-line->command " {\"op\":\"hello\"} \t")
                 (hasheq 'op "hello"))
   (for ([line (in-list '("{} {}" "{} ; comment" "[]"))])
     (check-exn exn:fail:convex:protocol?
                (lambda () (strict-line->command line))))))
