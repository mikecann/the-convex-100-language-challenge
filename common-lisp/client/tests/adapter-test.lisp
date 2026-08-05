(load "/project/client/load.lisp")
(load "/project/client/tests/conformance/adapter.lisp")

(in-package #:convex)

(defun check (condition message)
  (unless condition (error "Adapter test failed: ~A" message)))

(defun free-port ()
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket
                                 :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
           (nth-value 1 (sb-bsd-sockets:socket-name listener)))
      (sb-bsd-sockets:socket-close listener))))

(defun write-binary-text (stream text)
  (write-sequence (string-octets text) stream)
  (force-output stream))

(defun read-binary-json-line (stream)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0)))
    (loop for byte = (read-byte stream nil nil)
          do (when (null byte) (error "Adapter reached EOF before an event"))
             (when (= byte 10) (return (json-decode (octets-string bytes))))
             (vector-push-extend byte bytes))))

(defun process-rss-kib (process)
  (with-open-file (input (format nil "/proc/~D/status" (sb-ext:process-pid process)))
    (loop for line = (read-line input nil nil)
          while line
          when (and (>= (length line) 6) (string= line "VmRSS:" :end1 6))
            do (return (parse-integer line :start 6 :junk-allowed t)))))

(defun wait-for-process-error-marker (process marker &key (timeout 5.0))
  "Wait for a saved-image readiness marker without assuming it is stderr line one.

The deliberately unread stdout writer may hit its bounded write deadline before
the main fixture thread reports readiness.  That diagnostic is valid evidence,
not a reason to make this memory probe depend on scheduler order."
  (let ((seen '()))
    (handler-case
        (sb-ext:with-timeout timeout
          (loop for line = (read-line (sb-ext:process-error process) nil nil)
                do (unless line
                     (error "Saved adapter reached EOF before ~A; saw ~S"
                            marker (nreverse seen)))
                   (push line seen)
                   (cond
                     ((string= line marker) (return t))
                     ((string= line
                               "adapter output failed: Timed out during adapter write"))
                     (t (error "Unexpected saved-adapter diagnostic before ~A: ~A"
                               marker line)))))
      (sb-ext:timeout ()
        (error "Timed out waiting for ~A; saw ~S" marker (nreverse seen))))))

(defun adapter-test-timestamp (value)
  (let ((bytes (make-array 8 :element-type '(unsigned-byte 8))))
    (dotimes (index 8)
      (setf (aref bytes index) (ldb (byte 8 (* index 8)) value)))
    (base64-encode bytes)))

(defun adapter-test-read-exactly (stream count)
  (let ((bytes (make-array count :element-type '(unsigned-byte 8))))
    (loop with offset = 0 while (< offset count)
          for next = (read-sequence bytes stream :start offset)
          do (when (= next offset) (error "Adapter fixture peer EOF"))
             (setf offset next))
    bytes))

(defun adapter-test-accept-websocket (listener)
  (let* ((socket (sb-bsd-sockets:socket-accept listener))
         (stream (sb-bsd-sockets:socket-make-stream
                  socket :input t :output t :element-type '(unsigned-byte 8)
                  :buffering :none))
         (headers (make-array 0 :element-type '(unsigned-byte 8)
                                :adjustable t :fill-pointer 0)))
    (loop until (find-octets +header-end+ headers)
          do (vector-push-extend (read-byte stream) headers))
    (let ((parsed (make-hash-table :test #'equal)))
      (dolist (line (rest (split-lines (octets-string headers))))
        (let ((colon (position #\: line)))
          (when colon
            (setf (gethash (string-downcase (subseq line 0 colon)) parsed)
                  (string-trim '(#\Space #\Tab)
                               (subseq line (1+ colon)))))))
      (let* ((key (gethash "sec-websocket-key" parsed))
             (accept (base64-encode
                      (sha1 (string-octets
                             (concatenate
                              'string key
                              "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))))))
        (write-sequence
         (string-octets
          (format nil
                  "HTTP/1.1 101 Switching Protocols~C~CUpgrade: websocket~C~CConnection: Upgrade~C~CSec-WebSocket-Accept: ~A~C~C~C~C"
                  #\Return #\Newline #\Return #\Newline #\Return #\Newline
                  accept #\Return #\Newline #\Return #\Newline))
         stream)
        (force-output stream)))
    stream))

(defun adapter-test-read-client-json (stream)
  (loop
    (let* ((first (read-byte stream))
           (second (read-byte stream))
           (opcode (logand first #x0f))
           (code (logand second #x7f))
           (length (cond ((< code 126) code)
                         ((= code 126)
                          (+ (ash (read-byte stream) 8) (read-byte stream)))
                         (t (loop repeat 8 for byte = (read-byte stream)
                                  for value = byte then (+ (ash value 8) byte)
                                  finally (return value)))))
           (mask (adapter-test-read-exactly stream 4))
           (payload (adapter-test-read-exactly stream length)))
      (dotimes (index length)
        (setf (aref payload index)
              (logxor (aref payload index) (aref mask (mod index 4)))))
      (case opcode
        (1 (return (json-decode (octets-string payload))))
        (8 (return :closed))))))

(defun adapter-test-write-transition (stream query-id count)
  (let ((message
          (json-object
           "type" "Transition"
           "startVersion" (state-version 0 0 (adapter-test-timestamp 0))
           "endVersion" (state-version 1 0 (adapter-test-timestamp 1))
           "modifications"
           (list (json-object "type" "QueryUpdated" "queryId" query-id
                              "value" (json-object "count" count)
                              "logLines" '())))))
    (write-sequence
     (websocket-frame-bytes 1 (string-octets (json-encode message)) :masked nil)
     stream)
    (force-output stream)))

(defun adapter-test-listener ()
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket
                                 :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen listener 4)
    listener))

(defun adapter-test-listener-url (listener)
  (format nil "http://127.0.0.1:~D"
          (nth-value 1 (sb-bsd-sockets:socket-name listener))))

(let* ((port (free-port))
       (listen (format nil "127.0.0.1:~D" port))
       (process (sb-ext:run-program
                 "/out/convex-adapter" '()
                 :environment (list (format nil "ADAPTER_LISTEN=~A" listen))
                 :input nil :output nil :error *error-output* :wait nil))
       (socket nil))
  (unwind-protect
       (progn
         (loop repeat 50
               do (handler-case
                      (progn
                        (setf socket (make-instance 'sb-bsd-sockets:inet-socket
                                                   :type :stream :protocol :tcp))
                        (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
                        (return))
                    (error ()
                      (when socket (ignore-errors (sb-bsd-sockets:socket-close socket)))
                      (setf socket nil)
                      (sleep 0.05))))
         (check socket "TCP adapter did not listen")
         (let ((stream (sb-bsd-sockets:socket-make-stream
                        socket :input t :output t
                        :element-type '(unsigned-byte 8) :buffering :none)))
           ;; Split inside a UTF-8 code point, then isolate both invalid UTF-8
           ;; and malformed JSON before a later valid command.
           (let* ((hello (string-octets
                          (concatenate
                           'string
                           "{\"protocolVersion\":1,\"id\":\"h🟨\",\"op\":\"hello\"}"
                           (string #\Newline))))
                  (marker (position #xF0 hello)))
             (write-sequence hello stream :end (1+ marker))
             (force-output stream)
             (write-sequence hello stream :start (1+ marker)))
           (write-sequence #(255 10) stream)
           (write-binary-text
            stream (concatenate 'string "{malformed}" (string #\Newline)))
           (write-binary-text
            stream
            (concatenate
             'string
             (json-encode
              (json-object "protocolVersion" 1
                           "id" (make-string 129 :initial-element #\i)
                           "op" "hello"))
             (string #\Newline)))
           (write-binary-text
            stream
            (concatenate
             'string
             (json-encode
              (json-object "id" "long-sub" "op" "unsubscribe"
                           "subscriptionId"
                           (make-string 129 :initial-element #\s)))
             (string #\Newline)))
           (write-binary-text
            stream
            (concatenate
             'string "{\"id\":\"deep\",\"op\":\"hello\",\"protocolVersion\":1,\"extra\":"
             (make-string 129 :initial-element #\[) "0"
             (make-string 129 :initial-element #\]) "}"
             (string #\Newline)))
           (write-binary-text
            stream
            (concatenate
             'string "{\"id\":\"dense\",\"op\":\"hello\",\"protocolVersion\":1,\"extra\":["
             (with-output-to-string (output)
               (dotimes (index 8200)
                 (unless (zerop index) (write-char #\, output))
                 (write-string "{}" output)))
             "]}" (string #\Newline)))
           (write-binary-text
            stream
            (concatenate 'string "{\"id\":\"close\",\"op\":\"close\"}"
                         (string #\Newline)))
           (let ((ready (read-binary-json-line stream))
                 (bad-utf8 (read-binary-json-line stream))
                 (bad-json (read-binary-json-line stream))
                 (bad-id (read-binary-json-line stream))
                 (bad-subscription-id (read-binary-json-line stream))
                 (too-deep (read-binary-json-line stream))
                 (too-dense (read-binary-json-line stream))
                 (closed (read-binary-json-line stream)))
             (check (string= (json-get ready "type") "ready") "partial hello")
             (check (string= (json-get bad-utf8 "type") "error")
                    "invalid UTF-8 isolation")
             (check (string= (json-get bad-json "type") "error")
                    "malformed JSON isolation")
             (check (and (string= (json-get bad-id "type") "error")
                         (not (json-has-key-p bad-id "id")))
                    "overlong command ID isolation")
             (check (and (string= (json-get bad-subscription-id "type") "error")
                         (string= (json-get bad-subscription-id "id") "long-sub"))
                    "overlong subscription ID isolation")
             (check (and (string= (json-get too-deep "type") "error")
                         (not (json-has-key-p too-deep "id")))
                    "over-depth command isolation")
             (check (and (string= (json-get too-dense "type") "error")
                         (not (json-has-key-p too-dense "id")))
                    "dense command isolation")
             (check (string= (json-get closed "type") "closed") "close event"))
           (close stream)))
    (when socket (ignore-errors (sb-bsd-sockets:socket-close socket))))
  (sb-ext:process-wait process)
  (check (zerop (sb-ext:process-exit-code process)) "TCP adapter clean exit"))

;; Run the actual saved adapter with an unread stdout pipe and near-limit
;; subscription events. Its resident memory must remain comfortably below the
;; shared 128 MiB cgroup ceiling.
(let* ((process
         (sb-ext:run-program
          "/out/convex-adapter" '()
          :environment '("ADAPTER_FLOOD_TEST=1")
          :input nil :output :stream :error :stream :wait nil))
       (rss nil))
  (unwind-protect
       (progn
         (check (wait-for-process-error-marker
                 process "adapter flood queue ready")
                "saved adapter flood did not reach the bounded queue")
         (check (sb-ext:process-alive-p process) "saved adapter flood process died")
         (setf rss (process-rss-kib process))
         (check (and rss (< rss (* 112 1024)))
                "saved adapter stopped-reader RSS bound")
         (format t "saved adapter stopped-reader RSS: ~D KiB~%" rss))
    (when (sb-ext:process-alive-p process) (sb-ext:process-kill process 15))
    (ignore-errors (sb-ext:process-wait process))
    (when (sb-ext:process-output process)
      (ignore-errors (close (sb-ext:process-output process))))))

;; Repeat the unread-output RSS proof through the real multi-subscription relay
;; path. Each update owns a distinct decoded near-limit string.
(let* ((process
         (sb-ext:run-program
          "/out/convex-adapter" '()
          :environment '("ADAPTER_RELAY_FLOOD_TEST=1")
          :input nil :output :stream :error :stream :wait nil))
       (rss nil))
  (unwind-protect
       (progn
         (check (wait-for-process-error-marker
                 process "adapter relay flood ready")
                "saved adapter relay flood did not reach its bounded state")
         (check (sb-ext:process-alive-p process)
                "saved adapter relay flood process died")
         (setf rss (process-rss-kib process))
         (check (and rss (< rss (* 112 1024)))
                "saved adapter multi-relay RSS bound")
         (format t "saved adapter multi-relay RSS: ~D KiB~%" rss))
    (when (sb-ext:process-alive-p process) (sb-ext:process-kill process 15))
    (ignore-errors (sb-ext:process-wait process))
    (when (sb-ext:process-output process)
      (ignore-errors (close (sb-ext:process-output process))))))

;; Repeat the saved-process RSS assertion for structurally dense values whose
;; decoded container overhead is much larger than their wire representation.
(let* ((process
         (sb-ext:run-program
          "/out/convex-adapter" '()
          :environment '("ADAPTER_DENSE_FLOOD_TEST=1")
          :input nil :output :stream :error :stream :wait nil))
       (rss nil))
  (unwind-protect
       (progn
         (check (wait-for-process-error-marker
                 process "adapter dense flood ready")
                "saved adapter dense flood did not reach its bounded state")
         (check (sb-ext:process-alive-p process)
                "saved adapter dense flood process died")
         (setf rss (process-rss-kib process))
         (check (and rss (< rss (* 112 1024)))
                "saved adapter dense RSS bound")
         (format t "saved adapter dense RSS: ~D KiB~%" rss))
    (when (sb-ext:process-alive-p process) (sb-ext:process-kill process 15))
    (ignore-errors (sb-ext:process-wait process))
    (when (sb-ext:process-output process)
      (ignore-errors (close (sb-ext:process-output process))))))

;; Controller EOF is also a complete lifecycle event. It must retire the
;; adapter without requiring a final protocol command.
(let* ((port (free-port))
       (listen (format nil "127.0.0.1:~D" port))
       (process (sb-ext:run-program
                 "/out/convex-adapter" '()
                 :environment (list (format nil "ADAPTER_LISTEN=~A" listen))
                 :input nil :output nil :error *error-output* :wait nil))
       (socket nil))
  (unwind-protect
       (progn
         (loop repeat 50
               do (handler-case
                      (progn
                        (setf socket (make-instance 'sb-bsd-sockets:inet-socket
                                                   :type :stream :protocol :tcp))
                        (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
                        (return))
                    (error ()
                      (when socket (ignore-errors (sb-bsd-sockets:socket-close socket)))
                      (setf socket nil)
                      (sleep 0.05))))
         (check socket "EOF adapter did not listen")
         (let ((stream (sb-bsd-sockets:socket-make-stream
                        socket :input t :output t :element-type 'character
                        :external-format :utf-8 :buffering :none)))
           (format stream
                   "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}~%")
           (force-output stream)
           (check (string= (json-get (json-decode (read-line stream)) "type") "ready")
                  "EOF hello")
           (close stream)
           (setf socket nil)))
    (when socket (ignore-errors (sb-bsd-sockets:socket-close socket))))
  (handler-case (sb-ext:with-timeout 2.0 (sb-ext:process-wait process))
    (sb-ext:timeout () (sb-ext:process-kill process 9))
    (error () (sb-ext:process-kill process 9)))
  (check (and (not (sb-ext:process-alive-p process))
              (zerop (sb-ext:process-exit-code process)))
         "TCP adapter EOF cleanup"))

;; Directly stop draining a real pipe while near-maximum subscription events
;; are published. The queue keeps a hard count and encoded-byte bound.
(sb-alien:define-alien-routine ("pipe" %pipe) sb-alien:int
  (fds (* sb-alien:int)))
(sb-alien:define-alien-routine ("close" %close) sb-alien:int
  (fd sb-alien:int))

(defun fd-collect-until (fd pattern timeout)
  (let ((text "") (deadline (deadline-after timeout)))
    (loop until (search pattern text)
          do (when (<= (- deadline (monotonic-seconds)) 0)
               (error "Timed out waiting for adapter output ~A" pattern))
             (handler-case
                 (let ((part (fd-read-some fd :timeout 0.25)))
                   (when part
                     (setf text (concatenate 'string text (octets-string part)))))
               (transport-timeout () nil)))
    text))

(let ((fds (sb-alien:make-alien sb-alien:int 2)))
  (check (zerop (%pipe fds)) "pipe creation")
  (let* ((read-fd (sb-alien:deref fds 0))
         (write-fd (sb-alien:deref fds 1))
         (sink (make-output-sink write-fd))
         (large (make-string 700000 :initial-element #\x)))
    (dotimes (index 100)
      (output-publish sink
                      (event "type" "subscription" "subscriptionId" "slow"
                             "value" (json-object "index" index "text" large))
                      :droppable t))
    (sb-thread:with-mutex ((output-sink-lock sink))
      (check (<= (output-sink-count sink) +output-count-limit+)
             "stopped-reader count bound")
      (check (<= (output-sink-total-bytes sink) +output-byte-limit+)
             "stopped-reader encoded-byte bound"))
    (let ((started (monotonic-seconds)))
      (%close read-fd)
      (close-output-sink sink :drain nil)
      (check (< (- (monotonic-seconds) started) 0.9)
             "stopped-reader write deadline"))
    (%close write-fd))
  (sb-alien:free-alien fds))

;; Replacement and unsubscribe ACKs use a real owner and socket barrier. Each
;; Remove writes a genuine masked frame prefix, pauses, then times out. No ACK
;; or stale relay value may cross before the owner retires that socket.
(let ((fds (sb-alien:make-alien sb-alien:int 2)))
  (check (zerop (%pipe fds)) "owner barrier pipe creation")
  (let* ((read-fd (sb-alien:deref fds 0))
         (write-fd (sb-alien:deref fds 1))
         (sink (make-output-sink write-fd))
         (listener (adapter-test-listener))
         (client (make-client (adapter-test-listener-url listener)))
         (state (make-adapter-state :client client :output sink))
         (fixture-partials 0)
         (fixture
           (sb-thread:make-thread
            (lambda ()
              (unwind-protect
                   (dotimes (generation 2)
                     (let* ((stream (adapter-test-accept-websocket listener))
                            (connect (adapter-test-read-client-json stream))
                            (add (adapter-test-read-client-json stream))
                            (query-id
                              (json-get (first (json-get add "modifications"))
                                        "queryId")))
                       (declare (ignore connect))
                       (adapter-test-write-transition stream query-id generation)
                       ;; The client hook sends one real byte, then later
                       ;; retires this corrupt generation.
                       (read-byte stream)
                       (incf fixture-partials)
                       (loop while (read-byte stream nil nil))))
                (sb-bsd-sockets:socket-close listener)))
            :name "Adapter Remove barrier peer"))
         (relay-lock (sb-thread:make-mutex :name "Old relay pause"))
         (relay-condition (sb-thread:make-waitqueue :name "Old relay pause"))
         (relay-paused nil)
         (relay-released nil)
         (remove-lock (sb-thread:make-mutex :name "Partial Remove pause"))
         (remove-condition (sb-thread:make-waitqueue :name "Partial Remove pause"))
         (remove-paused 0)
         (remove-released 0)
         (worker nil)
         (captured ""))
    (unwind-protect
         (progn
           (handle-adapter-command
            state
            (json-object "id" "first" "op" "subscribe"
                         "subscriptionId" "same" "path" "demo:state"
                         "args" (json-object "room" "barrier")))
           (setf captured (fd-collect-until read-fd "\"count\":0" 3.0))
           (let* ((record (gethash "same" (adapter-state-relays state)))
                  (subscription (relay-record-subscription record))
                  (manager (subscription-manager subscription)))
             (setf *adapter-relay-after-dequeue-hook*
                   (lambda ()
                     (sb-thread:with-mutex (relay-lock)
                       (setf relay-paused t)
                       (sb-thread:condition-broadcast relay-condition)
                       (loop until relay-released
                             do (sb-thread:condition-wait
                                 relay-condition relay-lock)))))
             (enqueue-update manager subscription
                             (make-update :value (json-object "count" 99)
                                          :generation 0)
                             "stale-before-replacement")
             (sb-thread:with-mutex (relay-lock)
               (loop until relay-paused
                     do (sb-thread:condition-wait relay-condition relay-lock))))
           (setf *websocket-frame-write-hook*
                 (lambda (websocket opcode payload frame timeout)
                   (if (and (= opcode 1)
                            (search "\"Remove\"" (octets-string payload)))
                       (let ((this-remove nil))
                         (transport-write-all (websocket-transport websocket)
                                              (subseq frame 0 1) :timeout timeout)
                         (sb-thread:with-mutex (remove-lock)
                           (setf this-remove (incf remove-paused))
                           (sb-thread:condition-broadcast remove-condition)
                           (loop until (>= remove-released this-remove)
                                 do (sb-thread:condition-wait
                                     remove-condition remove-lock)))
                         (error 'transport-timeout
                                :operation "fixture partial Remove"))
                       (transport-write-all (websocket-transport websocket)
                                            frame :timeout timeout))))
           ;; Same-ID replacement must wait for old Remove retirement.
           (setf worker
                 (sb-thread:make-thread
                  (lambda ()
                    (handle-adapter-command
                     state
                     (json-object "id" "replace" "op" "subscribe"
                                  "subscriptionId" "same"
                                  "path" "demo:state"
                                  "args" (json-object "room" "barrier"))))
                  :name "Adapter replacement barrier"))
           (sb-thread:with-mutex (remove-lock)
             (loop until (= remove-paused 1)
                   do (sb-thread:condition-wait remove-condition remove-lock)))
           (handler-case
               (let ((premature (fd-read-some read-fd :timeout 0.15)))
                 (when premature
                   (setf captured
                         (concatenate 'string captured (octets-string premature)))))
             (transport-timeout () nil))
           (check (not (search "\"id\":\"replace\"" captured))
                  "replacement ACK crossed partial Remove")
           (setf *adapter-relay-after-dequeue-hook* nil)
           (sb-thread:with-mutex (relay-lock)
             (setf relay-released t)
             (sb-thread:condition-broadcast relay-condition))
           (sb-thread:with-mutex (remove-lock)
             (setf remove-released 1)
             (sb-thread:condition-broadcast remove-condition))
           (sb-thread:join-thread worker)
           (setf captured
                 (concatenate 'string captured
                              (fd-collect-until read-fd "\"id\":\"replace\""
                                                4.0)))
           (check (not (search "\"count\":99" captured))
                  "stale relay crossed replacement ACK")
           ;; Unsubscribe has the same transport barrier on the replacement.
           (setf worker
                 (sb-thread:make-thread
                  (lambda ()
                    (handle-adapter-command
                     state
                     (json-object "id" "unsubscribe" "op" "unsubscribe"
                                  "subscriptionId" "same")))
                  :name "Adapter unsubscribe barrier"))
           (sb-thread:with-mutex (remove-lock)
             (loop until (= remove-paused 2)
                   do (sb-thread:condition-wait remove-condition remove-lock)))
           (handler-case
               (let ((premature (fd-read-some read-fd :timeout 0.15)))
                 (when premature
                   (setf captured
                         (concatenate 'string captured (octets-string premature)))))
             (transport-timeout () nil))
           (check (not (search "\"id\":\"unsubscribe\"" captured))
                  "unsubscribe ACK crossed partial Remove")
           (sb-thread:with-mutex (remove-lock)
             (setf remove-released 2)
             (sb-thread:condition-broadcast remove-condition))
           (sb-thread:join-thread worker)
           (setf captured
                 (concatenate 'string captured
                              (fd-collect-until
                               read-fd "\"id\":\"unsubscribe\"" 3.0)))
           (sb-ext:with-timeout 2.0 (sb-thread:join-thread fixture))
           (check (= fixture-partials 2)
                  "fixture did not observe both partial Remove frames"))
      (setf *adapter-relay-after-dequeue-hook* nil
            *websocket-frame-write-hook* nil)
      (sb-thread:with-mutex (relay-lock)
        (setf relay-released t)
        (sb-thread:condition-broadcast relay-condition))
      (sb-thread:with-mutex (remove-lock)
        (setf remove-released 2)
        (sb-thread:condition-broadcast remove-condition))
      (when (and worker (sb-thread:thread-alive-p worker))
        (ignore-errors (sb-thread:terminate-thread worker)))
      (ignore-errors (cleanup-adapter state))
      (ignore-errors (client-close client))
      (when (sb-thread:thread-alive-p fixture)
        (handler-case (sb-ext:with-timeout 2.0 (sb-thread:join-thread fixture))
          (sb-ext:timeout () (ignore-errors (sb-thread:terminate-thread fixture)))
          (error () (ignore-errors (sb-thread:terminate-thread fixture)))))
      (close-output-sink sink :drain nil)
      (%close read-fd)
      (%close write-fd)))
  (sb-alien:free-alien fds))

;; Sixteen active subscriptions share one dispatcher. Pause it after dequeue,
;; publish an ACK concurrently, then enqueue newer states. One charged item
;; stays in flight, queued entries remain evictable, and publication has no
;; lock cycle with the encoder.
(let ((fds (sb-alien:make-alien sb-alien:int 2)))
  (check (zerop (%pipe fds)) "multi-relay gate pipe creation")
  (let* ((read-fd (sb-alien:deref fds 0))
         (write-fd (sb-alien:deref fds 1))
         (sink (make-output-sink write-fd))
         (state (make-adapter-state :output sink))
         (manager (%make-live-manager))
         (subscriptions '())
         (records '())
         (lock (sb-thread:make-mutex :name "Stalled relay gate"))
         (condition (sb-thread:make-waitqueue :name "Stalled relay gate"))
         (paused nil)
         (released nil)
         (target nil))
    (unwind-protect
         (progn
           (dotimes (index 16)
             (let* ((subscription
                      (%make-subscription :manager manager :query-id index
                                          :path "demo:state"
                                          :args (json-object "room" index)))
                    (id (format nil "gate-~D" index))
                    (record (make-relay-record :subscription subscription
                                               :generation 1 :active t)))
               (setf (gethash index (live-manager-active manager)) subscription
                     (gethash id (adapter-state-generations state)) 1
                     (gethash id (adapter-state-relays state)) record)
               (push subscription subscriptions)
               (push record records)
               (start-relay state id record)))
           (setf subscriptions (nreverse subscriptions)
                 *adapter-relay-after-dequeue-hook*
                 (lambda ()
                   (sb-thread:with-mutex (lock)
                     (unless paused
                       (setf paused t)
                       (sb-thread:condition-broadcast condition))
                     (loop until released
                           do (sb-thread:condition-wait condition lock)))))
           (loop for subscription in subscriptions
                 for index from 0
                 do (enqueue-update manager subscription
                                    (make-update
                                     :value (json-object "count" index)
                                     :generation 0)
                                    (format nil "initial-~D" index)))
           (sb-thread:with-mutex (lock)
             (loop until paused do (sb-thread:condition-wait condition lock)))
           (sb-thread:with-mutex ((live-manager-lock manager))
             (check (= (length (live-manager-in-flight-deliveries manager)) 1)
                    "relay gate allowed multiple in-flight deliveries")
             (check (= (live-delivery-count manager) 16)
                    "relay global count before eviction")
             (setf target
                   (delivery-subscription
                    (first (live-manager-in-flight-deliveries manager)))))
           (loop for count from 100 to 120
                 do (enqueue-update manager target
                                    (make-update
                                     :value (json-object "count" count)
                                     :generation 0)
                                    (format nil "newest-~D" count)))
           (sb-thread:with-mutex ((live-manager-lock manager))
             (check (<= (live-delivery-count manager) +delivery-count-limit+)
                    "multi-relay newest-state count bound")
             (check (<= (live-manager-delivery-bytes manager)
                        +delivery-byte-limit+)
                    "multi-relay newest-state byte bound"))
           (let ((started (monotonic-seconds)))
             (publish-response state (event "id" "parallel-ack" "type" "ack"))
             (check (< (- (monotonic-seconds) started) 0.5)
                    "relay and ACK lock-order deadlock"))
           (setf *adapter-relay-after-dequeue-hook* nil)
           (sb-thread:with-mutex (lock)
             (setf released t)
             (sb-thread:condition-broadcast condition))
           (let ((seen (fd-collect-until read-fd "\"count\":120" 5.0)))
             (check (search "\"id\":\"parallel-ack\"" seen)
                    "concurrent ACK disappeared behind relay publication")))
      (setf *adapter-relay-after-dequeue-hook* nil)
      (sb-thread:with-mutex (lock)
        (setf released t)
        (sb-thread:condition-broadcast condition))
      (cleanup-adapter state)
      (close-output-sink sink :drain nil)
      (%close read-fd)
      (%close write-fd)))
  (sb-alien:free-alien fds))

;; EOF cleanup is one client retirement, not one potentially failing owner
;; request per relay. Even managers with no runnable owner must release every
;; relay thread within one bounded cleanup.
(let ((fds (sb-alien:make-alien sb-alien:int 2)))
  (check (zerop (%pipe fds)) "multi-relay EOF pipe creation")
  (let* ((read-fd (sb-alien:deref fds 0))
         (write-fd (sb-alien:deref fds 1))
         (sink (make-output-sink write-fd))
         (state (make-adapter-state :output sink))
         (manager (%make-live-manager))
         (records '()))
    (dotimes (index 8)
      (let* ((subscription
               (%make-subscription :manager manager :query-id index
                                   :path "demo:state" :args (json-object)))
             (id (format nil "eof-~D" index))
             (record (make-relay-record :subscription subscription
                                        :generation 1 :active t)))
        (setf (gethash index (live-manager-active manager)) subscription
              (gethash id (adapter-state-generations state)) 1
              (gethash id (adapter-state-relays state)) record)
        (push record records)
        (start-relay state id record)))
    (let ((started (monotonic-seconds)))
      (cleanup-adapter state)
      (check (< (- (monotonic-seconds) started) 0.8)
             "multi-relay EOF cleanup deadline"))
    (check (not (sb-thread:thread-alive-p
                 (adapter-state-relay-thread state)))
           "multi-relay EOF left the dispatcher alive")
    (close-output-sink sink :drain nil)
    (%close read-fd)
    (%close write-fd))
  (sb-alien:free-alien fds))

;; Pause precisely after dequeue. Invalidation and its acknowledgement happen
;; before the old relay resumes, so the stale event must fail the generation
;; check and never cross that barrier.
(let ((fds (sb-alien:make-alien sb-alien:int 2)))
  (check (zerop (%pipe fds)) "relay pipe creation")
  (let* ((read-fd (sb-alien:deref fds 0))
         (write-fd (sb-alien:deref fds 1))
         (sink (make-output-sink write-fd))
         (state (make-adapter-state :output sink))
         (record (make-relay-record :generation 1 :active t))
         (lock (sb-thread:make-mutex :name "Paused adapter relay"))
         (condition (sb-thread:make-waitqueue :name "Paused adapter relay"))
         (paused nil)
         (released nil)
         (thread nil))
    (setf (gethash "same" (adapter-state-generations state)) 1
          *adapter-relay-after-dequeue-hook*
          (lambda ()
            (sb-thread:with-mutex (lock)
              (setf paused t)
              (sb-thread:condition-broadcast condition)
              (loop until released
                    do (sb-thread:condition-wait condition lock)))))
    (unwind-protect
         (progn
           (setf thread
                 (sb-thread:make-thread
                  (lambda ()
                    (publish-relay-event
                     state "same" record (make-update :value 99 :generation 0)
                     (event "type" "subscription" "subscriptionId" "same"
                            "value" (json-object "count" 99))))
                  :name "Paused stale relay"))
           (sb-thread:with-mutex (lock)
             (loop until paused do (sb-thread:condition-wait condition lock)))
           (sb-thread:with-mutex ((adapter-state-publication-lock state))
             (setf (relay-record-active record) nil)
             (next-generation state "same")
             (output-publish sink (event "id" "remove" "type" "ack")))
           (sb-thread:with-mutex (lock)
             (setf released t)
             (sb-thread:condition-broadcast condition))
           (sb-thread:join-thread thread)
           (let ((text (octets-string (fd-read-some read-fd :timeout 0.5))))
             (check (search "\"id\":\"remove\"" text) "barrier acknowledgement")
             (check (not (search "\"subscriptionId\":\"same\"" text))
                    "stale relay crossed acknowledgement")))
      (setf *adapter-relay-after-dequeue-hook* nil)
      (sb-thread:with-mutex (lock)
        (setf released t)
        (sb-thread:condition-broadcast condition))
      (when (and thread (sb-thread:thread-alive-p thread))
        (ignore-errors (sb-thread:terminate-thread thread)))
      (close-output-sink sink :drain nil)
      (%close read-fd)
      (%close write-fd)))
  (sb-alien:free-alien fds))

;; debugDisconnect has a separate transport-generation barrier. The
;; subscription remains active, but an old connection's already-dequeued value
;; cannot cross the debug ACK; a later new-generation value still can.
(let ((fds (sb-alien:make-alien sb-alien:int 2)))
  (check (zerop (%pipe fds)) "debug barrier pipe creation")
  (let* ((read-fd (sb-alien:deref fds 0))
         (write-fd (sb-alien:deref fds 1))
         (sink (make-output-sink write-fd))
         (state (make-adapter-state :output sink))
         (record (make-relay-record :generation 1 :active t))
         (lock (sb-thread:make-mutex :name "Paused debug relay"))
         (condition (sb-thread:make-waitqueue :name "Paused debug relay"))
         (paused nil)
         (released nil)
         (thread nil))
    (setf (gethash "live" (adapter-state-generations state)) 1
          *adapter-relay-after-dequeue-hook*
          (lambda ()
            (sb-thread:with-mutex (lock)
              (setf paused t)
              (sb-thread:condition-broadcast condition)
              (loop until released
                    do (sb-thread:condition-wait condition lock)))))
    (unwind-protect
         (progn
           (setf thread
                 (sb-thread:make-thread
                  (lambda ()
                    (publish-relay-event
                     state "live" record
                     (make-update :value (json-object "count" 99) :generation 0)
                     (event "type" "subscription" "subscriptionId" "live"
                            "value" (json-object "count" 99))))
                  :name "Paused pre-debug relay"))
           (sb-thread:with-mutex (lock)
             (loop until paused do (sb-thread:condition-wait condition lock)))
           (sb-thread:with-mutex ((adapter-state-publication-lock state))
             (setf (adapter-state-minimum-live-generation state) 1)
             (output-publish sink (event "id" "debug" "type" "ack")))
           (setf *adapter-relay-after-dequeue-hook* nil)
           (sb-thread:with-mutex (lock)
             (setf released t)
             (sb-thread:condition-broadcast condition))
           (sb-thread:join-thread thread)
           (publish-relay-event
            state "live" record
            (make-update :value (json-object "count" 100) :generation 1)
            (event "type" "subscription" "subscriptionId" "live"
                   "value" (json-object "count" 100)))
           (sleep 0.05)
           (let ((text (octets-string (fd-read-some read-fd :timeout 0.5))))
             (check (search "\"id\":\"debug\"" text) "debug acknowledgement")
             (check (not (search "\"count\":99" text))
                    "old transport value crossed debug acknowledgement")
             (check (search "\"count\":100" text)
                    "new transport value was stranded")))
      (setf *adapter-relay-after-dequeue-hook* nil)
      (sb-thread:with-mutex (lock)
        (setf released t)
        (sb-thread:condition-broadcast condition))
      (when (and thread (sb-thread:thread-alive-p thread))
        (ignore-errors (sb-thread:terminate-thread thread)))
      (close-output-sink sink :drain nil)
      (%close read-fd)
      (%close write-fd)))
  (sb-alien:free-alien fds))

;; Keep schema-sensitive event shapes local and deterministic. Optional fields
;; are omitted rather than serialized as JSON null.
(let* ((success
         (json-decode (json-encode
                       (event "id" "query" "type" "result"
                              "value" (json-object "count" 1)))))
       (http-error
         (json-decode
          (json-encode
           (error-event
            (make-condition 'function-error :name "FunctionError"
                            :message "nope" :data (json-object "code" "NOPE")
                            :logs '("failed"))
            :id "mutation"))))
       (subscription-error
         (json-decode
          (json-encode
           (error-event
            (make-condition 'protocol-error :name "ProtocolError"
                            :message "bad transition")
            :subscription-id "live"))))
       (closed (json-decode (json-encode (event "id" "close" "type" "closed")))))
  (check (and (string= (json-get success "type") "result")
              (json-has-key-p success "value"))
         "serialized success shape")
  (check (and (string= (json-get (json-get http-error "error") "name")
                       "FunctionError")
              (string= (json-get (json-get (json-get http-error "error") "data")
                                 "code")
                       "NOPE")
              (equal (json-get http-error "logs") '("failed")))
         "serialized HTTP error shape")
  (check (and (string= (json-get subscription-error "subscriptionId") "live")
              (not (json-has-key-p subscription-error "id"))
              (string= (json-get (json-get subscription-error "error") "name")
                       "ProtocolError"))
         "serialized subscription error shape")
  (check (and (string= (json-get closed "type") "closed")
              (not (json-has-key-p closed "value")))
         "serialized close shape"))

(format t "PASS adapter TCP, partial input, isolation, barriers, EOF, and backpressure~%")
