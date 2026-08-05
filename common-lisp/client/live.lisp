(in-package #:convex)

(defconstant +delivery-count-limit+ 16)
(defconstant +delivery-byte-limit+ (* 20 1024 1024))
(defconstant +active-subscription-count-limit+ 64)
(defconstant +active-subscription-byte-limit+ (* 8 1024 1024))
(defconstant +initial-backoff+ 0.1d0)
(defconstant +maximum-backoff+ 15.0d0)
(defparameter +initial-timestamp+ "AAAAAAAAAAA=")

;; Deterministic tests can stop the owner immediately before a socket write.
;; Production leaves this NIL.
(defvar *live-before-write-hook* nil)
(defvar *delivery-batch-after-first-hook* nil)

(defstruct response-cell
  (lock (sb-thread:make-mutex :name "Convex response"))
  (condition (sb-thread:make-waitqueue :name "Convex response"))
  done value error)

(defstruct owner-command kind data response)

(defstruct (subscription (:constructor %make-subscription))
  manager query-id path args (accounted-size 0) (active t) last-signature)

(defstruct delivery subscription update size)

(defstruct (live-manager (:constructor %make-live-manager))
  deployment-url client-version
  (lock (sb-thread:make-mutex :name "Convex Live owner queue"))
  (condition (sb-thread:make-waitqueue :name "Convex Live owner queue"))
  (commands '())
  (pending-responses '())
  (active (make-hash-table))
  (active-bytes 0)
  (deliveries '())
  (in-flight-deliveries '())
  (delivery-bytes 0)
  (next-query-id 0)
  thread
  closed
  (connection-count 0)
  (last-close-reason "InitialConnect")
  max-observed-timestamp)

(defun complete-response (cell &key value error)
  (sb-thread:with-mutex ((response-cell-lock cell))
    (setf (response-cell-value cell) value
          (response-cell-error cell) error
          (response-cell-done cell) t)
    (sb-thread:condition-broadcast (response-cell-condition cell))))

(defun fail-response-unless-complete (cell condition)
  (sb-thread:with-mutex ((response-cell-lock cell))
    (unless (response-cell-done cell)
      (setf (response-cell-error cell) condition
            (response-cell-done cell) t)
      (sb-thread:condition-broadcast (response-cell-condition cell)))))

(defun await-response (cell &optional (timeout 12.0))
  (let ((deadline (deadline-after timeout)))
    (sb-thread:with-mutex ((response-cell-lock cell))
      (loop until (response-cell-done cell)
            for remaining = (- deadline (monotonic-seconds))
            do (when (<= remaining 0.001d0)
                 (error 'transport-error :name "TransportError"
                        :message "Timed out waiting for the Live owner"))
               (sb-thread:condition-wait (response-cell-condition cell)
                                         (response-cell-lock cell)
                                         :timeout remaining))
      (when (response-cell-error cell) (error (response-cell-error cell)))
      (response-cell-value cell))))

(defun owner-request (manager kind &optional data (timeout 12.0))
  (let ((response (make-response-cell)))
    (sb-thread:with-mutex ((live-manager-lock manager))
      (when (live-manager-closed manager)
        (error "Convex Live client is closed"))
      (setf (live-manager-commands manager)
            (nconc (live-manager-commands manager)
                   (list (make-owner-command :kind kind :data data :response response)))
            (live-manager-pending-responses manager)
            (cons response (live-manager-pending-responses manager)))
      (sb-thread:condition-notify (live-manager-condition manager)))
    (unwind-protect
         (await-response response timeout)
      (sb-thread:with-mutex ((live-manager-lock manager))
        (setf (live-manager-pending-responses manager)
              (delete response (live-manager-pending-responses manager)
                      :test #'eq :count 1))))))

(defun make-live-manager (deployment-url client-version)
  (let ((manager (%make-live-manager :deployment-url deployment-url
                                     :client-version client-version)))
    (setf (live-manager-thread manager)
          (sb-thread:make-thread (lambda () (live-owner-loop manager))
                                 :name "Convex Live socket owner"))
    manager))

(defun client-subscribe (client path arguments)
  (unless (and (stringp path) (plusp (length path)))
    (error "Convex function path is required"))
  (let ((args (ensure-json-object arguments))
        (manager nil))
    (sb-thread:with-mutex ((client-lock client))
      (when (client-closed client) (error "Convex client is closed"))
      (unless (client-live client)
        (setf (client-live client)
              (make-live-manager (client-deployment-url client)
                                 (client-client-version client))))
      (setf manager (client-live client)))
    (owner-request manager :subscribe (list path args))))

(defun subscription-close (subscription &key (timeout 1.0))
  (when (subscription-active subscription)
    (unwind-protect
         (owner-request (subscription-manager subscription) :unsubscribe
                        subscription timeout)
      ;; The owner invalidates before attempting Remove. A caller timeout must
      ;; not make this handle appear usable again.
      (setf (subscription-active subscription) nil)))
  t)

(defun client-debug-disconnect (client)
  (let ((manager
          (sb-thread:with-mutex ((client-lock client)) (client-live client))))
    (unless manager (error "Live WebSocket has not been started"))
    (owner-request manager :debug-disconnect)))

(defun client-live-metadata (client)
  (let ((manager
          (sb-thread:with-mutex ((client-lock client)) (client-live client))))
    (if manager
        (sb-thread:with-mutex ((live-manager-lock manager))
          (json-object "connectionCount" (live-manager-connection-count manager)
                       "lastCloseReason" (live-manager-last-close-reason manager)
                       "maxObservedTimestamp"
                       (or (live-manager-max-observed-timestamp manager) +json-null+)
                       ;; A relay-owned delivery remains charged until its
                       ;; encoded adapter event is published or dropped.
                       "queuedCount" (live-delivery-count manager)
                       "queuedBytes" (live-manager-delivery-bytes manager)
                       "activeCount" (hash-table-count (live-manager-active manager))
                       "activeBytes" (live-manager-active-bytes manager)))
        (json-object "connectionCount" 0 "lastCloseReason" "InitialConnect"
                     "maxObservedTimestamp" +json-null+
                     "queuedCount" 0 "queuedBytes" 0
                     "activeCount" 0 "activeBytes" 0))))

(defun calculate-subscription-size (path args)
  (+ 4096
     (* 4 (+ (json-string-encoded-byte-length path)
             (json-encoded-byte-length args)
             32))
     (json-runtime-overhead path)
     (json-runtime-overhead args)))

(defun ensure-subscription-capacity (manager accounted-size)
  (when (or (>= (hash-table-count (live-manager-active manager))
                +active-subscription-count-limit+)
            (> (+ (live-manager-active-bytes manager) accounted-size)
               +active-subscription-byte-limit+))
    (error 'protocol-error :name "ProtocolError"
           :message "Live active subscription budget exceeded")))

(defun value-signature (value)
  (concatenate 'string "value:" (base64-encode (json-sha256 value))))

(defun error-signature (message data)
  (concatenate
   'string "error:"
   (base64-encode
    (json-sha256 (json-object "message" message "data" data)))))

(defun remove-subscription-deliveries (manager subscription)
  (let ((retained '()))
    (dolist (entry (live-manager-deliveries manager))
      (if (eq (delivery-subscription entry) subscription)
          (decf (live-manager-delivery-bytes manager) (delivery-size entry))
          (push entry retained)))
    ;; A relay may already own an entry. It remains charged until that relay's
    ;; unwind path publishes or drops it and calls RELEASE-DELIVERY.
    (setf (live-manager-deliveries manager) (nreverse retained))))

(defun live-delivery-count (manager)
  (+ (length (live-manager-deliveries manager))
     (length (live-manager-in-flight-deliveries manager))))

(defun update-accounting-object (update)
  (if (update-error update)
      (let ((condition (update-error update)))
        (json-object
         "type" "subscription"
         "error"
         (json-object
          "name" (if (typep condition 'convex-error)
                     (error-name condition) "Error")
          "message" (if (typep condition 'convex-error)
                        (error-message condition) (format nil "~A" condition))
          "data" (if (typep condition 'convex-error)
                     (error-data condition) +json-null+))
         "logs" (if (typep condition 'convex-error)
                    (error-logs condition) '())))
      (json-object "type" "subscription" "value" (update-value update)
                   "logs" (update-logs update))))

(defun update-accounted-size (update)
  (let* ((accounting-object (update-accounting-object update))
         (encoded-bytes (json-encoded-byte-length accounting-object))
         (runtime-overhead (json-runtime-overhead accounting-object)))
    ;; SBCL can retain four bytes per character, plus hash/list/vector headers,
    ;; queue cells and the encoded adapter copy. Four times the value/log/error
    ;; envelope plus 4 KiB is intentionally conservative; the fixed allowance
    ;; also covers the adapter's event keys and maximum 128-byte subscriptionId.
    (+ (* 4 encoded-bytes) runtime-overhead 4096)))

(defun enqueue-update-locked (manager subscription update signature)
  ;; One manager-wide queue is both count and byte bounded. Intermediate
  ;; reactive states may be coalesced, but the newest state always survives.
  (let* ((size (update-accounted-size update))
         (entry (make-delivery :subscription subscription :update update :size size)))
    (when (and (subscription-active subscription)
               (gethash (subscription-query-id subscription)
                        (live-manager-active manager)))
      (loop while (and (live-manager-deliveries manager)
                       (or (>= (live-delivery-count manager)
                               +delivery-count-limit+)
                           (> (+ (live-manager-delivery-bytes manager) size)
                              +delivery-byte-limit+)))
            for dropped = (pop (live-manager-deliveries manager))
            do (decf (live-manager-delivery-bytes manager)
                     (delivery-size dropped)))
      (when (and (< (live-delivery-count manager) +delivery-count-limit+)
                 (<= (+ (live-manager-delivery-bytes manager) size)
                     +delivery-byte-limit+))
        (setf (live-manager-deliveries manager)
              (nconc (live-manager-deliveries manager) (list entry)))
        (incf (live-manager-delivery-bytes manager) size)
        ;; Transport and protocol events describe the connection, not a new
        ;; query state. Their NIL signature deliberately leaves the last value
        ;; intact so reconnect hydration cannot replay an unchanged value.
        ;; QueryFailed has a real signature and therefore still allows an
        ;; identical later value to prove that the query recovered.
        (when signature
          (setf (subscription-last-signature subscription) signature))))))

(defun enqueue-update (manager subscription update signature)
  (sb-thread:with-mutex ((live-manager-lock manager))
    (enqueue-update-locked manager subscription update signature)
    (sb-thread:condition-broadcast (live-manager-condition manager))))

(defun enqueue-changes (manager changes)
  ;; One transition becomes visible under one lock and one notification. A
  ;; consumer can observe all of its query changes or none of them, never a
  ;; partially hydrated query set.
  (sb-thread:with-mutex ((live-manager-lock manager))
    (loop for change in changes
          for index from 0
          do (apply #'enqueue-update-locked manager change)
             (when (and (zerop index) *delivery-batch-after-first-hook*)
               (funcall *delivery-batch-after-first-hook*)))
    (sb-thread:condition-broadcast (live-manager-condition manager))))

(defun subscription-take-delivery (subscription timeout retain)
  (let* ((manager (subscription-manager subscription))
         (deadline (deadline-after timeout)))
    (sb-thread:with-mutex ((live-manager-lock manager))
      (loop
        (let ((entry (find subscription (live-manager-deliveries manager)
                           :key #'delivery-subscription)))
          (when entry
            (setf (live-manager-deliveries manager)
                  (delete entry (live-manager-deliveries manager) :count 1))
            (if retain
                (push entry (live-manager-in-flight-deliveries manager))
                (decf (live-manager-delivery-bytes manager)
                      (delivery-size entry)))
            (return entry)))
        (unless (and (subscription-active subscription)
                     (not (live-manager-closed manager)))
          (return nil))
        (let ((remaining (- deadline (monotonic-seconds))))
          (when (<= remaining 0.001d0) (return nil))
          (sb-thread:condition-wait (live-manager-condition manager)
                                    (live-manager-lock manager)
                                    :timeout remaining))))))

(defun subscription-next-delivery (subscription &key (timeout 10.0))
  "Adapter-only dequeue whose bytes stay charged until publication finishes."
  (subscription-take-delivery subscription timeout t))

(defun manager-next-delivery (manager &key (timeout 10.0))
  "Adapter-only manager-wide dequeue, charged until RELEASE-DELIVERY.

One adapter dispatcher consumes this queue for every subscription. This avoids
both head-of-line starvation and one conservatively retained large value per
subscription thread."
  (let ((deadline (deadline-after timeout)))
    (sb-thread:with-mutex ((live-manager-lock manager))
      (loop
        (let ((entry (pop (live-manager-deliveries manager))))
          (when entry
            (push entry (live-manager-in-flight-deliveries manager))
            (return entry)))
        (when (live-manager-closed manager)
          (return nil))
        (let ((remaining (- deadline (monotonic-seconds))))
          (when (<= remaining 0.001d0) (return nil))
          (sb-thread:condition-wait (live-manager-condition manager)
                                    (live-manager-lock manager)
                                    :timeout remaining))))))

(defun release-delivery (delivery)
  (when delivery
    (let ((manager (subscription-manager (delivery-subscription delivery))))
      (sb-thread:with-mutex ((live-manager-lock manager))
        (when (member delivery (live-manager-in-flight-deliveries manager) :test #'eq)
          (setf (live-manager-in-flight-deliveries manager)
                (delete delivery (live-manager-in-flight-deliveries manager)
                        :test #'eq :count 1))
          (decf (live-manager-delivery-bytes manager) (delivery-size delivery))
          (sb-thread:condition-broadcast (live-manager-condition manager))))))
  t)

(defun subscription-next (subscription &key (timeout 10.0))
  (let ((delivery (subscription-take-delivery subscription timeout nil)))
    (and delivery (delivery-update delivery))))

(defun client-close (client &key (timeout 3.0))
  (let ((manager nil)
        (deadline (deadline-after timeout)))
    (sb-thread:with-mutex ((client-lock client))
      (unless (client-closed client)
        (setf (client-closed client) t
              manager (client-live client))))
    (when manager
      (let* ((thread (live-manager-thread manager))
             (reserve (min 0.2d0 (/ timeout 4.0d0)))
             (request-timeout (- deadline (monotonic-seconds) reserve))
             (acknowledged
               (and (> request-timeout 0.001d0)
                    (handler-case
                        (progn (owner-request manager :close nil request-timeout) t)
                      (error () nil)))))
        ;; If the owner cannot acknowledge inside the one public deadline, ask
        ;; SBCL to terminate that owner. Its unwind-protect performs the socket
        ;; retirement in the owner thread, preserving exclusive ownership.
        (when (and thread (sb-thread:thread-alive-p thread) (not acknowledged))
          (ignore-errors (sb-thread:terminate-thread thread)))
        (when (and thread (sb-thread:thread-alive-p thread))
          (let ((remaining (- deadline (monotonic-seconds))))
            (if (<= remaining 0)
                (ignore-errors (sb-thread:terminate-thread thread))
                (handler-case
                    (sb-ext:with-timeout remaining
                      (sb-thread:join-thread thread))
                  (sb-ext:timeout ()
                    (ignore-errors (sb-thread:terminate-thread thread)))
                  (error () (ignore-errors
                              (sb-thread:terminate-thread thread)))))))
        (when (and thread (sb-thread:thread-alive-p thread))
          (error 'transport-error :name "TransportError"
                 :message "Live owner did not retire before the close deadline"))
        (let ((pending nil))
          (sb-thread:with-mutex ((live-manager-lock manager))
            (setf pending (live-manager-pending-responses manager)
                  (live-manager-pending-responses manager) '()))
          (dolist (response pending)
            (fail-response-unless-complete
             response
             (make-condition 'transport-error :name "TransportError"
                             :message "Live owner closed"))))
        (sb-thread:with-mutex ((live-manager-lock manager))
          (maphash (lambda (id subscription)
                     (declare (ignore id))
                     (setf (subscription-active subscription) nil))
                   (live-manager-active manager))
          (clrhash (live-manager-active manager))
          (setf (live-manager-closed manager) t
                (live-manager-commands manager) '()
                (live-manager-deliveries manager) '()
                (live-manager-in-flight-deliveries manager) '()
                (live-manager-delivery-bytes manager) 0
                (live-manager-active-bytes manager) 0)
          (sb-thread:condition-broadcast (live-manager-condition manager)))))
    t))

(defun state-version (query-set identity timestamp)
  (json-object "querySet" query-set "identity" identity "ts" timestamp))

(defun valid-state-version-p (version)
  (and (hash-table-p version)
       (let ((query-set (json-get version "querySet" -1))
             (identity (json-get version "identity" -1))
             (timestamp (json-get version "ts" nil)))
         (and (integerp query-set) (>= query-set 0)
              (integerp identity) (>= identity 0)
              (stringp timestamp) (canonical-timestamp-p timestamp)))))

(defun same-state-version-p (left right)
  (and (valid-state-version-p left) (valid-state-version-p right)
       (= (json-get left "querySet") (json-get right "querySet"))
       (= (json-get left "identity") (json-get right "identity"))
       (string= (json-get left "ts") (json-get right "ts"))))

(defun session-id ()
  (let ((hex (random-hex-id 16)))
    (format nil "~A-~A-4~A-~A-~A"
            (subseq hex 0 8) (subseq hex 8 12) (subseq hex 13 16)
            (concatenate 'string
                         (string (char "89ab" (mod (parse-integer hex :start 16 :end 18
                                                                 :radix 16) 4)))
                         (subseq hex 17 20))
            (subseq hex 20 32))))

(defun query-modification (kind subscription)
  (if (eq kind :add)
      (json-object "type" "Add"
                   "queryId" (subscription-query-id subscription)
                   "udfPath" (subscription-path subscription)
                   "args" (list (subscription-args subscription)))
      (json-object "type" "Remove"
                   "queryId" (subscription-query-id subscription))))

(defun sorted-subscriptions (manager)
  (sort (loop for value being the hash-values of (live-manager-active manager)
              collect value)
        #'< :key #'subscription-query-id))

(defun publish-error-to-active (manager condition)
  (dolist (subscription (sorted-subscriptions manager))
    (enqueue-update manager subscription
                    (make-update :error condition
                                 :generation (live-manager-connection-count manager))
                    nil)))

(defun live-owner-loop (manager)
  ;; This thread alone opens, reads, writes, retires, and reconnects sockets.
  (let ((websocket nil)
        (remote-version (state-version 0 0 +initial-timestamp+))
        (query-set-version 0)
        (next-connect-at nil)
        (backoff +initial-backoff+)
        (last-response (monotonic-seconds)))
    (labels
         ((send-json (value)
           (let ((deadline (deadline-after 5.0)))
             (when *live-before-write-hook*
               (handler-case
                   (sb-ext:with-timeout
                       (deadline-remaining deadline "Live owner write hook")
                     (funcall *live-before-write-hook* value))
                 (sb-ext:timeout ()
                   (error 'transport-timeout :operation "Live owner write hook"))))
             (websocket-send-text
              websocket (json-encode value)
              :timeout (deadline-remaining deadline "Live owner write"))))
         (retire (reason &key reconnect)
           (when websocket
             (websocket-close websocket :reason "retired")
             (setf websocket nil)
             (sb-thread:with-mutex ((live-manager-lock manager))
               (incf (live-manager-connection-count manager))))
           (sb-thread:with-mutex ((live-manager-lock manager))
             (setf (live-manager-last-close-reason manager) reason))
           (setf query-set-version 0
                 remote-version (state-version 0 0 +initial-timestamp+)
                 next-connect-at (and reconnect
                                      (+ (monotonic-seconds) backoff)))
           (when reconnect (setf backoff (min +maximum-backoff+ (* backoff 2)))))
         (connect-now ()
           (handler-case
               (progn
                 (setf websocket
                       (websocket-connect (live-manager-deployment-url manager)
                                          (live-manager-client-version manager)
                                          :timeout 2.0))
                 (let ((connect
                         (json-object
                          "type" "Connect"
                          "sessionId" (session-id)
                          "connectionCount"
                          (live-manager-connection-count manager)
                          "lastCloseReason"
                          (live-manager-last-close-reason manager)
                          "clientTs" 0)))
                   (when (live-manager-max-observed-timestamp manager)
                     (setf (gethash "maxObservedTimestamp" connect)
                           (live-manager-max-observed-timestamp manager)))
                   (send-json connect))
                 (let ((subscriptions (sorted-subscriptions manager)))
                   (when subscriptions
                     (send-json
                      (json-object
                       "type" "ModifyQuerySet"
                       "baseVersion" 0 "newVersion" 1
                       "modifications"
                       (mapcar (lambda (subscription)
                                 (query-modification :add subscription))
                               subscriptions)))
                     (setf query-set-version 1)))
                 (setf remote-version (state-version 0 0 +initial-timestamp+)
                       next-connect-at nil
                       last-response (monotonic-seconds)
                       backoff +initial-backoff+)
                 t)
             (error (condition)
               (when websocket (websocket-close websocket) (setf websocket nil))
               (sb-thread:with-mutex ((live-manager-lock manager))
                 (incf (live-manager-connection-count manager))
                 (setf (live-manager-last-close-reason manager)
                       (format nil "~A" condition)))
               (setf next-connect-at (+ (monotonic-seconds) backoff)
                     backoff (min +maximum-backoff+ (* backoff 2)))
               nil)))
         (ensure-connected ()
           (if websocket
               (values t nil)
               (let ((connected (connect-now)))
                 ;; CONNECT-NOW resends every active Add exactly once.
                 (values connected connected))))
         (modify-one (kind subscription)
           (multiple-value-bind (connected rehydrated) (ensure-connected)
             (unless connected
               (error 'transport-error :name "TransportError"
                      :message "Live WebSocket connection failed"))
             (handler-case
                 (progn
                   ;; The first subscribe was already included in CONNECT-NOW's
                   ;; active-query hydration. Sending it again would advance the
                   ;; query-set version with a duplicate Add.
                   (unless (and rehydrated (eq kind :add))
                     (send-json
                      (json-object "type" "ModifyQuerySet"
                                   "baseVersion" query-set-version
                                   "newVersion" (1+ query-set-version)
                                   "modifications"
                                   (list (query-modification kind subscription))))
                     (incf query-set-version))
                   t)
               (error (condition)
                 (retire (format nil "~A" condition) :reconnect t)
                 (error 'transport-error :name "TransportError"
                        :message (format nil "Live write failed: ~A" condition))))))
         (process-command (command)
           (let ((response (owner-command-response command)))
             (handler-case
                 (case (owner-command-kind command)
                   (:subscribe
                    (destructuring-bind (path args) (owner-command-data command)
                      (let* ((accounted-size (calculate-subscription-size path args))
                             (query-id (live-manager-next-query-id manager))
                             (subscription
                               (%make-subscription :manager manager :query-id query-id
                                                   :path path :args args
                                                   :accounted-size accounted-size)))
                        (ensure-subscription-capacity manager accounted-size)
                        (incf (live-manager-next-query-id manager))
                        (setf (gethash query-id (live-manager-active manager)) subscription)
                        (incf (live-manager-active-bytes manager) accounted-size)
                        (handler-case
                            (progn
                              (modify-one :add subscription)
                              (complete-response response :value subscription))
                          (error (condition)
                            (remhash query-id (live-manager-active manager))
                            (decf (live-manager-active-bytes manager) accounted-size)
                            (setf (subscription-active subscription) nil)
                            (error condition))))))
                   (:unsubscribe
                   (let ((subscription (owner-command-data command)))
                      ;; Invalidate local delivery first. The acknowledgement is
                      ;; published only after Remove is written or the old socket
                      ;; is retired, so no stale generation crosses the barrier.
                      (when (gethash (subscription-query-id subscription)
                                     (live-manager-active manager))
                        (remhash (subscription-query-id subscription)
                                 (live-manager-active manager))
                        (decf (live-manager-active-bytes manager)
                              (subscription-accounted-size subscription)))
                      (setf (subscription-active subscription) nil)
                      (sb-thread:with-mutex ((live-manager-lock manager))
                        (remove-subscription-deliveries manager subscription)
                        (sb-thread:condition-broadcast
                         (live-manager-condition manager)))
                      (when websocket (modify-one :remove subscription))
                      (complete-response response :value t)))
                   (:debug-disconnect
                    ;; Retire the generation synchronously, then schedule normal
                    ;; reconnect work before the adapter may acknowledge it.
                    (if websocket
                        (retire "DebugDisconnect" :reconnect t)
                        ;; A real peer failure may already have retired the old
                        ;; generation between its last value and this command.
                        ;; In that case the required barrier is already true;
                        ;; make reconnect promptly runnable and acknowledge it.
                        (progn
                          (setf next-connect-at
                                (min (or next-connect-at most-positive-double-float)
                                     (+ (monotonic-seconds) +initial-backoff+)))
                          (sb-thread:with-mutex ((live-manager-lock manager))
                            (setf (live-manager-last-close-reason manager)
                                  "DebugDisconnectAfterRetirement"))))
                    (complete-response
                     response :value (live-manager-connection-count manager)))
                   (:close
                    (setf (live-manager-closed manager) t)
                    (maphash (lambda (id subscription)
                               (declare (ignore id))
                               (setf (subscription-active subscription) nil))
                             (live-manager-active manager))
                    (clrhash (live-manager-active manager))
                    (sb-thread:with-mutex ((live-manager-lock manager))
                      (setf (live-manager-deliveries manager) '()
                            (live-manager-in-flight-deliveries manager) '()
                            (live-manager-delivery-bytes manager) 0
                            (live-manager-active-bytes manager) 0)
                      (sb-thread:condition-broadcast
                       (live-manager-condition manager)))
                    (when websocket (websocket-close websocket) (setf websocket nil))
                    (complete-response response :value t)))
               (error (condition) (complete-response response :error condition)))))
         (handle-transition (message)
           (let ((start (json-get message "startVersion"))
                 (end (json-get message "endVersion"))
                 (modifications (json-get message "modifications")))
             (unless (valid-state-version-p start)
               (error "Malformed Transition startVersion"))
             (unless (same-state-version-p start remote-version)
               (error "Transition startVersion does not match local state"))
             (unless (and (valid-state-version-p end) (listp modifications))
               (error "Malformed Transition"))
             (let ((timestamp (json-get end "ts" "")))
               ;; Validate every modification and retain only the final change
               ;; for each query. Nothing, including timestamp metadata, is
               ;; committed while this pass can still fail.
               (let ((pending (make-hash-table))
                     (query-order '()))
               (dolist (modification modifications)
                 (let* ((kind (json-get modification "type"))
                        (query-id (json-get modification "queryId" -1))
                        (subscription (gethash query-id (live-manager-active manager))))
                   (unless (and (stringp kind) (integerp query-id) (>= query-id 0))
                     (error "Malformed Transition modification"))
                   (unless (member query-id query-order) (push query-id query-order))
                   (cond
                     ((string= kind "QueryUpdated")
                     (unless (json-has-key-p modification "value")
                        (error "QueryUpdated omitted value"))
                      (let ((logs
                              (if (json-has-key-p modification "logLines")
                                  (json-get modification "logLines") '())))
                        (unless (valid-log-lines-p logs)
                          (error "QueryUpdated logLines must be an array of strings"))
                      (when subscription
                        (let* ((value (json-get modification "value"))
                               (signature (value-signature value)))
                          (unless (string= signature
                                           (or (subscription-last-signature subscription) ""))
                            (setf (gethash query-id pending)
                                  (list subscription
                                        (make-update
                                         :value value
                                         :generation
                                         (live-manager-connection-count manager)
                                         :logs logs)
                                        signature)))
                          (when (string= signature
                                         (or (subscription-last-signature subscription) ""))
                            (remhash query-id pending))))))
                     ((string= kind "QueryFailed")
                      (let ((logs
                              (if (json-has-key-p modification "logLines")
                                  (json-get modification "logLines") '()))
                            (message-text
                              (if (json-has-key-p modification "errorMessage")
                                  (json-get modification "errorMessage")
                                  "Live query failed")))
                        (unless (valid-log-lines-p logs)
                          (error "QueryFailed logLines must be an array of strings"))
                        (unless (stringp message-text)
                          (error "QueryFailed errorMessage must be a string"))
                        (when subscription
                        (let* ((data (json-get modification "errorData" +json-null+))
                               (error (make-condition
                                       'function-error :name "FunctionError"
                                       :message message-text :data data
                                       :logs logs))
                               (signature (error-signature message-text data)))
                          (unless (string= signature
                                           (or (subscription-last-signature subscription) ""))
                            (setf (gethash query-id pending)
                                  (list subscription
                                        (make-update
                                         :error error :generation
                                         (live-manager-connection-count manager))
                                        signature)))
                          (when (string= signature
                                         (or (subscription-last-signature subscription) ""))
                            (remhash query-id pending))))))
                     ((string= kind "QueryRemoved") (remhash query-id pending))
                     (t (error "Unknown Transition modification ~S" kind)))))
                 (let ((changes
                         (loop for query-id in (nreverse query-order)
                               for change = (gethash query-id pending)
                               when change collect change)))
                   ;; Timestamp, state version and all coalesced deliveries
                   ;; become visible together.
                   (sb-thread:with-mutex ((live-manager-lock manager))
                     (let ((current (live-manager-max-observed-timestamp manager)))
                       (when (or (null current)
                                 (timestamp-greater-p timestamp current))
                         (setf (live-manager-max-observed-timestamp manager) timestamp)))
                     (dolist (change changes)
                       (apply #'enqueue-update-locked manager change))
                     (setf remote-version end
                           last-response (monotonic-seconds)
                           backoff +initial-backoff+)
                     (sb-thread:condition-broadcast
                      (live-manager-condition manager))))))))
         (handle-message (text)
           (let ((message (json-decode text)))
             (unless (hash-table-p message) (error "Live message is not an object"))
             (let ((kind (json-get message "type")))
               (cond
                 ((string= kind "Transition") (handle-transition message))
                 ((member kind '("Ping" "MutationResponse" "ActionResponse")
                          :test #'string=)
                  (setf last-response (monotonic-seconds)
                        backoff +initial-backoff+))
                 ((string= kind "TransitionChunk")
                  (error "TransitionChunk assembly is not implemented"))
                 ((member kind '("FatalError" "AuthError") :test #'string=)
                  (error "~A: ~A" kind (json-get message "error" "server error")))
                 (t (error "Unknown Live message type ~S" kind)))))))
      (unwind-protect
           (loop until (live-manager-closed manager)
                 do
                    ;; Drain all controller work before reading another frame.
                    ;; A continuously sending peer therefore cannot starve close,
                    ;; unsubscribe, replacement, or debug barriers.
                    (loop for command =
                            (sb-thread:with-mutex ((live-manager-lock manager))
                              (pop (live-manager-commands manager)))
                          while command do (process-command command))
                    (when (and (not websocket)
                               (> (hash-table-count (live-manager-active manager)) 0)
                               next-connect-at
                               (>= (monotonic-seconds) next-connect-at))
                      (connect-now))
                    (when (and websocket
                               (> (- (monotonic-seconds) last-response) 30.0))
                      (let ((condition
                              (make-condition 'transport-error :name "TransportError"
                                              :message "Live server became inactive")))
                        (publish-error-to-active manager condition)
                        (retire "InactiveServer" :reconnect t)))
                    (if websocket
                        (handler-case
                            (let ((message (websocket-receive websocket :timeout 0.05)))
                              (cond
                                ((stringp message) (handle-message message))
                                ((and (consp message) (eq (first message) :closed))
                                 (let* ((payload (second message))
                                        (close-text
                                          (if (>= (length payload) 2)
                                              (handler-case
                                                  (octets-string (subseq payload 2))
                                                (error () "invalid close reason"))
                                              "peer EOF"))
                                        (condition
                                         (make-condition
                                          'transport-error :name "TransportError"
                                          :message (format nil "Live WebSocket closed: ~A"
                                                           close-text))))
                                   ;; Surface the real retirement and keep the
                                   ;; subscription alive for the later recovery.
                                   (publish-error-to-active manager condition)
                                   (retire (format nil "PeerClosed: ~A" close-text)
                                           :reconnect t)))))
                          (websocket-idle-timeout () nil)
                          ((or transport-timeout transport-io-error) (condition)
                            (let ((transport
                                    (make-condition
                                     'transport-error :name "TransportError"
                                     :message (format nil "Live transport failed: ~A"
                                                      condition))))
                              (publish-error-to-active manager transport)
                              (retire (error-message transport) :reconnect t)))
                          (error (condition)
                            (let ((protocol
                                    (make-condition
                                     'protocol-error :name "ProtocolError"
                                     :message (format nil "Live protocol failed: ~A"
                                                      condition))))
                              (publish-error-to-active manager protocol)
                              (retire (error-message protocol) :reconnect t))))
                        (sb-thread:with-mutex ((live-manager-lock manager))
                          (when (and (null (live-manager-commands manager))
                                     (not (live-manager-closed manager)))
                            (sb-thread:condition-wait
                             (live-manager-condition manager)
                             (live-manager-lock manager) :timeout 0.05)))))
        (when websocket (websocket-close websocket))
        (let ((pending nil))
          (sb-thread:with-mutex ((live-manager-lock manager))
            (setf (live-manager-closed manager) t
                  pending (live-manager-pending-responses manager)
                  (live-manager-pending-responses manager) '())
            (sb-thread:condition-broadcast (live-manager-condition manager)))
          (dolist (response pending)
            (fail-response-unless-complete
             response
             (make-condition 'transport-error :name "TransportError"
                             :message "Live owner retired"))))))))
