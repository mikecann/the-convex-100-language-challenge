#lang racket/base

(require json
         net/http-client
         net/url
         racket/list
         racket/port
         racket/string
         "errors.rkt")

(provide
 default-client-version
 default-max-response-bytes
 default-request-timeout-seconds
 (struct-out convex-result)
 convex-client?
 make-convex-client
 convex-client-deployment-url
 convex-client-client-version
 convex-client-closed?
 convex-client-open?
 convex-client-auth-snapshot
 convex-client-register-auth-hook!
 convex-client-register-close-hook!
 convex-client-set-auth!
 convex-client-clear-auth!
 convex-client-query
 convex-client-mutation
 convex-client-action
 convex-client-call
 convex-client-close!)

(define default-client-version "racket-0.1.0")
(define default-max-response-bytes (* 2 1024 1024))
(define default-request-timeout-seconds 30)

;; HTTP responses keep Convex log lines beside the value instead of silently
;; dropping diagnostics that are useful when teaching or debugging a function.
(struct convex-result (value logs) #:transparent)

;; `lock` protects every mutable field. Network I/O never runs while it is held.
;; The client custodian lets close interrupt an in-flight DNS, TLS, or HTTP read
;; without depending on a cooperative peer.
(struct convex-client
  (deployment-url
   scheme
   host
   port
   base-path
   host-header
   client-version
   max-response-bytes
   request-timeout-seconds
   lock
   custodian
   [auth-token #:mutable]
   [auth-generation #:mutable]
   [auth-hooks #:mutable]
   [close-hooks #:mutable]
   close-done
   [closed? #:mutable]))

(define (call-with-lock lock procedure)
  (semaphore-wait lock)
  (dynamic-wind
   void
   procedure
   (lambda () (semaphore-post lock))))

(define (safe-header-text? value)
  (and (string? value)
       (for/and ([character (in-string value)])
         (define code (char->integer character))
         (and (>= code 32) (not (= code 127))))))

(define (validate-header-text value description #:empty? [empty? #t])
  (unless (and (safe-header-text? value)
               (or empty? (positive? (string-length value))))
    (raise-argument-error description
                          (if empty?
                              "string without HTTP control characters"
                              "non-empty string without HTTP control characters")
                          value)))

(define (default-port scheme)
  (if (string=? scheme "https") 443 80))

(define (make-host-header host port scheme)
  (define displayed-host
    (if (string-contains? host ":")
        (string-append "[" host "]")
        host))
  (if (= port (default-port scheme))
      displayed-host
      (format "~a:~a" displayed-host port)))

(define (extract-base-path deployment-url scheme)
  ;; Find the first slash after the URL authority. This preserves percent
  ;; encoding exactly as the caller supplied it instead of decoding and then
  ;; re-encoding path segments with subtly different spelling.
  (define authority-start (+ (string-length scheme) 3))
  (define slash-match
    (regexp-match-positions #rx"/" deployment-url authority-start))
  (define path
    (if slash-match
        (substring deployment-url (caar slash-match))
        ""))
  (regexp-replace #px"/+$" path ""))

(define (parse-deployment-url deployment-url)
  (unless (and (string? deployment-url)
               (positive? (string-length deployment-url))
               (for/and ([character (in-string deployment-url)])
                 (and (not (char-whitespace? character))
                      (>= (char->integer character) 32)
                      (not (= (char->integer character) 127)))))
    (raise-argument-error
     'make-convex-client
     "non-empty HTTP or HTTPS URL without whitespace or control characters"
     deployment-url))
  (define parsed
    (with-handlers
        ([exn:fail?
          (lambda (error)
            (raise-arguments-error
             'make-convex-client
             "invalid Convex deployment URL"
             "URL" deployment-url
             "detail" (exn-message error)))])
      (string->url deployment-url)))
  (define scheme (and (url-scheme parsed) (string-downcase (url-scheme parsed))))
  (unless (member scheme '("http" "https"))
    (raise-arguments-error
     'make-convex-client
     "Convex deployment URL must use http or https"
     "URL" deployment-url))
  (unless (and (url-host parsed) (positive? (string-length (url-host parsed))))
    (raise-arguments-error
     'make-convex-client
     "Convex deployment URL must include a host"
     "URL" deployment-url))
  (when (url-user parsed)
    (raise-arguments-error
     'make-convex-client
     "Convex deployment URL must not include user information"
     "URL" deployment-url))
  (unless (and (null? (url-query parsed)) (not (url-fragment parsed)))
    (raise-arguments-error
     'make-convex-client
     "Convex deployment URL must not include a query or fragment"
     "URL" deployment-url))
  (define port (or (url-port parsed) (default-port scheme)))
  (unless (<= 1 port 65535)
    (raise-arguments-error
     'make-convex-client
     "Convex deployment URL has an invalid port"
     "URL" deployment-url))
  (define base-path (extract-base-path deployment-url scheme))
  (values
   (regexp-replace #px"/+$" deployment-url "")
   scheme
   (url-host parsed)
   port
   base-path
   (make-host-header (url-host parsed) port scheme)))

(define (normalize-auth-token token who)
  (cond
    [(not token) #f]
    [(not (string? token))
     (raise-argument-error who "(or/c #f string?)" token)]
    [else
     (validate-header-text token who)
     (and (positive? (string-length token)) token)]))

(define (make-convex-client deployment-url
                            #:auth-token [auth-token #f]
                            #:client-version [client-version default-client-version]
                            #:max-response-bytes
                            [max-response-bytes default-max-response-bytes]
                            #:request-timeout-seconds
                            [request-timeout-seconds
                             default-request-timeout-seconds])
  (validate-header-text client-version 'make-convex-client #:empty? #f)
  (unless (exact-positive-integer? max-response-bytes)
    (raise-argument-error
     'make-convex-client
     "exact-positive-integer?"
     max-response-bytes))
  (unless (and (real? request-timeout-seconds)
               (positive? request-timeout-seconds))
    (raise-argument-error
     'make-convex-client
     "positive real number"
     request-timeout-seconds))
  (define token (normalize-auth-token auth-token 'make-convex-client))
  (define-values
    (normalized-url scheme host port base-path host-header)
    (parse-deployment-url deployment-url))
  (convex-client
   normalized-url
   scheme
   host
   port
   base-path
   host-header
   client-version
   max-response-bytes
   request-timeout-seconds
   (make-semaphore 1)
   (make-custodian)
   token
   0
   '()
   '()
   (make-semaphore 0)
   #f))

(define (convex-client-open? client)
  (unless (convex-client? client)
    (raise-argument-error 'convex-client-open? "convex-client?" client))
  (call-with-lock
   (convex-client-lock client)
   (lambda () (not (convex-client-closed? client)))))

(define (convex-client-auth-snapshot client)
  (unless (convex-client? client)
    (raise-argument-error 'convex-client-auth-snapshot "convex-client?" client))
  (call-with-lock
   (convex-client-lock client)
   (lambda ()
     (when (convex-client-closed? client) (raise-convex-closed))
     (values (convex-client-auth-token client)
             (convex-client-auth-generation client)))))

(define (notify-hooks hooks . arguments)
  ;; Hooks only enqueue work for optional Live support. A broken hook must not
  ;; prevent the HTTP client from updating its own lifecycle state.
  (for ([hook (in-list hooks)])
    (with-handlers ([exn? void])
      (apply hook arguments))))

(define (convex-client-register-auth-hook! client hook)
  (unless (and (procedure? hook) (procedure-arity-includes? hook 2))
    (raise-argument-error
     'convex-client-register-auth-hook!
     "procedure accepting token and generation"
     hook))
  (define-values (closed? token generation)
    (call-with-lock
     (convex-client-lock client)
     (lambda ()
       (if (convex-client-closed? client)
           (values #t #f 0)
           (begin
             (set-convex-client-auth-hooks!
              client
              (cons hook (convex-client-auth-hooks client)))
             (values #f
                     (convex-client-auth-token client)
                     (convex-client-auth-generation client)))))))
  (when closed? (raise-convex-closed))
  (hook token generation)
  (void))

(define (convex-client-register-close-hook! client hook)
  (unless (and (procedure? hook) (procedure-arity-includes? hook 0))
    (raise-argument-error
     'convex-client-register-close-hook!
     "procedure accepting no arguments"
     hook))
  (define already-closed?
    (call-with-lock
     (convex-client-lock client)
     (lambda ()
       (if (convex-client-closed? client)
           #t
           (begin
             (set-convex-client-close-hooks!
              client
              (cons hook (convex-client-close-hooks client)))
             #f)))))
  (when already-closed?
    ;; The owner was created during a close race. Retire it before reporting the
    ;; closed client so the caller cannot leak a networking thread.
    (with-handlers ([exn? void]) (hook))
    (raise-convex-closed))
  (void))

(define (convex-client-set-auth! client token)
  (unless (convex-client? client)
    (raise-argument-error 'convex-client-set-auth! "convex-client?" client))
  (define normalized (normalize-auth-token token 'convex-client-set-auth!))
  (define-values (hooks generation)
    (call-with-lock
     (convex-client-lock client)
     (lambda ()
       (when (convex-client-closed? client) (raise-convex-closed))
       (define next-generation (add1 (convex-client-auth-generation client)))
       (set-convex-client-auth-token! client normalized)
       (set-convex-client-auth-generation! client next-generation)
       (values (convex-client-auth-hooks client) next-generation))))
  (notify-hooks hooks normalized generation)
  (void))

(define (convex-client-clear-auth! client)
  (convex-client-set-auth! client #f))

(define valid-operations '(query mutation action))

(define (validate-call operation path arguments)
  (unless (memq operation valid-operations)
    (raise-argument-error
     'convex-client-call
     "one of 'query, 'mutation, or 'action"
     operation))
  (unless (and (string? path) (positive? (string-length path)))
    (raise-argument-error
     'convex-client-call
     "non-empty Convex function path string"
     path))
  (unless (and (hash? arguments) (jsexpr? arguments))
    (raise-argument-error
     'convex-client-call
     "JSON object represented by a hash with symbol keys"
     arguments)))

(define (response-status-code status-line)
  (define match (regexp-match #px#"^HTTP/[0-9.]+[ ]+([0-9]{3})(?:[ ]|$)" status-line))
  (and match
       (string->number (bytes->string/latin-1 (cadr match)))))

(define (read-bounded-response input max-bytes operation)
  (define output (open-output-bytes))
  (let loop ([total 0])
    ;; Reading one byte beyond the boundary distinguishes an exactly-full body
    ;; from an oversized body without buffering an unbounded peer response.
    (define remaining (+ 1 (- max-bytes total)))
    (define chunk (read-bytes (min 8192 remaining) input))
    (cond
      [(eof-object? chunk) (get-output-bytes output)]
      [else
       (define next-total (+ total (bytes-length chunk)))
       (when (> next-total max-bytes)
         (raise-convex-transport
          (format "response exceeds ~a bytes" max-bytes)
          operation))
       (write-bytes chunk output)
       (loop next-total)])))

(define (decode-response body status-code operation)
  (define text
    (with-handlers
        ([exn:fail?
          (lambda (error)
            (raise-convex-protocol
             (format "HTTP ~a response is not valid UTF-8: ~a"
                     status-code
                     (exn-message error))))])
      (bytes->string/utf-8 body)))
  (define decoded
    (with-handlers
        ([exn:fail?
          (lambda (error)
            (raise-convex-protocol
             (format "HTTP ~a response is not valid JSON: ~a"
                     status-code
                     (exn-message error))))])
      (define input (open-input-string text))
      (define value (read-json input))
      (define remainder (port->string input))
      (unless (for/and ([character (in-string remainder)])
                (memv character '(#\space #\tab #\return #\newline)))
        (error 'decode-response "trailing content after JSON value"))
      value))
  (unless (hash? decoded)
    (raise-convex-protocol
     (format "HTTP ~a Convex response is not an object" status-code)))
  (define status (hash-ref decoded 'status #f))
  (define logs (hash-ref decoded 'logLines '()))
  (unless (and (list? logs) (andmap string? logs))
    (raise-convex-protocol "Convex HTTP logLines must be an array of strings"))
  (cond
    [(equal? status "success")
     (unless (hash-has-key? decoded 'value)
       (raise-convex-protocol "successful Convex response omitted value"))
     (convex-result (hash-ref decoded 'value) logs)]
    [(equal? status "error")
     (define message (hash-ref decoded 'errorMessage #f))
     (unless (string? message)
       (raise-convex-protocol "Convex HTTP errorMessage must be a string"))
     (raise-convex-function
      message
      operation
      (hash-ref decoded 'errorData missing-error-data)
      logs)]
    [else
     (raise-convex-protocol
      (format "HTTP ~a response has unknown Convex status ~v"
              status-code
              status))]))

(define (perform-http-request client operation token path arguments)
  (with-handlers
      ([exn:fail:convex? raise]
       [exn:fail?
        (lambda (error)
          (raise-convex-transport (exn-message error) operation error))])
    (define operation-text (symbol->string operation))
    (define endpoint
      (string->bytes/utf-8
       (string-append (convex-client-base-path client)
                      "/api/"
                      operation-text)))
    (define body
      (string->bytes/utf-8
       (jsexpr->string
        (hasheq 'path path 'args arguments 'format "json"))))
    (define headers
      (append
       (list #"Content-Type: application/json"
             #"Accept: application/json"
             (string->bytes/utf-8
              (string-append "Convex-Client: "
                             (convex-client-client-version client)))
             (string->bytes/latin-1
              (format "Host: ~a" (convex-client-host-header client))))
       (if token
           (list
            (string->bytes/utf-8
             (string-append "Authorization: Bearer " token)))
           '())))
    (define-values (status-line response-headers response-port)
      (http-sendrecv
       (convex-client-host client)
       endpoint
       #:ssl? (if (string=? (convex-client-scheme client) "https") 'secure #f)
       #:port (convex-client-port client)
       #:method #"POST"
       #:headers headers
       #:data body))
    (define status-code (response-status-code status-line))
    (unless status-code
      (close-input-port response-port)
      (raise-convex-protocol
       (format "malformed HTTP status line ~v" status-line)))
    (define response-body
      (dynamic-wind
       void
       (lambda ()
         (read-bounded-response
          response-port
          (convex-client-max-response-bytes client)
          operation))
       (lambda () (close-input-port response-port))))
    (decode-response response-body status-code operation)))

(define (client-request-snapshot client)
  (call-with-lock
   (convex-client-lock client)
   (lambda ()
     (when (convex-client-closed? client) (raise-convex-closed))
     (convex-client-auth-token client))))

(define (convex-client-call client operation path [arguments (hasheq)])
  (unless (convex-client? client)
    (raise-argument-error 'convex-client-call "convex-client?" client))
  (validate-call operation path arguments)
  (define token (client-request-snapshot client))
  (define answer (make-channel))
  ;; A child custodian gives a timed-out request its own cleanup boundary while
  ;; still making it a child of the client-wide close boundary.
  (define request-custodian
    (parameterize ([current-custodian (convex-client-custodian client)])
      (make-custodian)))
  (define worker
    (parameterize ([current-custodian request-custodian])
      (thread
       (lambda ()
         (with-handlers
             ([exn?
               (lambda (error)
                 (channel-put answer (cons 'error error)))])
           (channel-put
            answer
            (cons 'value
                  (perform-http-request
                   client operation token path arguments))))))))
  (define response-event
    (handle-evt answer values))
  (define dead-event
    (handle-evt (thread-dead-evt worker) (lambda (_) 'worker-dead)))
  (define outcome
    (sync/timeout
     (convex-client-request-timeout-seconds client)
     response-event
     dead-event))
  (cond
    [(not outcome)
     (custodian-shutdown-all request-custodian)
     (raise-convex-transport
      (format "request exceeded ~a seconds"
              (convex-client-request-timeout-seconds client))
      operation)]
    [(eq? outcome 'worker-dead)
     (define raced-answer (sync/timeout 0 response-event))
     (custodian-shutdown-all request-custodian)
     (cond
       [raced-answer
        (if (eq? (car raced-answer) 'value)
            (cdr raced-answer)
            (raise (cdr raced-answer)))]
       [(not (convex-client-open? client)) (raise-convex-closed)]
       [else
        (raise-convex-transport
         "HTTP request worker exited without a result"
         operation)])]
    [else
     (custodian-shutdown-all request-custodian)
     (if (eq? (car outcome) 'value)
         (cdr outcome)
         (raise (cdr outcome)))]))

(define (convex-client-query client path [arguments (hasheq)])
  (convex-client-call client 'query path arguments))

(define (convex-client-mutation client path [arguments (hasheq)])
  (convex-client-call client 'mutation path arguments))

(define (convex-client-action client path [arguments (hasheq)])
  (convex-client-call client 'action path arguments))

(define (convex-client-close! client)
  (unless (convex-client? client)
    (raise-argument-error 'convex-client-close! "convex-client?" client))
  (define hooks
    (call-with-lock
     (convex-client-lock client)
     (lambda ()
       (if (convex-client-closed? client)
           #f
           (begin0 (convex-client-close-hooks client)
             (set-convex-client-closed?! client #t)
             (set-convex-client-auth-hooks! client '())
             (set-convex-client-close-hooks! client '()))))))
  (when hooks
    ;; This interrupts in-flight HTTP work before waiting for optional Live
    ;; owners, keeping close bounded even if an HTTP peer stopped responding.
    (dynamic-wind
     void
     (lambda ()
       (custodian-shutdown-all (convex-client-custodian client))
       (notify-hooks hooks))
     (lambda () (semaphore-post (convex-client-close-done client)))))
  (unless hooks
    ;; A concurrent caller waits for the thread that won the transition from
    ;; open to closed. Returning earlier would make close's completion depend
    ;; on which application thread happened to call it first.
    (sync (semaphore-peek-evt (convex-client-close-done client))))
  (void))
