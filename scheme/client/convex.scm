(module convex
  (json-null json-null? json-object json-object? json-get json-has?
   json-encode json-decode json-byte-length utf8-valid? utf8-octet-length
   convex-error? convex-error-name convex-error-message convex-error-data
   convex-error-logs convex-error-operation
   result? result-value result-logs
   make-client client? client-set-auth! client-query client-mutation
   client-action client-subscribe client-close! client-debug-disconnect!
   client-live-generation
   subscription? subscription-next subscription-close!
   update? update-value update-logs update-error update-generation)

  (import scheme
          (chicken base)
          (chicken blob)
          (chicken condition)
          (chicken file)
          (chicken io)
          (chicken port)
          (chicken process-context)
          (chicken sort)
          (chicken string)
          (chicken tcp)
          (chicken time)
          (chicken bitwise)
          srfi-1
          srfi-4
          srfi-18
          srfi-69
          base64
          json
          openssl
          simple-sha1)

  (define +max-json-bytes+ (* 2 1024 1024))
  (define +max-json-depth+ 128)
  (define +max-json-nodes+ 8192)
  (define +max-uint32+ 4294967295)

  ;; The json egg maps JSON null to CHICKEN's singleton void value. Keeping the
  ;; representation behind these two procedures avoids leaking that oddity to
  ;; callers of the educational client.
  (define json-null (void))
  (define (json-null? value) (eq? value json-null))

  (define (json-object . pairs)
    (when (odd? (length pairs))
      (error 'json-object "expected alternating string keys and values"))
    (list->vector
     (let loop ((remaining pairs) (result '()))
       (if (null? remaining)
           (reverse result)
           (let ((key (car remaining)))
             (unless (string? key)
               (error 'json-object "object keys must be strings" key))
             (loop (cddr remaining)
                   (cons (cons key (cadr remaining)) result)))))))

  (define (json-object? value)
    (and (vector? value)
         (every (lambda (entry)
                  (and (pair? entry)
                       (or (string? (car entry)) (symbol? (car entry)))))
                (vector->list value))))

  (define (normalise-key key)
    (cond ((string? key) key)
          ((symbol? key) (symbol->string key))
          (else #f)))

  (define (json-entry object key)
    (and (json-object? object)
         (find (lambda (entry)
                 (equal? (normalise-key (car entry)) key))
               (vector->list object))))

  (define (json-get object key #!optional (default #f))
    (let ((entry (json-entry object key)))
      (if entry (cdr entry) default)))

  (define (json-has? object key)
    (and (json-entry object key) #t))

  (define (json-encode value)
    (call-with-output-string
     (lambda (port) (json-write value port))))

  (define (json-byte-length value)
    (utf8-octet-length (json-encode value)))

  ;; CHICKEN strings at this boundary are byte strings. Validate the encoding
  ;; and then count the actual octets, rather than treating a Unicode codepoint
  ;; count as a wire-size estimate.
  (define (utf8-octet-length text)
    (unless (utf8-valid? text)
      (error 'utf8-octet-length "text is not valid UTF-8"))
    (string-length text))

  ;; JSON numbers may be decoded as exact integers or inexact values such as
  ;; 1.0. Normalize only mathematically integral real numbers. integer? also
  ;; rejects NaN and infinities in CHICKEN, so those never reach a range check.
  (define (exact-integral-number value)
    (and (number? value)
         (real? value)
         (integer? value)
         (if (exact? value) value (inexact->exact value))))

  (define (uint32-number value who)
    (let ((number (exact-integral-number value)))
      (unless (and number (<= 0 number +max-uint32+))
        (error who "expected an unsigned 32-bit integer" value))
      number))

  ;; Validate bytes before handing untrusted NDJSON or WebSocket text to the
  ;; parser. CHICKEN strings are byte strings here, which makes the boundary
  ;; checks deterministic even for malformed input.
  (define (utf8-valid? text)
    (and (string? text)
         (let ((length (string-length text)))
           (let loop ((index 0))
             (if (= index length)
                 #t
                 (let ((first (char->integer (string-ref text index))))
                   (cond
                     ((<= first #x7f) (loop (+ index 1)))
                     ((and (<= #xc2 first #xdf)
                           (< (+ index 1) length)
                           (continuation-byte? text (+ index 1)))
                      (loop (+ index 2)))
                     ((and (= first #xe0)
                           (< (+ index 2) length)
                           (byte-between? text (+ index 1) #xa0 #xbf)
                           (continuation-byte? text (+ index 2)))
                      (loop (+ index 3)))
                     ((and (or (<= #xe1 first #xec) (<= #xee first #xef))
                           (< (+ index 2) length)
                           (continuation-byte? text (+ index 1))
                           (continuation-byte? text (+ index 2)))
                      (loop (+ index 3)))
                     ((and (= first #xed)
                           (< (+ index 2) length)
                           (byte-between? text (+ index 1) #x80 #x9f)
                           (continuation-byte? text (+ index 2)))
                      (loop (+ index 3)))
                     ((and (= first #xf0)
                           (< (+ index 3) length)
                           (byte-between? text (+ index 1) #x90 #xbf)
                           (continuation-byte? text (+ index 2))
                           (continuation-byte? text (+ index 3)))
                      (loop (+ index 4)))
                     ((and (<= #xf1 first #xf3)
                           (< (+ index 3) length)
                           (continuation-byte? text (+ index 1))
                           (continuation-byte? text (+ index 2))
                           (continuation-byte? text (+ index 3)))
                      (loop (+ index 4)))
                     ((and (= first #xf4)
                           (< (+ index 3) length)
                           (byte-between? text (+ index 1) #x80 #x8f)
                           (continuation-byte? text (+ index 2))
                           (continuation-byte? text (+ index 3)))
                      (loop (+ index 4)))
                     (else #f))))))))

  (define (byte-between? text index low high)
    (let ((byte (char->integer (string-ref text index))))
      (<= low byte high)))

  (define (continuation-byte? text index)
    (byte-between? text index #x80 #xbf))

  (define (validate-json-shape value)
    (let ((nodes 0))
      (define (walk item depth)
        (set! nodes (+ nodes 1))
        (when (> nodes +max-json-nodes+)
          (error 'json-decode "JSON exceeds structural node limit"))
        (when (> depth +max-json-depth+)
          (error 'json-decode "JSON exceeds nesting limit"))
        (cond
          ((json-object? item)
           (for-each (lambda (entry) (walk (cdr entry) (+ depth 1)))
                     (vector->list item)))
          ((list? item)
           (for-each (lambda (child) (walk child (+ depth 1))) item))))
      (walk value 0)
      value))

  ;; The json egg builds a complete value before returning it. Check the two
  ;; structural budgets lexically first so hostile nesting cannot exhaust the
  ;; 128 MiB runtime before validate-json-shape gets a value to inspect. This
  ;; scanner deliberately understands strings and escapes, so brackets and
  ;; commas inside JSON strings never affect the accounting.
  (define (preflight-json-shape text)
    (let ((length (string-length text)))
      (let loop ((index 0) (depth 0) (nodes 1)
                 (inside-string? #f) (escaped? #f))
        (when (> depth +max-json-depth+)
          (error 'json-decode "JSON exceeds nesting limit"))
        (when (> nodes +max-json-nodes+)
          (error 'json-decode "JSON exceeds structural node limit"))
        (when (< index length)
          (let ((character (string-ref text index)))
            (cond
              (inside-string?
               (cond
                 (escaped?
                  (loop (+ index 1) depth nodes #t #f))
                 ((char=? character #\\)
                  (loop (+ index 1) depth nodes #t #t))
                 ((char=? character #\")
                  (loop (+ index 1) depth nodes #f #f))
                 (else
                  (loop (+ index 1) depth nodes #t #f))))
              ((char=? character #\")
               (loop (+ index 1) depth nodes #t #f))
              ((or (char=? character #\{) (char=? character #\[))
               (loop (+ index 1) (+ depth 1) (+ nodes 1) #f #f))
              ((or (char=? character #\}) (char=? character #\]))
               (loop (+ index 1) (max 0 (- depth 1)) nodes #f #f))
              ((char=? character #\,)
               ;; Each comma introduces at least one additional array item or
               ;; object member, so it is a conservative pre-allocation bound.
               (loop (+ index 1) depth (+ nodes 1) #f #f))
              (else
               (loop (+ index 1) depth nodes #f #f))))))))

  (define (json-decode text)
    (unless (string? text) (error 'json-decode "JSON input must be a string"))
    (when (> (string-length text) +max-json-bytes+)
      (error 'json-decode "JSON exceeds byte limit"))
    (unless (utf8-valid? text) (error 'json-decode "JSON is not valid UTF-8"))
    (preflight-json-shape text)
    (call-with-input-string
     text
     (lambda (port)
       (let ((value (json-read port)))
         (let trailing-loop ((character (read-char port)))
           (cond
             ((eof-object? character) (validate-json-shape value))
             ((char-whitespace? character)
              (trailing-loop (read-char port)))
             (else (error 'json-decode "JSON has trailing data"))))))))

  (define-record-type <convex-error>
    (%make-convex-error name message data logs operation)
    convex-error?
    (name convex-error-name)
    (message convex-error-message)
    (data convex-error-data)
    (logs convex-error-logs)
    (operation convex-error-operation))

  (define-record-printer (<convex-error> condition output)
    (display "#<ConvexError " output)
    (display (convex-error-name condition) output)
    (display ": " output)
    (display (convex-error-message condition) output)
    (display ">" output))

  (define-record-type <result>
    (%make-result value logs)
    result?
    (value result-value)
    (logs result-logs))

  (define-record-type <update>
    (%make-update value logs error generation)
    update?
    (value update-value)
    (logs update-logs)
    (error update-error)
    ;; The adapter uses this owner-stamped transport generation to ensure a
    ;; dequeued update from a retired socket can never cross a debug barrier.
    (generation update-generation))

  (define (make-convex-error name message #!optional
                             (data json-null) (logs '()) (operation #f))
    (%make-convex-error name message data logs operation))

  (define (raise-convex name message #!optional
                        (data json-null) (logs '()) (operation #f))
    (raise (make-convex-error name message data logs operation)))

  (define (condition-message condition)
    (cond
      ((convex-error? condition) (convex-error-message condition))
      ((and (condition? condition)
            ((condition-predicate 'exn) condition))
       (let ((message (get-condition-property condition 'exn 'message #f)))
         (if message (with-output-to-string (lambda () (display message)))
             "Scheme exception")))
      (else (with-output-to-string (lambda () (write condition))))))

  (define-record-type <client>
    (%make-client deployment-url client-version auth-token closed live lock)
    client?
    (deployment-url client-deployment-url)
    (client-version client-version)
    (auth-token client-auth-token client-auth-token-set!)
    (closed client-closed? client-closed-set!)
    (live client-live client-live-set!)
    (lock client-lock))

  (define (string-prefix? prefix text)
    (and (<= (string-length prefix) (string-length text))
         (string=? prefix (substring text 0 (string-length prefix)))))

  (define (string-contains-char? text character)
    (let loop ((index 0))
      (and (< index (string-length text))
           (or (char=? (string-ref text index) character)
               (loop (+ index 1))))))

  (define (string-index-from text character start)
    (let loop ((index start))
      (cond ((>= index (string-length text)) #f)
            ((char=? (string-ref text index) character) index)
            (else (loop (+ index 1))))))

  (define (trim-trailing-slashes text)
    (let loop ((end (string-length text)))
      (if (and (> end 0) (char=? (string-ref text (- end 1)) #\/))
          (loop (- end 1))
          (substring text 0 end))))

  (define (validate-deployment-url deployment-url)
    (unless (and (string? deployment-url)
                 (or (string-prefix? "http://" deployment-url)
                     (string-prefix? "https://" deployment-url))
                 (not (string-contains-char? deployment-url #\newline))
                 (not (string-contains-char? deployment-url #\return))
                 (not (string-contains-char? deployment-url #\#))
                 (not (string-contains-char? deployment-url #\?)))
      (error 'make-client "deployment URL must be an absolute HTTP(S) URL without query or fragment"))
    (let* ((scheme-end (if (string-prefix? "https://" deployment-url) 8 7))
           (authority-end
             (or (string-index-from deployment-url #\/ scheme-end)
                 (string-length deployment-url)))
           (authority (substring deployment-url scheme-end authority-end)))
      (when (or (= (string-length authority) 0)
                (string-contains-char? authority #\@))
        (error 'make-client "deployment URL must not contain credentials")))
    (trim-trailing-slashes deployment-url))

  (define (make-client deployment-url #!key
                       (auth-token "") (client-version "scheme-0.1.0"))
    (unless (and (string? auth-token) (safe-header-value? auth-token))
      (error 'make-client "auth token must be a newline-free string"))
    (unless (and (safe-header-value? client-version)
                 (> (string-length client-version) 0))
      (error 'make-client "client version must be a non-empty newline-free string"))
    (%make-client (validate-deployment-url deployment-url)
                  client-version auth-token #f #f (make-mutex 'convex-client)))

  (define (safe-header-value? value)
    (and (string? value)
         (not (string-contains-char? value #\return))
         (not (string-contains-char? value #\newline))))

  (define (client-set-auth! client token)
    (unless (client? client) (error 'client-set-auth! "expected a client"))
    (unless (safe-header-value? token)
      (error 'client-set-auth! "auth token must be a newline-free string"))
    (mutex-lock! (client-lock client))
    (if (client-closed? client)
        (begin
          (mutex-unlock! (client-lock client))
          (raise-convex "ClosedError" "client is closed"))
        (begin
          (client-auth-token-set! client token)
          (mutex-unlock! (client-lock client))
          #t)))

  (define (client-snapshot client)
    (mutex-lock! (client-lock client))
    (let ((closed (client-closed? client))
          (token (client-auth-token client)))
      (mutex-unlock! (client-lock client))
      (when closed (raise-convex "ClosedError" "client is closed"))
      token))

  (define (valid-path? path)
    (and (string? path)
         (> (string-length path) 2)
         (string-index-from path #\: 0)
         (safe-header-value? path)))

  (define (read-bounded-response port)
    (let ((output (open-output-string)))
      (let loop ((count 0))
        (let ((character (read-char port)))
          (cond
            ((eof-object? character) (get-output-string output))
            ((>= count +max-json-bytes+)
             (raise-convex "TransportError"
                           "HTTP response exceeds 2097152 bytes"))
            (else
             (write-char character output)
             (loop (+ count 1))))))))

  (define (last-index-in text character)
    (let loop ((index (- (string-length text) 1)))
      (cond ((< index 0) #f)
            ((char=? (string-ref text index) character) index)
            (else (loop (- index 1))))))

  (define (validated-port value default who)
    (if (not value)
        default
        (let ((port (string->number value)))
          (unless (and port (integer? port) (exact? port) (<= 1 port 65535))
            (error who "URL port is invalid" value))
          port)))

  (define (deployment-connection deployment-url)
    (let* ((secure? (string-prefix? "https://" deployment-url))
           (scheme-end (if secure? 8 7))
           (authority-end (or (string-index-from deployment-url #\/ scheme-end)
                              (string-length deployment-url)))
           (authority (substring deployment-url scheme-end authority-end)))
      (if (and (> (string-length authority) 0)
               (char=? (string-ref authority 0) #\[))
          (let ((closing (string-index-from authority #\] 1)))
            (unless closing (error 'make-client "IPv6 URL is missing ]"))
            (let ((host (substring authority 1 closing))
                  (port-text
                   (and (< (+ closing 1) (string-length authority))
                        (substring authority (+ closing 2)))))
              (unless (> (string-length host) 0)
                (error 'make-client "URL host must not be empty"))
              (values secure? host
                      (validated-port port-text (if secure? 443 80)
                                      'make-client))))
          (let* ((colon (last-index-in authority #\:))
                 (has-port? (and colon
                                 (not (string-contains-char?
                                       (substring authority (+ colon 1)) #\:))))
                 (host (if has-port? (substring authority 0 colon) authority))
                 (port-text (and has-port?
                                 (substring authority (+ colon 1)))))
            (unless (> (string-length host) 0)
              (error 'make-client "URL host must not be empty"))
            (values secure? host
                    (validated-port port-text (if secure? 443 80)
                                    'make-client))))))

  (define (close-http-port! port)
    (when port
      (handle-exceptions condition #f (close-input-port port))
      (handle-exceptions condition #f (close-output-port port))))

  (define (read-http-response input)
    (let* ((status-line (read-line input))
           (status-code
            (and (string? status-line)
                 (>= (string-length status-line) 12)
                 (string=? (substring status-line 0 5) "HTTP/")
                 (string->number (substring status-line 9 12)))))
      (unless (and status-code (integer? status-code))
        (error 'read-http-response "HTTP status line is invalid"))
      (let header-loop ((line (read-line input)))
        (unless (string? line)
          (error 'read-http-response "HTTP headers ended unexpectedly"))
        (if (string=? line "")
            (values (read-bounded-response input) status-code)
            (header-loop (read-line input))))))

  (define (write-http-request output host path body token version)
    (display "POST " output)
    (display path output)
    (display " HTTP/1.1\r\nHost: " output)
    (display host output)
    (display "\r\nContent-Type: application/json\r\nAccept: application/json\r\nConnection: close\r\nConvex-Client: " output)
    (display version output)
    (display "\r\nContent-Length: " output)
    (display (string-length body) output)
    (display "\r\n" output)
    (unless (string=? token "")
      (display "Authorization: Bearer " output)
      (display token output)
      (display "\r\n" output))
    (display "\r\n" output)
    (display body output)
    (flush-output output))

  (define (http-post-response client operation body token)
    (let-values (((secure? host port)
                  (deployment-connection (client-deployment-url client))))
      (parameterize ((tcp-connect-timeout 5000)
                     (tcp-read-timeout 10000)
                     (tcp-write-timeout 5000)
                     (ssl-handshake-timeout 2000)
                     (ssl-shutdown-timeout 500))
        (call-with-values
          (lambda ()
            (if secure?
                (ssl-connect* hostname: host port: port)
                (tcp-connect host port)))
          (lambda (input output)
            (handle-exceptions condition
              (begin
                (close-http-port! input)
                (close-http-port! output)
                (raise condition))
              (begin
                (write-http-request
                 output host (string-append "/api/" operation)
                 body token (client-version client))
                (let-values (((response-text status-code)
                              (read-http-response input)))
                  (close-http-port! input)
                  (close-http-port! output)
                  (list response-text status-code)))))))))

  (define (call-convex client operation path args)
    (unless (client? client) (error 'call-convex "expected a client"))
    (unless (valid-path? path)
      (error 'call-convex "function path must be module:function"))
    (unless (json-object? args)
      (error 'call-convex "arguments must be a named JSON object"))
    (let* ((token (client-snapshot client))
           (body (json-encode
                  (json-object "path" path "args" args "format" "json")))
           (response-text+status
            (handle-exceptions condition
              (if (convex-error? condition)
                  (raise condition)
                  (raise-convex
                   "TransportError"
                   (string-append operation " transport failed: "
                                  (condition-message condition))
                   json-null '() operation))
              (http-post-response client operation body token)))
           (response-text (car response-text+status))
           (status-code (cadr response-text+status))
           (payload
            (handle-exceptions parse-error
              (raise-convex
               "TransportError"
               (string-append "HTTP " (number->string status-code)
                              " returned non-Convex JSON")
               json-null '() operation)
              (json-decode response-text)))
           (status (json-get payload "status" #f))
           (logs (json-get payload "logLines" '())))
      (unless (and (list? logs) (every string? logs))
        (raise-convex "ProtocolError" "Convex logLines must be an array of strings"
                      json-null '() operation))
      (cond
        ((and (string? status) (string=? status "success")
              (json-has? payload "value"))
         (%make-result (json-get payload "value") logs))
        ((and (string? status) (string=? status "error"))
         (raise-convex
          "FunctionError"
          (let ((message (json-get payload "errorMessage" #f)))
            (if (string? message) message "Convex function failed"))
          (json-get payload "errorData" json-null)
          logs operation))
        (else
         (raise-convex
          "ProtocolError"
          (string-append "HTTP " (number->string status-code)
                         " response has unknown status")
          json-null logs operation)))))

  (define (client-query client path #!optional (args (json-object)))
    (call-convex client "query" path args))

  (define (client-mutation client path #!optional (args (json-object)))
    (call-convex client "mutation" path args))

  (define (client-action client path #!optional (args (json-object)))
    (call-convex client "action" path args))

  ;; Live is deliberately in the same module as HTTP. The example and the
  ;; adapter therefore cannot accidentally exercise a second implementation.
  (define +initial-timestamp+ "AAAAAAAAAAA=")
  (define +initial-backoff+ 0.1)
  (define +maximum-backoff+ 15.0)
  (define +maximum-subscriptions+ 64)
  (define +subscription-byte-limit+ (* 8 1024 1024))
  (define +delivery-count-limit+ 16)
  (define +delivery-byte-limit+ (* 20 1024 1024))
  (define +live-message-byte-limit+ (* 2 1024 1024))

  (define-record-type <subscription>
    (%make-subscription manager query-id path args accounted-size active last-signature)
    subscription?
    (manager subscription-manager)
    (query-id subscription-query-id)
    (path subscription-path)
    (args subscription-args)
    (accounted-size subscription-accounted-size)
    (active subscription-active? subscription-active-set!)
    (last-signature subscription-last-signature subscription-last-signature-set!))

  (define-record-type <owner-response>
    (%make-owner-response lock condition done value error)
    owner-response?
    (lock owner-response-lock)
    (condition owner-response-condition)
    (done owner-response-done? owner-response-done-set!)
    (value owner-response-value owner-response-value-set!)
    (error owner-response-error owner-response-error-set!))

  (define-record-type <live-manager>
    (%make-live-manager deployment-url client-version lock condition commands active
                        next-query-id active-bytes deliveries delivery-bytes closed
                        owner connection-count last-close-reason max-observed-timestamp
                        generation)
    live-manager?
    (deployment-url live-deployment-url)
    (client-version live-client-version)
    (lock live-lock)
    (condition live-condition)
    (commands live-commands live-commands-set!)
    (active live-active)
    (next-query-id live-next-query-id live-next-query-id-set!)
    (active-bytes live-active-bytes live-active-bytes-set!)
    (deliveries live-deliveries live-deliveries-set!)
    (delivery-bytes live-delivery-bytes live-delivery-bytes-set!)
    (closed live-closed? live-closed-set!)
    (owner live-owner live-owner-set!)
    (connection-count live-connection-count live-connection-count-set!)
    (last-close-reason live-last-close-reason live-last-close-reason-set!)
    (max-observed-timestamp live-max-observed-timestamp
                            live-max-observed-timestamp-set!)
    (generation live-generation live-generation-set!))

  (define (now-seconds)
    (time->seconds (current-time)))

  (define (make-owner-response)
    (%make-owner-response (make-mutex 'live-owner-response)
                          (make-condition-variable 'live-owner-response)
                          #f #f #f))

  (define (complete-owner-response! response value)
    (mutex-lock! (owner-response-lock response))
    (unless (owner-response-done? response)
      (owner-response-value-set! response value)
      (owner-response-done-set! response #t)
      (condition-variable-broadcast! (owner-response-condition response)))
    (mutex-unlock! (owner-response-lock response)))

  (define (fail-owner-response! response condition)
    (mutex-lock! (owner-response-lock response))
    (unless (owner-response-done? response)
      (owner-response-error-set! response condition)
      (owner-response-done-set! response #t)
      (condition-variable-broadcast! (owner-response-condition response)))
    (mutex-unlock! (owner-response-lock response)))

  (define (wait-owner-response response timeout operation)
    (let ((deadline (+ (now-seconds) timeout)))
      (let loop ()
        (mutex-lock! (owner-response-lock response))
        (cond
          ((owner-response-done? response)
           (let ((value (owner-response-value response))
                 (condition (owner-response-error response)))
             (mutex-unlock! (owner-response-lock response))
             (if condition (raise condition) value)))
          (else
           (let ((remaining (- deadline (now-seconds))))
             (if (<= remaining 0)
                 (begin
                   (mutex-unlock! (owner-response-lock response))
                   (raise-convex
                    "TransportError"
                    (string-append "timed out waiting for Live owner " operation)))
                 (begin
                   (mutex-unlock! (owner-response-lock response)
                                  (owner-response-condition response)
                                  remaining)
                   (loop)))))))))

  (define (enqueue-owner-command! manager kind data)
    (let ((response (make-owner-response)))
      (mutex-lock! (live-lock manager))
      (if (live-closed? manager)
          (begin
            (mutex-unlock! (live-lock manager))
            (raise-convex "ClosedError" "Live client is closed"))
          (begin
            (live-commands-set!
             manager
             (append (live-commands manager) (list (vector kind data response))))
            (condition-variable-broadcast! (live-condition manager))
            (mutex-unlock! (live-lock manager))
            response))))

  (define (dequeue-owner-command manager)
    (mutex-lock! (live-lock manager))
    (let ((commands (live-commands manager)))
      (if (null? commands)
          (begin (mutex-unlock! (live-lock manager)) #f)
          (let ((command (car commands)))
            (live-commands-set! manager (cdr commands))
            (mutex-unlock! (live-lock manager))
            command))))

  (define (subscription-charge path args)
    ;; Four times the exact wire length pays for byte-string and encoded copies;
    ;; 4096 bytes conservatively covers records, pairs, and queue cells.
    (+ 4096 (* 4 (+ (string-length path) (json-byte-length args)))))

  (define (sorted-active-subscriptions manager)
    (sort (hash-table-values (live-active manager))
          (lambda (left right)
            (< (subscription-query-id left) (subscription-query-id right)))))

  (define (active-subscription manager query-id)
    (hash-table-ref/default (live-active manager) query-id #f))

  (define (delivery-signature update)
    (let ((error (update-error update)))
      (fnv1a-64
       (json-encode
        (if error
            (json-object "error"
                         (json-object "name" (convex-error-name error)
                                      "message" (convex-error-message error)
                                      "data" (convex-error-data error))
                         "logs" (update-logs update))
            (json-object "value" (update-value update)
                         "logs" (update-logs update)))))))

  (define (fnv1a-64 text)
    (let loop ((index 0) (hash 14695981039346656037))
      (if (= index (string-length text))
          hash
          (loop (+ index 1)
                (modulo (* (bitwise-xor hash
                                        (char->integer (string-ref text index)))
                           1099511628211)
                        18446744073709551616)))))

  (define (update-charge update)
    (+ 4096
       (* 4
          (json-byte-length
           (let ((error (update-error update)))
             (if error
                 (json-object "error"
                              (json-object "name" (convex-error-name error)
                                           "message" (convex-error-message error)
                                           "data" (convex-error-data error))
                              "logs" (update-logs update))
                 (json-object "value" (update-value update)
                              "logs" (update-logs update))))))))

  (define (drop-oldest-delivery! manager)
    (let ((deliveries (live-deliveries manager)))
      (when (pair? deliveries)
        (live-deliveries-set! manager (cdr deliveries))
        (live-delivery-bytes-set!
         manager
         (- (live-delivery-bytes manager) (vector-ref (car deliveries) 2))))))

  (define (enqueue-updates-atomically! manager updates)
    ;; Calculate every fallible signature and charge before committing any
    ;; delivery or hydration signature. One bad member therefore rejects the
    ;; whole Transition rather than exposing a partially published state.
    (let ((prepared
            (filter-map
             (lambda (entry)
               (let* ((subscription (car entry))
                      (update (cdr entry))
                      (signature (delivery-signature update)))
                 (and (subscription-active? subscription)
                      (not (equal? signature
                                   (subscription-last-signature subscription)))
                      (let ((size (update-charge update)))
                        (when (> size +delivery-byte-limit+)
                          (error 'enqueue-updates-atomically!
                                 "Live update exceeds global delivery budget"))
                        (vector subscription update signature size)))))
             updates)))
      ;; The owner validates and coalesces a whole Transition before taking
      ;; this lock, then makes its final per-query states visible together.
      (mutex-lock! (live-lock manager))
      (for-each
       (lambda (item)
         (let ((subscription (vector-ref item 0))
               (update (vector-ref item 1))
               (signature (vector-ref item 2))
               (size (vector-ref item 3)))
           (let trim ()
             (when (or (>= (length (live-deliveries manager))
                            +delivery-count-limit+)
                       (> (+ (live-delivery-bytes manager) size)
                          +delivery-byte-limit+))
               (drop-oldest-delivery! manager)
               (trim)))
           (subscription-last-signature-set! subscription signature)
           (live-deliveries-set!
            manager
            (append (live-deliveries manager)
                    (list (vector subscription update size))))
           (live-delivery-bytes-set!
            manager (+ (live-delivery-bytes manager) size))))
       prepared)
      (condition-variable-broadcast! (live-condition manager))
      (mutex-unlock! (live-lock manager))))

  (define (remove-first-delivery deliveries subscription prefix)
    (cond
      ((null? deliveries) (values #f (reverse prefix)))
      ((eq? (vector-ref (car deliveries) 0) subscription)
       (values (car deliveries) (append (reverse prefix) (cdr deliveries))))
      (else
       (remove-first-delivery (cdr deliveries) subscription
                              (cons (car deliveries) prefix)))))

  (define (subscription-next subscription #!optional (timeout 10.0))
    (unless (subscription? subscription)
      (error 'subscription-next "expected a subscription"))
    (let* ((manager (subscription-manager subscription))
           (deadline (+ (now-seconds) timeout)))
      (let loop ()
        (mutex-lock! (live-lock manager))
        (call-with-values
          (lambda ()
            (remove-first-delivery (live-deliveries manager) subscription '()))
          (lambda (delivery remaining)
            (cond
              (delivery
               (live-deliveries-set! manager remaining)
               (live-delivery-bytes-set!
                manager (- (live-delivery-bytes manager) (vector-ref delivery 2)))
               (condition-variable-broadcast! (live-condition manager))
               (mutex-unlock! (live-lock manager))
               (vector-ref delivery 1))
              ((not (subscription-active? subscription))
               (mutex-unlock! (live-lock manager))
               #f)
              (else
               (let ((remaining-time (- deadline (now-seconds))))
                 (if (<= remaining-time 0)
                     (begin (mutex-unlock! (live-lock manager)) #f)
                     (begin
                       (mutex-unlock! (live-lock manager)
                                      (live-condition manager)
                                      remaining-time)
                       (loop)))))))))))

  (define (purge-subscription-deliveries! manager subscription)
    (mutex-lock! (live-lock manager))
    (let loop ((remaining (live-deliveries manager))
               (kept '()) (bytes 0))
      (if (null? remaining)
          (begin
            (live-deliveries-set! manager (reverse kept))
            (live-delivery-bytes-set! manager bytes)
            (condition-variable-broadcast! (live-condition manager))
            (mutex-unlock! (live-lock manager)))
          (let ((delivery (car remaining)))
            (if (eq? (vector-ref delivery 0) subscription)
                (loop (cdr remaining) kept bytes)
                (loop (cdr remaining) (cons delivery kept)
                      (+ bytes (vector-ref delivery 2))))))))

  (define (base64-value character)
    (cond
      ((and (char<=? #\A character) (char<=? character #\Z))
       (- (char->integer character) 65))
      ((and (char<=? #\a character) (char<=? character #\z))
       (+ 26 (- (char->integer character) 97)))
      ((and (char<=? #\0 character) (char<=? character #\9))
       (+ 52 (- (char->integer character) 48)))
      ((char=? character #\+) 62)
      ((char=? character #\/) 63)
      (else #f)))

  (define +base64-alphabet+
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

  (define (timestamp-encode number)
    (unless (and (integer? number) (exact? number)
                 (<= 0 number 18446744073709551615))
      (error 'timestamp-encode "timestamp is outside uint64"))
    (let ((bytes (make-vector 8 0)))
      (let fill ((index 0) (remaining number))
        (when (< index 8)
          (vector-set! bytes index (modulo remaining 256))
          (fill (+ index 1) (quotient remaining 256))))
      (let ((output (make-string 12 #\=)))
        (let groups ((byte-index 0) (char-index 0))
          (cond
            ((<= (+ byte-index 3) 8)
             (let ((a (vector-ref bytes byte-index))
                   (b (vector-ref bytes (+ byte-index 1)))
                   (c (vector-ref bytes (+ byte-index 2))))
               (string-set! output char-index
                            (string-ref +base64-alphabet+ (quotient a 4)))
               (string-set! output (+ char-index 1)
                            (string-ref +base64-alphabet+
                                        (+ (* (modulo a 4) 16) (quotient b 16))))
               (string-set! output (+ char-index 2)
                            (string-ref +base64-alphabet+
                                        (+ (* (modulo b 16) 4) (quotient c 64))))
               (string-set! output (+ char-index 3)
                            (string-ref +base64-alphabet+ (modulo c 64)))
               (groups (+ byte-index 3) (+ char-index 4))))
            ((= byte-index 6)
             (let ((a (vector-ref bytes 6)) (b (vector-ref bytes 7)))
               (string-set! output 8
                            (string-ref +base64-alphabet+ (quotient a 4)))
               (string-set! output 9
                            (string-ref +base64-alphabet+
                                        (+ (* (modulo a 4) 16) (quotient b 16))))
               (string-set! output 10
                            (string-ref +base64-alphabet+ (* (modulo b 16) 4)))))))
        output)))

  (define (timestamp-decode text)
    (unless (and (string? text) (= (string-length text) 12)
                 (char=? (string-ref text 11) #\=))
      (error 'timestamp-decode "timestamp is not canonical base64 uint64"))
    (let ((values (make-vector 11 0)))
      (let loop ((index 0))
        (when (< index 11)
          (let ((value (base64-value (string-ref text index))))
            (unless value
              (error 'timestamp-decode "timestamp contains invalid base64"))
            (vector-set! values index value)
            (loop (+ index 1)))))
      (unless (= (modulo (vector-ref values 10) 4) 0)
        (error 'timestamp-decode "timestamp base64 has non-zero padding bits"))
      (let ((bytes (make-vector 8 0)))
        (let groups ((char-index 0) (byte-index 0))
          (when (< byte-index 8)
            (let ((v0 (vector-ref values char-index))
                  (v1 (vector-ref values (+ char-index 1)))
                  (v2 (vector-ref values (+ char-index 2))))
              (vector-set! bytes byte-index (+ (* v0 4) (quotient v1 16)))
              (vector-set! bytes (+ byte-index 1)
                           (+ (* (modulo v1 16) 16) (quotient v2 4)))
              (when (< (+ byte-index 2) 8)
                (vector-set! bytes (+ byte-index 2)
                             (+ (* (modulo v2 4) 64)
                                (vector-ref values (+ char-index 3)))))
              (groups (+ char-index 4) (+ byte-index 3)))))
        (let accumulate ((index 7) (number 0))
          (if (< index 0)
              (begin
                (unless (string=? text (timestamp-encode number))
                  (error 'timestamp-decode "timestamp is not canonical"))
                number)
              (accumulate (- index 1)
                          (+ (* number 256) (vector-ref bytes index))))))))

  (define (version-object query-set identity timestamp)
    (json-object "querySet" query-set "identity" identity "ts" timestamp))

  (define (valid-version object)
    (unless (json-object? object)
      (error 'valid-version "Live state version must be an object"))
    (let ((query-set (json-get object "querySet" #f))
          (identity (json-get object "identity" #f))
          (timestamp (json-get object "ts" #f)))
      (set! query-set (uint32-number query-set 'valid-version))
      (set! identity (uint32-number identity 'valid-version))
      (unless (string? timestamp)
        (error 'valid-version "Live state version timestamp must be a string"))
      (timestamp-decode timestamp)
      (vector query-set identity timestamp)))

  (define (version=? left right)
    (and (= (vector-ref left 0) (vector-ref right 0))
         (= (vector-ref left 1) (vector-ref right 1))
         (string=? (vector-ref left 2) (vector-ref right 2))))

  (define (zero-version)
    (vector 0 0 +initial-timestamp+))

  (define (client-live-generation client)
    ;; The adapter uses this owner-published generation as a second check after
    ;; dequeue. It closes the automatic transport-failure race where a relay
    ;; has already removed an old update from the manager queue.
    (unless (client? client) (error 'client-live-generation "expected a client"))
    (mutex-lock! (client-lock client))
    (let ((manager (client-live client)))
      (mutex-unlock! (client-lock client))
      (if manager (live-generation manager) 0)))

  (define (hex-digit number)
    (string-ref "0123456789abcdef" number))

  (define (session-id)
    (call-with-input-file
     "/dev/urandom"
     (lambda (port)
       (let ((bytes (read-u8vector 16 port)))
         (unless (= (u8vector-length bytes) 16)
           (error 'session-id "could not read /dev/urandom"))
         (let ((result (make-string 32 #\0)))
           (let loop ((index 0))
             (when (< index 16)
               (let ((byte (u8vector-ref bytes index)))
                 (string-set! result (* index 2) (hex-digit (quotient byte 16)))
                 (string-set! result (+ (* index 2) 1) (hex-digit (modulo byte 16)))
                 (loop (+ index 1)))))
           result)))))

  (define (live-url deployment-url)
    (string-append
     (cond
       ((string-prefix? "https://" deployment-url)
        (string-append "wss://" (substring deployment-url 8)))
       (else (string-append "ws://" (substring deployment-url 7))))
     "/api/sync"))

  (define (query-modification kind subscription)
    (if (eq? kind 'add)
        (json-object "type" "Add"
                     "queryId" (subscription-query-id subscription)
                     "udfPath" (subscription-path subscription)
                     "args" (list (subscription-args subscription)))
        (json-object "type" "Remove"
                     "queryId" (subscription-query-id subscription))))

  (define (u8vector->byte-string bytes #!optional
                                 (length (u8vector-length bytes)))
    (let ((text (make-string length #\nul)))
      (let loop ((index 0))
        (when (< index length)
          (string-set! text index (integer->char (u8vector-ref bytes index)))
          (loop (+ index 1))))
      text))

  (define (byte-string->u8vector text)
    (let ((bytes (make-u8vector (string-length text) 0)))
      (let loop ((index 0))
        (when (< index (string-length text))
          (u8vector-set! bytes index (char->integer (string-ref text index)))
          (loop (+ index 1))))
      bytes))

  (define (join-chunks chunks size)
    (let ((result (make-u8vector size 0)))
      (let outer ((remaining (reverse chunks)) (offset 0))
        (if (null? remaining)
            result
            (let* ((chunk (car remaining))
                   (length (u8vector-length chunk)))
              (let inner ((index 0))
                (when (< index length)
                  (u8vector-set! result (+ offset index)
                                 (u8vector-ref chunk index))
                  (inner (+ index 1))))
              (outer (cdr remaining) (+ offset length)))))))

  ;; Keep the WebSocket transport in this module so the demonstration remains
  ;; a native Scheme client. The wire format is small enough to audit directly
  ;; and avoids delegating Convex Live to a second client runtime.
  (define-record-type <live-socket>
    (%make-live-socket input output)
    live-socket?
    (input live-socket-input)
    (output live-socket-output))

  (define-record-type <websocket-frame>
    (%make-websocket-frame fin? opcode masked? payload)
    websocket-frame?
    (fin? frame-fin?)
    (opcode frame-opcode)
    (masked? frame-mask?)
    (payload frame-payload-data))

  (define (frame-optype frame)
    (case (frame-opcode frame)
      ((1) 'text) ((2) 'binary) ((0) 'continuation)
      ((8) 'connection-close) ((9) 'ping) ((10) 'pong)
      (else 'unsupported)))

  (define (frame-payload-length frame)
    (u8vector-length (frame-payload-data frame)))

  (define (random-bytes count)
    (call-with-input-file
     "/dev/urandom"
     (lambda (port)
       (let ((bytes (read-u8vector count port)))
         (unless (= (u8vector-length bytes) count)
           (error 'random-bytes "could not read secure random bytes"))
         bytes))))

  (define (hex-digit-value character)
    (cond ((and (char<=? #\0 character) (char<=? character #\9))
           (- (char->integer character) (char->integer #\0)))
          ((and (char<=? #\a character) (char<=? character #\f))
           (+ 10 (- (char->integer character) (char->integer #\a))))
          ((and (char<=? #\A character) (char<=? character #\F))
           (+ 10 (- (char->integer character) (char->integer #\A))))
          (else #f)))

  (define (hex-string->byte-string text)
    (unless (and (string? text) (even? (string-length text)))
      (error 'hex-string->byte-string "expected an even-length hexadecimal string"))
    (let ((result (make-string (/ (string-length text) 2) #\nul)))
      (let loop ((index 0))
        (when (< index (string-length result))
          (let ((high (hex-digit-value (string-ref text (* index 2))))
                (low (hex-digit-value (string-ref text (+ (* index 2) 1)))))
            (unless (and high low)
              (error 'hex-string->byte-string "invalid hexadecimal string"))
            (string-set! result index
                         (integer->char (+ (* high 16) low)))
            (loop (+ index 1)))))
      result))

  (define (write-u16 output value)
    (write-byte (quotient value 256) output)
    (write-byte (modulo value 256) output))

  (define (read-u16 bytes)
    (+ (* 256 (u8vector-ref bytes 0)) (u8vector-ref bytes 1)))

  (define (write-u64 output value)
    (let loop ((index 7) (remaining value))
      (when (>= index 0)
        (let ((divisor (expt 256 index)))
          (write-byte (modulo (quotient remaining divisor) 256) output)
          (loop (- index 1) remaining)))))

  (define (read-exact-u8vector input count)
    ;; A stream read may return fewer bytes than requested without reaching
    ;; EOF. Read one byte at a time so a fragmented TCP delivery never shifts
    ;; the WebSocket parser to a false frame boundary.
    (let ((bytes (make-u8vector count 0)))
      (let loop ((index 0))
        (if (= index count)
            bytes
            (let ((byte (read-byte input)))
              (if (eof-object? byte)
                  (signal (make-composite-condition
                           (make-property-condition 'websocket)
                           (make-property-condition 'exn
                                                    'message "WebSocket EOF")))
                  (begin
                    (u8vector-set! bytes index byte)
                    (loop (+ index 1)))))))))

  (define (read-u64 bytes)
    (let loop ((index 0) (value 0))
      (if (= index 8)
          value
          (loop (+ index 1)
                (+ (* value 256) (u8vector-ref bytes index))))))

  (define (websocket-endpoint endpoint)
    (let* ((secure? (string-prefix? "wss://" endpoint))
           (scheme-length (if secure? 6 5))
           (authority-end (or (string-index-from endpoint #\/ scheme-length)
                              (string-length endpoint)))
           (authority (substring endpoint scheme-length authority-end))
           (path (if (< authority-end (string-length endpoint))
                     (substring endpoint authority-end)
                     "/")))
      ;; deployment-connection returns multiple values, so capture them with
      ;; let-values instead of accidentally treating the values as a list.
      (let-values (((_secure host port)
                    (deployment-connection
                     (string-append (if secure? "https://" "http://") authority))))
        (list secure? host port path))))

  (define (read-websocket-response input expected-accept)
    (define (lowercase-ascii text)
      (list->string
       (map (lambda (character)
              (if (and (char<=? #\A character) (char<=? character #\Z))
                  (integer->char (+ (char->integer character) 32))
                  character))
            (string->list text))))
    (define (trim-space text)
      (let* ((length (string-length text))
             (start (let loop ((index 0))
                      (if (and (< index length)
                               (char-whitespace? (string-ref text index)))
                          (loop (+ index 1))
                          index)))
             (end (let loop ((index length))
                    (if (and (> index start)
                             (char-whitespace? (string-ref text (- index 1))))
                        (loop (- index 1))
                        index))))
        (substring text start end)))
    (let ((status (read-line input)))
      (unless (and (string? status)
                   (string-prefix? "HTTP/1.1 101 " status))
        (error 'ws-connect "WebSocket upgrade was rejected"))
      (let loop ((accept #f) (count 0))
        (when (> count 64)
          (error 'ws-connect "WebSocket handshake has too many headers"))
        (let ((line (read-line input)))
          (cond
            ((eof-object? line)
             (error 'ws-connect "WebSocket handshake ended unexpectedly"))
            ((string=? (trim-space line) "")
             (unless (and accept (string=? accept expected-accept))
               (error 'ws-connect "WebSocket accept key did not match")))
            (else
             (let ((colon (string-index-from line #\: 0)))
               (unless colon
                 (error 'ws-connect "malformed WebSocket handshake header"))
               (let ((name (lowercase-ascii (substring line 0 colon)))
                     (value (trim-space (substring line (+ colon 1)))))
                 (loop (if (string=? name "sec-websocket-accept") value accept)
                       (+ count 1))))))))))

  (define (optype->opcode kind)
    (case kind ((text) 1) ((binary) 2) ((continuation) 0)
          ((connection-close) 8) ((ping) 9) ((pong) 10)
          (else (error 'optype->opcode "unsupported WebSocket opcode" kind))))

  ;; Preserve the small constructor shape used by the Live state machine while
  ;; the transport record keeps only the fields the client actually needs.
  (define (make-ws-frame fin? _rsv opcode masked length payload)
    (unless (= length (u8vector-length payload))
      (error 'make-ws-frame "frame length does not match payload"))
    (%make-websocket-frame fin? opcode masked payload))

  (define (ws-connect endpoint headers)
    (let* ((parts (websocket-endpoint endpoint))
           (secure? (car parts))
           (host (cadr parts))
           (port (caddr parts))
           (path (cadddr parts))
           (input #f)
           (output #f)
           (key (base64-encode (u8vector->byte-string (random-bytes 16))))
           (expected-accept
             (base64-encode
              (hex-string->byte-string
               (string->sha1sum
                (string-append key
                               "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))))))
      (handle-exceptions condition
        (begin
          (when input (handle-exceptions ignored #f (close-input-port input)))
          (when output (handle-exceptions ignored #f (close-output-port output)))
          (raise condition))
        (let-values (((new-input new-output)
                      (parameterize ((tcp-connect-timeout 2000)
                                     (tcp-read-timeout 1000)
                                     (tcp-write-timeout 1000)
                                     ;; ssl-connect* defers the handshake until
                                     ;; the first write, so keep this deadline
                                     ;; below the public Live close bound.
                                     (ssl-handshake-timeout 500))
                      (if secure?
                          (ssl-connect* hostname: host port: port)
                          (tcp-connect host port)))))
          (set! input new-input)
          (set! output new-output)
          (parameterize ((tcp-read-timeout 1000)
                         (tcp-write-timeout 1000)
                         (ssl-handshake-timeout 500)
                         (ssl-shutdown-timeout 500))
            (display (string-append "GET " path " HTTP/1.1\r\n"
                                    "Host: " host "\r\n"
                                    "Upgrade: websocket\r\n"
                                    "Connection: Upgrade\r\n"
                                    "Sec-WebSocket-Key: " key "\r\n"
                                    "Sec-WebSocket-Version: 13\r\n"
                                    "Convex-Client: " (car headers) "\r\n\r\n")
                     output)
            (flush-output output)
            (read-websocket-response input expected-accept)
            (%make-live-socket input output))))))

  (define (ws-disconnect! socket)
    (handle-exceptions ignored #f
      (close-input-port (live-socket-input socket)))
    (handle-exceptions ignored #f
      (close-output-port (live-socket-output socket))))

  (define (ws-close socket)
    (let ((payload (make-u8vector 2 0)))
      (u8vector-set! payload 0 3)
      (u8vector-set! payload 1 232)
      (send-frame socket (%make-websocket-frame #t 8 #t payload))))

  (define (ws-data-ready? socket)
    (char-ready? (live-socket-input socket)))

  (define (send-frame socket frame)
    (let* ((output (live-socket-output socket))
           (payload (frame-payload-data frame))
           (length (u8vector-length payload))
           (mask (random-bytes 4)))
      (write-byte (+ #x80 (frame-opcode frame)) output)
      (cond ((< length 126) (write-byte (+ #x80 length) output))
            ((< length 65536)
             (write-byte #xfe output)
             (write-u16 output length))
            (else
             (write-byte #xff output)
             (write-u64 output length)))
      (write-u8vector mask output)
      (let ((encoded (make-u8vector length 0)))
        (let loop ((index 0))
          (when (< index length)
            (u8vector-set! encoded index
                           (bitwise-xor (u8vector-ref payload index)
                                        (u8vector-ref mask (modulo index 4))))
            (loop (+ index 1))))
        (write-u8vector encoded output))
      (flush-output output)))

  (define (send-text-message socket text)
    (send-frame socket
                (%make-websocket-frame #t 1 #t
                                       (byte-string->u8vector text))))

  (define (recv-frame socket)
    (let* ((input (live-socket-input socket))
           (first (read-byte input)))
      (when (eof-object? first)
        (signal (make-composite-condition
                 (make-property-condition 'websocket)
                 (make-property-condition 'exn 'message "WebSocket EOF"))))
      (let* ((second (read-byte input))
             (_second-check
              (unless (number? second)
                (signal (make-composite-condition
                         (make-property-condition 'websocket)
                         (make-property-condition 'exn
                                                  'message "WebSocket EOF")))))
             (fin? (not (zero? (bitwise-and first #x80))))
             (opcode (bitwise-and first #x0f))
             (masked? (not (zero? (bitwise-and second #x80))))
             (marker (bitwise-and second #x7f))
             (length
               (cond ((< marker 126) marker)
                     ((= marker 126)
                      (read-u16 (read-exact-u8vector input 2)))
                     (else (read-u64 (read-exact-u8vector input 8))))))
        (when masked? (error 'recv-frame "server WebSocket frame was masked"))
        (when (and (member opcode '(8 9 10))
                   (or (not fin?) (> length 125)))
          (error 'recv-frame "invalid WebSocket control frame"))
        (when (or (and (= marker 126) (< length 126))
                  (and (= marker 127) (< length 65536))
                  (>= length 9223372036854775808)
                  (> length +live-message-byte-limit+))
          (error 'recv-frame "invalid or oversized WebSocket frame"))
        (%make-websocket-frame fin? opcode #f
                               (read-exact-u8vector input length)))))

  (define (timeout-condition? condition)
    (and (condition? condition) ((condition-predicate 'timeout) condition)))

  (define (condition-kind? condition kind)
    (and (condition? condition) ((condition-predicate kind) condition)))

  (define (transport-condition? condition)
    (or (timeout-condition? condition)
        (condition-kind? condition 'i/o)
        ;; Native frame reads represent an EOF as websocket + exn. Protocol
        ;; failures instead carry the distinct fail component.
        (and (condition-kind? condition 'websocket)
             (condition-kind? condition 'exn)
             (not (condition-kind? condition 'fail)))))

  (define (close-frame-valid? frame)
    (let* ((length (frame-payload-length frame))
           (data (frame-payload-data frame)))
      (cond
        ((= length 0) #t)
        ((= length 1) #f)
        (else
         (let ((code (+ (* 256 (u8vector-ref data 0)) (u8vector-ref data 1))))
           (and (or (member code '(1000 1001 1002 1003 1007 1008 1009 1010 1011))
                    (<= 3000 code 4999))
                (utf8-valid?
                 (let ((reason (make-u8vector (- length 2) 0)))
                   (let loop ((index 2))
                     (when (< index length)
                       (u8vector-set! reason (- index 2) (u8vector-ref data index))
                       (loop (+ index 1))))
                   (u8vector->byte-string reason)))))))))

  (define (log-lines value)
    (unless (and (list? value) (every string? value))
      (error 'log-lines "Live logLines must be an array of strings"))
    value)

  (define (coalesce-change changes item)
    (cons item
          (filter (lambda (existing) (not (= (car existing) (car item))))
                  changes)))

  (define (live-owner-loop manager)
    ;; This thread alone opens, reads, writes, retires, and reconnects the
    ;; WebSocket. API calls communicate with it through acknowledged commands.
    (let ((socket #f)
          (remote-version (zero-version))
          (query-set-version 0)
          (next-connect-at #f)
          (backoff +initial-backoff+)
          (fragment-kind #f)
          (fragment-chunks '())
          (fragment-size 0)
          (stop? #f))
      (define (reset-fragments!)
        (set! fragment-kind #f)
        (set! fragment-chunks '())
        (set! fragment-size 0))

      (define (send-json! value)
        (send-text-message socket (json-encode value)))

      (define (schedule-reconnect! delay)
        (set! next-connect-at (+ (now-seconds) delay))
        (set! backoff (min +maximum-backoff+ (* backoff 2))))

      (define (disconnect-socket! #!optional (graceful #f))
        (when socket
          (parameterize ((ssl-shutdown-timeout 500)
                         (tcp-write-timeout 500))
            (when graceful
              (handle-exceptions condition #f
                (ws-close socket)))
            ;; Close the ports after the optional close frame. The owner
            ;; generation is advanced below, so no old relay can cross a
            ;; command acknowledgement barrier.
            (handle-exceptions condition #f (ws-disconnect! socket)))
          (set! socket #f)
          (live-generation-set! manager (+ (live-generation manager) 1))
          (live-connection-count-set!
           manager (+ (live-connection-count manager) 1))))

      (define (retire! reason reconnect? #!optional (graceful #f))
        (disconnect-socket! graceful)
        (live-last-close-reason-set! manager reason)
        (set! query-set-version 0)
        (set! remote-version (zero-version))
        (reset-fragments!)
        (if (and reconnect? (pair? (sorted-active-subscriptions manager)))
            (schedule-reconnect! backoff)
            (set! next-connect-at #f)))

      (define (purge-live-deliveries!)
        (mutex-lock! (live-lock manager))
        (live-deliveries-set! manager '())
        (live-delivery-bytes-set! manager 0)
        (condition-variable-broadcast! (live-condition manager))
        (mutex-unlock! (live-lock manager)))

      (define (rebase-live-deliveries!)
        ;; A valid update received before a transport failure must remain ahead
        ;; of the structured failure event. Retiring increments the owner
        ;; generation, so stamp queued values with that new generation while
        ;; retaining their order and byte charges. Explicit
        ;; unsubscribe/replacement barriers still purge their deliveries.
        (mutex-lock! (live-lock manager))
        (live-deliveries-set!
         manager
         (map
          (lambda (delivery)
            (let ((update (vector-ref delivery 1)))
              (vector (vector-ref delivery 0)
                      (%make-update (update-value update)
                                    (update-logs update)
                                    (update-error update)
                                    (live-generation manager))
                      (vector-ref delivery 2))))
          (live-deliveries manager)))
        (condition-variable-broadcast! (live-condition manager))
        (mutex-unlock! (live-lock manager)))

      (define (publish-recoverable-error! name message)
        (let ((generation (live-generation manager)))
          (enqueue-updates-atomically!
           manager
           (map (lambda (subscription)
                  (cons subscription
                        (%make-update
                         json-null '()
                         (make-convex-error name message json-null '() "query")
                         generation)))
                (sorted-active-subscriptions manager)))))

      (define (retire-with-condition! condition)
        (let* ((message (condition-message condition))
               (name (if (transport-condition? condition)
                         "TransportError" "ProtocolError")))
          ;; Retire first. This increments the owner generation. Queued values
          ;; are rebased so they remain before the failure, while a paused
          ;; relay still fails its generation check.
          (retire! message #t)
          (rebase-live-deliveries!)
          (handle-exceptions publish-condition #f
            (publish-recoverable-error! name message))))

      (define (connect-message)
        (apply json-object
               (append
                (list "type" "Connect"
                      "sessionId" (session-id)
                      "connectionCount" (live-connection-count manager)
                      "lastCloseReason" (live-last-close-reason manager)
                      "clientTs" 0)
                (if (> (live-max-observed-timestamp manager) 0)
                    (list "maxObservedTimestamp"
                          (timestamp-encode
                           (live-max-observed-timestamp manager)))
                    '()))))

      (define (connect-now!)
        (handle-exceptions condition
          (begin
            (when socket (disconnect-socket!))
            (live-connection-count-set!
             manager (+ (live-connection-count manager) 1))
            (live-last-close-reason-set! manager (condition-message condition))
            (schedule-reconnect! backoff)
            #f)
          (let ((candidate
                  (ws-connect (live-url (live-deployment-url manager))
                              (list (live-client-version manager)))))
            (unless (live-socket? candidate)
              (error 'connect-now! "WebSocket upgrade was rejected"))
            (set! socket candidate))
          (send-json! (connect-message))
          (let ((subscriptions (sorted-active-subscriptions manager)))
            (when (pair? subscriptions)
              (send-json!
               (json-object
                "type" "ModifyQuerySet"
                "baseVersion" 0
                "newVersion" 1
                "modifications"
                (map (lambda (subscription)
                       (query-modification 'add subscription))
                     subscriptions)))
              (set! query-set-version 1)))
          (set! remote-version (zero-version))
          (set! next-connect-at #f)
          (set! backoff +initial-backoff+)
          (reset-fragments!)
          #t))

      (define (send-modification! kind subscription)
        (unless socket (error 'send-modification! "Live socket is not connected"))
        (when (= query-set-version +max-uint32+)
          (error 'send-modification! "Live query-set version exhausted"))
        (send-json!
         (json-object "type" "ModifyQuerySet"
                      "baseVersion" query-set-version
                      "newVersion" (+ query-set-version 1)
                      "modifications"
                      (list (query-modification kind subscription))))
        (set! query-set-version (+ query-set-version 1)))

      (define (remove-active! subscription)
        (when (active-subscription manager (subscription-query-id subscription))
          (hash-table-delete! (live-active manager)
                              (subscription-query-id subscription))
          (live-active-bytes-set!
           manager (- (live-active-bytes manager)
                      (subscription-accounted-size subscription))))
        (subscription-active-set! subscription #f)
        (purge-subscription-deliveries! manager subscription))

      (define (process-subscribe-command! data response)
        (let* ((path (car data))
               (args (cadr data))
               (charge (subscription-charge path args)))
          (when (or (>= (hash-table-size (live-active manager))
                        +maximum-subscriptions+)
                    (> (+ (live-active-bytes manager) charge)
                       +subscription-byte-limit+))
            (raise-convex "ProtocolError" "Live subscription capacity exceeded"))
          (when (>= (live-next-query-id manager) +max-uint32+)
            (raise-convex "ProtocolError" "Live query ID space exhausted"))
          (let* ((query-id (live-next-query-id manager))
                 (subscription
                   (%make-subscription manager query-id path args charge #t #f)))
            (live-next-query-id-set! manager (+ query-id 1))
            (hash-table-set! (live-active manager) query-id subscription)
            (live-active-bytes-set! manager (+ (live-active-bytes manager) charge))
            (handle-exceptions condition
              (begin
                ;; If the write may have partially happened, retire the socket
                ;; before failing the acknowledgement. No stale Add can cross it.
                (retire! (condition-message condition) #t)
                (remove-active! subscription)
                (fail-owner-response!
                 response
                 (make-convex-error
                  "TransportError"
                  (string-append "Live subscribe failed: "
                                 (condition-message condition)))))
              (if socket
                  (send-modification! 'add subscription)
                  (unless (connect-now!)
                    (error 'process-subscribe-command!
                           (string-append
                            "Live WebSocket connection failed: "
                            (live-last-close-reason manager)))))
              (complete-owner-response! response subscription)))))

      (define (process-unsubscribe-command! subscription response)
        (handle-exceptions condition
          (begin
            (retire! (condition-message condition) #t)
            (remove-active! subscription)
            ;; Retirement is a valid Remove barrier: the old generation cannot
            ;; publish anything even though its final write failed.
            (complete-owner-response! response #t))
          (when (and socket
                     (active-subscription manager
                                          (subscription-query-id subscription)))
            (send-modification! 'remove subscription))
          (remove-active! subscription)
          (complete-owner-response! response #t)))

      (define (process-owner-command! command)
        (let ((kind (vector-ref command 0))
              (data (vector-ref command 1))
              (response (vector-ref command 2)))
          (case kind
            ((subscribe)
             (handle-exceptions condition
               (fail-owner-response! response condition)
               (process-subscribe-command! data response)))
            ((unsubscribe)
             (process-unsubscribe-command! data response))
            ((debug-disconnect)
             (if socket
                 (begin
                   ;; Fault injection is a hard drop. Ack only after the old
                   ;; transport is retired and the reconnect has been scheduled.
                   (disconnect-socket!)
                   (live-last-close-reason-set! manager "DebugDisconnect")
                   (set! query-set-version 0)
                   (set! remote-version (zero-version))
                   (reset-fragments!)
                   ;; Anything not yet consumed belongs to the retired socket.
                   ;; Dropping it here gives the adapter a real generation
                   ;; barrier for debugDisconnect acknowledgements.
                   (mutex-lock! (live-lock manager))
                   (live-deliveries-set! manager '())
                   (live-delivery-bytes-set! manager 0)
                   (condition-variable-broadcast! (live-condition manager))
                   (mutex-unlock! (live-lock manager))
                   (set! next-connect-at (+ (now-seconds) +initial-backoff+))
                   (set! backoff (* 2 +initial-backoff+))
                   (complete-owner-response! response
                                             (live-generation manager)))
                 (fail-owner-response!
                  response
                  (make-convex-error "TransportError"
                                     "Live WebSocket is not connected"))))
            ((close)
             (set! stop? #t)
             (for-each
              (lambda (subscription)
                (subscription-active-set! subscription #f))
              (sorted-active-subscriptions manager))
             (hash-table-clear! (live-active manager))
             (live-active-bytes-set! manager 0)
             (mutex-lock! (live-lock manager))
             (live-deliveries-set! manager '())
             (live-delivery-bytes-set! manager 0)
             (live-closed-set! manager #t)
             (condition-variable-broadcast! (live-condition manager))
             (mutex-unlock! (live-lock manager))
             (retire! "ClientClosed" #f #t)
             (complete-owner-response! response #t))
            (else
             (fail-owner-response!
              response (make-convex-error "ProtocolError"
                                          "unknown Live owner command"))))))

      (define (parse-live-change change)
        (unless (json-object? change)
          (error 'parse-live-change "Live modification must be an object"))
        (let ((kind (json-get change "type" #f))
              (query-id (json-get change "queryId" #f)))
          (unless (string? kind)
            (error 'parse-live-change "Live modification type must be a string"))
          (set! query-id (uint32-number query-id 'parse-live-change))
          (let ((subscription (active-subscription manager query-id)))
            (cond
              ((string=? kind "QueryUpdated")
               (unless (json-has? change "value")
                 (error 'parse-live-change "QueryUpdated is missing value"))
               (list query-id subscription
                     (and subscription
                          (%make-update
                           (json-get change "value")
                           (log-lines (json-get change "logLines" '()))
                           #f
                           (live-generation manager)))))
              ((string=? kind "QueryFailed")
               (let ((message (json-get change "errorMessage" #f))
                     (logs (log-lines (json-get change "logLines" '()))))
                 (unless (string? message)
                   (error 'parse-live-change "QueryFailed errorMessage must be a string"))
                 (list query-id subscription
                       (and subscription
                            (%make-update
                             json-null logs
                             (make-convex-error
                              "FunctionError" message
                              (json-get change "errorData" json-null)
                              logs "query")
                             (live-generation manager))))))
              ((string=? kind "QueryRemoved") (list query-id #f #f))
              (else
               (error 'parse-live-change "unsupported Live modification" kind))))))

      (define (process-transition! event)
        (let* ((start (valid-version (json-get event "startVersion" #f)))
               (end (valid-version (json-get event "endVersion" #f)))
               (modifications (json-get event "modifications" #f)))
          (unless (version=? start remote-version)
            (error 'process-transition!
                   "Live transition start version did not match local state"))
          (unless (list? modifications)
            (error 'process-transition! "Live modifications must be an array"))
          (let ((end-timestamp (timestamp-decode (vector-ref end 2))))
            (when (< end-timestamp (timestamp-decode (vector-ref start 2)))
              (error 'process-transition! "Live timestamp moved backwards"))
            (let ((coalesced
                    (fold (lambda (change result)
                            (coalesce-change result (parse-live-change change)))
                          '() modifications)))
              ;; Only after every field validates do we commit the version and
              ;; atomically publish the final state for each affected query.
              (set! remote-version end)
              (when (> end-timestamp (live-max-observed-timestamp manager))
                (live-max-observed-timestamp-set! manager end-timestamp))
              (enqueue-updates-atomically!
               manager
               (filter-map
                (lambda (item)
                  (and (cadr item) (caddr item)
                       (cons (cadr item) (caddr item))))
                coalesced))
              (set! backoff +initial-backoff+)
              (set! next-connect-at #f)))))

      (define (process-live-message! bytes)
        (when (> (u8vector-length bytes) +live-message-byte-limit+)
          (error 'process-live-message! "Live message exceeds byte limit"))
        (let ((text (u8vector->byte-string bytes)))
          (unless (utf8-valid? text)
            (error 'process-live-message! "Live text message is invalid UTF-8"))
          (let* ((event (json-decode text))
                 (kind (json-get event "type" #f)))
            (unless (string? kind)
              (error 'process-live-message! "Live message type is missing"))
            (cond
              ((string=? kind "Transition") (process-transition! event))
              ((member kind '("Ping" "MutationResponse" "ActionResponse")) #t)
              (else (error 'process-live-message!
                           "unsupported Live server message" kind))))))

      (define (append-fragment! data)
        (let ((new-size (+ fragment-size (u8vector-length data))))
          (when (> new-size +live-message-byte-limit+)
            (error 'append-fragment! "fragmented Live message exceeds byte limit"))
          (when (>= (length fragment-chunks) 4096)
            (error 'append-fragment! "fragmented Live message has too many frames"))
          ;; Keep chunks in reverse order so each fragment is O(1) to append.
          ;; join-chunks reverses once when the final frame arrives.
          (set! fragment-chunks (cons data fragment-chunks))
          (set! fragment-size new-size)))

      (define (process-frame! frame)
        (when (frame-mask? frame)
          (error 'process-frame! "server WebSocket frame was masked"))
        (let ((kind (frame-optype frame))
              (data (frame-payload-data frame))
              (length (frame-payload-length frame)))
          (case kind
            ((ping)
             (send-frame socket
                         (make-ws-frame #t 0 (optype->opcode 'pong) #t
                                        length data)))
            ((pong) #t)
            ((connection-close)
             (unless (close-frame-valid? frame)
             (error 'process-frame! "invalid WebSocket close payload"))
             (retire! "ServerClosed" #t #t)
             (rebase-live-deliveries!)
             (publish-recoverable-error!
              "TransportError" "Live server closed the WebSocket"))
            ((binary)
             (error 'process-frame! "binary Live messages are unsupported"))
            ((text)
             (when fragment-kind
               (error 'process-frame! "WebSocket fragments arrived out of order"))
             (if (frame-fin? frame)
                 (process-live-message! data)
                 (begin
                   (set! fragment-kind 'text)
                   (set! fragment-chunks '())
                   (set! fragment-size 0)
                   (append-fragment! data))))
            ((continuation)
             (unless fragment-kind
               (error 'process-frame! "WebSocket continuation has no start"))
             (append-fragment! data)
             (when (frame-fin? frame)
               (let ((message (join-chunks fragment-chunks fragment-size)))
                 (reset-fragments!)
                 (process-live-message! message))))
            (else (error 'process-frame! "unsupported WebSocket frame" kind)))))

      (let loop ()
        (let command-loop ((command (dequeue-owner-command manager)))
          (when command
            (process-owner-command! command)
            (command-loop (dequeue-owner-command manager))))
        (unless stop?
          (cond
            (socket
             (if (ws-data-ready? socket)
                 (handle-exceptions condition
                   ;; ws-data-ready? guarantees that recv-frame consumed at
                   ;; least one byte before a later read could time out. Any
                   ;; failure therefore retires the connection. Restarting the
                   ;; stateless parser on this socket could treat payload data
                   ;; as a fresh RFC6455 header.
                   (retire-with-condition! condition)
                   (process-frame!
                    (parameterize ((tcp-read-timeout 1000))
                      (recv-frame socket))))
                 (thread-sleep! 0.01)))
            ((and (pair? (sorted-active-subscriptions manager))
                  (or (not next-connect-at)
                      (>= (now-seconds) next-connect-at)))
             (connect-now!))
            (else (thread-sleep! 0.01)))
          (loop)))))

  (define (make-live-manager deployment-url client-version)
    (let ((manager
            (%make-live-manager deployment-url client-version
                                (make-mutex 'live-manager)
                                (make-condition-variable 'live-manager)
                                '() (make-hash-table) 0 0 '() 0 #f #f 0
                                "InitialConnect" 0 0)))
      (live-owner-set!
       manager
       (thread-start!
        (make-thread
         (lambda ()
           (handle-exceptions condition
             (begin
               (display "Convex Live owner stopped: " (current-error-port))
               (display (condition-message condition) (current-error-port))
               (newline (current-error-port))
               (flush-output (current-error-port))
               (mutex-lock! (live-lock manager))
               (let ((pending (live-commands manager)))
                 (live-commands-set! manager '())
                 (live-closed-set! manager #t)
                 (for-each
                  (lambda (command)
                    (fail-owner-response!
                     (vector-ref command 2)
                     (make-convex-error "TransportError"
                                        "Live owner stopped unexpectedly")))
                  pending))
               (condition-variable-broadcast! (live-condition manager))
               (mutex-unlock! (live-lock manager)))
             (live-owner-loop manager)))
         'convex-live-owner)))
      manager))

  (define (ensure-live-manager client)
    (mutex-lock! (client-lock client))
    (cond
      ((client-closed? client)
       (mutex-unlock! (client-lock client))
       (raise-convex "ClosedError" "client is closed"))
      ((client-live client)
       (let ((manager (client-live client)))
         (mutex-unlock! (client-lock client))
         manager))
      (else
       (let ((manager (make-live-manager (client-deployment-url client)
                                         (client-version client))))
         (client-live-set! client manager)
         (mutex-unlock! (client-lock client))
         manager))))

  (define (client-subscribe client path #!optional (args (json-object)))
    (unless (client? client) (error 'client-subscribe "expected a client"))
    (unless (valid-path? path)
      (error 'client-subscribe "function path must be module:function"))
    (unless (json-object? args)
      (error 'client-subscribe "arguments must be a named JSON object"))
    (let* ((manager (ensure-live-manager client))
           (response (enqueue-owner-command! manager 'subscribe (list path args))))
      (wait-owner-response response 5.0 "subscribe")))

  (define (subscription-close! subscription #!optional (timeout 5.0))
    (unless (subscription? subscription)
      (error 'subscription-close! "expected a subscription"))
    (if (not (subscription-active? subscription))
        #t
        (wait-owner-response
         (enqueue-owner-command! (subscription-manager subscription)
                                 'unsubscribe subscription)
         timeout "unsubscribe")))

  (define (client-debug-disconnect! client #!optional (timeout 5.0))
    (unless (client? client)
      (error 'client-debug-disconnect! "expected a client"))
    (mutex-lock! (client-lock client))
    (let ((manager (client-live client)) (closed (client-closed? client)))
      (mutex-unlock! (client-lock client))
      (when closed (raise-convex "ClosedError" "client is closed"))
      (unless manager
        (raise-convex "ProtocolError" "Live WebSocket has not been started"))
      (wait-owner-response
       (enqueue-owner-command! manager 'debug-disconnect #f)
       timeout "debug disconnect")))

  (define (client-close! client #!optional (timeout 5.0))
    (unless (client? client) (error 'client-close! "expected a client"))
    (mutex-lock! (client-lock client))
    (let ((already-closed (client-closed? client))
          (manager (client-live client)))
      (client-closed-set! client #t)
      (mutex-unlock! (client-lock client))
      (cond
        (already-closed #t)
        (manager
         (wait-owner-response
          (enqueue-owner-command! manager 'close #f) timeout "close"))
        (else #t))))
)
