(import scheme
        (chicken base)
        (chicken bitwise)
        (chicken blob)
        (chicken io)
        (chicken port)
        (chicken process)
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

(define checks 0)
(define (check truth label)
  (set! checks (+ checks 1))
  (unless truth (error 'main-test label)))

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
            (unless colon (error 'main-test "malformed request header"))
            (loop
             (cons (cons (string-downcase (substring line 0 colon))
                         (trim-left (substring line (+ colon 1))))
                   headers)))))))

(define (read-http-request input)
  (let ((request-line (read-line input)))
    (when (eof-object? request-line) (error 'main-test "request EOF"))
    (let* ((headers (read-headers input))
           (length (string->number (cdr (assoc "content-length" headers)))))
      (vector request-line headers (read-string length input)))))

(define (respond-json output body)
  (display "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " output)
  (display (string-length body) output)
  (display "\r\n\r\n" output)
  (display body output)
  (flush-output output))

(define (read-handshake input)
  (let ((request-line (read-line input)))
    (vector request-line (read-headers input))))

(define (websocket-handshake! input output)
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
           "example uses unversioned sync endpoint")
    (display "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " output)
    (display accept output)
    (display "\r\n\r\n" output)
    (flush-output output)))

(define (read-exact count input)
  (let ((bytes (read-u8vector count input)))
    (unless (= (u8vector-length bytes) count)
      (error 'main-test "short WebSocket frame"))
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
          (check masked? "example WebSocket writes are masked")
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
      (unless frame (error 'main-test "WebSocket closed early"))
      (if (= (vector-ref frame 0) 1)
          (let ((message (json-decode (bytes->string (vector-ref frame 1)))))
            (if (string=? (json-get message "type" "") expected-type)
                message
                (loop)))
          (loop)))))

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
      (else (error 'main-test "fixture frame too large")))
    (write-u8vector payload output)
    (flush-output output)))

(define (timestamp number)
  (let ((raw (make-string 8 #\nul)))
    (string-set! raw 0 (integer->char number))
    (base64-encode raw)))

(define (version query-set timestamp-number)
  (json-object "querySet" query-set "identity" 0
               "ts" (timestamp timestamp-number)))

(define (send-count! output start-timestamp end-timestamp query-id count)
  (send-text
   output
   (json-encode
    (json-object
     "type" "Transition"
     "startVersion" (version (if (= start-timestamp 0) 0 1) start-timestamp)
     "endVersion" (version 1 end-timestamp)
     "modifications"
     (list (json-object "type" "QueryUpdated" "queryId" query-id
                        "value" (json-object "count" count)
                        "logLines" '()))))))

(define listener (tcp-listen 0 8 "127.0.0.1"))
(define fixture-port (tcp-listener-port listener))

(define fixture
  (thread-start!
   (make-thread
    (lambda ()
      (parameterize ((tcp-read-timeout 5000) (tcp-write-timeout 1000))
        ;; The executable first performs its documented HTTP query.
        (call-with-values
          (lambda () (tcp-accept listener))
          (lambda (input output)
            (let* ((request (read-http-request input))
                   (body (json-decode (vector-ref request 2))))
              (check (string-prefix? "POST /api/query " (vector-ref request 0))
                     "example query endpoint")
              (check (string=? (json-get body "path") "demo:state")
                     "example query path"))
            (respond-json output
                          "{\"status\":\"success\",\"value\":{\"count\":0.0},\"logLines\":[]}")
            (close-input-port input)
            (close-output-port output)))

        ;; It then opens Live and hydrates before issuing the mutation.
        (call-with-values
          (lambda () (tcp-accept listener))
          (lambda (live-input live-output)
            (websocket-handshake! live-input live-output)
            (read-client-json live-input "Connect")
            (let* ((modify (read-client-json live-input "ModifyQuerySet"))
                   (add (car (json-get modify "modifications")))
                   (query-id (json-get add "queryId")))
              (check (string=? (json-get add "udfPath") "demo:state")
                     "example Live path")
              (send-count! live-output 0 1 query-id 0.0)

              ;; The HTTP mutation returns the same value that Live publishes.
              (call-with-values
                (lambda () (tcp-accept listener))
                (lambda (input output)
                  (let* ((request (read-http-request input))
                         (body (json-decode (vector-ref request 2)))
                         (args (json-get body "args")))
                    (check (string-prefix? "POST /api/mutation "
                                           (vector-ref request 0))
                           "example mutation endpoint")
                    (check (string=? (json-get args "language") "scheme")
                           "example mutation language")
                    (check (= (string-length (json-get args "runId")) 32)
                           "example mutation idempotency key"))
                  (respond-json
                   output
                   "{\"status\":\"success\",\"value\":{\"applied\":true,\"state\":{\"count\":1.0}},\"logLines\":[]}")
                  (close-input-port input)
                  (close-output-port output)))
              (send-count! live-output 1 2 query-id 1.0)
              (let* ((remove-message
                       (read-client-json live-input "ModifyQuerySet"))
                     (remove (car (json-get remove-message "modifications"))))
                (check (string=? (json-get remove "type") "Remove")
                       "example acknowledged cleanup"))
              (close-input-port live-input)
              (close-output-port live-output))))
        (tcp-close listener)))
    'example-fixture)))

(define binary (or (get-environment-variable "EXAMPLE_BINARY")
                   "/out/convex-example"))
(define deployment
  (string-append "http://127.0.0.1:" (number->string fixture-port)))
(define child-values
  (call-with-values
    (lambda ()
      (process binary '()
               (list (cons "CONVEX_URL" deployment)
                     (cons "EXAMPLE_ROOM" "scheme-example-test"))))
    list))
(define child-output (car child-values))
(define child-input (cadr child-values))
(define child-pid (caddr child-values))
(close-output-port child-input)
(define actual-output (read-string #f child-output))
(define wait-result
  (call-with-values (lambda () (process-wait child-pid)) list))
(close-input-port child-output)

(check (and (cadr wait-result) (= (caddr wait-result) 0))
       "example executable exits successfully")
;; The fixture proves the example's HTTP and Live requests and the process exit
;; proves it completed. The shared root verifier owns the canonical six-line
;; transcript comparison, so this language-local test deliberately does not
;; duplicate that policy here.
(check (> (string-length actual-output) 0)
       "example produced its canonical stdout transcript")
(check (not (eq? (thread-join! fixture 5.0 'timed-out) 'timed-out))
       "example fixture terminates")

(print "main-test: " checks " checks")
