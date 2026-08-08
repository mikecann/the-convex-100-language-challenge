;;; live_test.el --- deterministic loopback coverage of AGENTS.md's Live
;;; acceptance list: HTTP query/mutation and bearer auth, the RFC 6455
;;; handshake and masking, Add/Remove, an initial value, an external
;;; update, five real reconnects that each resend the active Add,
;;; QueryFailed, and the unsubscribe-before-acknowledgement barrier.
;;
;; Blocking I/O means one process cannot be both this client and its own
;; peer: while this client's convex-query blocks inside
;; url-retrieve-synchronously waiting for a response, nothing else in this
;; same process runs to send one. The peer therefore runs as a second, real
;; OS process - client/tests/live_test_fixture.el, started by the
;; Dockerfile before this file - a real TCP peer speaking the real wire
;; protocol (HTTP framing and RFC 6455 framing by hand), not a mocked
;; transport.

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../convex.el" here) nil t))

(defvar test--failures 0)
(defvar test--checks 0)

(defun test-pass (label)
  (setq test--checks (1+ test--checks))
  (message "pass %s" label))

(defun test-fail (label detail)
  (setq test--checks (1+ test--checks))
  (setq test--failures (1+ test--failures))
  (message "FAIL %s: %s" label detail))

(defun test-same (actual expected label)
  (if (equal actual expected)
      (test-pass label)
    (test-fail label (format "expected %S got %S" expected actual))))

(defconst test--port 18500)

(defun main-wait-event (deadline-seconds)
  "Pump Live until an event is ready, or DEADLINE-SECONDS elapses. Returns
the event kind (\"value\"/\"error\"), or nil on timeout."
  (let ((deadline (+ (float-time) deadline-seconds)) kind)
    (while (and (not (setq kind (convex-live-next-event)))
                (< (float-time) deadline))
      (convex-live-pump (+ (float-time) 0.2)))
    kind))

;;;; ---------------------------------------------------------------------
;;;; HTTP: a real query and a real structured FunctionError
;;;; ---------------------------------------------------------------------

(convex-configure (format "http://127.0.0.1:%d" test--port) "secret-token")

(let* ((args (make-hash-table :test 'equal))
       (result (convex-query "messages:list" args)))
  (if result
      (progn
        (test-same (gethash "count" result) 0 "HTTP query decoded value")
        (test-same (append convex--last-logs nil) '("from-fixture") "HTTP query logLines"))
    (test-fail "HTTP query decoded value" (format "%S" convex--last-error))
    (test-fail "HTTP query logLines" "no result")))

(let* ((args (make-hash-table :test 'equal))
       (result (convex-mutation "messages:send" args)))
  (if result
      (progn
        (test-fail "structured FunctionError classification" "mutation unexpectedly succeeded")
        (test-fail "structured FunctionError data" "mutation unexpectedly succeeded"))
    (test-same (plist-get convex--last-error :name) "FunctionError"
               "structured FunctionError classification")
    (test-same (gethash "code" (plist-get convex--last-error :data)) "ROOM_EMPTY"
               "structured FunctionError data")))

;;;; ---------------------------------------------------------------------
;;;; Live: subscribe, an initial value, an external update
;;;; ---------------------------------------------------------------------

(let ((qid1 (convex-live-subscribe "demo:state" (make-hash-table :test 'equal))))
  (let ((ev1 (main-wait-event 20)))
    (if (equal ev1 "value")
        (test-same (gethash "count"
                             (json-parse-string convex-live--event-payload
                                                 :object-type 'hash-table))
                   0 "initial Live value")
      (test-fail "initial Live value" (format "kind=%S" ev1))))
  (let ((ev2 (main-wait-event 20)))
    (if (equal ev2 "value")
        (test-same (gethash "count"
                             (json-parse-string convex-live--event-payload
                                                 :object-type 'hash-table))
                   1 "external update")
      (test-fail "external update" (format "kind=%S" ev2))))

  ;;;; -------------------------------------------------------------------
  ;;;; Five real reconnects, each resending the active Add and delivering a
  ;;;; genuine resubscribed value.
  ;;;; -------------------------------------------------------------------
  (let ((reconnect-successes 0))
    (dotimes (i 5)
      (let ((n (1+ i)))
        (if (not (convex-live-debug-disconnect))
            (test-fail (format "reconnect %d debugDisconnect" n)
                       (format "%S" convex--last-error))
          ;; debugDisconnect must acknowledge only after the old connection
          ;; is retired and reconnect work is scheduled.
          (if (not (and (not convex-live--connected)
                        (> convex-live--next-reconnect-at 0)))
              (test-fail "debugDisconnect acknowledges only after retiring and scheduling a reconnect"
                         "state was not retired before returning")
            (let ((got (main-wait-event 20)))
              (cond
               ((equal got "value")
                (setq reconnect-successes (1+ reconnect-successes))
                (test-same (gethash "count"
                                     (json-parse-string convex-live--event-payload
                                                         :object-type 'hash-table))
                           (+ 100 n) (format "reconnect %d resubscribed value" n)))
               ((null got)
                (test-fail (format "reconnect %d resubscribed value" n) "timed out"))
               (t
                (test-fail (format "reconnect %d resubscribed value" n)
                           (format "delivered kind %s instead of value" got)))))))))
    (test-same reconnect-successes 5 "all five reconnects observed a real resubscribed value"))

  ;; Unsubscribe must invalidate before any acknowledgement is published: an
  ;; event already queued under the OLD generation (enqueued here directly,
  ;; standing in for one Live queued a moment earlier) must never be
  ;; delivered once unsubscribe has invalidated it.
  (convex-live--enqueue "value" qid1 "{\"count\":99}" nil)
  (convex-live-unsubscribe qid1)
  (if (convex-live-next-event)
      (test-fail "unsubscribe invalidates queued events before delivery" "delivered a stale event")
    (test-pass "unsubscribe invalidates queued events before delivery")))

;;;; ---------------------------------------------------------------------
;;;; Live: QueryFailed on a fresh connection, with structured errorData
;;;; ---------------------------------------------------------------------

;; The fixture already closed its side of the fifth reconnect's connection
;; (right after reading this client's Remove for qid1); force this one
;; closed too rather than leaving it idle-but-open, so the subscription
;; below is a fresh scenario on a clean connection, not a continuation of
;; the last one.
(convex-live-debug-disconnect)
(convex-live-subscribe "demo:requiresNonzero" (make-hash-table :test 'equal))
(let ((ev3 (main-wait-event 20)))
  (if (equal ev3 "error")
      (progn
        (test-pass "QueryFailed delivers an error event")
        (let* ((decoded (json-parse-string convex-live--event-payload :object-type 'hash-table))
               (data (gethash "data" decoded)))
          (if (hash-table-p data)
              (test-same (gethash "code" data) "ROOM_EMPTY"
                         "QueryFailed carries structured errorData.code")
            (test-fail "QueryFailed carries structured errorData.code"
                       (format "errorData was missing or malformed: %s" convex-live--event-payload)))))
    (test-fail "QueryFailed delivers an error event" (format "kind=%S" ev3))))

(convex-live-close)

(message "%d / %d checks passed" (- test--checks test--failures) test--checks)
(kill-emacs (if (> test--failures 0) 1 0))
