(load "/project/client/load.lisp")

(in-package #:convex)

(defun check (condition message)
  (unless condition (error "HTTP test failed: ~A" message)))

(defun start-http-fixture (response callback)
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket
                                 :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen listener 4)
    (multiple-value-bind (address port) (sb-bsd-sockets:socket-name listener)
      (declare (ignore address))
      (values
       port
       (sb-thread:make-thread
        (lambda ()
          (unwind-protect
               (dolist (one-response
                         (if (stringp response) (list response) response))
                 (let* ((socket (sb-bsd-sockets:socket-accept listener))
                        (stream (sb-bsd-sockets:socket-make-stream
                                 socket :input t :output t :element-type 'character
                                 :external-format :utf-8 :buffering :none))
                        (request-line (read-line stream))
                        (headers (make-hash-table :test #'equal)))
                   (loop for line = (string-right-trim '(#\Return) (read-line stream))
                         until (zerop (length line))
                         do (let ((colon (position #\: line)))
                              (setf (gethash (string-downcase (subseq line 0 colon)) headers)
                                    (string-trim '(#\Space) (subseq line (1+ colon))))))
                   (let* ((length (parse-integer (gethash "content-length" headers)))
                          (body (make-string length)))
                     (read-sequence body stream)
                     (funcall callback request-line headers (json-decode body)))
                   ;; Split every important boundary so the client cannot depend
                   ;; on one recv call returning a complete response.
                   (loop for fragment in
                           (list (format nil "HTTP/1.1 200 OK~C~CContent-Type: application/json~C~C"
                                         #\Return #\Newline #\Return #\Newline)
                                 (format nil "Content-Length: ~D~C~C~C~C"
                                         (length (string-octets one-response))
                                         #\Return #\Newline #\Return #\Newline)
                                 (subseq one-response 0 (floor (length one-response) 2))
                                 (subseq one-response (floor (length one-response) 2)))
                         do (write-string fragment stream)
                            (force-output stream)
                            (sleep 0.005))
                   (close stream)))
            (sb-bsd-sockets:socket-close listener)))
        :name "HTTP fixture")))))

(multiple-value-bind (port fixture)
    (start-http-fixture
     "{\"status\":\"success\",\"value\":{\"count\":1.0},\"logLines\":[\"hello\"]}"
     (lambda (request-line headers body)
       (check (search "POST /api/query HTTP/1.1" request-line) "query endpoint")
       (check (string= (gethash "authorization" headers) "Bearer test-token")
              "bearer header")
       (check (string= (json-get body "path") "demo:state") "function path")
       (check (string= (json-get (json-get body "args") "room") "room-1") "args")))
  (let* ((client (make-client (format nil "http://127.0.0.1:~D" port)
                              :auth-token "test-token"))
         (result (client-query client "demo:state" (json-object "room" "room-1"))))
    (check (= (json-get (result-value result) "count") 1) "decoded integral decimal")
    (check (equal (result-logs result) '("hello")) "logs"))
  (sb-thread:join-thread fixture))

(dolist (constructor
          (list (lambda ()
                  (make-client (format nil "http://example.invalid/bad~%path")))
                (lambda () (make-client "http://example.invalid"
                                        :auth-token
                                        (format nil "token~%Injected: yes")))
                (lambda () (make-client "http://example.invalid"
                                        :client-version
                                        (format nil "client~C~%Injected: yes"
                                                #\Return)))))
  (handler-case
      (funcall constructor)
    (error () (setf constructor nil)))
  (check (null constructor) "HTTP control character rejection"))

(let ((client (make-client "http://example.invalid")))
  (let ((rejected nil))
    (handler-case (client-set-auth client (format nil "token~Cbad" #\Return))
      (error () (setf rejected t)))
    (check rejected "replacement auth control character rejection")))

(multiple-value-bind (port fixture)
    (start-http-fixture
     "{\"status\":\"error\",\"errorMessage\":\"nope\",\"errorData\":{\"code\":\"NOPE\"},\"logLines\":[\"failed\"]}"
     (lambda (&rest ignored) (declare (ignore ignored))))
  (let ((client (make-client (format nil "http://127.0.0.1:~D" port))))
    (handler-case
        (progn
          (client-mutation client "demo:increment" (json-object))
          (error "Function error was accepted"))
      (function-error (condition)
        (check (string= (error-name condition) "FunctionError") "error name")
        (check (string= (json-get (error-data condition) "code") "NOPE")
               "structured error data"))))
  (sb-thread:join-thread fixture))

;; Malformed server diagnostics are protocol failures, never schema-invalid
;; adapter fields. The same HTTP client remains usable for a later valid call.
(dolist (malformed
          '("{\"status\":\"success\",\"value\":{},\"logLines\":\"bad\"}"
            "{\"status\":\"error\",\"errorMessage\":7,\"logLines\":[]}"))
  (multiple-value-bind (port fixture)
      (start-http-fixture
       (list malformed "{\"status\":\"success\",\"value\":{\"count\":2},\"logLines\":[]}")
       (lambda (&rest ignored) (declare (ignore ignored))))
    (let ((client (make-client (format nil "http://127.0.0.1:~D" port))))
      (handler-case
          (progn (client-query client "demo:state" (json-object))
                 (error "Malformed HTTP diagnostics were accepted"))
        (protocol-error () nil))
      (check (= (json-get
                 (result-value
                  (client-query client "demo:state" (json-object))) "count")
                2)
             "HTTP ProtocolError recovery"))
    (sb-thread:join-thread fixture)))

(format t "PASS documented HTTP client~%")
