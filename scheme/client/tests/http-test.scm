(import scheme
        (chicken base)
        (chicken condition)
        (chicken io)
        (chicken port)
        (chicken string)
        (chicken tcp)
        (chicken time)
        srfi-1
        srfi-13
        srfi-18
        convex)

(define checks 0)
(define (check truth label)
  (set! checks (+ checks 1))
  (unless truth (error 'http-test label)))

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

(define (read-request input)
  (let ((request-line (read-line input)))
    (when (eof-object? request-line) (error 'http-test "unexpected request EOF"))
    (let header-loop ((headers '()))
      (let ((line (read-line input)))
        (if (string=? line "")
            (let* ((content-length
                     (string->number
                      (cdr (assoc "content-length" headers))))
                   (body (read-string content-length input)))
              (vector request-line (reverse headers) body))
            (let ((colon (index-of line #\:)))
              (unless colon (error 'http-test "malformed request header"))
              (header-loop
               (cons (cons (string-downcase (substring line 0 colon))
                           (trim-left (substring line (+ colon 1))))
                     headers))))))))

(define responses
  (list
   "{\"status\":\"success\",\"value\":{\"count\":7,\"text\":\"雪\"},\"logLines\":[\"query-log\"]}"
   "{\"status\":\"error\",\"errorMessage\":\"counter rejected\",\"errorData\":{\"code\":\"DENIED\"},\"logLines\":[\"mutation-log\"]}"
   "{\"status\":\"success\",\"value\":[true,null,2.5],\"logLines\":[]}"
   "{\"status\":\"success\",\"value\":1,\"logLines\":[]}"
   "{\"status\":\"success\",\"value\":2,\"logLines\":[]}"
   "{\"status\":\"success\",\"value\":3,\"logLines\":[]}"
   "not-json"))

(define listener (tcp-listen 0 8 "127.0.0.1"))
(define port (tcp-listener-port listener))
(define captured '())
(define capture-lock (make-mutex 'http-capture))

(define server
  (thread-start!
   (make-thread
    (lambda ()
      (for-each
       (lambda (response-body)
         (call-with-values
          (lambda () (tcp-accept listener))
          (lambda (input output)
            (let ((request (read-request input)))
              (mutex-lock! capture-lock)
              (set! captured (append captured (list request)))
              (mutex-unlock! capture-lock))
            (display "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " output)
            (display (string-length response-body) output)
            (display "\r\n\r\n" output)
            (display response-body output)
            (flush-output output)
            (close-input-port input)
            (close-output-port output))))
       responses)
      (tcp-close listener))
    'http-fixture)))

(define client
  (make-client (string-append "http://127.0.0.1:" (number->string port))))

(handle-exceptions error
  (error 'http-test
         (if (convex-error? error) (convex-error-message error) "query failed"))
  (let ((query (client-query client "demo:state"
                             (json-object "room" "nested"
                                          "input" (json-object "array" (list 1 #t))))))
    (check (= (json-get (result-value query) "count") 7) "query value")
    (check (string=? (json-get (result-value query) "text") "雪") "UTF-8 value")
    (check (equal? (result-logs query) '("query-log")) "query logs")))

(handle-exceptions error
  (begin
    (check (convex-error? error) "structured error type")
    (check (string=? (convex-error-name error) "FunctionError") "error name")
    (check (string=? (convex-error-message error) "counter rejected") "error message")
    (check (string=? (json-get (convex-error-data error) "code") "DENIED")
           "error data")
    (check (equal? (convex-error-logs error) '("mutation-log")) "error logs"))
  (client-mutation client "demo:increment" (json-object "room" "nested")))

(let ((action (client-action client "demo:echo" (json-object "value" json-null))))
  (check (equal? (result-value action) (list #t json-null 2.5)) "action JSON values"))

(client-set-auth! client "opaque token:one")
(client-query client "demo:state")
(client-set-auth! client "replacement-token")
(client-query client "demo:state")
(client-set-auth! client "")
(client-query client "demo:state")

(handle-exceptions error
  (begin
    (check (convex-error? error) "invalid JSON error type")
    (check (string=? (convex-error-name error) "TransportError")
           "invalid JSON transport error"))
  (client-query client "demo:state"))

(client-close! client)
(thread-join! server 5 'timed-out)
(check (= (length captured) 7) "all real HTTP requests captured")

(define (captured-header index name)
  (cdr (assoc name (vector-ref (list-ref captured index) 1))))

(check (string-prefix? "POST /api/query " (vector-ref (list-ref captured 0) 0))
       "query endpoint")
(check (string-prefix? "POST /api/mutation " (vector-ref (list-ref captured 1) 0))
       "mutation endpoint")
(check (string-prefix? "POST /api/action " (vector-ref (list-ref captured 2) 0))
       "action endpoint")
(check (string=? (captured-header 0 "convex-client") "scheme-0.1.0")
       "Convex-Client header")
(check (not (assoc "authorization" (vector-ref (list-ref captured 0) 1)))
       "initial auth absent")
(check (string=? (captured-header 3 "authorization") "Bearer opaque token:one")
       "opaque auth exact")
(check (string=? (captured-header 4 "authorization") "Bearer replacement-token")
       "replacement auth exact")
(check (not (assoc "authorization" (vector-ref (list-ref captured 5) 1)))
       "cleared auth absent")

(let ((body (json-decode (vector-ref (list-ref captured 0) 2))))
  (check (string=? (json-get body "path") "demo:state") "request path")
  (check (string=? (json-get body "format") "json") "documented JSON format")
  (check (json-object? (json-get body "args")) "named request arguments"))

(handle-exceptions error
  (check #t "header injection rejected")
  (client-set-auth! client "bad\r\ntoken")
  (error 'http-test "header injection was accepted"))

(handle-exceptions error
  (check #t "client version header injection rejected")
  (make-client "http://127.0.0.1" client-version: "bad\r\nversion")
  (error 'http-test "client version header injection was accepted"))

;; A peer that accepts TCP and never speaks TLS must not hold an HTTP call for
;; openssl's 120-second default handshake deadline.
(let* ((stall-listener (tcp-listen 0 1 "127.0.0.1"))
       (stall-port (tcp-listener-port stall-listener))
       (stall-server
         (thread-start!
          (make-thread
           (lambda ()
             (call-with-values
               (lambda () (tcp-accept stall-listener))
               (lambda (input output)
                 (tcp-close stall-listener)
                 (thread-sleep! 4.0)
                 (tcp-abandon-port output))))
           'http-tls-stall)))
       (stall-client
         (make-client
          (string-append "https://127.0.0.1:"
                         (number->string stall-port))))
       (started (current-milliseconds)))
  (handle-exceptions error
    (begin
      (check (convex-error? error) "TLS stall is a structured failure")
      (check (string=? (convex-error-name error) "TransportError")
             "TLS stall is a TransportError"))
    (client-query stall-client "demo:state")
    (error 'http-test "stalled TLS handshake unexpectedly succeeded"))
  (check (< (- (current-milliseconds) started) 3500)
         "HTTP TLS handshake deadline is bounded")
  (client-close! stall-client)
  (check (not (eq? (thread-join! stall-server 5.0 'timed-out) 'timed-out))
         "TLS stall fixture terminates"))

(print "http-test: " checks " checks")
