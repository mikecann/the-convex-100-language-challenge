#lang racket/base

;; A deliberately small RFC 6455 client transport. Convex's query-set state
;; machine lives in live.rkt; this module owns only the HTTP upgrade and frames.

(require file/sha1
         json
         net/base64
         net/url
         openssl
         racket/list
         racket/match
         racket/port
         racket/random
         racket/string
         racket/tcp)

(provide ws-connect
         ws-from-ports
         ws-input-port
         ws-pending?
         ws-open?
         ws-write-text!
         ws-write-json!
         ws-read-message
         ws-close!
         ws-abort!
         ws-close-info
         (struct-out ws-peer-close)
         (struct-out exn:fail:websocket))

(define websocket-guid #"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
(define default-max-message-bytes (* 2 1024 1024))
(define default-max-header-bytes (* 32 1024))

;; kind is one of 'protocol, 'transport, 'timeout, or 'closed. close-code is the
;; RFC 6455 status to send when the connection is still healthy enough to reply.
(struct exn:fail:websocket exn:fail (kind close-code) #:transparent)
(struct ws-peer-close (code reason) #:transparent)

(struct socket-state
  (in
   out
   custodian
   [open? #:mutable]
   [close-info #:mutable]
   write-lock
   read-timeout
   write-timeout
   close-timeout
   max-message-bytes
   mask-generator)
  #:transparent)

(define (raise-ws kind close-code format-string . values)
  (raise
   (exn:fail:websocket
    (apply format format-string values)
    (current-continuation-marks)
    kind
    close-code)))

(define (positive-timeout? value)
  (or (not value) (and (real? value) (positive? value))))

(define (check-timeout who value)
  (unless (positive-timeout? value)
    (raise-argument-error who "(or/c #f positive-real?)" value)))

(define (check-bounded-timeout who value)
  (unless (and (real? value) (positive? value))
    (raise-argument-error who "positive-real?" value)))

(define (check-positive-size who value)
  (unless (and (exact-integer? value) (positive? value))
    (raise-argument-error who "exact-positive-integer?" value)))

(define (make-deadline timeout)
  (and timeout (+ (current-inexact-milliseconds) (* timeout 1000.0))))

(define (deadline-remaining deadline)
  (and deadline
       (max 0.0 (/ (- deadline (current-inexact-milliseconds)) 1000.0))))

(define (wait-ready event deadline operation)
  (when (and deadline (zero? (deadline-remaining deadline)))
    (raise-ws 'timeout #f "WebSocket ~a timed out" operation))
  (define ready
    (if deadline
        (sync/timeout (deadline-remaining deadline) event)
        (sync event)))
  (unless ready
    (raise-ws 'timeout #f "WebSocket ~a timed out" operation)))

(define (read-exactly state length deadline operation)
  (define result (make-bytes length))
  (let loop ([offset 0])
    (cond
      [(= offset length) result]
      [else
       (wait-ready (socket-state-in state) deadline operation)
       (define count
         (read-bytes-avail!*
          result
          (socket-state-in state)
          offset
          length))
       (cond
         [(eof-object? count)
          (raise-ws 'transport #f
                    "WebSocket peer closed during ~a"
                    operation)]
         [(zero? count) (loop offset)]
         [else (loop (+ offset count))])])))

(define (write-all! state value deadline operation)
  ;; Socket output ports are unbuffered, but write-bytes-avail!* still matters:
  ;; it lets a stalled peer hit our deadline instead of trapping the owner.
  (let loop ([offset 0])
    (unless (= offset (bytes-length value))
      (wait-ready (socket-state-out state) deadline operation)
      (define count
        (write-bytes-avail*
         value
         (socket-state-out state)
         offset
         (bytes-length value)))
      (if (zero? count)
          (loop offset)
          (loop (+ offset count)))))
  (flush-output (socket-state-out state)))

(define (strict-utf8 bytes description [close-code 1007])
  (with-handlers ([exn:fail?
                   (lambda (_error)
                     (raise-ws 'protocol close-code
                               "invalid UTF-8 in WebSocket ~a"
                               description))])
    (bytes->string/utf-8 bytes #f)))

(define (base64 bytes)
  (bytes->string/utf-8 (base64-encode bytes #"") #f))

(define (sha1 bytes)
  (sha1-bytes (open-input-bytes bytes)))

(define (header-token? headers name token)
  (for/or ([piece (in-list
                   (string-split (hash-ref headers name "") ","))])
    (string-ci=? (string-trim piece) token)))

(define (valid-header-name? name)
  (regexp-match?
   #px"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"
   name))

(define (read-http-upgrade state max-header-bytes deadline)
  (define response (open-output-bytes))
  (let loop ([tail #""])
    (when (>= (file-position response) max-header-bytes)
      (raise-ws 'protocol 1002 "WebSocket upgrade headers are too large"))
    (define next (read-exactly state 1 deadline "upgrade response"))
    (write-bytes next response)
    (define next-tail
      (if (< (bytes-length tail) 3)
          (bytes-append tail next)
          (bytes-append (subbytes tail (- (bytes-length tail) 3)) next)))
    (unless (bytes=? next-tail #"\r\n\r\n")
      (loop next-tail)))
  (bytes->string/latin-1 (get-output-bytes response)))

(define (parse-upgrade! response key)
  (define lines (regexp-split #rx"\r\n" response))
  (define status (if (pair? lines) (car lines) ""))
  (unless (regexp-match? #px"^HTTP/1[.]1 101(?:[ ]|$)" status)
    (raise-ws 'protocol 1002
              "WebSocket upgrade failed: ~a"
              (if (string=? status "") "empty response" status)))
  (define headers (make-hash))
  (for ([line (in-list (cdr lines))]
        #:break (string=? line ""))
    (when (or (string-prefix? line " ") (string-prefix? line "\t"))
      (raise-ws 'protocol 1002 "folded WebSocket upgrade header"))
    (match (regexp-match #px"^([^:]+):(.*)$" line)
      [(list _ raw-name raw-value)
       (define name (string-downcase raw-name))
       (unless (valid-header-name? name)
         (raise-ws 'protocol 1002 "invalid WebSocket upgrade header name"))
       (define value (string-trim raw-value))
       (if (hash-has-key? headers name)
           (hash-set! headers name
                      (string-append (hash-ref headers name) "," value))
           (hash-set! headers name value))]
      [_ (raise-ws 'protocol 1002 "malformed WebSocket upgrade header")]))
  (unless (header-token? headers "upgrade" "websocket")
    (raise-ws 'protocol 1002 "WebSocket upgrade omitted Upgrade: websocket"))
  (unless (header-token? headers "connection" "upgrade")
    (raise-ws 'protocol 1002 "WebSocket upgrade omitted Connection: Upgrade"))
  (define expected
    (base64
     (sha1
      (bytes-append (string->bytes/utf-8 key) websocket-guid))))
  (unless (string=? (hash-ref headers "sec-websocket-accept" "") expected)
    (raise-ws 'protocol 1002
              "WebSocket upgrade returned an invalid accept key")))

(define (call-with-connect-timeout timeout thunk)
  (define owner (make-custodian))
  (define result-channel (make-channel))
  (parameterize ([current-custodian owner])
    (thread
     (lambda ()
       (with-handlers ([exn?
                        (lambda (error)
                          (channel-put result-channel (cons 'error error)))])
         (call-with-values thunk
           (lambda values
             (channel-put result-channel (cons 'ok values))))))))
  (define result (sync/timeout timeout result-channel))
  (cond
    [(not result)
     (custodian-shutdown-all owner)
     (raise-ws 'timeout #f "WebSocket connection timed out")]
    [(eq? (car result) 'error)
     (custodian-shutdown-all owner)
     (raise (cdr result))]
    [else
     (apply values (append (cdr result) (list owner)))]))

(define (url-resource parsed rendered)
  (when (url-fragment parsed)
    (raise-ws 'protocol 1002 "WebSocket URLs must not contain fragments"))
  (match (regexp-match #px"^wss?://(?:\\[[^]]+\\]|[^/?#]+)([^#]*)$" rendered)
    [(list _ "") "/"]
    [(list _ suffix)
     (if (string-prefix? suffix "?")
         (string-append "/" suffix)
         suffix)]
    [_ (raise-ws 'protocol 1002 "invalid WebSocket URL")]))

(define (host-header host port default-port)
  (define displayed-host
    (if (string-contains? host ":")
        (string-append "[" host "]")
        host))
  (if (= port default-port)
      displayed-host
      (format "~a:~a" displayed-host port)))

(define (ws-connect url
                    #:client-version [client-version "convex-racket"]
                    #:headers [extra-headers '()]
                    #:connect-timeout [connect-timeout 10.0]
                    #:read-timeout [read-timeout #f]
                    #:write-timeout [write-timeout 10.0]
                    #:close-timeout [close-timeout 0.25]
                    #:max-message-bytes
                    [max-message-bytes default-max-message-bytes]
                    #:max-header-bytes
                    [max-header-bytes default-max-header-bytes]
                    #:mask-generator [mask-generator crypto-random-bytes]
                    #:tls-context [tls-context #f])
  (unless (string? url)
    (raise-argument-error 'ws-connect "string?" url))
  (unless (and (string? client-version)
               (not (regexp-match? #rx"[\r\n]" client-version)))
    (raise-argument-error 'ws-connect "string-without-newlines?"
                          client-version))
  (define protected-headers
    '("host" "upgrade" "connection" "sec-websocket-key"
             "sec-websocket-version" "convex-client"))
  (for ([entry (in-list extra-headers)])
    (unless (and (pair? entry)
                 (string? (car entry))
                 (string? (cdr entry))
                 (valid-header-name? (car entry))
                 (not (regexp-match? #rx"[\r\n]" (cdr entry))))
      (raise-argument-error
       'ws-connect
       "(listof (cons/c valid-http-header-name? string-without-newlines?))"
       extra-headers)))
  (for ([entry (in-list extra-headers)])
    (when (member (string-downcase (car entry)) protected-headers)
      (raise-arguments-error 'ws-connect
                             "a WebSocket handshake header cannot be overridden"
                             "header" (car entry))))
  (check-timeout 'ws-connect read-timeout)
  (for ([value (in-list (list connect-timeout write-timeout close-timeout))])
    (check-bounded-timeout 'ws-connect value))
  (check-positive-size 'ws-connect max-message-bytes)
  (check-positive-size 'ws-connect max-header-bytes)
  (unless (procedure? mask-generator)
    (raise-argument-error 'ws-connect "procedure?" mask-generator))
  (define parsed
    (with-handlers ([exn:fail?
                     (lambda (_error)
                       (raise-ws 'protocol 1002 "invalid WebSocket URL"))])
      (string->url url)))
  (define scheme (url-scheme parsed))
  (unless (member scheme '("ws" "wss"))
    (raise-ws 'protocol 1002 "WebSocket URL must use ws or wss"))
  (when (url-user parsed)
    (raise-ws 'protocol 1002 "WebSocket URLs must not include user info"))
  (define host (url-host parsed))
  (unless (and host (not (string=? host "")))
    (raise-ws 'protocol 1002 "WebSocket URL is missing a host"))
  (define secure? (string=? scheme "wss"))
  (define default-port (if secure? 443 80))
  (define port (or (url-port parsed) default-port))
  (define rendered (url->string parsed))
  (define resource (url-resource parsed rendered))
  (define-values (input output owner)
    (with-handlers ([exn:fail:websocket? raise]
                    [exn:fail?
                     (lambda (error)
                       (raise-ws 'transport #f
                                 "WebSocket connection failed: ~a"
                                 (exn-message error)))])
      (call-with-connect-timeout
       connect-timeout
       (lambda ()
         (if secure?
             (ssl-connect host port
                          (or tls-context
                              (ssl-make-client-context 'secure)))
             (tcp-connect host port))))))
  (define state
    (socket-state input output owner #t #f (make-semaphore 1)
                  read-timeout write-timeout close-timeout
                  max-message-bytes mask-generator))
  (with-handlers ([exn:fail:websocket?
                   (lambda (error)
                     (ws-abort! state)
                     (raise error))]
                  [exn:fail?
                   (lambda (error)
                     (ws-abort! state)
                     (raise-ws 'transport #f
                               "WebSocket upgrade failed: ~a"
                               (exn-message error)))])
    (with-handlers ([exn:fail? void])
      (file-stream-buffer-mode output 'none))
    (define key (base64 (crypto-random-bytes 16)))
    (define request-lines
      (append
       (list (format "GET ~a HTTP/1.1" resource)
             (format "Host: ~a" (host-header host port default-port))
             "Upgrade: websocket"
             "Connection: Upgrade"
             (format "Sec-WebSocket-Key: ~a" key)
             "Sec-WebSocket-Version: 13"
             (format "Convex-Client: ~a" client-version))
       (for/list ([entry (in-list extra-headers)])
         (format "~a: ~a" (car entry) (cdr entry)))
       (list "" "")))
    (define deadline (make-deadline write-timeout))
    (write-all! state
                (string->bytes/utf-8 (string-join request-lines "\r\n"))
                deadline
                "upgrade request")
    (parse-upgrade!
     (read-http-upgrade state max-header-bytes
                        (make-deadline connect-timeout))
     key)
    state))

(define (ws-from-ports input output
                       #:read-timeout [read-timeout #f]
                       #:write-timeout [write-timeout 10.0]
                       #:close-timeout [close-timeout 0.25]
                       #:max-message-bytes
                       [max-message-bytes default-max-message-bytes]
                       #:mask-generator [mask-generator crypto-random-bytes])
  (unless (input-port? input)
    (raise-argument-error 'ws-from-ports "input-port?" input))
  (unless (output-port? output)
    (raise-argument-error 'ws-from-ports "output-port?" output))
  (check-timeout 'ws-from-ports read-timeout)
  (for ([value (in-list (list write-timeout close-timeout))])
    (check-bounded-timeout 'ws-from-ports value))
  (check-positive-size 'ws-from-ports max-message-bytes)
  (unless (procedure? mask-generator)
    (raise-argument-error 'ws-from-ports "procedure?" mask-generator))
  (with-handlers ([exn:fail? void])
    (file-stream-buffer-mode output 'none))
  (socket-state input output #f #t #f (make-semaphore 1)
                read-timeout write-timeout close-timeout
                max-message-bytes mask-generator))

(define (ws-input-port state)
  (socket-state-in state))

(define (ws-open? state)
  (socket-state-open? state))

(define (ws-close-info state)
  (socket-state-close-info state))

(define (ws-pending? state)
  (and (socket-state-open? state)
       (not (not (sync/timeout 0 (socket-state-in state))))))

(define (masked-payload payload mask)
  (define result (bytes-copy payload))
  (for ([index (in-range (bytes-length result))])
    (bytes-set! result index
                (bitwise-xor (bytes-ref result index)
                             (bytes-ref mask (modulo index 4)))))
  result)

(define (frame-header opcode payload-length mask)
  (define first (bytes (bitwise-ior #x80 opcode)))
  (define length-header
    (cond
      [(< payload-length 126)
       (bytes (bitwise-ior #x80 payload-length))]
      [(<= payload-length #xffff)
       (bytes-append
        (bytes (bitwise-ior #x80 126))
        (integer->integer-bytes payload-length 2 #f #t))]
      [else
       (bytes-append
        (bytes (bitwise-ior #x80 127))
        (integer->integer-bytes payload-length 8 #f #t))]))
  (bytes-append first length-header mask))

(define (write-frame! state opcode payload timeout [permit-closing? #f])
  (unless (or permit-closing? (socket-state-open? state))
    (raise-ws 'closed #f "WebSocket is closed"))
  (when (and (>= opcode #x8) (> (bytes-length payload) 125))
    (raise-ws 'protocol 1002 "WebSocket control payload exceeds 125 bytes"))
  (define mask ((socket-state-mask-generator state) 4))
  (unless (and (bytes? mask) (= (bytes-length mask) 4))
    (raise-ws 'transport #f "WebSocket mask generator did not return 4 bytes"))
  (define packet
    (bytes-append
     (frame-header opcode (bytes-length payload) mask)
     (masked-payload payload mask)))
  (call-with-semaphore
   (socket-state-write-lock state)
   (lambda ()
     (with-handlers ([exn:fail:websocket?
                      (lambda (error)
                        (unless (eq? (exn:fail:websocket-kind error) 'protocol)
                          (ws-abort! state))
                        (raise error))]
                     [exn:fail?
                      (lambda (error)
                        (ws-abort! state)
                        (raise-ws 'transport #f
                                  "WebSocket write failed: ~a"
                                  (exn-message error)))])
       (write-all! state packet (make-deadline timeout) "frame write")))))

(define (ws-write-text! state text)
  (unless (string? text)
    (raise-argument-error 'ws-write-text! "string?" text))
  (define payload (string->bytes/utf-8 text))
  (when (> (bytes-length payload) (socket-state-max-message-bytes state))
    (raise-ws 'protocol 1009 "WebSocket message is too large"))
  (write-frame! state #x1 payload (socket-state-write-timeout state)))

(define (ws-write-json! state value)
  (ws-write-text! state (jsexpr->string value)))

(define (read-frame state deadline)
  (define header (read-exactly state 2 deadline "frame header"))
  (define first (bytes-ref header 0))
  (define second (bytes-ref header 1))
  (unless (zero? (bitwise-and first #x70))
    (raise-ws 'protocol 1002 "WebSocket extensions are not enabled"))
  (define final? (not (zero? (bitwise-and first #x80))))
  (define opcode (bitwise-and first #x0f))
  (unless (member opcode '(0 1 2 8 9 10))
    (raise-ws 'protocol 1002 "unsupported WebSocket opcode ~a" opcode))
  (unless (zero? (bitwise-and second #x80))
    (raise-ws 'protocol 1002 "server WebSocket frames must not be masked"))
  (define short-length (bitwise-and second #x7f))
  (define length
    (cond
      [(< short-length 126) short-length]
      [(= short-length 126)
       (define decoded
         (integer-bytes->integer
          (read-exactly state 2 deadline "frame length") #f #t))
       (when (< decoded 126)
         (raise-ws 'protocol 1002 "non-minimal WebSocket frame length"))
       decoded]
      [else
       (define encoded (read-exactly state 8 deadline "frame length"))
       (when (not (zero? (bitwise-and (bytes-ref encoded 0) #x80)))
         (raise-ws 'protocol 1002 "invalid 64-bit WebSocket frame length"))
       (define decoded (integer-bytes->integer encoded #f #t))
       (when (<= decoded #xffff)
         (raise-ws 'protocol 1002 "non-minimal WebSocket frame length"))
       decoded]))
  (when (and (>= opcode #x8) (not final?))
    (raise-ws 'protocol 1002 "fragmented WebSocket control frame"))
  (when (and (>= opcode #x8) (> length 125))
    (raise-ws 'protocol 1002 "oversized WebSocket control frame"))
  (when (> length (socket-state-max-message-bytes state))
    (raise-ws 'protocol 1009 "WebSocket frame is too large"))
  (values final? opcode
          (read-exactly state length deadline "frame payload")))

(define (valid-close-code? code)
  (or (member code '(1000 1001 1002 1003 1007 1008 1009
                         1010 1011 1012 1013 1014))
      (<= 3000 code 4999)))

(define (decode-close payload)
  (cond
    [(zero? (bytes-length payload)) (ws-peer-close #f "")]
    [(= (bytes-length payload) 1)
     (raise-ws 'protocol 1002 "one-byte WebSocket close payload")]
    [else
     (define code
       (integer-bytes->integer payload #f #t 0 2))
     (unless (valid-close-code? code)
       (raise-ws 'protocol 1002 "invalid WebSocket close code ~a" code))
     (ws-peer-close code
                    (strict-utf8 (subbytes payload 2) "close reason"))]))

(define (best-effort-protocol-close! state error)
  (when (and (socket-state-open? state)
             (exn:fail:websocket-close-code error))
    (with-handlers ([exn? void])
      (write-frame!
       state
       #x8
       (integer->integer-bytes
        (exn:fail:websocket-close-code error) 2 #f #t)
       (socket-state-close-timeout state)
       #t))))

(define (handle-peer-close! state payload)
  (define close (decode-close payload))
  (set-socket-state-close-info! state close)
  (with-handlers ([exn? void])
    (write-frame! state #x8 payload
                  (socket-state-close-timeout state) #t))
  (ws-abort! state)
  #f)

(define (ws-read-message state)
  (unless (socket-state-open? state)
    (raise-ws 'closed #f "WebSocket is closed"))
  (with-handlers ([exn:fail:websocket?
                   (lambda (error)
                     (best-effort-protocol-close! state error)
                     (ws-abort! state)
                     (raise error))]
                  [exn:fail?
                   (lambda (error)
                     (ws-abort! state)
                     (raise-ws 'transport #f
                               "WebSocket read failed: ~a"
                               (exn-message error)))])
    (define deadline (make-deadline (socket-state-read-timeout state)))
    (let loop ([message #f] [message-length 0])
      (define-values (final? opcode payload) (read-frame state deadline))
      (case opcode
        [(0)
         (unless message
           (raise-ws 'protocol 1002 "unexpected WebSocket continuation"))
         (define next-length (+ message-length (bytes-length payload)))
         (when (> next-length (socket-state-max-message-bytes state))
           (raise-ws 'protocol 1009 "WebSocket message is too large"))
         (write-bytes payload message)
         (if final?
             (strict-utf8 (get-output-bytes message) "text message")
             (loop message next-length))]
        [(1)
         (when message
           (raise-ws 'protocol 1002 "interleaved WebSocket text messages"))
         (if final?
             (strict-utf8 payload "text message")
             (let ([next (open-output-bytes)])
               (write-bytes payload next)
               (loop next (bytes-length payload))))]
        [(2)
         (raise-ws 'protocol 1003 "binary WebSocket messages are unsupported")]
        [(8) (handle-peer-close! state payload)]
        [(9)
         (write-frame! state #xA payload
                       (socket-state-write-timeout state))
         (loop message message-length)]
        [(10) (loop message message-length)]))))

(define (close-payload code reason)
  (unless (valid-close-code? code)
    (raise-argument-error 'ws-close! "valid WebSocket close code" code))
  (unless (string? reason)
    (raise-argument-error 'ws-close! "string?" reason))
  (define reason-bytes (string->bytes/utf-8 reason))
  (when (> (bytes-length reason-bytes) 123)
    (raise-argument-error 'ws-close! "UTF-8 string no longer than 123 bytes"
                          reason))
  (bytes-append (integer->integer-bytes code 2 #f #t) reason-bytes))

(define (await-peer-close! state deadline)
  ;; Ignore data while closing, but keep servicing ping. The fixed deadline is
  ;; deliberately not reset by a chatty peer or by a partial frame.
  (let loop ()
    (define-values (_final? opcode payload) (read-frame state deadline))
    (case opcode
      [(8)
       (set-socket-state-close-info! state (decode-close payload))]
      [(9)
       (write-frame! state #xA payload
                     (deadline-remaining deadline) #t)
       (loop)]
      [else (loop)])))

(define (ws-close! state #:code [code 1000] #:reason [reason "client closed"])
  (define payload (close-payload code reason))
  (when (socket-state-open? state)
    (define deadline (make-deadline (socket-state-close-timeout state)))
    (with-handlers ([exn? void])
      (write-frame! state #x8 payload
                    (deadline-remaining deadline) #t)
      (await-peer-close! state deadline))
    (ws-abort! state))
  (void))

(define (ws-abort! state)
  (when (socket-state-open? state)
    (set-socket-state-open?! state #f))
  (with-handlers ([exn? void])
    (close-input-port (socket-state-in state)))
  (with-handlers ([exn? void])
    (close-output-port (socket-state-out state)))
  (when (socket-state-custodian state)
    (with-handlers ([exn? void])
      (custodian-shutdown-all (socket-state-custodian state))))
  (void))
