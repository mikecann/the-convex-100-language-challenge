(in-package #:convex)

(defconstant +adapter-line-limit+ (* 2 1024 1024))
(defconstant +output-count-limit+ 16)
(defconstant +output-byte-limit+ (* 6 1024 1024))

(defstruct output-item bytes droppable)

(defstruct (output-sink (:constructor %make-output-sink))
  fd
  (encoder-lock (sb-thread:make-mutex :name "Adapter JSON encoder"))
  (lock (sb-thread:make-mutex :name "Adapter output queue"))
  (condition (sb-thread:make-waitqueue :name "Adapter output queue"))
  (queue '())
  (bytes 0)
  (in-flight-bytes 0)
  writer
  closed failed)

(defun output-sink-count (sink)
  (+ (length (output-sink-queue sink))
     (if (plusp (output-sink-in-flight-bytes sink)) 1 0)))

(defun output-sink-total-bytes (sink)
  (+ (output-sink-bytes sink) (output-sink-in-flight-bytes sink)))

(defun make-output-sink (fd)
  ;; Accepted TCP sockets and pipes are blocking by default. The writer's
  ;; deadline is only real once the descriptor itself is nonblocking.
  (set-nonblocking fd)
  (let ((sink (%make-output-sink :fd fd)))
    (setf (output-sink-writer sink)
          (sb-thread:make-thread (lambda () (output-writer-loop sink))
                                 :name "Adapter bounded writer"))
    sink))

(defun remove-first-droppable (sink)
  (let ((previous nil)
        (remaining (output-sink-queue sink)))
    (loop while remaining
          for item = (first remaining)
          do (if (output-item-droppable item)
                 (progn
                   (if previous
                       (setf (cdr previous) (rest remaining))
                       (setf (output-sink-queue sink) (rest remaining)))
                   (decf (output-sink-bytes sink) (length (output-item-bytes item)))
                   (return-from remove-first-droppable t))
                 (setf previous remaining
                       remaining (rest remaining))))
    nil))

(defun output-publish (sink object &key droppable (timeout 5.0))
  (let* ((bytes
         ;; At most one near-limit JSON tree is being encoded outside the
         ;; bounded byte queue, even with many concurrent subscription relays.
         (sb-thread:with-mutex ((output-sink-encoder-lock sink))
             (json-encode-octets object :newline t)))
         (size (length bytes))
         (deadline (deadline-after timeout)))
    (when (> size +output-byte-limit+)
      (error "Adapter event exceeds the encoded output byte budget"))
    (sb-thread:with-mutex ((output-sink-lock sink))
      (loop while (or (>= (output-sink-count sink) +output-count-limit+)
                      (> (+ (output-sink-total-bytes sink) size)
                         +output-byte-limit+))
            do (cond
                 ((remove-first-droppable sink) nil)
                 (droppable (return-from output-publish nil))
                 (t
                  (let ((remaining (- deadline (monotonic-seconds))))
                    (when (<= remaining 0.001)
                      (error "Adapter output remained backpressured"))
                    (sb-thread:condition-wait (output-sink-condition sink)
                                              (output-sink-lock sink)
                                              :timeout remaining)))))
      (when (or (output-sink-closed sink) (output-sink-failed sink))
        (if droppable
            (return-from output-publish nil)
            (error "Adapter output is closed")))
      (let ((item (make-output-item :bytes bytes :droppable droppable)))
        (setf (output-sink-queue sink)
              (nconc (output-sink-queue sink) (list item)))
        (incf (output-sink-bytes sink) size)
        (sb-thread:condition-notify (output-sink-condition sink))))
    t))

(defun output-writer-loop (sink)
  (handler-case
      (loop
        (let ((item
                (sb-thread:with-mutex ((output-sink-lock sink))
                  (loop while (and (null (output-sink-queue sink))
                                   (not (output-sink-closed sink)))
                        do (sb-thread:condition-wait (output-sink-condition sink)
                                                     (output-sink-lock sink)))
                  (when (and (null (output-sink-queue sink))
                             (output-sink-closed sink))
                    (return-from output-writer-loop))
                  (let ((next (pop (output-sink-queue sink))))
                    (decf (output-sink-bytes sink) (length (output-item-bytes next)))
                    ;; Keep the kernel-blocked write inside the same global
                    ;; count and encoded-byte budget as queued events.
                    (setf (output-sink-in-flight-bytes sink)
                          (length (output-item-bytes next)))
                    next))))
          (fd-write-all (output-sink-fd sink) (output-item-bytes item) :timeout 0.5)
          (sb-thread:with-mutex ((output-sink-lock sink))
            (setf (output-sink-in-flight-bytes sink) 0)
            (sb-thread:condition-broadcast (output-sink-condition sink)))))
    (error (condition)
      (format *error-output* "adapter output failed: ~A~%" condition)
      (finish-output *error-output*)
      (sb-thread:with-mutex ((output-sink-lock sink))
        (setf (output-sink-in-flight-bytes sink) 0
              (output-sink-failed sink) condition
              (output-sink-closed sink) t)
        (sb-thread:condition-broadcast (output-sink-condition sink))))))

(defun close-output-sink (sink &key (drain t))
  (sb-thread:with-mutex ((output-sink-lock sink))
    (unless drain
      (setf (output-sink-queue sink) '()
            (output-sink-bytes sink) 0))
    (setf (output-sink-closed sink) t)
    (sb-thread:condition-broadcast (output-sink-condition sink)))
  (let ((writer (output-sink-writer sink)))
    (when (and writer (sb-thread:thread-alive-p writer))
      (handler-case (sb-ext:with-timeout 1.0 (sb-thread:join-thread writer))
        (sb-ext:timeout () (ignore-errors (sb-thread:terminate-thread writer)))
        (error () (ignore-errors (sb-thread:terminate-thread writer)))))))

(defun event (&rest pairs)
  (apply #'json-object pairs))

(defun error-event (condition &key id subscription-id)
  (let ((result (event "type" (if subscription-id "subscription" "error")))
        (name "Error") (message (format nil "~A" condition))
        (data +json-null+) (logs nil))
    (when id (setf (gethash "id" result) id))
    (when subscription-id
      (setf (gethash "subscriptionId" result) subscription-id))
    (when (typep condition 'convex-error)
      (setf name (error-name condition)
            message (error-message condition)
            data (error-data condition)
            logs (error-logs condition)))
    (setf (gethash "error" result)
          (event "name" name "message" message "data" data))
    (when logs (setf (gethash "logs" result) logs))
    result))

(defstruct relay-record subscription generation active)

;; Tests pause a relay after it has dequeued an update but before it enters the
;; publication barrier. Production leaves this NIL.
(defvar *adapter-relay-after-dequeue-hook* nil)

(defstruct adapter-state
  client
  (client-lock (sb-thread:make-mutex :name "Adapter client"))
  (publication-lock (sb-thread:make-mutex :name "Adapter publication barrier"))
  (relays (make-hash-table :test #'equal))
  (generations (make-hash-table :test #'equal))
  (minimum-live-generation 0)
  relay-manager
  relay-thread
  output
  closed)

(defun ensure-adapter-client (state)
  (sb-thread:with-mutex ((adapter-state-client-lock state))
    (or (adapter-state-client state)
        (let ((url (sb-ext:posix-getenv "CONVEX_URL")))
          (unless (and url (plusp (length url))) (error "CONVEX_URL is required"))
          (setf (adapter-state-client state)
                (make-client url :auth-token (sb-ext:posix-getenv "CONVEX_AUTH_TOKEN")
                                 :client-version "common-lisp-0.1.0"))))))

(defun next-generation (state subscription-id)
  (setf (gethash subscription-id (adapter-state-generations state))
        (1+ (gethash subscription-id (adapter-state-generations state) 0))))

(defun invalidate-relay (state subscription-id)
  (sb-thread:with-mutex ((adapter-state-publication-lock state))
    (next-generation state subscription-id)
    (let ((record (gethash subscription-id (adapter-state-relays state))))
      (when record (setf (relay-record-active record) nil))
      (remhash subscription-id (adapter-state-relays state))
      record)))

(defun owner-wait-timeout-p (condition)
  (and (typep condition 'transport-error)
       (search "Timed out waiting for the Live owner"
               (error-message condition))))

(defun stop-relay (record &key require-transport-barrier (timeout 1.0)
                               (close-subscription t))
  (when record
    (let ((close-error nil))
      (if close-subscription
          (handler-case
              (subscription-close (relay-record-subscription record) :timeout timeout)
            (transport-error (condition)
              ;; MODIFY-ONE retires the old socket before returning a transport
              ;; failure. That is a successful adapter barrier. A caller-side
              ;; owner wait timeout has no such proof and is not acknowledged.
              (when (and require-transport-barrier
                         (owner-wait-timeout-p condition))
                (setf close-error condition)))
            (error (condition)
              (when require-transport-barrier (setf close-error condition))))
          (let* ((subscription (relay-record-subscription record))
                 (manager (subscription-manager subscription)))
            (setf (subscription-active subscription) nil)
            (sb-thread:with-mutex ((live-manager-lock manager))
              (sb-thread:condition-broadcast (live-manager-condition manager)))))
      (when close-error (error close-error)))))

(defun publish-relay-event (state subscription-id record update event)
  (when *adapter-relay-after-dequeue-hook*
    (funcall *adapter-relay-after-dequeue-hook*))
  ;; Recheck the generation while holding the same lock used to publish
  ;; replacement and unsubscribe ACKs.
  (sb-thread:with-mutex ((adapter-state-publication-lock state))
    (when (and (relay-record-active record)
               (= (relay-record-generation record)
                  (gethash subscription-id (adapter-state-generations state)))
               (>= (update-generation update)
                   (adapter-state-minimum-live-generation state)))
      (output-publish (adapter-state-output state) event :droppable t))))

(defun relay-for-subscription (state subscription)
  (sb-thread:with-mutex ((adapter-state-publication-lock state))
    (loop for id being the hash-keys of (adapter-state-relays state)
            using (hash-value record)
          when (eq subscription (relay-record-subscription record))
            do (return (values id record)))))

(defun adapter-relay-loop (state manager)
  ;; One dispatcher owns every manager delivery from dequeue through adapter
  ;; publication. Besides making the global lease bound literal, this prevents
  ;; idle per-subscription stacks from conservatively retaining released large
  ;; values in a saved SBCL process.
  (loop until (adapter-state-closed state)
        do (let ((delivery (manager-next-delivery manager :timeout 0.25)))
             (when delivery
               (let ((update nil) (outbound-event nil)
                     (subscription-id nil) (record nil))
                 (multiple-value-setq (subscription-id record)
                   (relay-for-subscription
                    state (delivery-subscription delivery)))
                 (unwind-protect
                      (when record
                        (setf update (delivery-update delivery)
                              outbound-event
                              (if (update-error update)
                                  (error-event
                                   (update-error update)
                                   :subscription-id subscription-id)
                                  (let ((value-event
                                          (event
                                           "type" "subscription"
                                           "subscriptionId" subscription-id
                                           "value" (update-value update))))
                                    (when (update-logs update)
                                      (setf (gethash "logs" value-event)
                                            (update-logs update)))
                                    value-event)))
                        (publish-relay-event
                         state subscription-id record update outbound-event))
                   (setf outbound-event nil update nil record nil
                         subscription-id nil)
                   (release-delivery delivery)
                   (setf delivery nil)))
               (sb-sys:scrub-control-stack)))))

(defun start-relay (state subscription-id record)
  (declare (ignore subscription-id))
  (let ((manager (subscription-manager (relay-record-subscription record))))
    (sb-thread:with-mutex ((adapter-state-publication-lock state))
      (unless (adapter-state-relay-manager state)
        (setf (adapter-state-relay-manager state) manager))
      (unless (eq manager (adapter-state-relay-manager state))
        (error "Adapter subscriptions unexpectedly use different Live managers"))
      (unless (and (adapter-state-relay-thread state)
                   (sb-thread:thread-alive-p
                    (adapter-state-relay-thread state)))
        (setf (adapter-state-relay-thread state)
              (sb-thread:make-thread
               (lambda () (adapter-relay-loop state manager))
               :name "Adapter global relay dispatcher"))))))

(defun publish-response (state object)
  (sb-thread:with-mutex ((adapter-state-publication-lock state))
    (output-publish (adapter-state-output state) object)))

(defun command-id (command)
  (let ((id (json-get command "id")))
    (and (stringp id) (<= 1 (length id) 128) id)))

(defun adapter-subscription-id (command)
  (let ((id (json-get command "subscriptionId")))
    (unless (and (stringp id) (<= 1 (length id) 128))
      (error "subscriptionId must contain 1 to 128 characters"))
    id))

(defun handle-adapter-command (state command)
  (unless (hash-table-p command) (error "Adapter command must be an object"))
  (let ((id (command-id command))
        (operation (json-get command "op")))
    (unless id (error "Adapter command requires a non-empty id"))
    (unless (stringp operation) (error "Adapter command requires op"))
    (handler-case
        (cond
          ((string= operation "hello")
           (unless (= (json-get command "protocolVersion" -1) 1)
             (error "Unsupported adapter protocol version"))
           (publish-response
            state (event "protocolVersion" 1 "id" id "type" "ready"
                         "language" "common-lisp"
                         "implementation" "native-sbcl-openssl3"
                         "runtime" (format nil "SBCL ~A" (lisp-implementation-version)))))
          ((member operation '("query" "mutation" "action") :test #'string=)
           (let* ((client (ensure-adapter-client state))
                  (path (json-get command "path"))
                  (args (json-get command "args" (json-object)))
                  (result (cond
                            ((string= operation "query") (client-query client path args))
                            ((string= operation "mutation") (client-mutation client path args))
                            (t (client-action client path args))))
                  (response (event "id" id "type" "result"
                                   "value" (result-value result))))
             (when (result-logs result)
               (setf (gethash "logs" response) (result-logs result)))
             (publish-response state response)))
          ((string= operation "setAuth")
           (client-set-auth (ensure-adapter-client state)
                            (or (json-get command "token") ""))
           (publish-response state (event "id" id "type" "ack")))
          ((string= operation "subscribe")
           (let ((subscription-id (adapter-subscription-id command)))
             (stop-relay (invalidate-relay state subscription-id)
                         :require-transport-barrier t :timeout 6.0)
             (let* ((subscription
                      (client-subscribe (ensure-adapter-client state)
                                        (json-get command "path")
                                        (json-get command "args" (json-object))))
                    (record nil))
               ;; Activate the new relay and publish its ACK through one
               ;; serialized barrier. The relay starts afterward, so even an
               ;; already-hydrated value cannot precede the ACK.
               (sb-thread:with-mutex ((adapter-state-publication-lock state))
                 (let ((generation (next-generation state subscription-id)))
                   (setf record (make-relay-record :subscription subscription
                                                   :generation generation :active t)
                         (gethash subscription-id (adapter-state-relays state)) record)
                   (output-publish (adapter-state-output state)
                                   (event "id" id "type" "ack"))))
               (start-relay state subscription-id record))))
          ((string= operation "unsubscribe")
           (let* ((subscription-id (adapter-subscription-id command))
                  (record (invalidate-relay state subscription-id)))
             (stop-relay record :require-transport-barrier t :timeout 6.0)
             (publish-response state (event "id" id "type" "ack"))))
          ((string= operation "debugDisconnect")
           (let ((generation
                   (client-debug-disconnect (ensure-adapter-client state))))
             ;; The Live owner has retired the old socket. Advance the adapter
             ;; transport barrier and publish the ACK under the same lock used
             ;; by relays, filtering both dequeued and queued old-generation
             ;; updates after this point.
             (sb-thread:with-mutex ((adapter-state-publication-lock state))
               (setf (adapter-state-minimum-live-generation state) generation)
               (output-publish (adapter-state-output state)
                               (event "id" id "type" "ack")))))
          ((string= operation "close")
           (setf (adapter-state-closed state) t)
           (publish-response state (event "id" id "type" "closed")))
          (t (error "Unknown operation ~S" operation)))
      (error (condition)
        (publish-response state (error-event condition :id id))))))

(defun cleanup-adapter (state)
  (let ((records '()))
    (sb-thread:with-mutex ((adapter-state-publication-lock state))
      (setf (adapter-state-closed state) t)
      (maphash (lambda (id record)
                 (next-generation state id)
                 (setf (relay-record-active record) nil)
                 (push record records))
               (adapter-state-relays state))
      (clrhash (adapter-state-relays state)))
    ;; EOF/close retires the one client after every local relay is invalidated.
    ;; Do not issue one serial owner Remove per relay during full teardown.
    (dolist (record records)
      (ignore-errors (stop-relay record :close-subscription nil)))
    (when (adapter-state-client state)
      (ignore-errors (client-close (adapter-state-client state) :timeout 2.0)))
    (let ((manager (adapter-state-relay-manager state))
          (thread (adapter-state-relay-thread state)))
      (when manager
        (sb-thread:with-mutex ((live-manager-lock manager))
          (sb-thread:condition-broadcast (live-manager-condition manager))))
      (when (and thread (sb-thread:thread-alive-p thread))
        (handler-case (sb-ext:with-timeout 0.5 (sb-thread:join-thread thread))
          (sb-ext:timeout () (ignore-errors (sb-thread:terminate-thread thread)))
          (error () (ignore-errors (sb-thread:terminate-thread thread))))))))

(defun adapter-loop (input-fd output-fd)
  (let* ((sink (make-output-sink output-fd))
         (state (make-adapter-state :output sink))
         (line (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 0))
         (discarding nil))
    (unwind-protect
         (loop until (adapter-state-closed state)
               for part = (fd-read-some input-fd)
               while part
               do (loop for byte across part
                        do (cond
                             ((= byte 10)
                              (unless discarding
                                (when (and (plusp (length line))
                                           (= (aref line (1- (length line))) 13))
                                  (decf (fill-pointer line)))
                                (when (plusp (length line))
                                  (handler-case
                                      (handle-adapter-command
                                       state (json-decode (octets-string line)))
                                    (error (condition)
                                      (publish-response state
                                                        (error-event condition))))))
                              (setf (fill-pointer line) 0
                                    discarding nil))
                             (discarding nil)
                             ((>= (length line) +adapter-line-limit+)
                              (setf discarding t (fill-pointer line) 0)
                              (publish-response
                               state (error-event
                                      (make-condition
                                       'protocol-error :name "ProtocolError"
                                       :message "Adapter command exceeds 2 MiB"))))
                             (t (vector-push-extend byte line)))))
      ;; EOF is a complete shutdown path, including all relay threads and Live.
      (cleanup-adapter state)
      (close-output-sink sink :drain t))))

(defun parse-listen-address (text)
  (let ((colon (position #\: text :from-end t)))
    (unless colon (error "ADAPTER_LISTEN must be host:port"))
    (values (subseq text 0 colon) (parse-integer text :start (1+ colon)))))

(defun adapter-flood-test-main ()
  ;; Internal Docker evidence hook: exercise the real saved adapter's bounded
  ;; writer while its controller deliberately does not read stdout.
  (let ((sink (make-output-sink 1))
        (large (make-string 350000 :initial-element #\x)))
    (unwind-protect
         (progn
           (let ((workers
                   (loop for worker below 4
                         collect
                         (sb-thread:make-thread
                          (lambda ()
                            (dotimes (index 8)
                              (output-publish
                               sink
                               (event "type" "subscription"
                                      "subscriptionId" "memory"
                                      "value"
                                      (json-object "worker" worker "index" index
                                                   "text" large))
                               :droppable t)))
                          :name "Concurrent adapter encoder"))))
             (dolist (worker workers) (sb-thread:join-thread worker)))
           (format *error-output* "adapter flood queue ready~%")
           (finish-output *error-output*)
           (sleep 3.0))
      (close-output-sink sink :drain nil))))

(defun adapter-relay-flood-test-main ()
  ;; Exercise the actual subscription relay path. Twelve relays compete for
  ;; one encoder while decoded near-limit updates stay charged to the manager
  ;; until publication or coalescing has completed.
  (let* ((sink (make-output-sink 1))
         (state (make-adapter-state :output sink))
         (manager (%make-live-manager :deployment-url (parse-url "http://127.0.0.1")
                                      :client-version "relay-flood"))
         (subscriptions '())
         (records '()))
    (unwind-protect
         (progn
           (dotimes (index 12)
             (let* ((subscription
                      (%make-subscription :manager manager :query-id index
                                          :path "demo:state"
                                          :args (json-object "room" index)))
                    (id (format nil "relay-~D" index))
                    (record (make-relay-record :subscription subscription
                                               :generation 1 :active t)))
               (setf (gethash index (live-manager-active manager)) subscription
                     (gethash id (adapter-state-generations state)) 1
                     (gethash id (adapter-state-relays state)) record)
               (push subscription subscriptions)
               (push record records)
               (start-relay state id record)))
           (setf subscriptions (nreverse subscriptions))
           (dotimes (index 12)
             (let ((subscription
                     (nth (mod index (length subscriptions)) subscriptions))
                   (text nil)
                   (value nil)
                   (update nil))
               ;; A distinct decoded value on every iteration prevents this
               ;; RSS proof from relying on one shared large string.
               (setf text
                     (make-string
                      700000 :initial-element
                      (code-char (+ (char-code #\a) (mod index 26))))
                     value (json-object "index" index "text" text)
                     update (make-update :value value :generation 0))
               (enqueue-update manager subscription
                               update
                               (format nil "relay-flood-~D" index))
               ;; Model a streaming decoder, not a fixture producer that
               ;; accidentally retains every prior value in conservative stack
               ;; slots outside the queues under test.
               (setf update nil value nil text nil)
               (sb-sys:scrub-control-stack)))
           (sleep 0.2)
           (sb-thread:with-mutex ((live-manager-lock manager))
             (unless (and (<= (live-delivery-count manager)
                              +delivery-count-limit+)
                          (<= (live-manager-delivery-bytes manager)
                              +delivery-byte-limit+))
               (error "Relay delivery accounting exceeded its global bound")))
           (format *error-output* "adapter relay flood ready~%")
           (finish-output *error-output*)
           (sleep 3.0))
      (cleanup-adapter state)
      (close-output-sink sink :drain nil))))

(defun adapter-dense-flood-test-main ()
  ;; A dense value is cheap on the wire but expensive as decoded hash tables
  ;; and cons cells. Exercise several distinct retained values in the real
  ;; saved image so recursive runtime charging is covered by RSS evidence.
  (let* ((manager (%make-live-manager))
         (subscription
           (%make-subscription :manager manager :query-id 1 :path "demo:dense"
                               :args (json-object))))
    (setf (gethash 1 (live-manager-active manager)) subscription)
    (dotimes (index 12)
      (let ((dense nil) (value nil) (update nil))
        (setf dense (loop repeat 4000 collect (json-object))
              value (json-object "index" index "dense" dense)
              update (make-update :value value :generation 0))
        (enqueue-update manager subscription update
                        (format nil "dense-flood-~D" index))
        (setf update nil value nil dense nil)
        (sb-sys:scrub-control-stack)))
    (unless (and (< (length (live-manager-deliveries manager)) 12)
                 (<= (live-manager-delivery-bytes manager)
                     +delivery-byte-limit+))
      (error "Dense delivery accounting did not enforce its runtime bound"))
    (format *error-output* "adapter dense flood ready~%")
    (finish-output *error-output*)
    (sleep 3.0)))

(defun adapter-main ()
  (handler-case
      (cond
        ((sb-ext:posix-getenv "ADAPTER_DENSE_FLOOD_TEST")
         (adapter-dense-flood-test-main))
        ((sb-ext:posix-getenv "ADAPTER_RELAY_FLOOD_TEST")
         (adapter-relay-flood-test-main))
        ((sb-ext:posix-getenv "ADAPTER_FLOOD_TEST")
         (adapter-flood-test-main))
        (t
         (let ((listen (sb-ext:posix-getenv "ADAPTER_LISTEN")))
        (if (or (null listen) (zerop (length listen)))
            (adapter-loop 0 1)
            (multiple-value-bind (host port) (parse-listen-address listen)
              (let ((listener (make-instance 'sb-bsd-sockets:inet-socket
                                             :type :stream :protocol :tcp)))
                (unwind-protect
                     (progn
                       (sb-bsd-sockets:socket-bind
                        listener
                        (sb-bsd-sockets:host-ent-address
                         (sb-bsd-sockets:get-host-by-name host))
                        port)
                       (sb-bsd-sockets:socket-listen listener 1)
                       (format *error-output* "adapter listening on ~A~%" listen)
                       (finish-output *error-output*)
                       (let ((controller (sb-bsd-sockets:socket-accept listener)))
                         (unwind-protect
                              (let ((fd (sb-bsd-sockets:socket-file-descriptor controller)))
                                (adapter-loop fd fd))
                           (sb-bsd-sockets:socket-close controller))))
                  (sb-bsd-sockets:socket-close listener))))))))
    (error (condition)
      (format *error-output* "adapter failed: ~A~%" condition)
      (finish-output *error-output*)
      (sb-ext:exit :code 1)))
  (sb-ext:exit :code 0))
