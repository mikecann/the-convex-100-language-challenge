(load "/project/client/load.lisp")

(in-package #:convex)

(defun check (condition message)
  (unless condition (error "Live test failed: ~A" message)))

(defun timestamp (value)
  (let ((bytes (make-array 8 :element-type '(unsigned-byte 8))))
    (dotimes (index 8)
      (setf (aref bytes index) (ldb (byte 8 (* index 8)) value)))
    (base64-encode bytes)))

(defun read-exactly (stream count)
  (let ((result (make-array count :element-type '(unsigned-byte 8))))
    (loop with offset = 0
          while (< offset count)
          for next = (read-sequence result stream :start offset)
          do (when (= next offset) (error "Fixture peer reached EOF"))
             (setf offset next))
    result))

(defun read-http-request (stream)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 0)))
    (loop until (find-octets +header-end+ bytes)
          do (vector-push-extend (read-byte stream) bytes)
             (when (> (length bytes) (* 64 1024)) (error "Fixture handshake too large")))
    (let* ((end (find-octets +header-end+ bytes))
           (lines (split-lines (octets-string (subseq bytes 0 end))))
           (headers (make-hash-table :test #'equal)))
      (check (search "GET /api/sync HTTP/1.1" (first lines)) "upgrade request")
      (dolist (line (rest lines))
        (let ((colon (position #\: line)))
          (setf (gethash (string-downcase (subseq line 0 colon)) headers)
                (string-trim '(#\Space #\Tab) (subseq line (1+ colon))))))
      headers)))

(defun accept-websocket (listener)
  (let* ((socket (sb-bsd-sockets:socket-accept listener))
         (stream (sb-bsd-sockets:socket-make-stream
                  socket :input t :output t :element-type '(unsigned-byte 8)
                  :buffering :none))
         (headers (read-http-request stream))
         (key (gethash "sec-websocket-key" headers))
         (accept (base64-encode
                  (sha1 (string-octets
                         (concatenate 'string key
                                      "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))))))
    (write-sequence
     (string-octets
      (format nil
              "HTTP/1.1 101 Switching Protocols~C~CUpgrade: websocket~C~CConnection: Upgrade~C~CSec-WebSocket-Accept: ~A~C~C~C~C"
              #\Return #\Newline #\Return #\Newline #\Return #\Newline
              accept #\Return #\Newline #\Return #\Newline))
     stream)
    (force-output stream)
    (values stream socket)))

(defun read-client-frame (stream)
  (let* ((first (read-byte stream))
         (second (read-byte stream))
         (opcode (logand first #x0f))
         (masked (not (zerop (logand second #x80))))
         (code (logand second #x7f))
         (length
           (cond
             ((< code 126) code)
             ((= code 126)
              (+ (ash (read-byte stream) 8) (read-byte stream)))
             (t (loop repeat 8 for byte = (read-byte stream)
                      for value = byte then (+ (ash value 8) byte)
                      finally (return value)))))
         (mask (and masked (read-exactly stream 4)))
         (payload (read-exactly stream length)))
    (check masked "client frame was not masked")
    (dotimes (index length)
      (setf (aref payload index)
            (logxor (aref payload index) (aref mask (mod index 4)))))
    (values opcode payload)))

(defun read-client-json (stream)
  (loop
    (multiple-value-bind (opcode payload) (read-client-frame stream)
      (case opcode
        (1 (return (json-decode (octets-string payload))))
        (8 (return :closed))
        ((9 10) nil)
        (otherwise (error "Unexpected client opcode ~D" opcode))))))

(defun write-server-frame (stream opcode payload &key (final t))
  (write-sequence (websocket-frame-bytes opcode payload :final final :masked nil) stream)
  (force-output stream))

(defun write-server-json (stream object &key fragmented)
  (let ((payload (string-octets (json-encode object))))
    (if fragmented
        (let* ((marker (position #xF0 payload))
               (split (if marker (1+ marker) (floor (length payload) 2))))
          ;; Split inside a four-byte UTF-8 code point and interleave ping. The
          ;; client must retain both frame and decoder state across the control.
          (write-server-frame stream 1 (subseq payload 0 split) :final nil)
          (write-server-frame stream 9 (string-octets "fixture-ping"))
          (write-server-frame stream 0 (subseq payload split) :final t))
        (write-server-frame stream 1 payload))))

(defun transition (start-query end-query start-ts end-ts query-id kind
                    &key (count 0) error)
  (let ((modification
          (cond
            ((string= kind "QueryUpdated")
             (json-object "type" kind "queryId" query-id
                          "value" (json-object "count" count
                                               "note" "fragmented 🟨")
                          "logLines" '() "journal" +json-null+))
            ((string= kind "QueryFailed")
             (json-object "type" kind "queryId" query-id
                          "errorMessage" "room is empty"
                          "errorData" (json-object "code" (or error "ROOM_EMPTY"))
                          "logLines" '()))
            (t (error "Unknown fixture modification")))))
    (json-object
     "type" "Transition"
     "startVersion" (state-version start-query 0 start-ts)
     "endVersion" (state-version end-query 0 end-ts)
     "modifications" (list modification))))

(defun make-listener ()
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket
                                 :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen listener 8)
    listener))

(defun listener-url (listener)
  (multiple-value-bind (address port) (sb-bsd-sockets:socket-name listener)
    (declare (ignore address))
    (format nil "http://127.0.0.1:~D" port)))

;; A peer that accepts TCP but never finishes the upgrade cannot strand Live.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (let ((socket (sb-bsd-sockets:socket-accept listener)))
                   (sleep 0.6)
                   (sb-bsd-sockets:socket-close socket))
              (sb-bsd-sockets:socket-close listener)))
          :name "Stalled handshake fixture"))
       (started (monotonic-seconds))
       (timed-out nil))
  (handler-case
      (websocket-connect (parse-url (listener-url listener)) "fixture" :timeout 0.2)
    (transport-timeout () (setf timed-out t)))
  (check timed-out "stalled handshake timeout")
  (check (< (- (monotonic-seconds) started) 0.8) "handshake deadline")
  (sb-thread:join-thread fixture))

;; One absolute deadline covers slow-drip headers rather than restarting for
;; every received byte.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (handler-case
                     (let* ((socket (sb-bsd-sockets:socket-accept listener))
                            (stream
                              (sb-bsd-sockets:socket-make-stream
                               socket :input t :output t
                               :element-type '(unsigned-byte 8) :buffering :none))
                            (headers (read-http-request stream))
                            (key (gethash "sec-websocket-key" headers))
                            (accept
                              (base64-encode
                               (sha1
                                (string-octets
                                 (concatenate
                                  'string key
                                  "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))))
                            (response
                              (string-octets
                               (format nil
                                       "HTTP/1.1 101 Switching Protocols~C~CUpgrade: websocket~C~CConnection: Upgrade~C~CSec-WebSocket-Accept: ~A~C~C~C~C"
                                       #\Return #\Newline #\Return #\Newline
                                       #\Return #\Newline accept #\Return
                                       #\Newline #\Return #\Newline))))
                       (loop for byte across response
                             do (write-byte byte stream)
                                (force-output stream)
                                (sleep 0.03)))
                   (error () nil))
              (sb-bsd-sockets:socket-close listener)))
          :name "Slow-drip handshake fixture"))
       (started (monotonic-seconds))
       (timed-out nil))
  (handler-case
      (websocket-connect (parse-url (listener-url listener)) "fixture" :timeout 0.2)
    (transport-timeout () (setf timed-out t)))
  (check timed-out "slow-drip handshake timeout")
  (check (< (- (monotonic-seconds) started) 0.5)
         "slow-drip absolute deadline")
  (sb-thread:join-thread fixture))

;; A stalled handshake write is interrupted by that same deadline.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (let ((socket (sb-bsd-sockets:socket-accept listener)))
                   (sleep 0.4)
                   (sb-bsd-sockets:socket-close socket))
              (sb-bsd-sockets:socket-close listener)))
          :name "Stalled handshake write fixture"))
       (*websocket-before-handshake-write-hook* (lambda () (sleep 1.0)))
       (started (monotonic-seconds))
       (timed-out nil))
  (handler-case
      (websocket-connect (parse-url (listener-url listener)) "fixture" :timeout 0.15)
    (transport-timeout () (setf timed-out t)))
  (check timed-out "stalled handshake write timeout")
  (check (< (- (monotonic-seconds) started) 0.5)
         "stalled handshake write deadline")
  (sb-thread:join-thread fixture))

(let ((rejected nil))
  (handler-case
      (websocket-connect (parse-url "http://127.0.0.1:1")
                         (format nil "client~%Injected: yes") :timeout 0.1)
    (error () (setf rejected t)))
  (check rejected "WebSocket client header control rejection"))

;; DNS resolution consumes the same handshake deadline as connect and TLS.
(let ((*dns-resolver* (lambda (host) (declare (ignore host)) (sleep 1.0))))
  (let ((started (monotonic-seconds))
        (timed-out nil))
    (handler-case
        (open-transport (parse-url "http://stalled-resolver.invalid") :timeout 0.1)
      (error () (setf timed-out t)))
    (check timed-out "DNS timeout")
    (check (< (- (monotonic-seconds) started) 0.5) "DNS handshake deadline")))

;; DNS may consume almost all of the budget. TCP connect must use the strict
;; remainder rather than granting itself a fresh minimum timeout.
(let ((resolver *dns-resolver*))
  (let ((*dns-resolver*
          (lambda (host)
            (sleep 0.09)
            (funcall resolver host))))
    (let ((started (monotonic-seconds))
          (failed nil))
      (handler-case
          (open-transport (parse-url "http://203.0.113.1:81") :timeout 0.1)
        (error () (setf failed t)))
      (check failed "near-deadline connect unexpectedly succeeded")
      (check (< (- (monotonic-seconds) started) 0.16)
             "DNS plus connect extended the absolute deadline"))))

;; A multi-query transition is inserted under one manager lock. Pause after
;; the first insertion and prove a consumer cannot observe that partial state.
(let* ((manager (%make-live-manager))
       (first-subscription
         (%make-subscription :manager manager :query-id 1 :path "demo:first"
                             :args (json-object)))
       (second-subscription
         (%make-subscription :manager manager :query-id 2 :path "demo:second"
                             :args (json-object)))
       (lock (sb-thread:make-mutex :name "Transactional hydration"))
       (condition (sb-thread:make-waitqueue :name "Transactional hydration"))
       (paused nil)
       (released nil)
       (consumer-done nil)
       (consumer-value nil)
       (producer nil)
       (consumer nil))
  (setf (gethash 1 (live-manager-active manager)) first-subscription
        (gethash 2 (live-manager-active manager)) second-subscription
        *delivery-batch-after-first-hook*
        (lambda ()
          (sb-thread:with-mutex (lock)
            (setf paused t)
            (sb-thread:condition-broadcast condition)
            (loop until released
                  do (sb-thread:condition-wait condition lock)))))
  (unwind-protect
       (progn
         (setf producer
               (sb-thread:make-thread
                (lambda ()
                  (enqueue-changes
                   manager
                   (list
                    (list first-subscription
                          (make-update :value (json-object "count" 1)) "first")
                    (list second-subscription
                          (make-update :value (json-object "count" 2)) "second"))))
                :name "Transactional producer"))
         (sb-thread:with-mutex (lock)
           (loop until paused do (sb-thread:condition-wait condition lock)))
         (setf consumer
               (sb-thread:make-thread
                (lambda ()
                  (setf consumer-value
                        (subscription-next first-subscription :timeout 1.0)
                        consumer-done t))
                :name "Transactional consumer"))
         (sleep 0.05)
         (check (not consumer-done) "partial transition became visible")
         (sb-thread:with-mutex (lock)
           (setf released t)
           (sb-thread:condition-broadcast condition))
         (sb-thread:join-thread producer)
         (sb-thread:join-thread consumer)
         (check (= (json-get (update-value consumer-value) "count") 1)
                "first transactional value")
         (check (= (json-get
                    (update-value
                     (subscription-next second-subscription :timeout 0.1))
                    "count")
                   2)
                "second transactional value"))
    (setf *delivery-batch-after-first-hook* nil)
    (sb-thread:with-mutex (lock)
      (setf released t)
      (sb-thread:condition-broadcast condition))
    (dolist (thread (list producer consumer))
      (when (and thread (sb-thread:thread-alive-p thread))
        (ignore-errors (sb-thread:terminate-thread thread))))))

;; Full-event accounting includes logs, structured error data and conservative
;; Lisp object overhead, not just the value field's encoded bytes.
(let* ((manager (%make-live-manager))
       (subscription
         (%make-subscription :manager manager :query-id 1 :path "demo:large"
                             :args (json-object)))
       (large (make-string 500000 :initial-element #\x))
       (small (make-update :value (json-object "count" 1)))
       (large-error
         (make-update
          :error
          (make-condition 'function-error :name "FunctionError"
                          :message "large error"
                          :data (json-object "detail" large)
                          :logs (list large)))))
  (setf (gethash 1 (live-manager-active manager)) subscription)
  (check (> (update-accounted-size large-error) (update-accounted-size small))
         "logs and structured error data were not charged")
  (dotimes (index 40)
    (enqueue-update manager subscription large-error (format nil "error-~D" index)))
  (check (<= (length (live-manager-deliveries manager)) +delivery-count-limit+)
         "full-event count bound")
  (check (<= (live-manager-delivery-bytes manager) +delivery-byte-limit+)
         "full-event byte and overhead bound"))

;; Dense JSON has little wire text but many hash tables and cons cells. Its
;; recursive runtime charge must evict older messages before count alone does.
(let* ((manager (%make-live-manager))
       (subscription
         (%make-subscription :manager manager :query-id 2 :path "demo:dense"
                             :args (json-object))))
  (setf (gethash 2 (live-manager-active manager)) subscription)
  (dotimes (index 12)
    (let* ((dense (loop repeat 4000 collect (json-object)))
           (update (make-update :value (json-object "index" index "dense" dense))))
      (enqueue-update manager subscription update (format nil "dense-~D" index))))
  (check (< (length (live-manager-deliveries manager)) 12)
         "dense delivery runtime overhead was not charged")
  (check (<= (live-manager-delivery-bytes manager) +delivery-byte-limit+)
         "dense delivery byte bound"))

;; Active arguments use the same recursive structural charge, and subscription
;; count/bytes are separately bounded from the delivery queue.
(let* ((manager (%make-live-manager))
       (dense (loop repeat 4000 collect (json-object)))
       (args (json-object "dense" dense))
       (size (calculate-subscription-size "demo:dense" args)))
  (check (> size (+ 4096 (* 4 (json-encoded-byte-length args))))
         "active dense argument overhead was not charged")
  (setf (live-manager-active-bytes manager)
        (- +active-subscription-byte-limit+ size -1))
  (let ((rejected nil))
    (handler-case (ensure-subscription-capacity manager size)
      (protocol-error () (setf rejected t)))
    (check rejected "active subscription byte bound")))

;; Sixty-four large subscriptions retain only fixed SHA-256 signatures, never
;; a second canonical JSON string per active value.
(let ((signatures (make-array +active-subscription-count-limit+)))
  (dotimes (index +active-subscription-count-limit+)
    (let ((value
            (json-object
             "index" index
             "text" (make-string 300000 :initial-element
                                 (code-char (+ (char-code #\a) (mod index 26)))))))
      (setf (aref signatures index) (value-signature value))))
  (check (every (lambda (signature) (= (length signature) 50)) signatures)
         "large subscription signature was not bounded")
  (check (= (length (remove-duplicates (coerce signatures 'list)
                                        :test #'string=))
            +active-subscription-count-limit+)
         "large subscription signatures did not distinguish values"))

;; Initial value, external update, QueryFailed recovery, fragmented UTF-8,
;; interleaved ping, canonical timestamps, and Remove all use a real socket.
(let* ((listener (make-listener))
       (remove-seen nil)
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (let ((stream (accept-websocket listener)))
                   (let ((connect (read-client-json stream))
                         (add (read-client-json stream)))
                     (check (string= (json-get connect "type") "Connect") "Connect")
                     (check (string= (json-get (first (json-get add "modifications"))
                                              "type") "Add") "Add")
                     (let ((duplicate
                             (handler-case
                                 (sb-ext:with-timeout 0.15
                                   (read-client-json stream))
                               (sb-ext:timeout () nil))))
                       (check (null duplicate)
                              "initial subscribe sent a duplicate buffered Add"))
                     (let ((query-id
                             (json-get (first (json-get add "modifications")) "queryId")))
                       (write-server-json stream
                                          (transition 0 1 (timestamp 0) (timestamp 1)
                                                      query-id "QueryUpdated" :count 0)
                                          :fragmented t)
                       (write-server-json stream
                                          (transition 1 1 (timestamp 1) (timestamp 2)
                                                      query-id "QueryFailed"))
                       (write-server-json stream
                                          (transition 1 1 (timestamp 2) (timestamp 3)
                                                      query-id "QueryUpdated" :count 1))
                       (loop for message = (read-client-json stream)
                             until (eq message :closed)
                             when (and (hash-table-p message)
                                       (string= (json-get message "type") "ModifyQuerySet")
                                       (string= (json-get
                                                 (first (json-get message "modifications"))
                                                 "type") "Remove"))
                               do (setf remove-seen t) (return))
                       (close stream)))
              (sb-bsd-sockets:socket-close listener))))
          :name "Live transition fixture"))
       (client (make-client (listener-url listener)))
       (subscription (client-subscribe client "demo:state" (json-object "room" "test"))))
  (let ((initial (subscription-next subscription :timeout 3.0)))
    (check (= (json-get (update-value initial) "count") 0) "initial QueryUpdated")
    (check (string= (json-get (update-value initial) "note") "fragmented 🟨")
           "fragmented UTF-8"))
  (let ((failed (subscription-next subscription :timeout 3.0)))
    (check (typep (update-error failed) 'function-error) "QueryFailed type")
    (check (string= (json-get (error-data (update-error failed)) "code") "ROOM_EMPTY")
           "QueryFailed data"))
  (let ((recovered (subscription-next subscription :timeout 3.0)))
    (check (= (json-get (update-value recovered) "count") 1) "QueryFailed recovery"))
  (let ((metadata (client-live-metadata client)))
    (check (string= (json-get metadata "maxObservedTimestamp") (timestamp 3))
           "maxObservedTimestamp")
    (check (<= (json-get metadata "queuedCount") 16) "global count bound")
    (check (<= (json-get metadata "queuedBytes") +delivery-byte-limit+)
           "global byte bound"))
  (subscription-close subscription)
  (client-close client)
  (sb-thread:join-thread fixture)
  (check remove-seen "Remove was not written before unsubscribe returned"))

;; A malformed transition produces ProtocolError, retires that generation,
;; reconnects with Add and timestamp metadata, then delivers a later valid value.
(let* ((listener (make-listener))
       (connects '())
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (dotimes (generation 2)
                   (let* ((stream (accept-websocket listener))
                          (connect (read-client-json stream))
                          (add (read-client-json stream))
                          (query-id (json-get (first (json-get add "modifications"))
                                              "queryId")))
                     (push connect connects)
                     (if (zerop generation)
                         (progn
                           (write-server-json stream
                                              (transition 0 1 (timestamp 0) (timestamp 4)
                                                          query-id "QueryUpdated" :count 4))
                           (write-server-frame stream 1 #(255 254 253)))
                         (write-server-json stream
                                            (transition 0 1 (timestamp 0) (timestamp 5)
                                                        query-id "QueryUpdated" :count 5)))
                     (when (zerop generation) (close stream))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Live recovery fixture"))
       (client (make-client (listener-url listener)))
       (subscription (client-subscribe client "demo:state" (json-object "room" "recovery"))))
  (check (= (json-get (update-value (subscription-next subscription :timeout 3.0)) "count") 4)
         "pre-failure value")
  (let ((failed (subscription-next subscription :timeout 3.0)))
    (check (typep (update-error failed) 'protocol-error) "malformed UTF-8 ProtocolError"))
  (let ((recovered (subscription-next subscription :timeout 5.0)))
    (check (= (json-get (update-value recovered) "count") 5)
           "protocol reconnect recovery"))
  (client-close client)
  (sb-thread:join-thread fixture)
  (setf connects (nreverse connects))
  (check (= (length connects) 2) "real reconnect count")
  (check (= (json-get (second connects) "connectionCount") 1) "connectionCount metadata")
  (check (string= (json-get (second connects) "maxObservedTimestamp") (timestamp 4))
         "reconnect timestamp metadata"))

;; A malformed endVersion cannot commit an otherwise valid value or timestamp.
;; After reconnect, two changes for one query coalesce to only the final value.
(let* ((listener (make-listener))
       (connects '())
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (dotimes (generation 2)
                   (let* ((stream (accept-websocket listener))
                          (connect (read-client-json stream))
                          (add (read-client-json stream))
                          (query-id
                            (json-get (first (json-get add "modifications"))
                                      "queryId")))
                     (push connect connects)
                     (if (zerop generation)
                         (progn
                           (write-server-json
                            stream
                            (transition 0 1 (timestamp 0) (timestamp 1)
                                        query-id "QueryUpdated" :count 0))
                           (write-server-json
                            stream
                            (json-object
                             "type" "Transition"
                             "startVersion" (state-version 1 0 (timestamp 1))
                             "endVersion"
                             (json-object "querySet" "1" "identity" -1
                                          "ts" (timestamp 100))
                             "modifications"
                             (list
                              (json-object "type" "QueryUpdated"
                                           "queryId" query-id
                                           "value" (json-object "count" 9)
                                           "logLines" '()))))
                           (loop for message = (read-client-json stream)
                                 until (eq message :closed)))
                         (progn
                           (write-server-json
                            stream
                            (json-object
                             "type" "Transition"
                             "startVersion" (state-version 0 0 (timestamp 0))
                             "endVersion" (state-version 1 0 (timestamp 2))
                             "modifications"
                             (list
                              (json-object "type" "QueryUpdated"
                                           "queryId" query-id
                                           "value" (json-object "count" 1)
                                           "logLines" '())
                              (json-object "type" "QueryUpdated"
                                           "queryId" query-id
                                           "value" (json-object "count" 2)
                                           "logLines" '()))))
                           (loop for message = (read-client-json stream)
                                 until (eq message :closed))))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Transactional transition fixture"))
       (client (make-client (listener-url listener)))
       (subscription
         (client-subscribe client "demo:state" (json-object "room" "transaction"))))
  (check (= (json-get (update-value (subscription-next subscription :timeout 3.0))
                       "count")
            0)
         "transaction pre-value")
  (let ((failed (subscription-next subscription :timeout 3.0)))
    (check (typep (update-error failed) 'protocol-error)
           "malformed endVersion ProtocolError"))
  (let ((recovered (subscription-next subscription :timeout 5.0)))
    (check (= (json-get (update-value recovered) "count") 2)
           "per-query transition coalescing"))
  (check (null (subscription-next subscription :timeout 0.2))
         "intermediate coalesced value was published")
  (client-close client)
  (sb-thread:join-thread fixture)
  (setf connects (nreverse connects))
  (check (string= (json-get (second connects) "maxObservedTimestamp") (timestamp 1))
         "malformed endVersion advanced timestamp metadata"))

;; Diagnostic fields are part of the transaction too. Invalid logs or error
;; messages emit ProtocolError, commit no state, and do not strand the query.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (dotimes (generation 4)
                   (let* ((stream (accept-websocket listener))
                          (connect (read-client-json stream))
                          (add (read-client-json stream))
                          (query-id
                            (json-get (first (json-get add "modifications"))
                                      "queryId")))
                     (declare (ignore connect))
                     (cond
                       ((zerop generation)
                        (write-server-json
                         stream
                         (transition 0 1 (timestamp 0) (timestamp 1)
                                     query-id "QueryUpdated" :count 0))
                        (write-server-json
                         stream
                         (json-object
                          "type" "Transition"
                          "startVersion" (state-version 1 0 (timestamp 1))
                          "endVersion" (state-version 2 0 (timestamp 20))
                          "modifications"
                          (list (json-object "type" "QueryUpdated"
                                             "queryId" query-id
                                             "value" (json-object "count" 20)
                                             "logLines" "not-an-array")))))
                       ((= generation 1)
                        (write-server-json
                         stream
                         (json-object
                          "type" "Transition"
                          "startVersion" (state-version 0 0 (timestamp 0))
                          "endVersion" (state-version 1 0 (timestamp 21))
                          "modifications"
                          (list (json-object "type" "QueryFailed"
                                             "queryId" query-id
                                             "errorMessage" 7
                                             "logLines" '())))))
                       ((= generation 2)
                        (write-server-frame
                         stream 1
                         (string-octets
                          (concatenate
                           'string
                           "{\"type\":\"Transition\",\"startVersion\":"
                           (json-encode (state-version 0 0 (timestamp 0)))
                           ",\"endVersion\":"
                           (json-encode (state-version 1 0 (timestamp 22)))
                           ",\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":"
                           (write-to-string query-id)
                           ",\"value\":"
                           (make-string 129 :initial-element #\[) "0"
                           (make-string 129 :initial-element #\])
                           ",\"logLines\":[]}]}"))))
                       (t
                        (write-server-json
                         stream
                         (transition 0 1 (timestamp 0) (timestamp 2)
                                     query-id "QueryUpdated" :count 2))))
                     (loop for message = (read-client-json stream)
                           until (eq message :closed))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Malformed Live diagnostic recovery fixture"))
       (client (make-client (listener-url listener)))
       (subscription
         (client-subscribe client "demo:state" (json-object "room" "diagnostics"))))
  (check (= (json-get (update-value
                       (subscription-next subscription :timeout 3.0)) "count") 0)
         "diagnostic pre-value")
  (dotimes (index 3)
    (declare (ignore index))
    (let ((failed (subscription-next subscription :timeout 5.0)))
      (check (typep (update-error failed) 'protocol-error)
             "malformed Live diagnostic ProtocolError")))
  (let ((recovered (subscription-next subscription :timeout 5.0)))
    (check (= (json-get (update-value recovered) "count") 2)
           "malformed Live diagnostic recovery"))
  (client-close client)
  (sb-thread:join-thread fixture))

;; A real peer close surfaces TransportError, then the same subscription
;; reconnects. Its unchanged hydration is suppressed before a later value.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (dotimes (generation 2)
                   (multiple-value-bind (stream peer) (accept-websocket listener)
                     (let* ((connect (read-client-json stream))
                            (add (read-client-json stream))
                            (query-id
                              (json-get (first (json-get add "modifications"))
                                        "queryId")))
                       (declare (ignore connect))
                       (write-server-json
                        stream
                        (transition 0 1 (timestamp 0) (timestamp (1+ generation))
                                    query-id "QueryUpdated" :count 0))
                       (if (zerop generation)
                           ;; Abortive close exercises reset/read-error handling
                           ;; where the platform supports SO_LINGER semantics.
                           (sb-bsd-sockets:socket-close peer :abort t)
                           (progn
                             (write-server-json
                              stream
                              (transition 1 1 (timestamp 2) (timestamp 3)
                                          query-id "QueryUpdated" :count 1))
                             (loop for message = (read-client-json stream)
                                   until (eq message :closed)))))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Transport retirement fixture"))
       (client (make-client (listener-url listener)))
       (subscription
         (client-subscribe client "demo:state" (json-object "room" "transport"))))
  (check (= (json-get (update-value (subscription-next subscription :timeout 3.0))
                       "count")
            0)
         "pre-retirement value")
  (let ((retired (subscription-next subscription :timeout 3.0)))
    (check (typep (update-error retired) 'transport-error)
           "peer close TransportError"))
  (let ((recovered (subscription-next subscription :timeout 5.0)))
    (check (= (json-get (update-value recovered) "count") 1)
           "transport retirement recovery"))
  (client-close client)
  (sb-thread:join-thread fixture))

;; A timeout after one real Pong frame byte is not an idle read. The owner must
;; surface TransportError, abandon that connection, and recover the query.
(let* ((listener (make-listener))
       (partial-pong-seen nil)
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (dotimes (generation 2)
                   (let* ((stream (accept-websocket listener))
                          (connect (read-client-json stream))
                          (add (read-client-json stream))
                          (query-id
                            (json-get (first (json-get add "modifications"))
                                      "queryId")))
                     (declare (ignore connect))
                     (write-server-json
                      stream
                      (transition 0 1 (timestamp 0) (timestamp (1+ generation))
                                  query-id "QueryUpdated" :count generation))
                     (if (zerop generation)
                         (progn
                           (write-server-frame stream 9 (string-octets "pong-timeout"))
                           ;; The test hook writes exactly one masked Pong byte.
                           (read-byte stream)
                           (setf partial-pong-seen t)
                           (close stream))
                         (loop for message = (read-client-json stream)
                               until (eq message :closed)))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Partial Pong retirement fixture"))
       (client (make-client (listener-url listener)))
       (subscription nil)
       (failed nil))
  (setf *websocket-frame-write-hook*
        (lambda (websocket opcode payload frame timeout)
          (declare (ignore payload))
          (if (and (= opcode 10) (not partial-pong-seen))
              (progn
                (transport-write-all (websocket-transport websocket)
                                     (subseq frame 0 1) :timeout timeout)
                (error 'transport-timeout :operation "fixture partial Pong"))
              (transport-write-all (websocket-transport websocket) frame
                                   :timeout timeout))))
  (unwind-protect
       (progn
         (setf subscription
               (client-subscribe client "demo:state"
                                 (json-object "room" "partial-pong")))
         (check (= (json-get (update-value
                              (subscription-next subscription :timeout 3.0))
                             "count")
                   0)
                "partial Pong pre-value")
         (setf failed (subscription-next subscription :timeout 3.0))
         (check (typep (update-error failed) 'transport-error)
                "partial Pong timeout was not TransportError")
         (check (= (json-get (update-value
                              (subscription-next subscription :timeout 5.0))
                             "count")
                   1)
                "partial Pong recovery"))
    (setf *websocket-frame-write-hook* nil)
    (ignore-errors (client-close client))
    (sb-thread:join-thread fixture))
  (check partial-pong-seen "fixture did not receive the partial Pong byte"))

;; Five forced disconnects must retire each old generation before returning,
;; resend Add on every connection, coalesce unchanged hydration, and preserve
;; connection metadata. This is the same ordering the adapter exposes.
(let* ((listener (make-listener))
       (connects '())
       (adds 0)
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (dotimes (generation 6)
                   (let* ((stream (accept-websocket listener))
                          (connect (read-client-json stream))
                          (add (read-client-json stream))
                          (query-id (json-get (first (json-get add "modifications"))
                                              "queryId"))
                          (base-ts (* generation 2)))
                     (push connect connects)
                     (incf adds)
                     ;; Rehydration carries the last delivered value. From the
                     ;; second connection onward it must not reach the consumer.
                     (write-server-json
                      stream
                      (transition 0 1 (timestamp 0) (timestamp (1+ base-ts))
                                  query-id "QueryUpdated"
                                  :count (max 0 (1- generation))))
                     (when (plusp generation)
                       (write-server-json
                        stream
                        (transition 1 1 (timestamp (1+ base-ts))
                                    (timestamp (+ base-ts 2))
                                    query-id "QueryUpdated" :count generation)))
                     (loop for message = (read-client-json stream)
                           until (eq message :closed)
                           when (and (= generation 5)
                                     (hash-table-p message)
                                     (string= (json-get message "type") "ModifyQuerySet")
                                     (string= (json-get
                                               (first (json-get message "modifications"))
                                               "type") "Remove"))
                             do (return))
                     (close stream)))
              (sb-bsd-sockets:socket-close listener)))
          :name "Five reconnect fixture"))
       (client (make-client (listener-url listener)))
       (subscription (client-subscribe client "demo:state" (json-object "room" "five"))))
  (check (= (json-get (update-value (subscription-next subscription :timeout 3.0)) "count") 0)
         "reconnect initial value")
  (loop for expected from 1 to 5
        do (client-debug-disconnect client)
           (let ((update (subscription-next subscription :timeout 5.0)))
             (check (= (json-get (update-value update) "count") expected)
                    "unchanged hydration crossed debug acknowledgement")))
  (subscription-close subscription)
  (client-close client)
  (sb-thread:join-thread fixture)
  (setf connects (nreverse connects))
  (check (= adds 6) "active Add was not resent on all reconnects")
  (loop for connect in connects
        for expected from 0
        do (check (= (json-get connect "connectionCount") expected)
                  "connectionCount across five reconnects"))
  (check (string= (json-get (sixth connects) "maxObservedTimestamp") (timestamp 10))
         "five reconnect maxObservedTimestamp"))

;; Even when the owner is stalled immediately before writing Remove, the
;; public unsubscribe call obeys its own deadline and leaves the handle closed.
(let* ((listener (make-listener))
       (remove-seen nil)
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (let ((stream (accept-websocket listener)))
                   (read-client-json stream)
                   (let* ((add (read-client-json stream))
                          (query-id
                            (json-get (first (json-get add "modifications"))
                                      "queryId")))
                     (write-server-json
                      stream (transition 0 1 (timestamp 0) (timestamp 1)
                                         query-id "QueryUpdated" :count 0))
                     (loop for message = (read-client-json stream)
                           until (eq message :closed)
                           when (and (hash-table-p message)
                                     (string= (json-get message "type" "")
                                              "ModifyQuerySet")
                                     (string= (json-get
                                               (first
                                                (json-get message "modifications"))
                                               "type" "")
                                              "Remove"))
                             do (setf remove-seen t))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Stalled unsubscribe fixture"))
       (client (make-client (listener-url listener)))
       (subscription
         (client-subscribe client "demo:state" (json-object "room" "stalled-remove")))
       (lock (sb-thread:make-mutex :name "Stalled Remove"))
       (condition (sb-thread:make-waitqueue :name "Stalled Remove"))
       (paused nil)
       (released nil)
       (timed-out nil)
       (elapsed nil)
       (closer nil))
  (subscription-next subscription :timeout 3.0)
  (setf *live-before-write-hook*
        (lambda (message)
          (when (and (string= (json-get message "type" "") "ModifyQuerySet")
                     (string= (json-get
                               (first (json-get message "modifications")) "type" "")
                              "Remove"))
            (sb-thread:with-mutex (lock)
              (setf paused t)
              (sb-thread:condition-broadcast condition)
              (loop until released
                    do (sb-thread:condition-wait condition lock))))))
  (unwind-protect
       (progn
         (setf closer
               (sb-thread:make-thread
                (lambda ()
                  (let ((started (monotonic-seconds)))
                    (handler-case (subscription-close subscription :timeout 0.2)
                      (transport-error () (setf timed-out t)))
                    (setf elapsed (- (monotonic-seconds) started))))
                :name "Bounded unsubscribe"))
         (sb-thread:with-mutex (lock)
           (loop until paused do (sb-thread:condition-wait condition lock)))
         (sb-thread:join-thread closer)
         (check timed-out "stalled unsubscribe did not time out")
         (check (< elapsed 0.6) "stalled unsubscribe deadline")
         (check (not (subscription-active subscription))
                "timed-out subscription remained active"))
    (setf *live-before-write-hook* nil)
    (sb-thread:with-mutex (lock)
      (setf released t)
      (sb-thread:condition-broadcast condition))
    (when (and closer (sb-thread:thread-alive-p closer))
      (ignore-errors (sb-thread:terminate-thread closer))))
  (client-close client)
  (sb-thread:join-thread fixture)
  (check remove-seen "stalled Remove was not eventually written"))

;; One absolute client-close deadline also covers an owner stalled after a real
;; data-frame prefix. Forced termination unwinds in the owner thread, retires
;; the socket, and releases another caller waiting on that owner command.
(let* ((listener (make-listener))
       (partial-seen nil)
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (let ((stream (accept-websocket listener)))
                   (read-client-json stream)
                   (let* ((add (read-client-json stream))
                          (query-id
                            (json-get (first (json-get add "modifications"))
                                      "queryId")))
                     (write-server-json
                      stream (transition 0 1 (timestamp 0) (timestamp 1)
                                         query-id "QueryUpdated" :count 0))
                     (read-byte stream)
                     (setf partial-seen t)
                     (loop while (read-byte stream nil nil))))
              (sb-bsd-sockets:socket-close listener)))
          :name "Stalled owner close fixture"))
       (client (make-client (listener-url listener)))
       (subscription
         (client-subscribe client "demo:state" (json-object "room" "close-base")))
       (manager (client-live client))
       (lock (sb-thread:make-mutex :name "Stalled owner write"))
       (condition (sb-thread:make-waitqueue :name "Stalled owner write"))
       (paused nil)
       (released nil)
       (request-error nil)
       (requester nil))
  (subscription-next subscription :timeout 3.0)
  (setf *websocket-frame-write-hook*
        (lambda (websocket opcode payload frame timeout)
          (if (and (= opcode 1)
                   (search "demo:second" (octets-string payload)))
              (progn
                (transport-write-all (websocket-transport websocket)
                                     (subseq frame 0 1) :timeout timeout)
                (sb-thread:with-mutex (lock)
                  (setf paused t)
                  (sb-thread:condition-broadcast condition)
                  (loop until released
                        do (sb-thread:condition-wait condition lock))))
              (transport-write-all (websocket-transport websocket) frame
                                   :timeout timeout))))
  (unwind-protect
       (progn
         (setf requester
               (sb-thread:make-thread
                (lambda ()
                  (handler-case
                      (client-subscribe client "demo:second"
                                        (json-object "room" "close-stall"))
                    (transport-error (condition) (setf request-error condition))))
                :name "Caller pending on stalled owner"))
         (sb-thread:with-mutex (lock)
           (loop until paused do (sb-thread:condition-wait condition lock)))
         (let ((started (monotonic-seconds)))
           (client-close client :timeout 0.5)
           (check (< (- (monotonic-seconds) started) 0.7)
                  "stalled-owner absolute close deadline"))
         (check (not (sb-thread:thread-alive-p (live-manager-thread manager)))
                "stalled owner remained alive after close")
         (sb-ext:with-timeout 1.0 (sb-thread:join-thread requester))
         (check (typep request-error 'transport-error)
                "pending owner caller was not released on forced close")
         (sb-thread:with-mutex ((live-manager-lock manager))
           (check (zerop (hash-table-count (live-manager-active manager)))
                  "forced close retained active subscriptions")
           (check (zerop (live-manager-active-bytes manager))
                  "forced close retained active subscription bytes")
           (check (null (live-manager-commands manager))
                  "forced close retained queued commands"))
         (check (not (subscription-active subscription))
                "forced close left prior subscription handle active"))
    (setf *websocket-frame-write-hook* nil)
    (sb-thread:with-mutex (lock)
      (setf released t)
      (sb-thread:condition-broadcast condition))
    (when (and requester (sb-thread:thread-alive-p requester))
      (ignore-errors (sb-thread:terminate-thread requester)))
    (ignore-errors (client-close client))
    (when (sb-thread:thread-alive-p fixture)
      (handler-case (sb-ext:with-timeout 1.0 (sb-thread:join-thread fixture))
        (sb-ext:timeout () (ignore-errors (sb-thread:terminate-thread fixture))))))
  (check partial-seen "stalled-owner fixture missed the partial write"))

;; Stop while a peer has sent only one frame byte. Parser state is abandoned
;; with that connection and close remains bounded instead of waiting for EOF.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (let ((stream (accept-websocket listener)))
                   (read-client-json stream)
                   (let* ((add (read-client-json stream))
                          (query-id (json-get (first (json-get add "modifications"))
                                              "queryId")))
                     (write-server-json stream
                                        (transition 0 1 (timestamp 0) (timestamp 1)
                                                    query-id "QueryUpdated" :count 0))
                     (write-byte #x81 stream)
                     (force-output stream)
                     (sleep 1.0)
                     (close stream)))
              (sb-bsd-sockets:socket-close listener)))
          :name "Live half-frame fixture"))
       (client (make-client (listener-url listener)))
       (subscription (client-subscribe client "demo:state" (json-object "room" "half"))))
  (subscription-next subscription :timeout 3.0)
  (let ((started (monotonic-seconds)))
    (client-close client :timeout 1.0)
    (check (< (- (monotonic-seconds) started) 0.8) "half-frame close deadline"))
  (sb-thread:join-thread fixture))

;; A valid peer can send continuously too. Controller commands are drained
;; before each buffered frame, so close cannot be starved by inbound traffic.
(let* ((listener (make-listener))
       (fixture
         (sb-thread:make-thread
          (lambda ()
            (unwind-protect
                 (handler-case
                     (let ((stream (accept-websocket listener)))
                       (read-client-json stream)
                       (let* ((add (read-client-json stream))
                              (query-id
                                (json-get (first (json-get add "modifications"))
                                          "queryId")))
                         (write-server-json
                          stream (transition 0 1 (timestamp 0) (timestamp 1)
                                             query-id "QueryUpdated" :count 0))
                         (loop for value from 1 to 1000
                               do (write-server-json
                                   stream
                                   (transition 1 1 (timestamp value)
                                               (timestamp (1+ value)) query-id
                                               "QueryUpdated" :count value)))
                         (sleep 0.5)
                         (close stream)))
                   (error () nil))
              (sb-bsd-sockets:socket-close listener)))
          :name "Continuous Live fixture"))
       (client (make-client (listener-url listener)))
       (subscription
         (client-subscribe client "demo:state" (json-object "room" "continuous"))))
  (subscription-next subscription :timeout 3.0)
  (let ((started (monotonic-seconds)))
    (client-close client :timeout 1.0)
    (check (< (- (monotonic-seconds) started) 0.8)
           "continuous-peer close deadline"))
  (sb-thread:join-thread fixture))

(check (canonical-timestamp-p (timestamp #xffffffffffffffff)) "uint64 timestamp")
(check (timestamp-greater-p (timestamp 256) (timestamp 255)) "little-endian comparison")
(check (not (canonical-timestamp-p "AQ==")) "short timestamp rejection")

(format t "PASS Live owner, reconnect, framing, and bounds~%")
