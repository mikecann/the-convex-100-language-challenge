#lang racket/base

;; One owner thread is the only place where Convex Live protocol state changes.
;; Connector and reader threads may block in I/O, but they only report tagged
;; results back to the owner. The generation tag makes a late result harmless.

(require json
         net/base64
         racket/async-channel
         racket/list
         racket/match
         racket/port
         racket/random
         racket/string
         "errors.rkt"
         "websocket.rkt")

(provide (struct-out convex-update)
         (struct-out live-manager)
         (struct-out convex-subscription)
         make-live-manager
         live-subscribe
         live-debug-disconnect!
         live-manager-close!
         subscription-next-update
         call-with-subscription-update
         subscription-close!
         timestamp->uint64
         newer-timestamp)

(define initial-timestamp "AAAAAAAAAAA=")
(define initial-backoff-ms 100.0)
(define maximum-backoff-ms 15000.0)
(define owner-response-timeout-seconds 3.0)
(define mailbox-capacity 16)
(define global-mailbox-budget-bytes (* 3 1024 1024))
(define protocol-read-headroom-bytes (* 2 1024 1024))
(define queued-update-overhead-bytes 512)
(define closed-marker (gensym 'closed))

(struct convex-update (value error logs) #:transparent)
(struct publication-budget (lock limit [used #:mutable]) #:transparent)
(struct queued-update (value bytes budget) #:transparent)
(struct mailbox (events lock budget [closed? #:mutable]) #:transparent)
(struct live-manager (commands done thread) #:transparent)
(struct convex-subscription (manager query-id mailbox close-lock [closed? #:mutable]) #:transparent)
(struct sub-state (path args mailbox) #:transparent)
(struct connector-result (generation socket error) #:transparent)
(struct pending-connector (generation custodian) #:transparent)
(struct socket-event (generation [value #:mutable] error processed) #:transparent)

(define (protocol-error message)
  (exn:fail:convex:protocol message (current-continuation-marks)))

(define (transport-error message [operation "live"] [cause #f])
  (exn:fail:convex:transport message (current-continuation-marks) operation cause))

(define (closed-error [message "Convex Live manager is closed"])
  (exn:fail:convex:closed message (current-continuation-marks)))

(define (make-mailbox budget)
  (mailbox (make-async-channel mailbox-capacity) (make-semaphore 1) budget #f))

(define (mailbox-try-put channel value)
  (and (sync/timeout 0 (async-channel-put-evt channel value)) #t))

(define json-escape-regexp #rx"[\0-\37\\\"\177]")

(define (json-string-size value)
  ;; `jsexpr->bytes` materializes a second copy of every large result merely to
  ;; count it. Count the exact default JSON encoding instead, so accounting
  ;; itself cannot consume the memory that it is supposed to bound.
  (+ 2
     (string-utf-8-length value)
     (for/sum ([position (in-list
                          (regexp-match-positions* json-escape-regexp value))])
       (define character (string-ref value (car position)))
       ;; Every matched character occupies one UTF-8 byte before escaping.
       (if (or (char=? character #\") (char=? character #\\)
               (memv character '(#\backspace #\newline #\return #\page #\tab)))
           1
           5))))

(define (encoded-jsexpr-size value)
  (cond
    [(exact-integer? value) (string-length (number->string value))]
    [(and (inexact-real? value) (rational? value))
     (string-length (number->string value))]
    [(eq? value #f) 5]
    [(eq? value #t) 4]
    [(eq? value 'null) 4]
    [(string? value) (json-string-size value)]
    [(list? value)
     (+ 2
        (if (null? value) 0 (sub1 (length value)))
        (for/sum ([item (in-list value)]) (encoded-jsexpr-size item)))]
    [(hash? value)
     (+ 2
        (if (zero? (hash-count value)) 0 (sub1 (hash-count value)))
        (for/sum ([(key item) (in-hash value)])
          (+ (json-string-size (symbol->string key)) 1
             (encoded-jsexpr-size item))))]
    [else
     ;; The public APIs validate jsexprs before they reach the owner. Keeping a
     ;; defensive failure here is clearer than silently undercounting one.
     (raise (protocol-error "Live update is not valid JSON"))]))

(define (encoded-update-size update)
  (define error (convex-update-error update))
  (define payload
    (cond
      [error
       (define detail
         (hasheq 'name
                 (cond
                   [(exn:fail:convex:function? error) "FunctionError"]
                   [(exn:fail:convex:protocol? error) "ProtocolError"]
                   [(exn:fail:convex:transport? error) "TransportError"]
                   [else "Error"])
                 'message (exn-message error)))
       (hasheq 'error
               (if (and (exn:fail:convex:function? error)
                        (not (convex-missing?
                              (exn:fail:convex:function-data error))))
                   (hash-set detail 'data (exn:fail:convex:function-data error))
                   detail)
               'logs (convex-update-logs update))]
      [else
       (hasheq 'value (convex-update-value update)
               'logs (convex-update-logs update))]))
  (+ queued-update-overhead-bytes (encoded-jsexpr-size payload)))

(define (release-queued-update! item)
  (define budget (queued-update-budget item))
  (call-with-semaphore
   (publication-budget-lock budget)
   (lambda ()
     (set-publication-budget-used!
      budget
      (max 0 (- (publication-budget-used budget) (queued-update-bytes item)))))))

(define (publication-budget-has-read-headroom? budget)
  (call-with-semaphore
   (publication-budget-lock budget)
   (lambda ()
     (<= (publication-budget-used budget)
         (- (publication-budget-limit budget) protocol-read-headroom-bytes)))))

(define (mailbox-deliver! box update)
  (define budget (mailbox-budget box))
  (define size (encoded-update-size update))
  (call-with-semaphore
   (publication-budget-lock budget)
   (lambda ()
     (call-with-semaphore
      (mailbox-lock box)
      (lambda ()
        (unless (mailbox-closed? box)
          ;; A reactive result is current state. Keep the newest sixteen instead
          ;; of allowing a slow application to stall the protocol owner.
          (define (drop-one!)
            (define dropped (async-channel-try-get (mailbox-events box)))
            (when (queued-update? dropped)
              (set-publication-budget-used!
               budget
               (max 0 (- (publication-budget-used budget)
                         (queued-update-bytes dropped)))))
            dropped)
          (let make-room ()
            (when (> (+ (publication-budget-used budget) size)
                     (publication-budget-limit budget))
              (when (drop-one!) (make-room))))
          (define inserted?
            (and (<= (+ (publication-budget-used budget) size)
                     (publication-budget-limit budget))
                 (let ([item (queued-update update size budget)])
                   (or (mailbox-try-put (mailbox-events box) item)
                       (and (drop-one!)
                            (mailbox-try-put (mailbox-events box) item))))))
          (when inserted?
            (set-publication-budget-used!
             budget (+ (publication-budget-used budget) size)))))))))

(define (mailbox-finish! box)
  (define budget (mailbox-budget box))
  (call-with-semaphore
   (publication-budget-lock budget)
   (lambda ()
     (call-with-semaphore
      (mailbox-lock box)
      (lambda ()
        (unless (mailbox-closed? box)
          (set-mailbox-closed?! box #t)
          (let drain ()
            (define dropped (async-channel-try-get (mailbox-events box)))
            (when dropped
              (when (queued-update? dropped)
                (set-publication-budget-used!
                 budget
                 (max 0 (- (publication-budget-used budget)
                           (queued-update-bytes dropped)))))
              (drain)))
          (async-channel-put (mailbox-events box) closed-marker)))))))

(define (mailbox-next box timeout)
  (define event
    (if timeout
        (sync/timeout timeout (mailbox-events box))
        (sync (mailbox-events box))))
  (cond
    [(not event) (raise (transport-error "timed out waiting for Live update"))]
    [(eq? event closed-marker) (raise (closed-error "Convex Live subscription is closed"))]
    [else event]))

(define (subscription-next-update subscription #:timeout [timeout #f])
  (define item (mailbox-next (convex-subscription-mailbox subscription) timeout))
  (begin0 (queued-update-value item) (release-queued-update! item)))

(define (call-with-subscription-update subscription procedure #:timeout [timeout #f])
  (unless (and (procedure? procedure) (procedure-arity-includes? procedure 1))
    (raise-argument-error 'call-with-subscription-update "procedure accepting one argument"
                          procedure))
  (define item (mailbox-next (convex-subscription-mailbox subscription) timeout))
  (dynamic-wind
    void
    (lambda () (procedure (queued-update-value item)))
    (lambda () (release-queued-update! item))))

(define (subscription-close! subscription)
  (define should-close?
    (call-with-semaphore
     (convex-subscription-close-lock subscription)
     (lambda ()
       (cond
         [(convex-subscription-closed? subscription) #f]
         [else
          (set-convex-subscription-closed?! subscription #t)
          #t]))))
  (when should-close?
    (with-handlers ([exn:fail:convex:closed? void])
      (owner-request (convex-subscription-manager subscription)
                     (list 'remove (convex-subscription-query-id subscription)))))
  (void))

(define (now-ms) (current-inexact-monotonic-milliseconds))

(define (make-live-manager deployment-url client-version)
  (define commands (make-channel))
  (define done (make-semaphore 0))
  (define manager #f)
  (define worker
    (thread
     (lambda ()
       (dynamic-wind
         void
         (lambda () (owner-run deployment-url client-version commands))
         (lambda () (semaphore-post done))))))
  (set! manager (live-manager commands done worker))
  manager)

(define (owner-request manager command)
  (when (sync/timeout 0 (live-manager-done manager))
    (raise (closed-error)))
  (define response (make-channel))
  (unless (sync/timeout owner-response-timeout-seconds
                        (channel-put-evt (live-manager-commands manager)
                                         (append command (list response))))
    (raise (transport-error "Live owner did not accept a command within 3 seconds")))
  (define answer (sync/timeout owner-response-timeout-seconds response))
  (unless answer
    (raise (transport-error "Live owner did not acknowledge a command within 3 seconds")))
  (match answer
    [(list 'ok value) value]
    [(list 'error error) (raise error)]))

(define (live-subscribe manager path args)
  (unless (and (string? path) (not (string=? path "")))
    (raise-argument-error 'live-subscribe "non-empty string?" path))
  (unless (hash? args)
    (raise-argument-error 'live-subscribe "hash?" args))
  ;; Encoding before the command ensures invalid arguments cannot partly change
  ;; the owner's query set.
  (jsexpr->bytes args)
  (define result (owner-request manager (list 'add path args)))
  (match-define (list id box) result)
  (convex-subscription manager id box (make-semaphore 1) #f))

(define (live-debug-disconnect! manager)
  (owner-request manager (list 'debug-disconnect))
  (void))

(define (live-manager-close! manager)
  (unless (sync/timeout 0 (live-manager-done manager))
    (with-handlers ([exn:fail:convex:closed? void])
      (owner-request manager (list 'close))))
  (unless (sync/timeout owner-response-timeout-seconds (live-manager-done manager))
    (raise (transport-error "Live owner did not close within 3 seconds")))
  (void))

(define (zero-version)
  (hasheq 'querySet 0 'identity 0 'ts initial-timestamp))

(define (random-session-id)
  (define raw (crypto-random-bytes 16))
  ;; UUID formatting is useful in protocol traces. Convex only requires a
  ;; unique session string, so setting the conventional version bits is enough.
  (bytes-set! raw 6 (bitwise-ior #x40 (bitwise-and #x0f (bytes-ref raw 6))))
  (bytes-set! raw 8 (bitwise-ior #x80 (bitwise-and #x3f (bytes-ref raw 8))))
  (define hex
    (apply string-append
           (for/list ([byte (in-bytes raw)])
             (define digits (number->string byte 16))
             (if (= (string-length digits) 1) (string-append "0" digits) digits))))
  (string-append (substring hex 0 8) "-" (substring hex 8 12) "-"
                 (substring hex 12 16) "-" (substring hex 16 20) "-"
                 (substring hex 20 32)))

(define (timestamp->uint64 value)
  (unless (string? value)
    (raise (protocol-error "Live timestamp must be a base64 string")))
  (define decoded
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (base64-decode (string->bytes/utf-8 value))))
  (unless (and decoded (= (bytes-length decoded) 8)
               (string=? value
                         (bytes->string/utf-8 (base64-encode decoded #""))))
    (raise (protocol-error "Live timestamp is not canonical base64 little-endian uint64")))
  (for/fold ([number 0]) ([byte (in-bytes decoded)] [shift (in-range 0 64 8)])
    (+ number (arithmetic-shift byte shift))))

(define (newer-timestamp current candidate)
  (cond
    [(not current) (timestamp->uint64 candidate) candidate]
    [(> (timestamp->uint64 candidate) (timestamp->uint64 current)) candidate]
    [else current]))

(define (add-modification id state)
  (hasheq 'type "Add" 'queryId id 'udfPath (sub-state-path state)
          'args (list (sub-state-args state))))

(define (send-json! socket value)
  (with-handlers ([exn:fail:websocket?
                   (lambda (error)
                     (raise (transport-error (exn-message error) "live write" error)))])
    (ws-write-json! socket value)))

(define (start-connector! target client-version generation outgoing)
  (thread
   (lambda ()
     (with-handlers ([exn:fail?
                      (lambda (error)
                        (async-channel-put outgoing
                                           (connector-result generation #f error)))])
       (define socket
         (ws-connect target
                     #:client-version client-version
                     #:write-timeout 0.5
                     #:close-timeout 0.25))
       (async-channel-put outgoing (connector-result generation socket #f))))))

(define (start-reader! socket generation incoming can-read?)
  (thread
   (lambda ()
     (define (wait-for-read-room!)
       (let loop ()
         (cond
           [(not (ws-open? socket)) #f]
           [(can-read?) #t]
           [else (sleep 0.05) (loop)])))
     (define (report! event)
       ;; A synchronous handoff is the transport side of global backpressure.
       ;; Retrying briefly lets close abort the socket and retire a reader that
       ;; was waiting to report after the owner stopped accepting events.
       (let loop ()
         (cond
           [(sync/timeout 0.05 (channel-put-evt incoming event))
            ;; Do not start decoding the next frame until the owner has applied
            ;; this one and its publication reservation is visible.
            (let await-owner ()
              (cond
                [(sync/timeout 0.05 (socket-event-processed event)) #t]
                [(ws-open? socket) (await-owner)]
                [else #f]))]
           [(ws-open? socket) (loop)]
           [else #f])))
     (let loop ()
       (when (wait-for-read-room!)
         (with-handlers
             ([exn:fail?
               (lambda (error)
                 (report! (socket-event generation #f error
                                        (make-semaphore 0))))])
           (define message (ws-read-message socket))
           (if message
               (when (report! (socket-event generation message #f
                                            (make-semaphore 0)))
                 (loop))
               (let ([closed (transport-error "Live peer closed")])
                 (report! (socket-event generation #f closed
                                        (make-semaphore 0)))))))))))

(define (owner-run deployment-url client-version commands)
  (define target (deployment->websocket-url deployment-url))
  ;; A decoded Racket string can occupy substantially more memory than its UTF-8
  ;; wire representation. Use a synchronous handoff so TCP backpressure starts
  ;; before a fast peer can queue decoded frames inside the 128 MiB runtime.
  (define incoming (make-channel))
  (define connectors (make-async-channel 8))
  (define global-budget
    (publication-budget (make-semaphore 1) global-mailbox-budget-bytes 0))
  (define active (make-hasheq))
  ;; Retain the last published result across transport reconnects. Convex
  ;; rehydrates the complete active query set, so suppressing an equal value
  ;; prevents a debug disconnect from looking like an application update.
  (define remote-results (make-hasheq))
  (define next-id 0)
  (define socket #f)
  (define query-set-version 0)
  (define remote-version (zero-version))
  (define max-observed-timestamp #f)
  (define connection-count 0)
  (define last-close-reason "InitialConnect")
  (define retry-ms initial-backoff-ms)
  (define reconnect-due (now-ms))
  (define generation 0)
  (define connecting #f)
  (define closed? #f)

  (define (invalidate-connector!)
    (when connecting
      ;; The connector custodian also owns the dial and TLS handshake resources
      ;; created below it. Closing the last subscription or client therefore
      ;; retires a stalled connector instead of leaving it alive for ten seconds.
      (custodian-shutdown-all (pending-connector-custodian connecting)))
    (set! generation (add1 generation))
    (set! connecting #f))

  (define (schedule-reconnect!)
    (set! reconnect-due (+ (now-ms) retry-ms))
    (set! retry-ms (min maximum-backoff-ms (* retry-ms 2))))

  (define (disconnect! reason reconnect?)
    (when socket
      (ws-abort! socket)
      (set! socket #f)
      (set! connection-count (add1 connection-count)))
    (invalidate-connector!)
    (set! last-close-reason reason)
    (set! query-set-version 0)
    (set! remote-version (zero-version))
    (when (and reconnect? (positive? (hash-count active)))
      (schedule-reconnect!)))

  (define (modify! modifications)
    (send-json! socket
                (hasheq 'type "ModifyQuerySet"
                        'baseVersion query-set-version
                        'newVersion (add1 query-set-version)
                        'modifications modifications))
    (set! query-set-version (add1 query-set-version)))

  (define (install! result)
    (define current-result?
      (and connecting
           (= (connector-result-generation result)
              (pending-connector-generation connecting))
           (positive? (hash-count active))))
    (when current-result?
      (define connector-custodian (pending-connector-custodian connecting))
      (set! connecting #f)
      (cond
        [(connector-result-error result)
         (custodian-shutdown-all connector-custodian)
         (set! connection-count (add1 connection-count))
         (set! last-close-reason (exn-message (connector-result-error result)))
         (schedule-reconnect!)]
        [else
         (define candidate (connector-result-socket result))
         (with-handlers ([exn:fail?
                          (lambda (error)
                            (ws-abort! candidate)
                            (set! connection-count (add1 connection-count))
                            (set! last-close-reason (exn-message error))
                            (schedule-reconnect!))])
           (define connect-message
             (hasheq 'type "Connect"
                     'sessionId (random-session-id)
                     'connectionCount connection-count
                     'lastCloseReason last-close-reason
                     'clientTs 0))
           (when max-observed-timestamp
             (set! connect-message
                   (hash-set connect-message 'maxObservedTimestamp
                             max-observed-timestamp)))
           (send-json! candidate connect-message)
           (define ids (sort (hash-keys active) <))
           (when (pair? ids)
             (send-json! candidate
                         (hasheq 'type "ModifyQuerySet" 'baseVersion 0 'newVersion 1
                                 'modifications
                                 (for/list ([id (in-list ids)])
                                   (add-modification id (hash-ref active id)))))
             (set! query-set-version 1))
           (set! socket candidate)
           (set! remote-version (zero-version))
           ;; A complete RFC 6455 upgrade plus both required client messages is
           ;; a healthy intervening connection, so it must not inherit an old
           ;; maximum reconnect delay.
           (set! retry-ms initial-backoff-ms)
           (start-reader! socket generation incoming
                          (lambda ()
                            (publication-budget-has-read-headroom?
                             global-budget))))]))
    (unless current-result?
      ;; A connector can complete after Remove or Close invalidated its
      ;; generation. Retire that late socket instead of silently leaking it.
      (when (connector-result-socket result)
        (ws-abort! (connector-result-socket result)))))

  (define (publish-protocol-error! error)
    (for ([state (in-hash-values active)])
      (mailbox-deliver! (sub-state-mailbox state)
                        (convex-update #f error '()))))

  (define (require-field value key context)
    (unless (and (hash? value) (hash-has-key? value key))
      (raise (protocol-error (format "~a omitted ~a" context key))))
    (hash-ref value key))

  (define (decode-live-message value)
    (define input (open-input-string value))
    (define message (read-json input))
    (define remainder (port->string input))
    (unless (for/and ([character (in-string remainder)])
              (memv character '(#\space #\tab #\return #\newline)))
      (raise (protocol-error "Live message has trailing content")))
    message)

  (define (validate-version value context)
    (unless (hash? value)
      (raise (protocol-error (format "~a is not an object" context))))
    (for ([key '(querySet identity ts)]) (require-field value key context))
    (unless (and (exact-nonnegative-integer? (hash-ref value 'querySet))
                 (exact-nonnegative-integer? (hash-ref value 'identity)))
      (raise (protocol-error (format "~a counters are invalid" context))))
    (timestamp->uint64 (hash-ref value 'ts))
    value)

  (define (handle-transition! message)
    (define start (validate-version (require-field message 'startVersion "Transition")
                                    "Transition startVersion"))
    (define ending (validate-version (require-field message 'endVersion "Transition")
                                     "Transition endVersion"))
    (unless (equal? start remote-version)
      (raise (protocol-error "Transition start version does not match local version")))
    (define modifications (require-field message 'modifications "Transition"))
    (unless (list? modifications)
      (raise (protocol-error "Transition modifications is not an array")))

    ;; Build the complete coalesced publication set before committing anything.
    ;; If one modification is malformed, no subscriber observes a partial state.
    (define changed (make-hasheq))
    (for ([modification (in-list modifications)])
      (define type (require-field modification 'type "Transition modification"))
      (define id (require-field modification 'queryId "Transition modification"))
      (unless (exact-nonnegative-integer? id)
        (raise (protocol-error "Transition queryId is invalid")))
      (case (string->symbol type)
        [(QueryUpdated)
         (define value (require-field modification 'value "QueryUpdated"))
         (define logs (hash-ref modification 'logLines '()))
         (unless (and (list? logs) (andmap string? logs))
           (raise (protocol-error "QueryUpdated logLines is invalid")))
         (define update (convex-update value #f logs))
         ;; Coalesce against the committed state, but replace any earlier
         ;; pending modification for this query. Returning to the committed
         ;; value means the whole transition is observationally unchanged.
         (if (equal? update (hash-ref remote-results id #f))
             (hash-remove! changed id)
             (hash-set! changed id (cons 'publish update)))]
        [(QueryFailed)
         (define message-text (require-field modification 'errorMessage "QueryFailed"))
         (define data (if (hash-has-key? modification 'errorData)
                          (hash-ref modification 'errorData) missing-error-data))
         (define logs (hash-ref modification 'logLines '()))
         (unless (and (string? message-text) (list? logs) (andmap string? logs))
           (raise (protocol-error "QueryFailed fields are invalid")))
         (define failure
           (exn:fail:convex:function message-text (current-continuation-marks)
                                     "query" data logs))
         ;; A repeated failure is still useful diagnostics, while a later
         ;; QueryUpdated naturally replaces it and proves recovery.
         (hash-set! changed id (cons 'publish (convex-update #f failure logs)))]
        [(QueryRemoved) (hash-set! changed id (cons 'removed #f))]
        [else (raise (protocol-error
                      (format "unknown Transition modification ~e" type)))]))

    (set! remote-version ending)
    (set! max-observed-timestamp
          (newer-timestamp max-observed-timestamp (hash-ref ending 'ts)))
    (for ([id (in-list (sort (hash-keys changed) <))])
      (define pending (hash-ref changed id))
      (cond
        [(eq? (car pending) 'removed) (hash-remove! remote-results id)]
        [else
         (hash-set! remote-results id (cdr pending))
         (when (hash-has-key? active id)
           (mailbox-deliver! (sub-state-mailbox (hash-ref active id)) (cdr pending)))])))

  (define (handle-socket-event! event)
    (when (and socket (= (socket-event-generation event) generation))
      (cond
        [(socket-event-error event)
         (define raw-error (socket-event-error event))
         (define published-error
           (cond
             [(exn:fail:convex? raw-error) raw-error]
             [(and (exn:fail:websocket? raw-error)
                   (eq? (exn:fail:websocket-kind raw-error) 'protocol))
              (protocol-error (exn-message raw-error))]
             [else
              (transport-error (exn-message raw-error) "live read" raw-error)]))
         (publish-protocol-error! published-error)
         (disconnect! (exn-message published-error) #t)]
        [else
         (with-handlers ([exn:fail?
                          (lambda (error)
                            (define wrapped
                              (if (exn:fail:convex? error)
                                  error
                                  (protocol-error
                                   (format "decode server message: ~a" (exn-message error)))))
                            (publish-protocol-error! wrapped)
                            (disconnect! (exn-message wrapped) #t))])
           (define large-message?
             (> (string-length (socket-event-value event)) (* 256 1024)))
           (define message
             (begin0 (decode-live-message (socket-event-value event))
               ;; The parsed result owns its strings. The complete raw frame is
               ;; now redundant, and on conservative GC retaining both through
               ;; publication can cross the 128 MiB runtime boundary.
               (set-socket-event-value! event #f)))
           (when large-message? (collect-garbage))
           (define type (require-field message 'type "Live message"))
           (cond
             [(string=? type "Transition") (handle-transition! message)]
             [(member type '("Ping" "MutationResponse" "ActionResponse")) (void)]
             [(member type '("FatalError" "AuthError"))
              (raise (protocol-error
                      (format "~a: ~a" type (hash-ref message 'error "server error"))))]
             [(string=? type "TransitionChunk")
              (raise (protocol-error "TransitionChunk is unsupported by the pinned profile"))]
             [else (raise (protocol-error (format "unknown server message ~e" type)))])
           ;; Only valid protocol traffic resets the exponential retry.
           (set! retry-ms initial-backoff-ms))])))

  (define (reply! channel value) (channel-put channel value))

  (define (handle-command! command)
    (match command
      [(list 'add path args response)
       (define id next-id)
       (set! next-id (add1 next-id))
       (define box (make-mailbox global-budget))
       (define state (sub-state path args box))
       (hash-set! active id state)
       (with-handlers ([exn:fail?
                        (lambda (error)
                          (when socket (disconnect! (exn-message error) #t)))])
         (if socket
             (modify! (list (add-modification id state)))
             (set! reconnect-due (now-ms))))
       ;; Reply after state installation and the attempted Add write.
       (reply! response (list 'ok (list id box)))]
      [(list 'remove id response)
       (define state (hash-ref active id #f))
       (when state
         (hash-remove! active id)
         (hash-remove! remote-results id)
         (mailbox-finish! (sub-state-mailbox state))
         (with-handlers ([exn:fail?
                          (lambda (error)
                            (when socket (disconnect! (exn-message error) #t)))])
           (when socket
             (modify! (list (hasheq 'type "Remove" 'queryId id))))))
       (when (zero? (hash-count active))
         ;; Do not merely advance the generation while leaving the current
         ;; reader attached to an open socket. A later subscription would then
         ;; reuse a socket whose every event is stale. Retire the transport and
         ;; let a future Add reconnect with a fresh reader generation.
         (disconnect! "NoActiveSubscriptions" #f))
       ;; This shares the owner turn with removal, so no later delivery can
       ;; cross the acknowledgement barrier.
       (reply! response (list 'ok (void)))]
      [(list 'debug-disconnect response)
       (if socket
           (begin
             (disconnect! "adapter debug disconnect" #t)
             (reply! response (list 'ok (void))))
           (reply! response
                   (list 'error (transport-error "Live WebSocket is not connected"))))]
      [(list 'close response)
       (set! closed? #t)
       (invalidate-connector!)
       (when socket
         ;; The transport close is bounded internally. An uncooperative peer
         ;; cannot keep the public close acknowledgement waiting forever.
         (ws-close! socket)
         (set! socket #f))
       (for ([state (in-hash-values active)])
         (mailbox-finish! (sub-state-mailbox state)))
       (hash-clear! active)
       (reply! response (list 'ok (void)))]))

  (let loop ()
    (unless closed?
      (when (and (not socket) (not connecting) (positive? (hash-count active))
                 (>= (now-ms) reconnect-due))
        (set! generation (add1 generation))
        (define connector-custodian (make-custodian))
        (set! connecting (pending-connector generation connector-custodian))
        (parameterize ([current-custodian connector-custodian])
          (start-connector! target client-version generation connectors)))
      (define wait-ms
        (if (and (not socket) (not connecting) (positive? (hash-count active)))
            (max 0.0 (- reconnect-due (now-ms)))
            100.0))
      (define owner-events
        (list (handle-evt commands (lambda (value) (cons 'command value)))
              (handle-evt connectors (lambda (value) (cons 'connector value)))))
      ;; Keep room for one maximum-size WebSocket publication before accepting
      ;; another decoded frame. Commands and connector completion remain live,
      ;; so close and unsubscribe still cut through a stalled output peer.
      (when (publication-budget-has-read-headroom? global-budget)
        (set! owner-events
              (cons (handle-evt incoming
                                 (lambda (value) (cons 'socket value)))
                    owner-events)))
      (define event
        (apply sync/timeout (/ (min wait-ms 100.0) 1000.0) owner-events))
      (when event
        (case (car event)
          [(command) (handle-command! (cdr event))]
          [(connector) (install! (cdr event))]
          [(socket)
           (define socket-value (cdr event))
           (define large-socket-event?
             (and (string? (socket-event-value socket-value))
                  (> (string-length (socket-event-value socket-value))
                     (* 256 1024))))
           (dynamic-wind
             void
             (lambda ()
               (handle-socket-event! socket-value)
               ;; Conservative GC otherwise lets transient decoded JSON from a
               ;; sustained stream approach the container limit before deciding
               ;; to collect. Large frames get an explicit memory boundary.
               (when large-socket-event?
                 (collect-garbage)))
             (lambda () (semaphore-post (socket-event-processed socket-value))))]))
      (loop)))
  (when socket (ws-abort! socket))
  (for ([state (in-hash-values active)])
    (mailbox-finish! (sub-state-mailbox state))))

(define (deployment->websocket-url deployment-url)
  (cond
    [(string-prefix? deployment-url "https://")
     (string-append "wss://"
                    (string-trim (substring deployment-url 8) "/" #:left? #f)
                    "/api/sync")]
    [(string-prefix? deployment-url "http://")
     (string-append "ws://"
                    (string-trim (substring deployment-url 7) "/" #:left? #f)
                    "/api/sync")]
    [else (raise-argument-error 'make-live-manager "absolute http(s) URL" deployment-url)]))
