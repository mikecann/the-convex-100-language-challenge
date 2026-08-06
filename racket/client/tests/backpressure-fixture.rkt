#lang racket/base

;; Manual final-image stress fixture. `server` speaks enough Convex Live to
;; publish near-limit values; `controller` subscribes through the real TCP
;; adapter, reads its acknowledgement, then deliberately stops reading output.

(require file/sha1
         json
         net/base64
         racket/file
         racket/port
         racket/string
         racket/tcp)

(define websocket-guid #"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(define (read-exactly input length)
  (define value (read-bytes length input))
  (unless (and (bytes? value) (= (bytes-length value) length))
    (error 'fixture "unexpected EOF"))
  value)

(define (read-headers input)
  (define output (open-output-bytes))
  (let loop ([tail #""])
    (define byte (read-exactly input 1))
    (write-bytes byte output)
    (define next-tail
      (if (< (bytes-length tail) 3)
          (bytes-append tail byte)
          (bytes-append (subbytes tail (- (bytes-length tail) 3)) byte)))
    (unless (bytes=? next-tail #"\r\n\r\n") (loop next-tail)))
  (bytes->string/latin-1 (get-output-bytes output)))

(define (header request name)
  (for/first ([line (in-list (string-split request "\r\n"))]
              #:when (string-prefix? (string-downcase line)
                                     (string-append (string-downcase name) ":")))
    (string-trim (substring line (add1 (string-length name))))))

(define (read-client-json input)
  (define frame (read-exactly input 2))
  (define second (bytes-ref frame 1))
  (unless (positive? (bitwise-and second #x80))
    (error 'fixture "client frame was not masked"))
  (define short (bitwise-and second #x7f))
  (define length
    (cond
      [(< short 126) short]
      [(= short 126) (integer-bytes->integer (read-exactly input 2) #f #t)]
      [else (integer-bytes->integer (read-exactly input 8) #f #t)]))
  (define mask (read-exactly input 4))
  (define payload (read-exactly input length))
  (for ([index (in-range length)])
    (bytes-set! payload index
                (bitwise-xor (bytes-ref payload index)
                             (bytes-ref mask (modulo index 4)))))
  (bytes->jsexpr payload))

(define (server-frame payload)
  (define length (bytes-length payload))
  (bytes-append
   #"\201"
   (cond
     [(< length 126) (bytes length)]
     [(<= length #xffff)
      (bytes-append #"\176" (integer->integer-bytes length 2 #f #t))]
     [else
      (bytes-append #"\177" (integer->integer-bytes length 8 #f #t))])
   payload))

(define (timestamp number)
  (bytes->string/utf-8
   (base64-encode (integer->integer-bytes number 8 #f #f) #"") #f))

(define (version query-set time)
  (hasheq 'querySet query-set 'identity 0 'ts (timestamp time)))

(define (accept-websocket-on listener)
  (define-values (input output) (tcp-accept listener))
  (define request (read-headers input))
  (define key (header request "Sec-WebSocket-Key"))
  (define accept
    (bytes->string/utf-8
     (base64-encode
      (sha1-bytes
       (open-input-bytes
        (bytes-append (string->bytes/utf-8 key) websocket-guid)))
      #"") #f))
  (fprintf output
           "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ~a\r\n\r\n"
           accept)
  (flush-output output)
  (values input output))

(define (accept-websocket)
  (define listener (tcp-listen 9101 4 #t "0.0.0.0"))
  (displayln "READY")
  (flush-output)
  (define-values (input output) (accept-websocket-on listener))
  (values input output listener))

(define (send-server-json! output value)
  (write-bytes (server-frame (jsexpr->bytes value)) output)
  (flush-output output))

(define (run-server)
  (define-values (input output listener) (accept-websocket))
  (read-client-json input) ; Connect
  (define add-envelope (read-client-json input))
  (define query-id
    (hash-ref (car (hash-ref add-envelope 'modifications)) 'queryId))
  ;; 1.7 MiB is over 80 percent of the transport's 2 MiB frame ceiling. It is
  ;; large enough to exercise the encoded-byte gate without making the check
  ;; depend on sub-megabyte allocator jitter at the 128 MiB process boundary.
  (define large-value (make-string (* 1700 1024) #\x))
  (define previous (version 0 0))
  (for ([count (in-range 24)])
    (define next (version 1 (add1 count)))
    (define message
      (hasheq
       'type "Transition"
       'startVersion previous
       'endVersion next
       'modifications
       (list (hasheq 'type "QueryUpdated" 'queryId query-id
                     'value (hasheq 'count count 'payload large-value)
                     'logLines '()))))
    (send-server-json! output message)
    (set! previous next))
  (sleep 15)
  (close-input-port input)
  (close-output-port output)
  (tcp-close listener))

(define (transition start ending modifications)
  (hasheq 'type "Transition" 'startVersion start 'endVersion ending
          'modifications modifications))

(define (updated query-id value)
  (hasheq 'type "QueryUpdated" 'queryId query-id 'value value 'logLines '()))

(define (expect-modification input expected-type)
  (define envelope (read-client-json input))
  (unless (equal? (hash-ref envelope 'type #f) "ModifyQuerySet")
    (error 'barrier-server "expected ModifyQuerySet, received ~e" envelope))
  (define modifications (hash-ref envelope 'modifications '()))
  (unless (= (length modifications) 1)
    (error 'barrier-server "expected one modification, received ~e" modifications))
  (define modification (car modifications))
  (unless (equal? (hash-ref modification 'type #f) expected-type)
    (error 'barrier-server "expected ~a, received ~e" expected-type modification))
  (hash-ref modification 'queryId))

(define (run-barrier-server)
  (define listener (tcp-listen 9101 4 #t "0.0.0.0"))
  (displayln "READY")
  (flush-output)

  (define-values (first-input first-output) (accept-websocket-on listener))
  (read-client-json first-input) ; Connect
  (define first-add (read-client-json first-input))
  (define first-id
    (hash-ref (car (hash-ref first-add 'modifications)) 'queryId))
  (define v0 (version 0 0))
  (define v1 (version 1 1))
  (send-server-json!
   first-output
   (transition v0 v1 (list (updated first-id (hasheq 'stage "stale-unsubscribe")))))

  (unless (= (expect-modification first-input "Remove") first-id)
    (error 'barrier-server "unsubscribe removed the wrong query"))
  (close-input-port first-input)
  (close-output-port first-output)

  ;; Removing the last Live query retires the old reader. The replacement must
  ;; therefore arrive on a fresh socket with a fresh generation.
  (define-values (second-input second-output) (accept-websocket-on listener))
  (read-client-json second-input) ; Connect
  (define second-add (read-client-json second-input))
  (define second-id
    (hash-ref (car (hash-ref second-add 'modifications)) 'queryId))
  (define second-v1 (version 1 2))
  (send-server-json!
   second-output
   (transition v0 second-v1
               (list (updated second-id (hasheq 'stage "replacement-one")))))
  (define second-v2 (version 1 3))
  (send-server-json!
   second-output
   (transition second-v1 second-v2
               (list (updated second-id (hasheq 'stage "stale-replacement")))))

  (unless (= (expect-modification second-input "Remove") second-id)
    (error 'barrier-server "replacement removed the wrong query"))
  (close-input-port second-input)
  (close-output-port second-output)

  (define-values (third-input third-output) (accept-websocket-on listener))
  (read-client-json third-input) ; Connect
  (define third-add (read-client-json third-input))
  (define third-id
    (hash-ref (car (hash-ref third-add 'modifications)) 'queryId))
  (define third-v1 (version 1 4))
  (send-server-json!
   third-output
   (transition v0 third-v1
               (list (updated third-id (hasheq 'stage "replacement-two")))))
  ;; The adapter's close is deliberately bounded even though this peer does
  ;; not participate in the WebSocket closing handshake.
  (sleep 2)
  (close-input-port third-input)
  (close-output-port third-output)
  (tcp-close listener))

(define (connect-with-retry host port)
  (let loop ([remaining 100])
    (with-handlers ([exn:fail:network?
                     (lambda (error)
                       (if (zero? remaining)
                           (raise error)
                           (begin (sleep 0.05) (loop (sub1 remaining)))))])
      (tcp-connect host port))))

(define (run-controller)
  (define-values (input output)
    (connect-with-retry (or (getenv "ADAPTER_HOST") "adapter") 9102))
  (for ([command
         (in-list
          (list
           (hasheq 'protocolVersion 1 'id "hello" 'op "hello")
           (hasheq 'id "subscribe" 'op "subscribe" 'subscriptionId "stress"
                   'path "demo:state" 'args (hasheq 'room "stress"))))])
    (write-json command output)
    (newline output)
    (flush-output output)
    (define response (read-line input 'any))
    (unless (string? response) (error 'controller "adapter closed before ack")))
  ;; The adapter now has a valid subscription, but this controller does not
  ;; consume any near-limit subscription events for the stress interval.
  (sleep 12)
  (close-input-port input)
  (close-output-port output))

(define (write-command! output value)
  (write-json value output)
  (newline output)
  (flush-output output))

(define (read-event input)
  (define line (read-line input 'any))
  (unless (string? line) (error 'barrier-controller "adapter closed early"))
  (string->jsexpr line))

(define (expect-event input type id)
  (define value (read-event input))
  (unless (and (equal? (hash-ref value 'type #f) type)
               (equal? (hash-ref value 'id #f) id))
    (error 'barrier-controller "expected ~a ~a, received ~e" type id value))
  value)

(define (wait-for-relay-count expected)
  (define state-file
    (or (getenv "RELAY_STATE_FILE")
        (error 'barrier-controller "RELAY_STATE_FILE is required")))
  (let loop ([remaining 100])
    (define count
      (with-handlers ([exn:fail:filesystem? (lambda (_error) 0)])
        (length (file->lines state-file))))
    (cond
      [(>= count expected) (void)]
      [(zero? remaining)
       (error 'barrier-controller "relay did not dequeue update ~a" expected)]
      [else (sleep 0.05) (loop (sub1 remaining))])))

(define (run-barrier-controller)
  (define-values (input output)
    (connect-with-retry (or (getenv "ADAPTER_HOST") "adapter") 9102))
  (write-command! output (hasheq 'protocolVersion 1 'id "hello" 'op "hello"))
  (expect-event input "ready" "hello")
  (write-command!
   output
   (hasheq 'id "first" 'op "subscribe" 'subscriptionId "same"
           'path "demo:state" 'args (hasheq 'room "barrier")))
  (expect-event input "ack" "first")

  ;; The old relay has removed the update from the client mailbox and is now
  ;; paused before the output gate. This makes the late-output race exact.
  (wait-for-relay-count 1)
  (write-command!
   output
   (hasheq 'id "unsubscribe" 'op "unsubscribe" 'subscriptionId "same"))
  (expect-event input "ack" "unsubscribe")

  (write-command!
   output
   (hasheq 'id "second" 'op "subscribe" 'subscriptionId "same"
           'path "demo:state" 'args (hasheq 'room "barrier")))
  (expect-event input "ack" "second")
  (define replacement-one (read-event input))
  (unless (equal? (hash-ref (hash-ref replacement-one 'value) 'stage #f)
                  "replacement-one")
    (error 'barrier-controller "unexpected first replacement event ~e"
           replacement-one))

  ;; A second update is now paused in the old replacement relay. Replacing the
  ;; same subscription ID must acknowledge first and suppress that old value.
  (wait-for-relay-count 3)
  (write-command!
   output
   (hasheq 'id "third" 'op "subscribe" 'subscriptionId "same"
           'path "demo:state" 'args (hasheq 'room "barrier")))
  (expect-event input "ack" "third")
  (define replacement-two (read-event input))
  (unless (equal? (hash-ref (hash-ref replacement-two 'value) 'stage #f)
                  "replacement-two")
    (error 'barrier-controller "unexpected second replacement event ~e"
           replacement-two))

  (write-command! output (hasheq 'id "close" 'op "close"))
  (expect-event input "closed" "close")
  (close-input-port input)
  (close-output-port output))

(module+ main
  (define arguments (current-command-line-arguments))
  (unless (= (vector-length arguments) 1)
    (error 'fixture "expected server or controller"))
  (case (string->symbol (vector-ref arguments 0))
    [(server) (run-server)]
    [(controller) (run-controller)]
    [(barrier-server) (run-barrier-server)]
    [(barrier-controller) (run-barrier-controller)]
    [else (error 'fixture "expected a server or controller mode")]))
