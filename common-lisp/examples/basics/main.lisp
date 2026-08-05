(in-package #:convex)

(defun example-count (value operation)
  "Accept Convex's integral decimal JSON numbers without accepting fractions."
  (let ((count (and (hash-table-p value) (json-get value "count"))))
    (unless (and (realp count)
                 (= count (truncate count))
                 (<= 0 count #x7fffffffffffffff))
      (error "~A returned a non-integral or out-of-range count" operation))
    (truncate count)))

(defun next-example-update (subscription operation)
  "Wait through recoverable transport events, but fail on query/protocol errors."
  (let ((deadline (deadline-after 10.0)))
    (loop
      for remaining = (- deadline (monotonic-seconds))
      do (when (<= remaining 0) (error "Timed out waiting for ~A" operation))
         (let ((update (subscription-next subscription :timeout remaining)))
           (unless update (error "Timed out waiting for ~A" operation))
           ;; Live reports a real socket retirement, then reconnects the same
           ;; subscription. The example waits for that recovery value.
           (when (and (update-error update)
                      (not (typep (update-error update) 'transport-error)))
             (error (update-error update)))
           (unless (update-error update) (return (update-value update)))))))

(defun example-main ()
  (handler-case
      (let ((deployment (sb-ext:posix-getenv "CONVEX_URL")))
        (unless (and deployment (plusp (length deployment)))
          (error "CONVEX_URL is required"))
        (let* ((arguments (rest sb-ext:*posix-argv*))
               (room (or (first arguments)
                         (sb-ext:posix-getenv "EXAMPLE_ROOM")
                         "common-lisp-example"))
               ;; Configure one client for the deployment supplied by Docker.
               (client (make-client deployment))
               (subscription nil))
          (unwind-protect
               (progn
                 ;; Query the room through Convex's documented HTTP endpoint.
                 (let* ((query (client-query client "demo:state"
                                             (json-object "room" room)))
                        ;; Decode the generic JSON object into the integer this
                        ;; counter program actually needs.
                        (current (example-count (result-value query) "current query")))
                   (format t "current count: ~D~%" current)

                   ;; Start Live before mutating so no reactive update is missed.
                   (setf subscription
                         (client-subscribe client "demo:state"
                                           (json-object "room" room)))

                   ;; The first Live value hydrates the same current query.
                   (let ((initial
                           (example-count
                            (next-example-update subscription "initial Live value")
                            "initial Live value")))
                     (unless (= initial current)
                       (error "Initial Live count disagreed with HTTP"))
                     (format t "live initial count: ~D~%" initial))

                   ;; A random runId is the mutation's idempotency key. Reusing
                   ;; it would return the prior result instead of incrementing twice.
                   (let* ((mutation
                            (client-mutation
                             client "demo:increment"
                             (json-object "room" room
                                          "language" "common-lisp"
                                          "runId" (random-hex-id))))
                          (mutation-value (result-value mutation))
                          (applied (json-get mutation-value "applied" +json-false+))
                          (mutation-count
                            (example-count (json-get mutation-value "state") "mutation"))
                          (expected (1+ current)))
                     (unless (eq applied t) (error "Mutation was not applied"))
                     (unless (= mutation-count expected)
                       (error "Mutation returned an unexpected count"))
                     (format t "mutation applied: true~%")
                     (format t "mutation count: ~D~%" mutation-count)

                     ;; Receive the mutation through Live, without polling HTTP.
                     (let ((updated
                             (example-count
                              (next-example-update subscription "updated Live value")
                              "updated Live value")))
                       (unless (= updated expected)
                         (error "Updated Live count disagreed with the mutation"))
                       (format t "live updated count: ~D~%" updated)

                       ;; All three operations agreed before this proof line prints.
                       (format t "verified count: ~D -> ~D~%" current updated)))))
            ;; Cleanup retires the subscription and bounds socket shutdown.
            (when subscription (ignore-errors (subscription-close subscription)))
            (ignore-errors (client-close client)))))
    (error (condition)
      (format *error-output* "Common Lisp example failed: ~A~%" condition)
      (finish-output *error-output*)
      (sb-ext:exit :code 1)))
  (sb-ext:exit :code 0))
