(import scheme
        (chicken base)
        (chicken bitwise)
        (chicken blob)
        (chicken io)
        (chicken port)
        (chicken process-context)
        (chicken string)
        (chicken tcp)
        srfi-4
        srfi-13
        srfi-18
        base64
        simple-sha1
        to-hex
        convex)

;; Include the actual adapter loop. Docker sets ADAPTER_LIBRARY_ONLY, so the
;; entrypoint does not run while this test drives it over a real TCP socket.
(include "conformance/adapter.scm")

(define checks 0)
(define (check truth label)
  (set! checks (+ checks 1))
  (unless truth (error 'adapter-live-test label)))

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

(define (read-headers input)
  (let loop ((headers '()))
    (let ((line (read-line input)))
      (if (string=? line "")
          (reverse headers)
          (let ((colon (index-of line #\:)))
            (unless colon (error 'adapter-live-test "malformed header"))
            (loop (cons (cons (string-downcase (substring line 0 colon))
                              (trim-left (substring line (+ colon 1))))
                        headers)))))))

(define (handshake! input output)
  (let* ((request-line (read-line input))
         (headers (read-headers input))
         (key (cdr (assoc "sec-websocket-key" headers)))
         (accept
           (base64-encode
            (hex_to_str
             (make-string 20)
             (string->sha1sum
              (string-append key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
             0 40))))
    (check (string-contains request-line "/api/sync")
           "adapter Live uses sync endpoint")
    (display "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " output)
    (display accept output)
    (display "\r\n\r\n" output)
    (flush-output output)))

(define (read-exact count input)
  (let ((bytes (read-u8vector count input)))
    (unless (= (u8vector-length bytes) count)
      (error 'adapter-live-test "short WebSocket frame"))
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

(define (bytes->string bytes)
  (let ((text (make-string (u8vector-length bytes) #\nul)))
    (let loop ((index 0))
      (when (< index (u8vector-length bytes))
        (string-set! text index (integer->char (u8vector-ref bytes index)))
        (loop (+ index 1))))
    text))

(define (string->bytes text)
  (let ((bytes (make-u8vector (string-length text) 0)))
    (let loop ((index 0))
      (when (< index (string-length text))
        (u8vector-set! bytes index (char->integer (string-ref text index)))
        (loop (+ index 1))))
    bytes))

(define (read-client-frame input)
  (let ((first (read-byte input)))
    (if (eof-object? first)
        #f
        (let* ((second (read-byte input))
               (opcode (bitwise-and first #x0f))
               (masked? (not (= 0 (bitwise-and second #x80))))
               (length (read-network-length input (bitwise-and second #x7f)))
               (mask (and masked? (read-exact 4 input)))
               (payload (read-exact length input)))
          (check masked? "adapter Live frames are masked")
          (let loop ((index 0))
            (when (< index length)
              (u8vector-set! payload index
                             (bitwise-xor (u8vector-ref payload index)
                                          (u8vector-ref mask (modulo index 4))))
              (loop (+ index 1))))
          (vector opcode payload)))))

(define (read-client-json input expected-type)
  (let loop ()
    (let ((frame (read-client-frame input)))
      (unless frame (error 'adapter-live-test "client disconnected early"))
      (if (= (vector-ref frame 0) 1)
          (let ((message (json-decode (bytes->string (vector-ref frame 1)))))
            (if (string=? (json-get message "type" "") expected-type)
                message
                (loop)))
          (loop)))))

(define (wait-disconnect input)
  (let loop ()
    (let ((frame (read-client-frame input)))
      (when frame (loop)))))

(define (send-text output text)
  (let* ((payload (string->bytes text))
         (length (u8vector-length payload)))
    (write-byte #x81 output)
    (cond
      ((< length 126) (write-byte length output))
      ((< length 65536)
       (write-byte 126 output)
       (write-byte (quotient length 256) output)
       (write-byte (modulo length 256) output))
      (else (error 'adapter-live-test "fixture frame too large")))
    (write-u8vector payload output)
    (flush-output output)))

(define (timestamp number)
  (let ((raw (make-string 8 #\nul)))
    (string-set! raw 0 (integer->char number))
    (base64-encode raw)))

(define (version query-set timestamp-number)
  (json-object "querySet" query-set "identity" 0
               "ts" (timestamp timestamp-number)))

(define (updated query-id count)
  (json-object "type" "QueryUpdated" "queryId" query-id
               "value" (json-object "count" count) "logLines" '()))

(define (send-transition! output start-query-set start-timestamp
                          end-query-set end-timestamp modifications)
  (send-text
   output
   (json-encode
    (json-object "type" "Transition"
                 "startVersion" (version start-query-set start-timestamp)
                 "endVersion" (version end-query-set end-timestamp)
                 "modifications" modifications))))

(define live-listener (tcp-listen 0 4 "127.0.0.1"))
(define live-port (tcp-listener-port live-listener))
(set-environment-variable!
 "CONVEX_URL"
 (string-append "http://127.0.0.1:" (number->string live-port)))

(define live-fixture-done? #f)
(define live-fixture
  (thread-start!
   (make-thread
    (lambda ()
      (parameterize ((tcp-read-timeout 7000) (tcp-write-timeout 1000))
        (call-with-values
          (lambda () (tcp-accept live-listener))
          (lambda (input output)
            (handshake! input output)
            (read-client-json input "Connect")
            (let* ((first-add-message
                     (read-client-json input "ModifyQuerySet"))
                   (first-add
                     (car (json-get first-add-message "modifications")))
                   (first-query-id (json-get first-add "queryId")))
              (send-transition! output 0 0 1 1
                                (list (updated first-query-id 0)))

              ;; Same-ID replacement must Remove the old query before Add and
              ;; must ignore a late value for that retired query.
              (let* ((remove-message
                       (read-client-json input "ModifyQuerySet"))
                     (remove (car (json-get remove-message "modifications")))
                     (add-message (read-client-json input "ModifyQuerySet"))
                     (add (car (json-get add-message "modifications")))
                     (second-query-id (json-get add "queryId")))
                (check (string=? (json-get remove "type") "Remove")
                       "replacement sends Remove first")
                (check (string=? (json-get add "type") "Add")
                       "replacement sends Add second")
                (send-transition!
                 output 1 1 3 2
                 (list (updated first-query-id 999)
                       (updated second-query-id 1)))

                ;; debugDisconnect hard-retires this transport before ACK.
                (wait-disconnect input)
                (tcp-abandon-port output)

                (call-with-values
                  (lambda () (tcp-accept live-listener))
                  (lambda (next-input next-output)
                    (handshake! next-input next-output)
                    (let ((connect (read-client-json next-input "Connect")))
                      (check (= (json-get connect "connectionCount") 1)
                             "debug reconnect increments connection count"))
                    (let* ((rehydrate-message
                             (read-client-json next-input "ModifyQuerySet"))
                           (rehydrate
                             (car (json-get rehydrate-message "modifications")))
                           (query-id (json-get rehydrate "queryId")))
                      ;; Rehydrating the unchanged value is suppressed, but the
                      ;; next state remains deliverable on the same subscription.
                      (send-transition! next-output 0 0 1 3
                                        (list (updated query-id 1)))
                      (send-transition! next-output 1 3 1 4
                                        (list (updated query-id 2)))
                      (let* ((last-remove-message
                               (read-client-json next-input "ModifyQuerySet"))
                             (last-remove
                               (car (json-get last-remove-message
                                              "modifications"))))
                        (check (string=? (json-get last-remove "type") "Remove")
                               "unsubscribe reaches owner before ACK"))
                      ;; The owner has removed the query. This valid late
                      ;; transition must not become a ghost adapter event.
                      (send-transition! next-output 1 4 2 5
                                        (list (updated query-id 777)))
                      (thread-sleep! 0.1)
                      (tcp-abandon-port next-output))))))))
        (tcp-close live-listener)
        (set! live-fixture-done? #t)))
    'adapter-live-fixture)))

(define controller-listener (tcp-listen 0 1 "127.0.0.1"))
(define controller-port (tcp-listener-port controller-listener))
(define adapter-server-done? #f)
(define adapter-server
  (thread-start!
   (make-thread
    (lambda ()
      (call-with-values
        (lambda () (tcp-accept controller-listener))
        (lambda (input output)
          (tcp-close controller-listener)
          (adapter-loop input output #t)
          (tcp-abandon-port output)
          (set! adapter-server-done? #t))))
    'adapter-live-controller)))

(define (send-command! output text)
  (display text output)
  (newline output)
  (flush-output output))

(define (read-event input)
  (let ((line (read-line input)))
    (when (eof-object? line) (error 'adapter-live-test "adapter output EOF"))
    (json-decode line)))

(call-with-values
  (lambda () (tcp-connect "127.0.0.1" controller-port))
  (lambda (input output)
    (parameterize ((tcp-read-timeout 7000) (tcp-write-timeout 1000))
      (send-command! output
                     "{\"id\":\"hello\",\"op\":\"hello\",\"protocolVersion\":1}")
      (check (string=? (json-get (read-event input) "type") "ready")
             "adapter ready")

      (send-command! output
                     "{\"id\":\"sub-a\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{\"room\":\"a\"}}")
      (check (string=? (json-get (read-event input) "id") "sub-a")
             "initial subscribe ACK precedes value")
      (check (= (json-get (json-get (read-event input) "value") "count") 0)
             "initial adapter Live value")

      (send-command! output
                     "{\"id\":\"sub-b\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{\"room\":\"b\"}}")
      (check (string=? (json-get (read-event input) "id") "sub-b")
             "replacement ACK precedes new generation")
      (check (= (json-get (json-get (read-event input) "value") "count") 1)
             "replacement drops late old generation")

      (send-command! output
                     "{\"id\":\"debug\",\"op\":\"debugDisconnect\"}")
      (check (string=? (json-get (read-event input) "id") "debug")
             "debug barrier ACK")
      (check (= (json-get (json-get (read-event input) "value") "count") 2)
             "unchanged reconnect hydration suppressed")

      (send-command! output
                     "{\"id\":\"unsub\",\"op\":\"unsubscribe\",\"subscriptionId\":\"same\"}")
      (check (string=? (json-get (read-event input) "id") "unsub")
             "unsubscribe barrier ACK")
      (thread-sleep! 0.2)
      (send-command! output "{\"id\":\"close\",\"op\":\"close\"}")
      (let ((next (read-event input)))
        (check (and (string=? (json-get next "type") "closed")
                    (string=? (json-get next "id") "close"))
               "no ghost subscription event after unsubscribe ACK"))
      (tcp-abandon-port output))))

(let ((deadline (+ (current-seconds) 5.0)))
  (let wait ()
    (unless (and live-fixture-done? adapter-server-done?)
      (when (>= (current-seconds) deadline)
        (error 'adapter-live-test "fixture threads did not terminate"))
      (thread-sleep! 0.01)
      (wait))))
(check live-fixture-done? "adapter Live fixture terminates")
(check adapter-server-done? "adapter controller terminates")

(print "adapter-live-test: " checks " checks")
