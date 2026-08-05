(in-package #:convex)

(define-condition convex-error (error)
  ((name :initarg :name :reader error-name)
   (message :initarg :message :reader error-message)
   (data :initarg :data :initform +json-null+ :reader error-data)
   (logs :initarg :logs :initform '() :reader error-logs))
  (:report (lambda (condition stream)
             (write-string (error-message condition) stream))))

(define-condition function-error (convex-error) ())
(define-condition protocol-error (convex-error) ())
(define-condition transport-error (convex-error) ())

(defstruct result value (logs '()))
(defstruct update value (logs '()) error (generation 0))

(defstruct (client (:constructor %make-client))
  deployment-url
  auth-token
  (client-version "common-lisp-0.1.0")
  lock
  live
  closed)

(defun make-client (deployment-url &key auth-token
                                     (client-version "common-lisp-0.1.0"))
  (require-safe-header-text client-version "Convex client version")
  (when auth-token (require-safe-header-text auth-token "Convex auth token"))
  (let ((url (parse-url deployment-url)))
    (unless (member (url-scheme url) '("http" "https") :test #'string=)
      (error "Convex deployment URL must use http or https"))
    (%make-client :deployment-url url
                  :auth-token auth-token
                  :client-version client-version
                  :lock (sb-thread:make-mutex :name "Convex client"))))

(defun client-set-auth (client token)
  (when token (require-safe-header-text token "Convex auth token"))
  (sb-thread:with-mutex ((client-lock client))
    (when (client-closed client) (error "Convex client is closed"))
    (setf (client-auth-token client) (and token (plusp (length token)) token)))
  t)

(defun copy-endpoint-url (base operation)
  (let* ((base-path (string-right-trim "/" (url-path base)))
         (path (format nil "~A/api/~A" base-path operation)))
    (make-url :scheme (url-scheme base) :host (url-host base)
              :port (url-port base) :path path)))

(defun find-octets (needle haystack &optional (start 0))
  (search needle haystack :start2 start :test #'=))

(defparameter +header-end+ #(13 10 13 10))

(defun split-lines (text)
  (loop with start = 0
        for end = (search (string #\Newline) text :start2 start)
        collect (string-right-trim '(#\Return) (subseq text start end))
        while end
        do (setf start (1+ end))))

(defun parse-http-headers (bytes)
  (let ((end (find-octets +header-end+ bytes)))
    (unless end (error "HTTP response headers exceed the limit"))
    (let* ((text (octets-string (subseq bytes 0 end)))
           (lines (split-lines text))
           (status-line (first lines))
           (first-space (position #\Space status-line))
           (second-space (and first-space
                              (position #\Space status-line :start (1+ first-space))))
           (status (and first-space
                        (parse-integer status-line :start (1+ first-space)
                                                  :end second-space
                                                  :junk-allowed t)))
           (headers (make-hash-table :test #'equal)))
      (unless status (error "Malformed HTTP status line"))
      (dolist (line (rest lines))
        (let ((colon (position #\: line)))
          (unless colon (error "Malformed HTTP response header"))
          (setf (gethash (string-downcase (subseq line 0 colon)) headers)
                (string-trim '(#\Space #\Tab) (subseq line (1+ colon))))))
      (values status headers (+ end 4)))))

(defun decode-chunked-body (bytes)
  (let ((index 0)
        (output (make-array 0 :element-type '(unsigned-byte 8)
                              :adjustable t :fill-pointer 0)))
    (loop
      (let ((line-end (find-octets #(13 10) bytes index)))
        (unless line-end (error "Truncated chunk size"))
        (let* ((line (octets-string (subseq bytes index line-end)))
               (extension (position #\; line))
               (size (parse-integer line :radix 16 :end extension :junk-allowed nil)))
          (setf index (+ line-end 2))
          (when (zerop size) (return output))
          (when (> (+ index size 2) (length bytes))
            (error "Truncated HTTP chunk"))
          (loop for byte across (subseq bytes index (+ index size))
                do (vector-push-extend byte output))
          (setf index (+ index size))
          (unless (and (= (aref bytes index) 13)
                       (= (aref bytes (1+ index)) 10))
            (error "Malformed HTTP chunk terminator"))
          (incf index 2))))))

(defun http-post-json (url body headers)
  (let ((transport nil))
    (handler-case
        (unwind-protect
             (progn
               (setf transport (open-transport url :timeout 10.0))
               (let ((request
                       (with-output-to-string (output)
                         (format output "POST ~A HTTP/1.1~C~C" (url-path url)
                                 #\Return #\Newline)
                         (format output "Host: ~A~C~C" (url-host-header url)
                                 #\Return #\Newline)
                         (format output "Content-Type: application/json~C~C"
                                 #\Return #\Newline)
                         (format output "Accept: application/json~C~C" #\Return #\Newline)
                         (dolist (header headers)
                           (require-safe-header-text (car header) "HTTP header name")
                           (require-safe-header-text (cdr header) "HTTP header value")
                           (format output "~A: ~A~C~C" (car header) (cdr header)
                                   #\Return #\Newline))
                         (format output "Content-Length: ~D~C~C"
                                 (length (string-octets body)) #\Return #\Newline)
                         (format output "Connection: close~C~C~C~C"
                                 #\Return #\Newline #\Return #\Newline)
                         (write-string body output))))
                 (transport-write-all transport (string-octets request) :timeout 5.0))
               (let ((received (make-array 0 :element-type '(unsigned-byte 8)
                                             :adjustable t :fill-pointer 0))
                     (header-offset nil)
                     (content-length nil)
                     (chunked nil)
                     (status nil)
                     (response-headers nil))
                 (loop
                   (when (> (length received) (+ (* 2 1024 1024) (* 64 1024)))
                     (error "HTTP response exceeds 2 MiB"))
                   (when (and header-offset content-length
                              (>= (- (length received) header-offset) content-length))
                     (return))
                   (let ((part (transport-read-some transport :timeout 30.0)))
                     (unless part (return))
                     (loop for byte across part do (vector-push-extend byte received)))
                   (when (and (not header-offset) (find-octets +header-end+ received))
                     (multiple-value-setq (status response-headers header-offset)
                       (parse-http-headers received))
                     (let ((length-text (gethash "content-length" response-headers))
                           (encoding (gethash "transfer-encoding" response-headers)))
                       (when length-text
                         (setf content-length (parse-integer length-text)))
                       (when (and encoding (search "chunked" encoding :test #'char-equal))
                         (setf chunked t)))))
                 (unless header-offset
                   (error "HTTP peer closed before response headers"))
                 (let ((payload (subseq received header-offset)))
                   (when (and content-length (< (length payload) content-length))
                     (error "HTTP peer closed before response body completed"))
                   (when content-length (setf payload (subseq payload 0 content-length)))
                   (when chunked (setf payload (decode-chunked-body payload)))
                   (values status response-headers (octets-string payload)))))
          (when transport (close-transport transport)))
      (convex-error (condition) (error condition))
      (error (condition)
        (error 'transport-error :name "TransportError"
               :message (format nil "Convex HTTP transport failed: ~A" condition))))))

(defun ensure-json-object (arguments)
  (cond
    ((null arguments) (json-object))
    ((hash-table-p arguments) arguments)
    (t (error "Convex arguments must be a named JSON object"))))

(defun valid-log-lines-p (value)
  (and (listp value) (every #'stringp value)))

(defun client-call (client operation path arguments)
  (unless (and (stringp path) (plusp (length path)))
    (error "Convex function path is required"))
  (multiple-value-bind (url token version)
      (sb-thread:with-mutex ((client-lock client))
        (when (client-closed client) (error "Convex client is closed"))
        (values (copy-endpoint-url (client-deployment-url client) operation)
                (client-auth-token client)
                (client-client-version client)))
    (let ((request (json-object "path" path
                                "args" (ensure-json-object arguments)
                                "format" "json"))
          (headers (list (cons "Convex-Client" version))))
      (when token
        (push (cons "Authorization" (concatenate 'string "Bearer " token)) headers))
      (multiple-value-bind (status response-headers response-body)
          (http-post-json url (json-encode request) headers)
        (declare (ignore response-headers))
        (let ((decoded
                (handler-case (json-decode response-body)
                  (error (condition)
                    (error 'protocol-error :name "ProtocolError"
                           :message (format nil "HTTP ~D returned malformed JSON: ~A"
                                            status condition))))))
          (unless (hash-table-p decoded)
            (error 'protocol-error :name "ProtocolError"
                   :message "Convex HTTP response is not an object"))
          (let ((response-status (json-get decoded "status"))
                (logs (if (json-has-key-p decoded "logLines")
                          (json-get decoded "logLines") '())))
            (unless (valid-log-lines-p logs)
              (error 'protocol-error :name "ProtocolError"
                     :message "Convex HTTP logLines must be an array of strings"))
            (cond
              ((and (stringp response-status)
                    (string= response-status "success"))
               (unless (json-has-key-p decoded "value")
                 (error 'protocol-error :name "ProtocolError"
                        :message "Successful Convex response omitted value"))
               (make-result :value (json-get decoded "value") :logs logs))
              ((and (stringp response-status)
                    (string= response-status "error"))
               (let ((message
                       (if (json-has-key-p decoded "errorMessage")
                           (json-get decoded "errorMessage")
                           "Convex function failed")))
                 (unless (stringp message)
                   (error 'protocol-error :name "ProtocolError"
                          :message "Convex HTTP errorMessage must be a string"))
                 (error 'function-error :name "FunctionError"
                        :message message
                        :data (json-get decoded "errorData" +json-null+)
                        :logs logs)))
              (t
               (error 'protocol-error :name "ProtocolError"
                      :message (format nil "HTTP ~D has unknown Convex status ~S"
                                       status response-status))))))))))

(defun client-query (client path arguments)
  (client-call client "query" path arguments))

(defun client-mutation (client path arguments)
  (client-call client "mutation" path arguments))

(defun client-action (client path arguments)
  (client-call client "action" path arguments))
