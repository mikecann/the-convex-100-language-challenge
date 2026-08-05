#lang racket/base

;; Manual final-image stress fixture. `server` speaks enough Convex Live to
;; publish near-limit values; `controller` subscribes through the real TCP
;; adapter, reads its acknowledgement, then deliberately stops reading output.

(require file/sha1
         json
         net/base64
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

(define (run-server)
  (define listener (tcp-listen 9101 4 #t "0.0.0.0"))
  (displayln "READY")
  (flush-output)
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
  (read-client-json input) ; Connect
  (define add-envelope (read-client-json input))
  (define query-id
    (hash-ref (car (hash-ref add-envelope 'modifications)) 'queryId))
  (define large-value (make-string (* 1800 1024) #\x))
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
    (write-bytes (server-frame (jsexpr->bytes message)) output)
    (flush-output output)
    (set! previous next))
  (sleep 15)
  (close-input-port input)
  (close-output-port output)
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
  (define-values (input output) (connect-with-retry "adapter" 9102))
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

(module+ main
  (define arguments (current-command-line-arguments))
  (unless (= (vector-length arguments) 1)
    (error 'fixture "expected server or controller"))
  (case (string->symbol (vector-ref arguments 0))
    [(server) (run-server)]
    [(controller) (run-controller)]
    [else (error 'fixture "expected server or controller")]))
