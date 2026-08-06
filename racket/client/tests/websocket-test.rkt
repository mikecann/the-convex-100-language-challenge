#lang racket/base

(require file/sha1
         net/base64
         rackunit
         rackunit/text-ui
         racket/match
         racket/port
         racket/string
         racket/tcp
         "../websocket.rkt")

(define websocket-guid #"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(define (read-exactly input length)
  (define value (read-bytes length input))
  (unless (and (bytes? value) (= (bytes-length value) length))
    (error 'read-exactly "unexpected EOF"))
  value)

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

(define (read-client-frame input)
  (define header (read-exactly input 2))
  (define first (bytes-ref header 0))
  (define second (bytes-ref header 1))
  (check-not-equal? (bitwise-and second #x80) 0
                    "client frames must be masked")
  (define short-length (bitwise-and second #x7f))
  (define length
    (cond
      [(< short-length 126) short-length]
      [(= short-length 126)
       (integer-bytes->integer (read-exactly input 2) #f #t)]
      [else
       (integer-bytes->integer (read-exactly input 8) #f #t)]))
  (define mask (read-exactly input 4))
  (define payload (read-exactly input length))
  (for ([index (in-range length)])
    (bytes-set! payload index
                (bitwise-xor (bytes-ref payload index)
                             (bytes-ref mask (modulo index 4)))))
  (values (not (zero? (bitwise-and first #x80)))
          (bitwise-and first #x0f)
          payload))

(define (make-tcp-pair #:read-timeout [read-timeout #f]
                       #:write-timeout [write-timeout 0.2]
                       #:close-timeout [close-timeout 0.08]
                       #:max-message-bytes [max-message-bytes (* 2 1024 1024)])
  (define listener (tcp-listen 0 1 #t "127.0.0.1"))
  (define-values (_local-host port _remote-host _remote-port)
    (tcp-addresses listener #t))
  (define-values (client-input client-output)
    (tcp-connect "127.0.0.1" port))
  (define-values (server-input server-output) (tcp-accept listener))
  (tcp-close listener)
  (values
   (ws-from-ports client-input client-output
                  #:read-timeout read-timeout
                  #:write-timeout write-timeout
                  #:close-timeout close-timeout
                  #:max-message-bytes max-message-bytes
                  #:mask-generator (lambda (_length) #"\1\2\3\4"))
   server-input
   server-output))

(define (close-port port)
  (with-handlers ([exn? void])
    (if (input-port? port)
        (close-input-port port)
        (close-output-port port))))

(define (with-tcp-pair procedure
                       #:read-timeout [read-timeout #f]
                       #:write-timeout [write-timeout 0.2]
                       #:close-timeout [close-timeout 0.08]
                       #:max-message-bytes [max-message-bytes (* 2 1024 1024)])
  (define-values (socket server-input server-output)
    (make-tcp-pair #:read-timeout read-timeout
                   #:write-timeout write-timeout
                   #:close-timeout close-timeout
                   #:max-message-bytes max-message-bytes))
  (dynamic-wind
    void
    (lambda () (procedure socket server-input server-output))
    (lambda ()
      (ws-abort! socket)
      (close-port server-input)
      (close-port server-output))))

(define (read-http-headers input)
  (define output (open-output-bytes))
  (let loop ([tail #""])
    (define next (read-exactly input 1))
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
              #:when (string-prefix? (string-downcase line)
                                     (string-append
                                      (string-downcase name) ":")))
    (string-trim (substring line (+ (string-length name) 1)))))

(define (accept-for key)
  (bytes->string/utf-8
   (base64-encode
    (sha1-bytes
     (open-input-bytes
      (bytes-append (string->bytes/utf-8 key) websocket-guid)))
    #"")
   #f))

(define (start-upgrade-server response-builder)
  (define listener (tcp-listen 0 1 #t "127.0.0.1"))
  (define-values (_local-host port _remote-host _remote-port)
    (tcp-addresses listener #t))
  (define result (make-channel))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([exn? (lambda (error) (channel-put result error))])
         (define-values (input output) (tcp-accept listener))
         (define request (read-http-headers input))
         (write-bytes (string->bytes/utf-8 (response-builder request)) output)
         (flush-output output)
         (channel-put result (list request input output))))))
  (values listener port worker result))

(define (finish-upgrade-server listener worker result)
  (define answer (sync/timeout 1 result))
  (tcp-close listener)
  (unless answer
    (kill-thread worker)
    (error 'upgrade-server "server did not finish"))
  (when (exn? answer) (raise answer))
  answer)

(define tests
  (test-suite
   "native WebSocket transport"

   (test-case
    "the HTTP upgrade is strict and carries the Convex client header"
    (define-values (listener port worker result)
      (start-upgrade-server
       (lambda (request)
         (define key (request-header request "Sec-WebSocket-Key"))
         (string-append
          "HTTP/1.1 101 Switching Protocols\r\n"
          "Upgrade: WebSocket\r\n"
          "Connection: keep-alive, Upgrade\r\n"
          "Sec-WebSocket-Accept: " (accept-for key) "\r\n\r\n"))))
    (define socket
      (ws-connect (format "ws://127.0.0.1:~a/api/sync?x=1" port)
                  #:client-version "convex-racket-test"
                  #:connect-timeout 1
                  #:close-timeout 0.02))
    (define server-state
      (finish-upgrade-server listener worker result))
    (define request (car server-state))
    (check-true (string-prefix? request "GET /api/sync?x=1 HTTP/1.1\r\n"))
    (check-equal? (request-header request "Convex-Client")
                  "convex-racket-test")
    (check-true (ws-open? socket))
    (ws-abort! socket)
    (close-port (cadr server-state))
    (close-port (caddr server-state)))

   (test-case
    "an invalid upgrade accept key closes the connection"
    (define-values (listener port worker result)
      (start-upgrade-server
       (lambda (_request)
         (string-append
          "HTTP/1.1 101 Switching Protocols\r\n"
          "Upgrade: websocket\r\nConnection: Upgrade\r\n"
          "Sec-WebSocket-Accept: wrong\r\n\r\n"))))
    (check-exn
     (lambda (error)
       (and (exn:fail:websocket? error)
            (eq? (exn:fail:websocket-kind error) 'protocol)))
     (lambda ()
       (ws-connect (format "ws://127.0.0.1:~a/" port)
                   #:connect-timeout 1)))
    (define server-state
      (finish-upgrade-server listener worker result))
    (close-port (cadr server-state))
    (close-port (caddr server-state)))

   (test-case
    "client text and control frames are masked"
    (with-tcp-pair
     (lambda (socket server-input _server-output)
       (ws-write-json! socket (hasheq 'type "Connect" 'clientTs 0))
       (define-values (final? opcode payload)
         (read-client-frame server-input))
       (check-true final?)
       (check-equal? opcode 1)
       (check-equal? payload #"{\"clientTs\":0,\"type\":\"Connect\"}"))))

   (test-case
    "fragmented UTF-8 survives an interleaved ping"
    (with-tcp-pair
     (lambda (socket server-input server-output)
       (define encoded (string->bytes/utf-8 "A☃B"))
       ;; Split inside the three-byte snowman, not merely between characters.
       (write-bytes (server-frame 1 (subbytes encoded 0 2) #:final? #f)
                    server-output)
       (write-bytes (server-frame 9 #"still-here") server-output)
       (write-bytes (server-frame 0 (subbytes encoded 2)) server-output)
       (flush-output server-output)
       (check-equal? (ws-read-message socket) "A☃B")
       (define-values (final? opcode payload)
         (read-client-frame server-input))
       (check-true final?)
       (check-equal? opcode 10)
       (check-equal? payload #"still-here"))))

   (test-case
    "a peer close is validated, echoed, and recorded"
    (with-tcp-pair
     (lambda (socket server-input server-output)
       (define payload
         (bytes-append (integer->integer-bytes 1000 2 #f #t) #"done"))
       (write-bytes (server-frame 8 payload) server-output)
       (flush-output server-output)
       (check-false (ws-read-message socket))
       (check-false (ws-open? socket))
       (check-equal? (ws-close-info socket) (ws-peer-close 1000 "done"))
       (define-values (_final? opcode echoed)
         (read-client-frame server-input))
       (check-equal? opcode 8)
       (check-equal? echoed payload))))

   (test-case
    "malformed frames retire only their own connection"
    (define malformed
      (list
       (cons #"\201\200" 1002) ; servers never mask
       (cons #"\011\0" 1002) ; control frames cannot fragment
       (cons #"\201\1\377" 1007) ; text is strict UTF-8
       (cons #"\200\0" 1002) ; no continuation without a start
       (cons #"\201\176\0\1A" 1002) ; extended lengths are minimal
       (cons #"\201\177\200\0\0\0\0\0\0\0" 1002)))
    (for ([fixture (in-list malformed)])
      (with-tcp-pair
       (lambda (socket _server-input server-output)
         (write-bytes (car fixture) server-output)
         (flush-output server-output)
         (define caught
           (with-handlers ([exn:fail:websocket? values])
             (ws-read-message socket)
             #f))
         (check-true (exn:fail:websocket? caught))
         (check-equal? (exn:fail:websocket-kind caught) 'protocol)
         (check-equal? (exn:fail:websocket-close-code caught) (cdr fixture))
         (check-false (ws-open? socket)))))
    ;; A parser failure is connection-local. A fresh real socket still works.
    (with-tcp-pair
     (lambda (socket _server-input server-output)
       (write-bytes (server-frame 1 #"recovered") server-output)
       (flush-output server-output)
       (check-equal? (ws-read-message socket) "recovered"))))

   (test-case
    "aggregate fragmented messages enforce the byte limit"
    (with-tcp-pair
     #:max-message-bytes 4
     (lambda (socket _server-input server-output)
       (write-bytes (server-frame 1 #"abc" #:final? #f) server-output)
       (write-bytes (server-frame 0 #"de") server-output)
       (flush-output server-output)
       (check-exn
        (lambda (error)
          (and (exn:fail:websocket? error)
               (= (exn:fail:websocket-close-code error) 1009)))
        (lambda () (ws-read-message socket))))))

   (test-case
    "a timeout halfway through a frame abandons parser state"
    (with-tcp-pair
     #:read-timeout 0.05
     (lambda (socket _server-input server-output)
       ;; The first extended-length byte arrives, the second never does.
       (write-bytes #"\201\176\0" server-output)
       (flush-output server-output)
       (define started (current-inexact-milliseconds))
       (check-exn
        (lambda (error)
          (and (exn:fail:websocket? error)
               (eq? (exn:fail:websocket-kind error) 'timeout)))
        (lambda () (ws-read-message socket)))
       (check-true (< (- (current-inexact-milliseconds) started) 500.0))
       (check-false (ws-open? socket)))))

   (test-case
    "close stays bounded while the peer continuously sends"
    (with-tcp-pair
     #:close-timeout 0.06
     (lambda (socket _server-input server-output)
       (define sending? #t)
       (define sender
         (thread
          (lambda ()
            (with-handlers ([exn? void])
              (let loop ()
                (when sending?
                  (write-bytes (server-frame 10 #"") server-output)
                  (flush-output server-output)
                  (loop)))))))
       (define started (current-inexact-milliseconds))
       (ws-close! socket)
       (set! sending? #f)
       (kill-thread sender)
       (check-true (< (- (current-inexact-milliseconds) started) 500.0))
       (check-false (ws-open? socket)))))

   (test-case
    "close stays bounded when the peer stalls inside a frame"
    (with-tcp-pair
     #:close-timeout 0.06
     (lambda (socket _server-input server-output)
       (write-bytes #"\201\176\0" server-output)
       (flush-output server-output)
       (define started (current-inexact-milliseconds))
       (ws-close! socket)
       (check-true (< (- (current-inexact-milliseconds) started) 500.0))
       (check-false (ws-open? socket)))))))

(module+ test
  (define failures (run-tests tests))
  (unless (zero? failures)
    (error 'websocket-test "~a WebSocket test(s) failed" failures)))

(module+ main
  (define failures (run-tests tests))
  (exit (if (zero? failures) 0 1)))
