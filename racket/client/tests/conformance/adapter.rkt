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
(define relay-state-file (getenv "ADAPTER_TEST_RELAY_STATE_FILE"))
(define relay-state-lock (make-semaphore 1))

(struct output-gate (port lock generations active [closed? #:mutable]) #:transparent)
(struct relay-state (subscription thread) #:transparent)

(define json-escape-regexp #rx"[\0-\37\\\"\177]")

(define (escaped-json-character character)
  (define code (char->integer character))
  (case character
    [(#\backspace) "\\b"]
    [(#\newline) "\\n"]
    [(#\return) "\\r"]
    [(#\page) "\\f"]
    [(#\tab) "\\t"]
    [(#\\) "\\\\"]
    [(#\") "\\\""]
    [else
     (format "\\u~a"
             (string-append
              (make-string (- 4 (string-length (number->string code 16))) #\0)
              (number->string code 16)))]))

(define (write-json-string! port value)
  ;; The standard JSON writer first runs regexp-replace* over a whole string.
  ;; That transient full-size copy is unacceptable for a near-2 MiB Live value
  ;; in the 128 MiB final runtime, so stream unchanged spans directly instead.
  (write-byte 34 port)
  (define start 0)
  (for ([position (in-list (regexp-match-positions* json-escape-regexp value))])
    (define index (car position))
    (write-string value port start index)
    (write-string (escaped-json-character (string-ref value index)) port)
    (set! start (cdr position)))
  (write-string value port start)
  (write-byte 34 port))

(define (write-json-stream! port value)
  (cond
    [(or (exact-integer? value)
         (and (inexact-real? value) (rational? value)))
     (write value port)]
    [(eq? value #f) (write-bytes #"false" port)]
    [(eq? value #t) (write-bytes #"true" port)]
    [(eq? value 'null) (write-bytes #"null" port)]
    [(string? value) (write-json-string! port value)]
    [(list? value)
     (write-byte 91 port)
     (for ([item (in-list value)] [index (in-naturals)])
       (when (positive? index) (write-byte 44 port))
       (write-json-stream! port item))
     (write-byte 93 port)]
    [(hash? value)
     (write-byte 123 port)
     (for ([(key item) (in-hash value)] [index (in-naturals)])
       (unless (symbol? key)
         (raise-argument-error 'write-json-stream! "hash with symbol keys" value))
       (when (positive? index) (write-byte 44 port))
       (write-json-string! port (symbol->string key))
       (write-byte 58 port)
       (write-json-stream! port item))
     (write-byte 125 port)]
    [else (raise-argument-error 'write-json-stream! "jsexpr?" value)]))

(define (write-json-line! port value)
  (write-json-stream! port value)
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

(define (signal-relay-dequeued!)
  (when (and relay-state-file (not (string=? relay-state-file "")))
    (call-with-semaphore
     relay-state-lock
     (lambda ()
       (call-with-output-file
        relay-state-file
        (lambda (output) (displayln "dequeued" output))
        #:exists 'append)))))

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
              (signal-relay-dequeued!)
              (when (positive? relay-delay-seconds) (sleep relay-delay-seconds))
              (gate-relay! gate subscription-id generation
                           (subscription-event subscription-id update)))
            #:timeout 60))
         (when relayed? (loop)))))))

(define (protocol-error message)
  (raise
   (exn:fail:convex:protocol message (current-continuation-marks))))

;; Read bytes rather than calling read-line, because read-line must allocate the
;; entire attacker-controlled record before the adapter could enforce its cap.
;; Once a record is too large, discard through LF so the next call starts at a
;; real NDJSON boundary and a well-formed following command can still run.
(define (read-command-line input)
  (define output (open-output-bytes))
  (let loop ([length 0])
    (define byte (read-byte input))
    (cond
      [(eof-object? byte)
       (if (zero? length) byte (get-output-bytes output))]
      [(= byte 10) (get-output-bytes output)]
      [(< length maximum-command-bytes)
       (write-byte byte output)
       (loop (add1 length))]
      [else
       (let drain ()
         (define discarded (read-byte input))
         (unless (or (eof-object? discarded) (= discarded 10)) (drain)))
       (protocol-error "adapter command exceeds 2 MiB")])))

(define (strict-bytes->command bytes)
  (define line
    (with-handlers ([exn:fail?
                     (lambda (_error)
                       (protocol-error "adapter command is not valid UTF-8"))])
      ;; #f requests strict decoding instead of a replacement character.
      (bytes->string/utf-8 bytes #f)))
  (define input (open-input-string line))
  (define value
    (with-handlers ([exn:fail?
                     (lambda (error)
                       (protocol-error
                        (format "decode command: ~a" (exn-message error))))])
      (read-json input)))
  (define remainder (port->string input))
  (unless (for/and ([character (in-string remainder)])
            (memv character '(#\space #\tab #\return #\newline)))
    (protocol-error "adapter command has trailing content"))
  (unless (hash? value)
    (protocol-error "adapter command must be a JSON object"))
  value)

(define (strict-line->command line)
  (define bytes (string->bytes/utf-8 line))
  (when (> (bytes-length bytes) maximum-command-bytes)
    (protocol-error "adapter command exceeds 2 MiB"))
  (strict-bytes->command bytes))

(define (valid-id? value)
  (and (string? value)
       (positive? (string-length value))
       (<= (string-length value) 128)))

(define (command-id-if-valid command)
  (define value (hash-ref command 'id #f))
  (and (valid-id? value) value))

(define (require-exact-fields! command operation fields)
  (unless (and (= (hash-count command) (length fields))
               (for/and ([field (in-list fields)])
                 (hash-has-key? command field)))
    (protocol-error
     (format "~a command must contain exactly: ~a"
             operation
             (string-join (map symbol->string fields) ", ")))))

(define (require-id! command field label)
  (unless (valid-id? (hash-ref command field #f))
    (protocol-error (format "~a must be a nonempty string of at most 128 characters"
                            label))))

(define (require-string! command field label)
  (unless (string? (hash-ref command field #f))
    (protocol-error (format "~a must be a string" label))))

(define (require-args! command)
  (unless (hash? (hash-ref command 'args #f))
    (protocol-error "args must be a JSON object")))

(define (operation-symbol operation)
  ;; Do not intern attacker-controlled operation strings with string->symbol.
  ;; Only the finite protocol vocabulary ever becomes a symbol.
  (cond
    [(string=? operation "hello") 'hello]
    [(string=? operation "query") 'query]
    [(string=? operation "mutation") 'mutation]
    [(string=? operation "action") 'action]
    [(string=? operation "setAuth") 'setAuth]
    [(string=? operation "subscribe") 'subscribe]
    [(string=? operation "unsubscribe") 'unsubscribe]
    [(string=? operation "debugDisconnect") 'debugDisconnect]
    [(string=? operation "close") 'close]
    [else #f]))

;; Validate the complete protocol-v1 shape before dispatch. Keeping this in one
;; place prevents a missing field from silently becoming an empty path, token,
;; or argument object with different behaviour from the shared schema.
(define (validate-command! command)
  (require-id! command 'id "id")
  (define operation (hash-ref command 'op #f))
  (unless (string? operation) (protocol-error "op must be a string"))
  (case (operation-symbol operation)
    [(hello)
     (require-exact-fields! command operation '(protocolVersion id op))
     (unless (and (exact-integer? (hash-ref command 'protocolVersion #f))
                  (= (hash-ref command 'protocolVersion) protocol-version))
       (protocol-error "protocolVersion must be exactly 1"))]
    [(query mutation action)
     (require-exact-fields! command operation '(id op path args))
     (require-string! command 'path "path")
     (when (< (string-length (hash-ref command 'path)) 3)
       (protocol-error "path must contain at least 3 characters"))
     (require-args! command)]
    [(setAuth)
     (require-exact-fields! command operation '(id op token))
     (require-string! command 'token "token")]
    [(subscribe)
     (require-exact-fields! command operation '(id op subscriptionId path args))
     (require-id! command 'subscriptionId "subscriptionId")
     (require-string! command 'path "path")
     (require-args! command)]
    [(unsubscribe)
     (require-exact-fields! command operation '(id op subscriptionId))
     (require-id! command 'subscriptionId "subscriptionId")]
    [(debugDisconnect close)
     (require-exact-fields! command operation '(id op))]
    [else (protocol-error "unknown adapter operation")])
  command)

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
        (define command-id #f)
        (with-handlers
            ([exn:fail?
              (lambda (error)
                (gate-send! gate (error-event error #:id command-id))
                (loop))])
          ;; The size check and overlong-record drain must be covered by the
          ;; same recovery handler as JSON decoding and schema validation.
          (define line (read-command-line input))
          (unless (eof-object? line)
            (define command (strict-bytes->command line))
            ;; A syntactically valid ID is safe to echo on a validation error.
            ;; Invalid IDs must be omitted or the error event itself violates
            ;; the adapter schema.
            (set! command-id (command-id-if-valid command))
            (validate-command! command)
            (define operation (hash-ref command 'op))
            (case (operation-symbol operation)
              [(hello)
               (gate-send!
                gate
                (hasheq 'protocolVersion protocol-version 'id command-id 'type "ready"
                        'language "racket" 'implementation "native-racket-0.1.0"
                        'runtime "racket-8.10-cgc"))]
              [(query mutation action)
               (define path (hash-ref command 'path))
               (define args (hash-ref command 'args))
               (define result
                 (case (operation-symbol operation)
                   [(query) (convex-client-query (ensure-client!) path args)]
                   [(mutation) (convex-client-mutation (ensure-client!) path args)]
                   [(action) (convex-client-action (ensure-client!) path args)]))
               (gate-send! gate (result-event command-id result))]
              [(setAuth)
               (convex-client-set-auth! (ensure-client!) (hash-ref command 'token))
               (gate-send! gate (event "ack" #:id command-id))]
              [(subscribe)
               (define subscription-id (hash-ref command 'subscriptionId))
               ;; Replacement first retires the old owner state and generation.
               ;; A failed replacement therefore cannot revive the old relay.
               (stop-relay! subscription-id)
               (define subscription
                 (convex-client-subscribe
                  (ensure-client!) (hash-ref command 'path)
                  (hash-ref command 'args)))
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
              [else (error 'adapter "validated operation was not dispatched")])
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

  (define (run-adapter-bytes input-bytes)
    (define output (open-output-bytes))
    (run-adapter (open-input-bytes input-bytes) output)
    (for/list ([line (in-list (string-split
                               (bytes->string/utf-8 (get-output-bytes output))
                               "\n"))]
               #:unless (string=? line ""))
      (string->jsexpr line)))

  (define (check-schema-valid-error value expected-id)
    (check-equal? (hash-ref value 'type) "error")
    (cond
      [expected-id (check-equal? (hash-ref value 'id) expected-id)]
      [else (check-false (hash-has-key? value 'id))])
    (check-false (hash-has-key? value 'subscriptionId))
    (check-false (hash-has-key? value 'value))
    (define detail (hash-ref value 'error))
    (check-true (hash? detail))
    (check-equal? (hash-ref detail 'name) "ProtocolError")
    (check-true (string? (hash-ref detail 'message))))

  (test-case
   "streaming adapter JSON preserves escapes and Unicode"
   (define value
     (hasheq 'text "quote \" slash \\ controls \u0001\u007f lambda λ emoji 😀"
             'items (list #t #f 'null 17 1.5)))
   (define bytes (open-output-bytes))
   (write-json-stream! bytes value)
   (check-equal? (bytes->jsexpr (get-output-bytes bytes)) value))

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
                (lambda () (strict-line->command line)))))

  (test-case
   "every operation has one exact protocol-v1 command shape"
   (for ([command
          (in-list
           (list
            (hasheq 'protocolVersion 1 'id "hello" 'op "hello")
            (hasheq 'id "query" 'op "query" 'path "a:b" 'args (hasheq))
            (hasheq 'id "mutation" 'op "mutation" 'path "a:b" 'args (hasheq))
            (hasheq 'id "action" 'op "action" 'path "a:b" 'args (hasheq))
            (hasheq 'id "auth" 'op "setAuth" 'token "")
            (hasheq 'id "subscribe" 'op "subscribe" 'subscriptionId "sub"
                    'path "a:b" 'args (hasheq))
            (hasheq 'id "unsubscribe" 'op "unsubscribe" 'subscriptionId "sub")
            (hasheq 'id "disconnect" 'op "debugDisconnect")
            (hasheq 'id "close" 'op "close")))])
     (check-eq? (validate-command! command) command))
   (for ([command
          (in-list
           (list
            (hasheq 'protocolVersion 1 'op "hello")
            (hasheq 'protocolVersion 1 'id "" 'op "hello")
            (hasheq 'protocolVersion 1.0 'id "hello" 'op "hello")
            (hasheq 'protocolVersion 1 'id "hello" 'op "hello" 'extra #t)
            (hasheq 'id "query" 'op "query" 'args (hasheq))
            (hasheq 'id "query" 'op "query" 'path 17 'args (hasheq))
            (hasheq 'id "query" 'op "query" 'path "a:b" 'args '())
            (hasheq 'id "auth" 'op "setAuth" 'token 17)
            (hasheq 'id "subscribe" 'op "subscribe" 'subscriptionId ""
                    'path "a:b" 'args (hasheq))
            (hasheq 'id "subscribe" 'op "subscribe" 'subscriptionId "sub"
                    'path "a:b")
            (hasheq 'id "unsubscribe" 'op "unsubscribe" 'subscriptionId 17)
            (hasheq 'id "disconnect" 'op "debugDisconnect" 'extra #t)
            (hasheq 'id "close" 'op "close" 'extra #t)
            (hasheq 'id "unknown" 'op "unknown")))])
     (check-exn exn:fail:convex:protocol?
                (lambda () (validate-command! command)))))

  (test-case
   "malformed commands emit valid errors and never echo invalid IDs"
   (define commands
     (string-append
      "{\"protocolVersion\":1,\"op\":\"hello\"}\n"
      "{\"protocolVersion\":1,\"id\":false,\"op\":\"hello\"}\n"
      "{\"protocolVersion\":1,\"id\":\"extra\",\"op\":\"hello\",\"x\":1}\n"
      "{\"id\":\"missing-path\",\"op\":\"query\",\"args\":{}}\n"
      "{\"id\":\"bad-args\",\"op\":\"mutation\",\"path\":\"a:b\",\"args\":[]}\n"
      "{\"id\":\"bad-sub\",\"op\":\"unsubscribe\",\"subscriptionId\":\"\"}\n"
      "{\"id\":\"bad-token\",\"op\":\"setAuth\",\"token\":7}\n"
      "{\"id\":\"close\",\"op\":\"close\"}\n"))
   (define events (run-adapter-bytes (string->bytes/utf-8 commands)))
   (check-equal? (length events) 8)
   (for ([value (in-list (take events 7))]
         [expected-id (in-list '(#f #f "extra" "missing-path" "bad-args"
                                   "bad-sub" "bad-token"))])
     (check-schema-valid-error value expected-id))
   (check-equal? (last events) (hasheq 'type "closed" 'id "close")))

  (test-case
   "oversized and invalid UTF-8 records recover at the next newline"
   (define suffix
     (string->bytes/utf-8
      (string-append
       "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"
       "{\"id\":\"close\",\"op\":\"close\"}\n")))
   (for ([bad-line
          (in-list
           (list
            (bytes-append (make-bytes (add1 maximum-command-bytes) 120) #"\n")
            #"{\"id\":\"bad-utf8\",\"op\":\377}\n"))])
     (define events (run-adapter-bytes (bytes-append bad-line suffix)))
     (check-equal? (length events) 3)
     (check-schema-valid-error (first events) #f)
     (check-equal? (hash-ref (second events) 'type) "ready")
     (check-equal? (hash-ref (second events) 'id) "hello")
     (check-equal? (last events) (hasheq 'type "closed" 'id "close")))))
