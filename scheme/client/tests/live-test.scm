(import scheme
        (chicken base)
        (chicken bitwise)
        (chicken blob)
        (chicken condition)
        (chicken io)
        (chicken port)
        (chicken string)
        (chicken tcp)
        srfi-4
        srfi-13
        srfi-18
        base64
        simple-sha1
        to-hex
        convex)

(define checks 0)
(define (check truth label)
  (set! checks (+ checks 1))
  (unless truth (error 'live-test label)))

(define (index-of text character)
  (let loop ((index 0))
    (cond ((= index (string-length text)) #f)
          ((char=? (string-ref text index) character) index)
          (else (loop (+ index 1))))))

(define (trim-left text)
  (let loop ((index 0))
    (if (and (< index (string-length text))
             (char-whitespace? (string-ref text index)))
        (loop (+ index 1))
        (substring text index))))

(define (read-handshake input)
  (let ((request-line (read-line input)))
    (when (eof-object? request-line) (error 'live-test "handshake EOF"))
    (let loop ((headers '()))
      (let ((line (read-line input)))
        (if (string=? line "")
            (vector request-line headers)
            (let ((colon (index-of line #\:)))
              (unless colon (error 'live-test "malformed handshake header"))
              (loop (cons (cons (string-downcase (substring line 0 colon))
                                (trim-left (substring line (+ colon 1))))
                          headers))))))))

(define (handshake! input output)
  (let* ((request (read-handshake input))
         (headers (vector-ref request 1))
         (key (cdr (assoc "sec-websocket-key" headers)))
         (accept
           (base64-encode
            (hex_to_str
             (make-string 20)
             (string->sha1sum
              (string-append key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
             0 40))))
    (check (string-contains (vector-ref request 0) "/api/sync")
           "unversioned sync endpoint")
    (check (string=? (cdr (assoc "convex-client" headers)) "scheme-0.1.0")
           "Live Convex-Client header")
    (display "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " output)
    (display accept output)
    (display "\r\n\r\n" output)
    (flush-output output)))

(define (read-exact count input)
  (let ((bytes (read-u8vector count input)))
    (unless (= (u8vector-length bytes) count)
      (error 'live-test "short WebSocket frame"))
    bytes))

(define (read-network-length input marker)
  (cond
    ((< marker 126) marker)
    ((= marker 126)
     (let ((bytes (read-exact 2 input)))
       (+ (* 256 (u8vector-ref bytes 0)) (u8vector-ref bytes 1))))
    (else
     (let ((bytes (read-exact 8 input)))
       (let loop ((index 0) (value 0))
         (if (= index 8) value
             (loop (+ index 1)
                   (+ (* value 256) (u8vector-ref bytes index)))))))))

(define (read-client-frame input)
  (let ((first (read-byte input)))
    (if (eof-object? first)
        #f
        (let* ((second (read-byte input))
               (fin? (not (= 0 (bitwise-and first #x80))))
               (opcode (bitwise-and first #x0f))
               (masked? (not (= 0 (bitwise-and second #x80))))
               (length (read-network-length input (bitwise-and second #x7f)))
               (mask (and masked? (read-exact 4 input)))
               (payload (read-exact length input)))
          (check masked? "client WebSocket frames are masked")
          (let loop ((index 0))
            (when (< index length)
              (u8vector-set! payload index
                             (bitwise-xor (u8vector-ref payload index)
                                          (u8vector-ref mask (modulo index 4))))
              (loop (+ index 1))))
          (vector fin? opcode payload)))))

(define (string->bytes text)
  (let ((bytes (make-u8vector (string-length text) 0)))
    (let loop ((index 0))
      (when (< index (string-length text))
        (u8vector-set! bytes index (char->integer (string-ref text index)))
        (loop (+ index 1))))
    bytes))

(define (bytes->string bytes)
  (let ((text (make-string (u8vector-length bytes) #\nul)))
    (let loop ((index 0))
      (when (< index (u8vector-length bytes))
        (string-set! text index (integer->char (u8vector-ref bytes index)))
        (loop (+ index 1))))
    text))

(define (slice bytes start end)
  (let ((result (make-u8vector (- end start) 0)))
    (let loop ((index start))
      (when (< index end)
        (u8vector-set! result (- index start) (u8vector-ref bytes index))
        (loop (+ index 1))))
    result))

(define (write-length output length masked?)
  (let ((mask-bit (if masked? #x80 0)))
    (cond
      ((< length 126) (write-byte (+ mask-bit length) output))
      ((< length 65536)
       (write-byte (+ mask-bit 126) output)
       (write-byte (quotient length 256) output)
       (write-byte (modulo length 256) output))
      (else (error 'live-test "fixture frame unexpectedly large")))))

(define (send-server-frame output fin? opcode payload #!optional (masked? #f))
  (write-byte (+ (if fin? #x80 0) opcode) output)
  (write-length output (u8vector-length payload) masked?)
  (if masked?
      (let ((mask #u8(1 2 3 4))
            (copy (slice payload 0 (u8vector-length payload))))
        (write-u8vector mask output)
        (let loop ((index 0))
          (when (< index (u8vector-length copy))
            (u8vector-set! copy index
                           (bitwise-xor (u8vector-ref copy index)
                                        (u8vector-ref mask (modulo index 4))))
            (loop (+ index 1))))
        (write-u8vector copy output))
      (write-u8vector payload output))
  (flush-output output))

(define (send-text output text)
  (send-server-frame output #t 1 (string->bytes text)))

(define (read-client-json input expected-kind)
  (let loop ()
    (let ((frame (read-client-frame input)))
      (unless frame (error 'live-test "client disconnected before expected message"))
      (case (vector-ref frame 1)
        ((1)
         (let ((message (json-decode (bytes->string (vector-ref frame 2)))))
           (if (string=? (json-get message "type" "") expected-kind)
               message
               (loop))))
        ((8) (error 'live-test "client closed before expected message"))
        (else (loop))))))

(define (wait-for-disconnect input)
  (handle-exceptions condition #t
    (let loop ((saw-pong? #f))
      (let ((frame (read-client-frame input)))
        (if frame
            (loop (or saw-pong? (= (vector-ref frame 1) 10)))
            saw-pong?)))))

(define (timestamp number)
  (let ((raw (make-string 8 #\nul)))
    (string-set! raw 0 (integer->char number))
    (base64-encode raw)))

(define zero-version
  (json-object "querySet" 0 "identity" 0 "ts" (timestamp 0)))

(define (version ts)
  (json-object "querySet" 1 "identity" 0 "ts" (timestamp ts)))

(define (updated query-id count #!optional (extra #f))
  (json-object "type" "QueryUpdated"
               "queryId" query-id
               "value" (if extra
                            (json-object "count" count "snow" extra)
                            (json-object "count" count))
               "logLines" (list (string-append "count=" (number->string count)))))

(define (failed query-id)
  (json-object "type" "QueryFailed"
               "queryId" query-id
               "errorMessage" "reactive failure"
               "errorData" (json-object "code" "BROKEN")
               "logLines" '("query-failed")))

(define (transition start end modifications)
  (json-object "type" "Transition"
               "startVersion" start
               "endVersion" end
               "modifications" modifications))

(define (send-transition output start-ts end-ts query-id change)
  (send-text output
             (json-encode
              (transition (if (= start-ts 0) zero-version (version start-ts))
                          (version end-ts)
                          (list change)))))

(define (accept-live listener expected-count expected-max)
  (call-with-values
   (lambda () (tcp-accept listener))
   (lambda (input output)
     (handshake! input output)
     (let ((connect (read-client-json input "Connect")))
       (check (= (json-get connect "connectionCount") expected-count)
              "connectionCount carried across reconnect")
       (if expected-max
           (check (string=? (json-get connect "maxObservedTimestamp")
                            (timestamp expected-max))
                  "maxObservedTimestamp carried across reconnect")
           (check (not (json-has? connect "maxObservedTimestamp"))
                  "initial Connect omits maxObservedTimestamp")))
     (let* ((modify (read-client-json input "ModifyQuerySet"))
            (changes (json-get modify "modifications"))
            (add (car changes)))
       (check (string=? (json-get add "type") "Add") "reconnect restores Add")
       (values input output (json-get add "queryId"))))))

(define listener (tcp-listen 0 8 "127.0.0.1"))
(define listen-port (tcp-listener-port listener))

(define server
  (thread-start!
   (make-thread
    (lambda ()
      (parameterize ((tcp-read-timeout 5000) (tcp-write-timeout 500))
        ;; Initial hydration, update, QueryFailed recovery, and one fragmented
        ;; UTF-8 message with a ping interleaved between fragments.
        (call-with-values
         (lambda () (accept-live listener 0 #f))
         (lambda (input output query-id)
           (send-transition output 0 1 query-id (updated query-id 0))
           ;; Two changes for one query in one transaction publish only the
           ;; final coalesced value.
           (send-text
            output
            (json-encode
             (transition (version 1) (version 2)
                         (list (updated query-id 100)
                               (updated query-id 1)))))
           (send-transition output 2 3 query-id (failed query-id))
           (send-transition output 3 4 query-id (updated query-id 2))
           ;; A valid change followed by a malformed member rejects the whole
           ;; transaction. Count 777 must never escape before recovery.
           (send-server-frame output #t 9 (string->bytes "transaction-ping"))
           (send-text
            output
            (json-encode
             (transition (version 4) (version 5)
                         (list (updated query-id 777)
                               (json-object "queryId" query-id)))))
           (check (wait-for-disconnect input)
                  "malformed transition retires its socket")
           (close-input-port input)
           (close-output-port output)))

        ;; Automatic recovery after the malformed transaction. Fragment the
        ;; next valid UTF-8 value inside its multibyte character, with a ping
        ;; interleaved, then wait for the first explicit debug disconnect.
        (call-with-values
         (lambda () (accept-live listener 1 4))
         (lambda (input output query-id)
           (let* ((text (json-encode
                         (transition zero-version (version 5)
                                     (list (updated query-id 3 "雪")))))
                  (bytes (string->bytes text))
                  (split-index
                    (let find ((index 0))
                      (if (>= (u8vector-ref bytes index) 128)
                          (+ index 1)
                          (find (+ index 1))))))
             (send-server-frame output #f 1 (slice bytes 0 split-index))
             (send-server-frame output #t 9 (string->bytes "ping"))
             (send-server-frame output #t 0
                                (slice bytes split-index (u8vector-length bytes))))
           (check (wait-for-disconnect input) "fragment ping received a pong")
           (close-input-port input)
           (close-output-port output)))

        ;; First debug reconnect. Rehydrate the unchanged value, then publish a
        ;; new one. The client must suppress the unchanged state.
        (call-with-values
         (lambda () (accept-live listener 2 5))
         (lambda (input output query-id)
           (send-transition output 0 6 query-id (updated query-id 3 "雪"))
           (send-transition output 6 7 query-id (updated query-id 4))
           ;; Invalid UTF-8 must retire this connection without turning into a
           ;; QueryFailed subscription event.
           (send-server-frame output #t 1 #u8(255))
           (wait-for-disconnect input)
           (close-input-port input)
           (close-output-port output)))

        ;; Automatic recovery after invalid UTF-8, followed by a malformed
        ;; reserved opcode to prove frame-level recovery too.
        (call-with-values
         (lambda () (accept-live listener 3 7))
         (lambda (input output query-id)
           (send-transition output 0 8 query-id (updated query-id 5))
           (send-server-frame output #t 3 #u8())
           (wait-for-disconnect input)
           (close-input-port input)
           (close-output-port output)))

        ;; Recovery from the malformed frame. The controller then performs its
        ;; remaining four explicit disconnect/reconnect cycles.
        (call-with-values
         (lambda () (accept-live listener 4 8))
         (lambda (input output query-id)
           (send-transition output 0 9 query-id (updated query-id 6))
           (wait-for-disconnect input)
           (close-input-port input)
           (close-output-port output)))

        (let reconnect-loop ((connection-count 5) (timestamp-number 10)
                             (count 7))
          (call-with-values
           (lambda ()
             (accept-live listener connection-count (- timestamp-number 1)))
           (lambda (input output query-id)
             (send-transition output 0 timestamp-number query-id
                              (updated query-id count))
             (if (< connection-count 8)
                 (begin
                   (wait-for-disconnect input)
                   (close-input-port input)
                   (close-output-port output)
                   (reconnect-loop (+ connection-count 1)
                                   (+ timestamp-number 1)
                                   (+ count 1)))
                 (begin
                   ;; The final connection receives a real Remove before the
                   ;; client acknowledges unsubscribe.
                   (let* ((modify (read-client-json input "ModifyQuerySet"))
                          (remove (car (json-get modify "modifications"))))
                     (check (string=? (json-get remove "type") "Remove")
                            "unsubscribe sends Remove")
                     (send-transition output timestamp-number
                                      (+ timestamp-number 1) query-id
                                      (updated query-id 999)))
                   ;; Keep a control-frame peer continuously readable. The one
                   ;; owner still has to observe close without starvation.
                   (handle-exceptions condition #t
                     (let ping-loop ((remaining 200))
                       (when (> remaining 0)
                         (send-server-frame output #t 9 #u8())
                         (ping-loop (- remaining 1)))))
                   (close-input-port input)
                   (close-output-port output))))))
        (tcp-close listener)))
    'live-fixture)))

(define client
  (make-client (string-append "http://127.0.0.1:" (number->string listen-port))))
(define subscription
  (client-subscribe client "demo:state" (json-object "room" "scheme-live")))

(define (next-update label)
  (let ((update (subscription-next subscription 5.0)))
    (unless update (error 'live-test (string-append "timed out: " label)))
    update))

(check (= (json-get (update-value (next-update "initial")) "count") 0)
       "initial Live value")
(check (= (json-get (update-value (next-update "update")) "count") 1)
       "separate Live update")
(let ((update (next-update "QueryFailed")))
  (check (convex-error? (update-error update)) "QueryFailed typed error")
  (check (string=? (convex-error-name (update-error update)) "FunctionError")
         "QueryFailed name")
  (check (string=? (json-get (convex-error-data (update-error update)) "code")
                   "BROKEN")
         "QueryFailed data"))
(check (= (json-get (update-value (next-update "recovery")) "count") 2)
       "QueryFailed recovery")
(let ((fragmented (next-update "fragmented UTF-8")))
  (check (= (json-get (update-value fragmented) "count") 3)
         "fragmented update")
  (check (string=? (json-get (update-value fragmented) "snow") "雪")
         "fragmented UTF-8 value"))

;; Five explicit fault-injection reconnects. The two malformed-message
;; recoveries happen independently and do not masquerade as query failures.
(client-debug-disconnect! client)
(check (= (json-get (update-value (next-update "first debug reconnect")) "count") 4)
       "unchanged hydration suppressed")
(check (= (json-get (update-value (next-update "invalid UTF-8 recovery")) "count") 5)
       "invalid UTF-8 recovery")
(check (= (json-get (update-value (next-update "malformed frame recovery")) "count") 6)
       "malformed frame recovery")

(let debug-loop ((expected 7) (remaining 4))
  (when (> remaining 0)
    (client-debug-disconnect! client)
    (check (= (json-get (update-value (next-update "debug reconnect")) "count")
              expected)
           "five reconnect sequence")
    (debug-loop (+ expected 1) (- remaining 1))))

(subscription-close! subscription)
(thread-sleep! 0.2)
(check (not (subscription-next subscription 0.1))
       "no ghost event after unsubscribe acknowledgement")

(let ((started (time->seconds (current-time))))
  (client-close! client)
  (check (< (- (time->seconds (current-time)) started) 2.5)
         "bounded close under continuous control frames"))

(let ((joined (thread-join! server 5 'timed-out)))
  (check (not (eq? joined 'timed-out)) "Live fixture terminated"))

(print "live-test: " checks " checks")
