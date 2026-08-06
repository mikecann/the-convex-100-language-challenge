#lang racket/base

;; These tests deliberately speak RFC 6455 over real loopback TCP sockets. The
;; fixture is small enough to make every Convex query-set transition explicit,
;; while still exercising the same connector, reader, and owner threads used by
;; the public client.

(require file/sha1
         json
         net/base64
         rackunit
         rackunit/text-ui
         racket/async-channel
         racket/list
         racket/match
         racket/port
         racket/string
         racket/tcp
         "../client.rkt")

(define websocket-guid #"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
(define socket-timeout-seconds 3.0)

(struct live-fixture (listener port peers lock) #:transparent)
(struct peer (input output) #:transparent)

(define (close-port port)
  (with-handlers ([exn? void])
    (if (input-port? port)
        (close-input-port port)
        (close-output-port port))))

(define (peer-close! connection)
  (close-port (peer-input connection))
  (close-port (peer-output connection)))

(define (start-live-fixture)
  (define listener (tcp-listen 0 16 #t "127.0.0.1"))
  (define-values (_local-host port _remote-host _remote-port)
    (tcp-addresses listener #t))
  (live-fixture listener port (box '()) (make-semaphore 1)))

(define (fixture-url fixture)
  (format "http://127.0.0.1:~a" (live-fixture-port fixture)))

(define (fixture-record-peer! fixture connection)
  (call-with-semaphore
   (live-fixture-lock fixture)
   (lambda ()
     (set-box! (live-fixture-peers fixture)
               (cons connection (unbox (live-fixture-peers fixture)))))))

(define (stop-live-fixture! fixture)
  (with-handlers ([exn? void])
    (tcp-close (live-fixture-listener fixture)))
  (for ([connection (in-list (unbox (live-fixture-peers fixture)))])
    (peer-close! connection)))

(define (deadline)
  (+ (current-inexact-monotonic-milliseconds)
     (* socket-timeout-seconds 1000.0)))

(define (remaining-seconds stop)
  (max 0.0
       (/ (- stop (current-inexact-monotonic-milliseconds)) 1000.0)))

(define (read-exactly/timeout input length stop [context "socket input"])
  (define result (make-bytes length))
  (let loop ([offset 0])
    (cond
      [(= offset length) result]
      [else
       (unless (sync/timeout (remaining-seconds stop) input)
         (error 'live-fixture "timed out reading ~a" context))
       (define count (read-bytes-avail!* result input offset length))
       (cond
         [(eof-object? count)
          (error 'live-fixture "peer closed while reading ~a" context)]
         [(zero? count) (loop offset)]
         [else (loop (+ offset count))])])))

(define (read-http-upgrade input)
  (define output (open-output-bytes))
  (define stop (deadline))
  (let loop ([tail #""])
    (define next (read-exactly/timeout input 1 stop "WebSocket upgrade"))
    (write-bytes next output)
    (define next-tail
      (if (< (bytes-length tail) 3)
          (bytes-append tail next)
          (bytes-append (subbytes tail (- (bytes-length tail) 3)) next)))
    (unless (bytes=? next-tail #"\r\n\r\n")
      (loop next-tail)))
  (bytes->string/latin-1 (get-output-bytes output)))

(define (request-header request name)
  (for/first ([line (in-list (regexp-split #rx"\r\n" request))]
              #:when (string-prefix?
                      (string-downcase line)
                      (string-append (string-downcase name) ":")))
    (string-trim (substring line (+ (string-length name) 1)))))

(define (websocket-accept key)
  (bytes->string/utf-8
   (base64-encode
    (sha1-bytes
     (open-input-bytes
      (bytes-append (string->bytes/utf-8 key) websocket-guid)))
    #"")
   #f))

(define (accept-tcp/timeout listener)
  (define result (make-channel))
  (define waiter
    (thread
     (lambda ()
       (with-handlers ([exn? (lambda (error) (channel-put result error))])
         (define-values (input output) (tcp-accept listener))
         (channel-put result (list input output))))))
  (define accepted (sync/timeout socket-timeout-seconds result))
  (unless accepted
    (kill-thread waiter)
    (error 'live-fixture "timed out accepting Live connection"))
  (when (exn? accepted) (raise accepted))
  (apply values accepted))

(define (fixture-accept! fixture)
  (define-values (input output)
    (accept-tcp/timeout (live-fixture-listener fixture)))
  (define request (read-http-upgrade input))
  (define key (request-header request "Sec-WebSocket-Key"))
  (unless key
    (close-port input)
    (close-port output)
    (error 'live-fixture "upgrade omitted Sec-WebSocket-Key"))
  (fprintf output "HTTP/1.1 101 Switching Protocols\r\n")
  (fprintf output "Upgrade: websocket\r\n")
  (fprintf output "Connection: Upgrade\r\n")
  (fprintf output "Sec-WebSocket-Accept: ~a\r\n\r\n"
           (websocket-accept key))
  (flush-output output)
  (define connection (peer input output))
  (fixture-record-peer! fixture connection)
  connection)

(define (server-frame opcode payload #:final? [final? #t])
  (define size (bytes-length payload))
  (define length
    (cond
      [(< size 126) (bytes size)]
      [(<= size #xffff)
       (bytes-append #"\176" (integer->integer-bytes size 2 #f #t))]
      [else
       (bytes-append #"\177" (integer->integer-bytes size 8 #f #t))]))
  (bytes-append
   (bytes (bitwise-ior (if final? #x80 0) opcode))
   length
   payload))

(define (peer-send-bytes! connection bytes)
  (write-bytes bytes (peer-output connection))
  (flush-output (peer-output connection)))

(define (peer-send-json! connection value)
  (peer-send-bytes!
   connection
   (server-frame 1 (string->bytes/utf-8 (jsexpr->string value)))))

(define (peer-send-text! connection value)
  (peer-send-bytes!
   connection
   (server-frame 1 (string->bytes/utf-8 value))))

(define (read-client-frame connection)
  (define stop (deadline))
  (define input (peer-input connection))
  (define header (read-exactly/timeout input 2 stop "client frame header"))
  (define first (bytes-ref header 0))
  (define second (bytes-ref header 1))
  (unless (not (zero? (bitwise-and second #x80)))
    (error 'live-fixture "client frame was not masked"))
  (define short-length (bitwise-and second #x7f))
  (define length
    (cond
      [(< short-length 126) short-length]
      [(= short-length 126)
       (integer-bytes->integer
        (read-exactly/timeout input 2 stop "client frame length") #f #t)]
      [else
       (integer-bytes->integer
        (read-exactly/timeout input 8 stop "client frame length") #f #t)]))
  (define mask (read-exactly/timeout input 4 stop "client frame mask"))
  (define payload
    (read-exactly/timeout input length stop "client frame payload"))
  (for ([index (in-range length)])
    (bytes-set! payload index
                (bitwise-xor (bytes-ref payload index)
                             (bytes-ref mask (modulo index 4)))))
  (values (not (zero? (bitwise-and first #x80)))
          (bitwise-and first #x0f)
          payload))

(define (peer-read-json connection)
  (let loop ()
    (define-values (final? opcode payload) (read-client-frame connection))
    (unless final?
      (error 'live-fixture "fixture does not accept fragmented client JSON"))
    (case opcode
      [(1) (string->jsexpr (bytes->string/utf-8 payload #f))]
      ;; Control traffic is not an application protocol message.
      [(9)
       (peer-send-bytes! connection (server-frame 10 payload))
       (loop)]
      [(10) (loop)]
      [(8) 'peer-close]
      [else (error 'live-fixture "unexpected client opcode ~a" opcode)])))

(define (read-json-in-thread connection)
  (define result (make-channel))
  (thread
   (lambda ()
     (with-handlers ([exn? (lambda (error) (channel-put result error))])
       (channel-put result (peer-read-json connection)))))
  result)

(define (await-json result)
  (define answer (sync/timeout socket-timeout-seconds result))
  (unless answer (error 'live-fixture "timed out waiting for client JSON"))
  (when (exn? answer) (raise answer))
  answer)

(define (timestamp value)
  (bytes->string/utf-8
   (base64-encode (integer->integer-bytes value 8 #f #f) #"")
   #f))

(define (version query-set timestamp-value [identity 0])
  (hasheq 'querySet query-set 'identity identity 'ts (timestamp timestamp-value)))

(define (transition start ending modifications)
  (hasheq 'type "Transition"
          'startVersion start
          'endVersion ending
          'modifications modifications))

(define (updated query-id count [logs '()])
  (hasheq 'type "QueryUpdated"
          'queryId query-id
          'value (hasheq 'count count)
          'logLines logs))

(define (failed query-id)
  (hasheq 'type "QueryFailed"
          'queryId query-id
          'errorMessage "room empty"
          'errorData (hasheq 'code "ROOM_EMPTY")
          'logLines '("before failure")))

(define (removed query-id)
  (hasheq 'type "QueryRemoved" 'queryId query-id))

(define (message-modification message)
  (define modifications (hash-ref message 'modifications '()))
  (unless (= (length modifications) 1)
    (error 'live-fixture "expected one query-set modification, got ~v"
           modifications))
  (car modifications))

(define (check-connect-and-add connection expected-count expected-reason
                               expected-timestamp)
  (define connect (peer-read-json connection))
  (define add-envelope (peer-read-json connection))
  (check-equal? (hash-ref connect 'type #f) "Connect")
  (check-equal? (hash-ref connect 'connectionCount #f) expected-count)
  (check-equal? (hash-ref connect 'lastCloseReason #f) expected-reason)
  (if expected-timestamp
      (check-equal? (hash-ref connect 'maxObservedTimestamp #f)
                    expected-timestamp)
      (check-false (hash-ref connect 'maxObservedTimestamp #f)))
  (check-equal? (hash-ref add-envelope 'type #f) "ModifyQuerySet")
  (check-equal? (hash-ref add-envelope 'baseVersion #f) 0)
  (check-equal? (hash-ref add-envelope 'newVersion #f) 1)
  (define add (message-modification add-envelope))
  (check-equal? (hash-ref add 'type #f) "Add")
  (values connect add))

(define (capture-error predicate thunk)
  (with-handlers ([predicate values])
    (thunk)
    #f))

(define (check-no-update subscription [seconds 0.08])
  (define caught
    (capture-error
     exn:fail:convex:transport?
     (lambda ()
       (subscription-next-update subscription #:timeout seconds))))
  (check-true (exn:fail:convex:transport? caught)
              "unexpected Live update was published"))

(define (with-client-fixture procedure)
  (define fixture (start-live-fixture))
  (define client
    (make-convex-client (fixture-url fixture)
                        #:client-version "racket-live-test"))
  (dynamic-wind
   void
   (lambda () (procedure fixture client))
   (lambda ()
     (with-handlers ([exn? void]) (convex-client-close! client))
     (stop-live-fixture! fixture))))

(define (invalid-live-transition field value query-id)
  (case field
    [(querySet)
     (transition (version 0 0)
                 (version value 1)
                 (list (updated query-id 99)))]
    [(identity)
     (transition (version 0 0)
                 (version 1 1 value)
                 (list (updated query-id 99)))]
    [(queryId)
     ;; Put a valid update before the malformed ID. The whole transition must
     ;; still roll back without publishing the first update.
     (transition (version 0 0)
                 (version 1 1)
                 (list (updated query-id 99)
                       (updated value 100)))]))

(define (check-invalid-live-id field value)
  (with-client-fixture
   (lambda (fixture client)
     (define subscription
       (convex-client-subscribe client "demo:state" (hasheq 'room "uint32")))
     (define first (fixture-accept! fixture))
     (define-values (_connect add)
       (check-connect-and-add first 0 "InitialConnect" #f))
     (define query-id (hash-ref add 'queryId))
     (peer-send-json! first (invalid-live-transition field value query-id))
     (define protocol-update
       (subscription-next-update subscription #:timeout socket-timeout-seconds))
     (define protocol-failure (convex-update-error protocol-update))
     (check-true (exn:fail:convex:protocol? protocol-failure))
     (check-true (string-contains? (exn-message protocol-failure) "uint32"))
     ;; No update from before the malformed ID may escape the failed transition.
     (check-no-update subscription)
     (peer-close! first)

     (define second (fixture-accept! fixture))
     (define-values (_reconnect resent-add)
       (check-connect-and-add second 1 (exn-message protocol-failure) #f))
     (check-equal? (hash-ref resent-add 'queryId #f) query-id)
     (peer-send-json!
      second
      (transition (version 0 0) (version 1 1)
                  (list (updated query-id 7))))
     (check-equal?
      (convex-update-value
       (subscription-next-update subscription #:timeout socket-timeout-seconds))
      (hasheq 'count 7))
     (subscription-close! subscription))))

(define live-tests
  (test-suite
   "native Racket Convex Live owner"

   (test-case
    "timestamps are canonical little-endian uint64 values across 255 to 256"
    (define at-255 (timestamp 255))
    (define at-256 (timestamp 256))
    (check-equal? at-255 "/wAAAAAAAAA=")
    (check-equal? at-256 "AAEAAAAAAAA=")
    (check-equal? (timestamp->uint64 at-255) 255)
    (check-equal? (timestamp->uint64 at-256) 256)
    (check-equal? (newer-timestamp at-255 at-256) at-256)
    (check-equal? (newer-timestamp at-256 at-255) at-256)
    (check-exn exn:fail:convex:protocol?
               (lambda () (timestamp->uint64 (string-append at-256 "\n")))))

   (test-case
    "query-set, identity, and query IDs are bounded uint32 values"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "uint32-max")))
       (define connection (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add connection 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))
       (define maximum (version #xffffffff 1 #xffffffff))
       (peer-send-json!
        connection
        (transition (version 0 0)
                    maximum
                    (list (updated query-id 0)
                          (updated #xffffffff 100))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 0))
       (peer-send-json!
        connection
        (transition maximum
                    (version #xffffffff 2 #xffffffff)
                    (list (updated query-id 1))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 1))
       (subscription-close! subscription))))

   (test-case
    "invalid uint32 IDs reject and atomically roll back before reconnect"
    (for* ([field (in-list '(querySet identity queryId))]
           [value (in-list (list #x100000000 -1 1.5 "1"))])
      (check-invalid-live-id field value)))

   (test-case
    "Add and Remove are acknowledged barriers and updates recover after QueryFailed"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "fixture")))
       (define connection (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add connection 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))
       (check-equal? (hash-ref add 'udfPath #f) "demo:state")
       (check-equal? (hash-ref add 'args #f)
                     (list (hasheq 'room "fixture")))

       (define v0 (version 0 0))
       (define v1 (version 1 1))
       (peer-send-json! connection
                        (transition v0 v1 (list (updated query-id 0 '("initial")))))
       (define initial
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
       (check-equal? (convex-update-value initial) (hasheq 'count 0))
       (check-equal? (convex-update-logs initial) '("initial"))

       (define v2 (version 1 2))
       (peer-send-json! connection
                        (transition v1 v2 (list (updated query-id 1))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 1))

       (define v3 (version 1 3))
       (peer-send-json! connection
                        (transition v2 v3 (list (failed query-id))))
       (define failed-update
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
       (check-true (exn:fail:convex:function? (convex-update-error failed-update)))
       (check-equal?
        (exn:fail:convex:function-data (convex-update-error failed-update))
        (hasheq 'code "ROOM_EMPTY"))
       (check-equal? (convex-update-logs failed-update) '("before failure"))

       (define v4 (version 1 4))
       (peer-send-json! connection
                        (transition v3 v4 (list (updated query-id 2))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 2))

       ;; Do not consume while the owner publishes these. Once it has had a
       ;; bounded local scheduling window, only counts 7 through 22 remain.
       (define previous v4)
       (for ([count (in-range 3 23)]
             [timestamp-value (in-range 5 25)])
         (define next (version 1 timestamp-value))
         (peer-send-json! connection
                          (transition previous next
                                      (list (updated query-id count))))
         (set! previous next))
       (sleep 0.2)
       (define retained
         (for/list ([_ (in-range 16)])
           (hash-ref
            (convex-update-value
             (subscription-next-update subscription
                                       #:timeout socket-timeout-seconds))
            'count)))
       (check-equal? retained (range 7 23))
       (check-no-update subscription)

       ;; With a healthy socket, the public subscribe call returns only after
       ;; its Add has been attempted by the sole protocol owner.
       (define add-result (read-json-in-thread connection))
       (define second
         (convex-client-subscribe client "demo:other" (hasheq 'room "second")))
       (define second-envelope (await-json add-result))
       (check-equal? (hash-ref second-envelope 'type #f) "ModifyQuerySet")
       (define second-add (message-modification second-envelope))
       (check-equal? (hash-ref second-add 'type #f) "Add")
       (check-equal? (hash-ref second-add 'udfPath #f) "demo:other")

       ;; Remove has the same acknowledgement barrier. Once close returns the
       ;; mailbox is terminal, and no later server result can cross it.
       (define remove-result (read-json-in-thread connection))
       (define remove-start (current-inexact-monotonic-milliseconds))
       (subscription-close! second)
       (check-true (< (- (current-inexact-monotonic-milliseconds) remove-start)
                      500.0))
       (define remove-envelope (await-json remove-result))
       (define remove (message-modification remove-envelope))
       (check-equal? (hash-ref remove 'type #f) "Remove")
       (check-equal? (hash-ref remove 'queryId #f)
                     (hash-ref second-add 'queryId))
       (peer-send-json!
        connection
        (transition previous (version 2 25)
                    (list (updated (hash-ref second-add 'queryId) 99))))
       (check-exn exn:fail:convex:closed?
                  (lambda ()
                    (subscription-next-update second #:timeout 0.05)))
       (subscription-close! subscription))))

   (test-case
    "five real reconnects retain metadata, resend Add, and suppress rehydration"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "five")))
       (define connection (fixture-accept! fixture))
       (define-values (_initial-connect initial-add)
         (check-connect-and-add connection 0 "InitialConnect" #f))
       (define query-id (hash-ref initial-add 'queryId))
       (define v0 (version 0 0))
       (define initial-version (version 1 255))
       (peer-send-json!
        connection
        (transition v0 initial-version (list (updated query-id 0))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 0))

       (define last-timestamp 255)
       (for ([attempt (in-range 1 6)])
         (convex-client-debug-disconnect! client)
         (peer-close! connection)
         (set! connection (fixture-accept! fixture))
         (define-values (_connect add)
           (check-connect-and-add
            connection attempt "adapter debug disconnect"
            (timestamp last-timestamp)))
         (check-equal? (hash-ref add 'queryId #f) query-id)
         (check-equal? (hash-ref add 'udfPath #f) "demo:state")
         (check-equal? (hash-ref add 'args #f)
                       (list (hasheq 'room "five")))

         ;; The first transition on a new socket rehydrates the active query
         ;; with its last value. It advances protocol state but is not an app
         ;; update. The next changed value must still arrive normally.
         (define hydrated (version 1 last-timestamp))
         (peer-send-json!
          connection
          (transition v0 hydrated (list (updated query-id (sub1 attempt)))))
         (check-no-update subscription)
         (define next-timestamp (+ 255 attempt))
         (define changed (version 1 next-timestamp))
         (peer-send-json!
          connection
          (transition hydrated changed (list (updated query-id attempt))))
         (check-equal?
          (convex-update-value
           (subscription-next-update subscription #:timeout socket-timeout-seconds))
          (hasheq 'count attempt))
         (set! last-timestamp next-timestamp))

       (check-equal? last-timestamp 260)
       (define remove-result (read-json-in-thread connection))
       (subscription-close! subscription)
       (check-equal?
        (hash-ref (message-modification (await-json remove-result)) 'type #f)
        "Remove"))))

   (test-case
    "socket EOF publishes TransportError, reconnects, and recovers"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "eof")))
       (define first (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add first 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))
       (peer-send-json!
        first
        (transition (version 0 0) (version 1 1)
                    (list (updated query-id 1))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 1))

       ;; Closing the real TCP peer is a transport event, not a protocol or
       ;; function failure. It must be observable without terminating the
       ;; subscription that the owner will rehydrate on the next connection.
       (peer-close! first)
       (define transport-update
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
       (define transport-failure (convex-update-error transport-update))
       (check-true (exn:fail:convex:transport? transport-failure))
       (check-equal? (exn:fail:convex:transport-operation transport-failure)
                     "live read")

       (define second (fixture-accept! fixture))
       (define-values (_reconnect resent-add)
         (check-connect-and-add second 1 (exn-message transport-failure)
                                (timestamp 1)))
       (check-equal? (hash-ref resent-add 'queryId #f) query-id)
       (peer-send-json!
        second
        (transition (version 0 0) (version 1 2)
                    (list (updated query-id 2))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 2))
       (subscription-close! subscription))))

   (test-case
    "a malformed RFC6455 frame publishes ProtocolError and recovers"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "frame")))
       (define first (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add first 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))
       (peer-send-json!
        first
        (transition (version 0 0) (version 1 2)
                    (list (updated query-id 2))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 2))

       ;; RFC 6455 forbids masked server frames. The parser can reject this
       ;; complete two-byte frame immediately, without a timing-sensitive
       ;; partial read or fixture-side EOF.
       (peer-send-bytes! first #"\201\200")
       (define protocol-update
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
       (define protocol-failure (convex-update-error protocol-update))
       (check-true (exn:fail:convex:protocol? protocol-failure))
       (check-true (string-contains? (exn-message protocol-failure)
                                     "server WebSocket frames must not be masked"))
       (peer-close! first)

       (define second (fixture-accept! fixture))
       (define-values (_reconnect resent-add)
         (check-connect-and-add second 1 (exn-message protocol-failure)
                                (timestamp 2)))
       (check-equal? (hash-ref resent-add 'queryId #f) query-id)
       (peer-send-json!
        second
        (transition (version 0 0) (version 1 3)
                    (list (updated query-id 3))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 3))
       (subscription-close! subscription))))

   (test-case
    "one Transition publishes only its final coalesced state per query"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "coalesced")))
       (define connection (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add connection 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))
       (define v0 (version 0 0))
       (define v1 (version 1 1))
       (peer-send-json! connection
                        (transition v0 v1 (list (updated query-id 0))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 0))

       ;; A transient new value followed by the committed value has no net
       ;; observable effect and therefore publishes nothing.
       (define v2 (version 1 2))
       (peer-send-json!
        connection
        (transition v1 v2
                    (list (updated query-id 1)
                          (updated query-id 0))))
       (check-no-update subscription)

       ;; QueryFailed is not leaked when a later modification in the same
       ;; atomic transition supplies the final healthy result.
       (define v3 (version 1 3))
       (peer-send-json!
        connection
        (transition v2 v3
                    (list (failed query-id)
                          (updated query-id 2))))
       (define after-failure
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
       (check-false (convex-update-error after-failure))
       (check-equal? (convex-update-value after-failure) (hasheq 'count 2))
       (check-no-update subscription)

       ;; QueryRemoved is likewise only intermediate when QueryUpdated is the
       ;; final modification for that query ID.
       (define v4 (version 1 4))
       (peer-send-json!
        connection
        (transition v3 v4
                    (list (removed query-id)
                          (updated query-id 3))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 3))
       (check-no-update subscription)

       ;; Multiple healthy values also collapse to exactly the final state.
       (define v5 (version 1 5))
       (peer-send-json!
        connection
        (transition v4 v5
                    (list (updated query-id 4)
                          (updated query-id 5))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 5))
       (check-no-update subscription)
       (subscription-close! subscription))))

   (test-case
    "trailing or second JSON values are ProtocolError and reconnect cleanly"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "json")))
       (define connection (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add connection 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))

       (for ([payload (in-list '("{\"type\":\"Ping\"} garbage"
                                 "{\"type\":\"Ping\"}{\"type\":\"Ping\"}"
                                 "{\"type\":\"Ping\"}\f"))]
             [connection-count (in-range 1 4)])
         (peer-send-text! connection payload)
         (define protocol-update
           (subscription-next-update subscription #:timeout socket-timeout-seconds))
         (define protocol-failure (convex-update-error protocol-update))
         (check-true (exn:fail:convex:protocol? protocol-failure))
         (check-true (string-contains? (exn-message protocol-failure)
                                       "trailing content"))
         (peer-close! connection)
         (set! connection (fixture-accept! fixture))
         (define-values (_reconnect resent-add)
           (check-connect-and-add connection connection-count
                                  (exn-message protocol-failure) #f))
         (check-equal? (hash-ref resent-add 'queryId #f) query-id))

       ;; Both malformed generations are retired. A valid Transition on the
       ;; third real socket still reaches the original subscription.
       (peer-send-json!
        connection
        (transition (version 0 0) (version 1 1)
                    (list (updated query-id 1))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 1))
       (subscription-close! subscription))))

   (test-case
    "malformed Live JSON reports ProtocolError, reconnects, and recovers"
    (with-client-fixture
     (lambda (fixture client)
       (define subscription
         (convex-client-subscribe client "demo:state" (hasheq 'room "recovery")))
       (define first (fixture-accept! fixture))
       (define-values (_connect add)
         (check-connect-and-add first 0 "InitialConnect" #f))
       (define query-id (hash-ref add 'queryId))
       (peer-send-json!
        first
        (transition (version 0 0) (version 1 4)
                    (list (updated query-id 4))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 4))

       (peer-send-bytes! first (server-frame 1 #"not-json"))
       (define protocol-update
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
       (check-true
        (exn:fail:convex:protocol? (convex-update-error protocol-update)))
       (check-true
        (string-contains? (exn-message (convex-update-error protocol-update))
                          "decode server message"))
       (peer-close! first)

       (define second (fixture-accept! fixture))
       (define-values (connect resent-add)
         (check-connect-and-add second 1
                                (exn-message (convex-update-error protocol-update))
                                (timestamp 4)))
       (check-equal? (hash-ref connect 'connectionCount #f) 1)
       (check-equal? (hash-ref resent-add 'queryId #f) query-id)
       (peer-send-json!
        second
        (transition (version 0 0) (version 1 5)
                    (list (updated query-id 5))))
       (check-equal?
        (convex-update-value
         (subscription-next-update subscription #:timeout socket-timeout-seconds))
        (hasheq 'count 5))
       (subscription-close! subscription))))

   (test-case
    "public close is bounded while the peer stalls inside a frame"
    (define fixture (start-live-fixture))
    (define client
      (make-convex-client (fixture-url fixture)
                          #:client-version "racket-live-test"))
    (dynamic-wind
     void
     (lambda ()
       (convex-client-subscribe client "demo:state" (hasheq 'room "stalled"))
       (define connection (fixture-accept! fixture))
       (define-values (_connect _add)
         (check-connect-and-add connection 0 "InitialConnect" #f))
       ;; Announce a 126-byte text frame, then leave the second length byte and
       ;; the entire payload missing. The Live reader is now in a partial read.
       (peer-send-bytes! connection #"\201\176\0")
       (sleep 0.03)
       (define started (current-inexact-monotonic-milliseconds))
       (convex-client-close! client)
       (check-true (< (- (current-inexact-monotonic-milliseconds) started)
                      1000.0)))
     (lambda ()
       (with-handlers ([exn? void]) (convex-client-close! client))
       (stop-live-fixture! fixture))))))

(module+ test
  (define failures (run-tests live-tests))
  (unless (zero? failures)
    (error 'live-test "~a Live test(s) failed" failures)))

(module+ main
  (define failures (run-tests live-tests))
  (exit (if (zero? failures) 0 1)))
