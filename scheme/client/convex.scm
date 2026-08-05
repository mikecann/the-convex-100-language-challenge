;; Native Guile Scheme transport for Convex's documented JSON HTTP API.
(use-modules (ice-9 match)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 ports)
             (web client)
             (web response)
             (web uri)
             (json))

(define (json-null) 'null)

(define (object-ref object key . default)
  (let ((entry (assoc key object)))
    (if entry (cdr entry) (if (null? default) #f (car default)))))

(define (json-read-string text)
  ;; Keep object keys as strings so JSON input remains distinct from Scheme symbols.
  (call-with-input-string text (lambda (port) (json->scm port #:ordered #t))))

(define (json-write-string value)
  (call-with-output-string (lambda (port) (scm->json value port))))

(define (safe-token token)
  (and (string? token)
       (not (string-any (lambda (ch) (or (char=? ch #\return) (char=? ch #\newline))) token))))

(define (convex-url operation)
  (let ((base (or (getenv "CONVEX_URL") (error "CONVEX_URL is required"))))
    (string-append (string-trim-right base #\/) "/api/" operation)))

(define (response-body-string port)
  (let ((text (get-string-all port)))
    (close-port port)
    text))

(define (convex-error response payload)
  (let ((message (object-ref payload "errorMessage" "Convex HTTP request failed")))
    `(("name" . "FunctionError")
      ("message" . ,message)
      ("data" . ,(object-ref payload "errorData" 'null))
      ("logs" . ,(object-ref payload "logLines" '())))))

(define (call-convex operation path args token)
  (unless (and (string? path) (>= (string-length path) 3))
    (error "Convex function path must be a non-empty module:function string"))
  (unless (list? args) (error "Convex arguments must be a JSON object"))
  (unless (or (not token) (safe-token token)) (error "Convex auth token contains a newline"))
  (let* ((headers `((content-type . (application/json))
                    (accept . (application/json))
                    ,@(if token `((authorization . ,(string-append "Bearer " token))) '())))
         (body (json-write-string `(("path" . ,path) ("args" . ,args) ("format" . "json"))))
         (response+port (call-with-values
                            (lambda () (http-post (convex-url operation) #:headers headers #:body body))
                          list))
         (response (car response+port))
         (payload (json-read-string (response-body-string (cadr response+port)))))
    (if (and (>= (response-code response) 200) (< (response-code response) 300))
        `(("ok" . #t) ("value" . ,(object-ref payload "value" 'null))
          ("logs" . ,(object-ref payload "logLines" '())))
        `(("ok" . #f) ("error" . ,(convex-error response payload))))))

(define (convex-query path args token) (call-convex "query" path args token))
(define (convex-mutation path args token) (call-convex "mutation" path args token))
(define (convex-action path args token) (call-convex "action" path args token))
