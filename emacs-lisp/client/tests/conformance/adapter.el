;;; adapter.el --- Test-only NDJSON adapter for the Emacs Lisp Convex client
;;
;; This is test infrastructure, not public client code (see AGENTS.md's
;; "Conformance executable" section). It implements NDJSON adapter protocol
;; v1 over stdin/stdout, or over a single TCP connection when ADAPTER_LISTEN
;; is set, and calls the real client (convex.el) for every operation. stdout
;; is reserved for protocol events; every diagnostic goes to stderr.
;;
;; Live delivery buffering is convex.el's own: a bounded queue (64 events,
;; 8 MiB of conservatively charged bytes, oldest dropped first) already lives
;; in convex-live--enqueue/convex-live-next-event and is exercised by
;; client/tests/live_test.el. This adapter adds no second queue on top of
;; it - it drains whatever convex-live-next-event has and writes it out
;; immediately, so a stalled reader applies ordinary OS pipe/socket
;; backpressure to this loop rather than an adapter-private buffer silently
;; growing without bound.
;;
;; The one problem convex.el itself never faces is reading this adapter's
;; own controller input without starving Live delivery. Emacs's network
;; processes support exactly this multiplexing via accept-process-output
;; with a timeout (used below for TCP mode), but batch-mode Emacs Lisp has
;; no equivalent for its own inherited stdin: the only primitive that reads
;; piped, non-tty stdin at all (`read-from-minibuffer') is an uninterruptible
;; blocking call, `read-event'/`read-char'/`sit-for' never observe piped
;; stdin data even when it is already available, and neither Lisp threads
;; nor a spawned subprocess give this process concurrent, non-blocking access
;; to its own external stdin (confirmed empirically: a thread blocked on
;; stdin stalls every other thread, and a child process does not inherit
;; this process's real stdin - Emacs redirects a child's stdin to a pipe it
;; controls). Several other single-threaded languages in this project hit
;; the identical wall for the identical reason and solve it the identical
;; way: a poll(2) readiness check on stdin, callable with a timeout, driven
;; from the adapter's own loop (see cobol/client/convex-native.c,
;; forth/client/convexrt.c, rexx/client/shim.c, icon/client/shim.c).
;; stdin-poll.c is this client's version of that primitive - a tiny,
;; reviewed, standalone helper invoked via `call-process', never linked into
;; Emacs itself. It never reads or forwards a byte of stdin; only this
;; file's own `read-from-minibuffer' call ever consumes adapter input, so
;; there is exactly one reader and no relay. convex.el remains untouched by
;; any of this and has no C anywhere in it.

(require 'json)
(require 'cl-lib)

(defconst adapter--here
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "This file's own directory, captured once while `load-file-name' is
still bound - it is only bound for the duration of loading a file, so
anything computed from it lazily at call time (long after loading
finished) would see nil instead.")

(load (expand-file-name "../../convex.el" adapter--here) nil t)

(defconst adapter--language "emacs-lisp")
(defconst adapter--implementation
  (format "native-emacs-%s" emacs-version))
(defconst adapter--runtime (format "emacs-%s" emacs-version))

(defconst adapter--stdin-poll-timeout-ms 200
  "How long one stdin readiness check waits before this loop instead goes
and pumps Live. Short enough that a Live value already sitting in
convex.el's queue is written out promptly; long enough that this process
is not busy-spinning a subprocess call.")

(defconst adapter--pump-budget 0.05
  "Seconds `convex-live-pump' may spend per call from this loop's own
cadence. Reconnecting or reading a large frame can still take longer -
this is only how long one iteration waits before this loop goes back to
checking stdin (or the TCP peer) again.")

(defconst adapter--close-timeout 2.0
  "Bounded wait for a queued closed event to actually leave this process
before giving up and exiting non-zero, matching AGENTS.md's requirement
that shutdown be bounded rather than merely scheduled.")

(defvar adapter--subs (make-hash-table :test 'equal)
  "subscriptionId -> queryId for every currently active subscription.")
(defvar adapter--sub-of-qid (make-hash-table :test 'eql)
  "queryId -> subscriptionId, the reverse of `adapter--subs', so a Live
event (identified only by queryId) can be reported under the
subscriptionId the controller actually used.")
(defvar adapter--closing nil)
(defvar adapter--out-stream t
  "Where events are written: `t' for stdout in stdio mode, or a network
process in TCP mode.")

;;;; ---------------------------------------------------------------------
;;;; Emitting events
;;;; ---------------------------------------------------------------------

(defun adapter--send (line)
  "Write LINE (a single already-terminated NDJSON line) to whichever
transport is active, and make sure it actually leaves this process rather
than sitting in a buffer."
  (if (processp adapter--out-stream)
      (process-send-string adapter--out-stream line)
    (princ line adapter--out-stream)))

(defun adapter--emit (fields)
  "FIELDS is an alist of (KEY . VALUE) pairs already in the shape
`json-serialize' expects (Lisp values, not pre-encoded JSON text). Adds
protocolVersion/language/implementation/runtime only when the caller asked
for them, serializes, and writes one NDJSON line."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (pair fields) (puthash (car pair) (cdr pair) h))
    (adapter--send (concat (json-serialize h) "\n"))))

(defun adapter--logs-present-p (logs)
  "LOGS is a Lisp vector/list already decoded from JSON, or nil. True only
when it is non-empty: an empty log array is omitted from adapter events
entirely, matching every other client in this project."
  (and logs (> (length logs) 0)))

(defun adapter--error-fields (name message &optional data)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "name" name h)
    (puthash "message" message h)
    (when data (puthash "data" data h))
    h))

(defun adapter--emit-error (message name data logs &optional id)
  (adapter--emit
   (append
    (if id (list (cons "id" id)) nil)
    (list (cons "type" "error")
          (cons "error" (adapter--error-fields name message data)))
    (if (adapter--logs-present-p logs) (list (cons "logs" (vconcat logs))) nil))))

;;;; ---------------------------------------------------------------------
;;;; Structured-error classification shared by every command handler
;;;; ---------------------------------------------------------------------

(define-error 'adapter-protocol-error "adapter protocol error")

(defun adapter--throw-protocol (message)
  (signal 'adapter-protocol-error (list message)))

(defun adapter--client-error-fields ()
  "After a convex.el call returns nil, the failure it left behind as
(NAME MESSAGE DATA), read from convex--last-error."
  (list (plist-get convex--last-error :name)
        (plist-get convex--last-error :message)
        (plist-get convex--last-error :data)))

;;;; ---------------------------------------------------------------------
;;;; Command validation
;;;; ---------------------------------------------------------------------

(defun adapter--require-string (command field &optional max-length)
  (let ((value (gethash field command)))
    (unless (and (stringp value)
                 (> (length value) 0)
                 (<= (length value) (or max-length 128)))
      (adapter--throw-protocol (format "command omitted valid %s" field)))
    value))

(defun adapter--require-args (command)
  (let ((value (gethash "args" command)))
    (unless (hash-table-p value)
      (adapter--throw-protocol "command omitted valid args"))
    value))

;;;; ---------------------------------------------------------------------
;;;; Command handlers. Each returns the response fields to `adapter--emit',
;;;; or signals `adapter-protocol-error' / lets a convex.el failure surface
;;;; through `convex--last-error' for the caller to classify.
;;;; ---------------------------------------------------------------------

(defun adapter--ensure-client ()
  (unless convex--url
    (let ((url (getenv "CONVEX_URL")))
      (when (or (null url) (string-empty-p url))
        (error "CONVEX_URL is required"))
      (convex-configure url (or (getenv "CONVEX_AUTH_TOKEN") ""))))
  t)

(defun adapter--handle-hello (id command)
  (unless (eql (gethash "protocolVersion" command) 1)
    (adapter--throw-protocol "unsupported adapter protocol version"))
  (adapter--emit (list (cons "protocolVersion" 1)
                        (cons "id" id)
                        (cons "type" "ready")
                        (cons "language" adapter--language)
                        (cons "implementation" adapter--implementation)
                        (cons "runtime" adapter--runtime))))

(defun adapter--handle-call (id op command)
  (let ((path (adapter--require-string command "path" 512))
        (args (adapter--require-args command)))
    (adapter--ensure-client)
    (let* ((fn (cond ((equal op "query") #'convex-query)
                      ((equal op "mutation") #'convex-mutation)
                      (t #'convex-action)))
           (result (funcall fn path args)))
      (if (or result (null convex--last-error))
          (adapter--emit
           (append
            (list (cons "id" id) (cons "type" "result") (cons "value" result))
            (if (adapter--logs-present-p convex--last-logs)
                (list (cons "logs" convex--last-logs))
              nil)))
        (cl-destructuring-bind (name message data) (adapter--client-error-fields)
          (adapter--emit-error message name data nil id))))))

(defun adapter--handle-set-auth (id command)
  (let ((token (gethash "token" command)))
    (unless (or (null token) (eq token :null) (stringp token))
      (adapter--throw-protocol "command omitted valid token"))
    (adapter--ensure-client)
    (convex-set-auth (if (stringp token) token ""))
    (adapter--emit (list (cons "id" id) (cons "type" "ack")))))

(defun adapter--handle-subscribe (id command)
  (let ((sub-id (adapter--require-string command "subscriptionId"))
        (path (adapter--require-string command "path" 512))
        (args (adapter--require-args command)))
    (adapter--ensure-client)
    ;; A same-subscriptionId replacement must invalidate the old relay
    ;; before this acknowledgement is published. convex-live-unsubscribe
    ;; bumps that query's generation counter synchronously, so any event
    ;; already queued for it is discarded by convex-live-next-event before
    ;; this function returns - there is no separate adapter-level
    ;; generation to keep in step with it.
    (let ((old-qid (gethash sub-id adapter--subs)))
      (when old-qid
        (convex-live-unsubscribe old-qid)
        (remhash old-qid adapter--sub-of-qid)))
    (let ((qid (convex-live-subscribe path args)))
      (puthash sub-id qid adapter--subs)
      (puthash qid sub-id adapter--sub-of-qid))
    (adapter--emit (list (cons "id" id) (cons "type" "ack")))))

(defun adapter--handle-unsubscribe (id command)
  (let ((sub-id (adapter--require-string command "subscriptionId")))
    (adapter--ensure-client)
    (let ((qid (gethash sub-id adapter--subs)))
      (when qid
        (convex-live-unsubscribe qid)
        (remhash sub-id adapter--subs)
        (remhash qid adapter--sub-of-qid)))
    (adapter--emit (list (cons "id" id) (cons "type" "ack")))))

(defun adapter--handle-debug-disconnect (id)
  (adapter--ensure-client)
  (unless (convex-live-debug-disconnect)
    (error "debugDisconnect: not connected"))
  ;; The acknowledgement barrier: convex-live-debug-disconnect only returns
  ;; successfully after retiring the old connection and scheduling a
  ;; reconnect, so reaching this line already satisfies it. Assert that
  ;; explicitly so a future refactor of convex.el cannot silently break it
  ;; without this test noticing.
  (unless (and (not convex-live--connected) (> convex-live--next-reconnect-at 0))
    (error "debugDisconnect acknowledgement barrier was not reached"))
  (adapter--emit (list (cons "id" id) (cons "type" "ack"))))

(defun adapter--handle-close (id)
  (maphash (lambda (_sub-id qid) (convex-live-unsubscribe qid)) adapter--subs)
  (clrhash adapter--subs)
  (clrhash adapter--sub-of-qid)
  (convex-live-close)
  (adapter--emit (list (cons "id" id) (cons "type" "closed")))
  (setq adapter--closing t))

;;;; ---------------------------------------------------------------------
;;;; Dispatch
;;;; ---------------------------------------------------------------------

(defun adapter--handle-line (line)
  (let* ((command
          (condition-case err
              (json-parse-string line :object-type 'hash-table
                                  :null-object :null :false-object :false)
            (error (adapter--emit-error
                    (format "decode command: %s" (error-message-string err))
                    "ProtocolError" nil nil)
                   nil))))
    (when command
      (let (id op)
        (condition-case err
            (progn
              (setq id (adapter--require-string command "id"))
              (setq op (adapter--require-string command "op" 32))
              (cond
               ((equal op "hello") (adapter--handle-hello id command))
               ((member op '("query" "mutation" "action"))
                (adapter--handle-call id op command))
               ((equal op "setAuth") (adapter--handle-set-auth id command))
               ((equal op "subscribe") (adapter--handle-subscribe id command))
               ((equal op "unsubscribe") (adapter--handle-unsubscribe id command))
               ((equal op "debugDisconnect") (adapter--handle-debug-disconnect id))
               ((equal op "close") (adapter--handle-close id))
               (t (adapter--throw-protocol (format "unknown adapter operation %s" op)))))
          (adapter-protocol-error
           (adapter--emit-error (cadr err) "ProtocolError" nil nil id))
          (error
           (adapter--emit-error (error-message-string err) "Error" nil nil id)))))))

(defun adapter--drain-live-events ()
  "Write out every Live event convex.el currently has queued, translated
into `subscription' events under the subscriptionId the controller used."
  (let (kind)
    (while (setq kind (convex-live-next-event))
      (let ((sub-id (gethash convex-live--event-queryid adapter--sub-of-qid)))
        (when sub-id
          (if (equal kind "value")
              (adapter--emit
               (append
                (list (cons "type" "subscription")
                      (cons "subscriptionId" sub-id)
                      (cons "value"
                            (json-parse-string convex-live--event-payload
                                                :object-type 'hash-table
                                                :null-object :null
                                                :false-object :false)))
                (let ((logs (and convex-live--event-logs
                                  (json-parse-string convex-live--event-logs))))
                  (if (adapter--logs-present-p logs) (list (cons "logs" logs)) nil))))
            (let* ((decoded (json-parse-string convex-live--event-payload
                                                :object-type 'hash-table
                                                :null-object :null
                                                :false-object :false))
                   (logs (and convex-live--event-logs
                              (json-parse-string convex-live--event-logs))))
              (adapter--emit
               (append
                (list (cons "type" "subscription")
                      (cons "subscriptionId" sub-id)
                      (cons "error"
                            (adapter--error-fields
                             (gethash "name" decoded) (gethash "message" decoded)
                             (gethash "data" decoded))))
                (if (adapter--logs-present-p logs) (list (cons "logs" logs)) nil))))))))))

;;;; ---------------------------------------------------------------------
;;;; Stdio transport: a small native helper answers "is stdin readable"
;;;; with a timeout (see the file header); the read itself is convex.el's
;;;; own line-oriented read-from-minibuffer, unchanged.
;;;; ---------------------------------------------------------------------

(defconst adapter--stdin-poll-path (expand-file-name "stdin-poll" adapter--here))

(defun adapter--stdin-ready-p (timeout-ms)
  "`call-process' does not give stdin-poll this process's own inherited
stdin (Emacs connects a call-process child's stdin to /dev/null unless an
INFILE is given), so this process's pid is passed instead and stdin-poll
reopens /proc/PID/fd/0 itself - see stdin-poll.c's own header comment."
  (= 0 (call-process adapter--stdin-poll-path nil nil nil
                      (number-to-string (emacs-pid))
                      (number-to-string timeout-ms))))

(defun adapter--run-stdio ()
  (setq adapter--out-stream t)
  (while (not adapter--closing)
    (if (adapter--stdin-ready-p adapter--stdin-poll-timeout-ms)
        (let ((line (condition-case nil (read-from-minibuffer "")
                      (end-of-file (setq adapter--closing t) nil))))
          (when line (adapter--handle-line line)))
      (convex-live-pump (+ (float-time) adapter--pump-budget)))
    (adapter--drain-live-events)))

;;;; ---------------------------------------------------------------------
;;;; TCP transport: fully native. accept-process-output already multiplexes
;;;; the controller connection and the Live WebSocket without any helper.
;;;; ---------------------------------------------------------------------

(defvar adapter--tcp-buffer "")
(defvar adapter--tcp-conn nil)

(defun adapter--tcp-filter (_proc chunk)
  (setq adapter--tcp-buffer (concat adapter--tcp-buffer chunk))
  (let (newline)
    (while (setq newline (string-search "\n" adapter--tcp-buffer))
      (let ((line (substring adapter--tcp-buffer 0 newline)))
        (setq adapter--tcp-buffer (substring adapter--tcp-buffer (1+ newline)))
        (adapter--handle-line line)))))

(defun adapter--run-tcp (listen-spec)
  (let* ((colon (string-search ":" listen-spec))
         (host (if (and colon (> colon 0)) (substring listen-spec 0 colon) "0.0.0.0"))
         (port (string-to-number (substring listen-spec (1+ (or colon -1))))))
    (let* ((accepted nil)
           (server
            (make-network-process
             :name "convex-adapter-listener" :service port :host host :server t
             :family 'ipv4 :coding 'utf-8
             :log (lambda (_server client _msg)
                    (setq accepted client)
                    (setq adapter--out-stream client)
                    (setq adapter--tcp-conn client)
                    (set-process-coding-system client 'utf-8 'utf-8)
                    (set-process-filter client #'adapter--tcp-filter)))))
      ;; accept-process-output does not reliably drive a listening process's
      ;; own :log callback (confirmed empirically: a connection made while
      ;; this loop called accept-process-output on the server process was
      ;; never accepted); sleep-for does, so the wait for the shared
      ;; harness's one controller connection uses that instead.
      (while (not accepted) (sleep-for 0.2))
      (delete-process server)
      (while (not adapter--closing)
        (accept-process-output adapter--tcp-conn adapter--pump-budget)
        (convex-live-pump (+ (float-time) adapter--pump-budget))
        (adapter--drain-live-events)
        (unless (process-live-p adapter--tcp-conn) (setq adapter--closing t))))))

;;;; ---------------------------------------------------------------------
;;;; Entry point
;;;; ---------------------------------------------------------------------

(defun adapter--main ()
  (let ((listen (getenv "ADAPTER_LISTEN")))
    (if (and listen (not (string-empty-p listen)))
        (adapter--run-tcp listen)
      (adapter--run-stdio)))
  ;; adapter--handle-close already wrote the closed event via
  ;; adapter--send before setting adapter--closing. Stdio output (princ to
  ;; stdout) is synchronous, so there is nothing left to drain there. TCP
  ;; output goes through process-send-string, which Emacs may still be
  ;; flushing to the socket in the background; give it a bounded chance to
  ;; finish rather than tearing the connection down mid-write.
  (when (processp adapter--out-stream)
    (let ((deadline (+ (float-time) adapter--close-timeout)))
      (while (and (< (float-time) deadline)
                  (process-live-p adapter--out-stream))
        (accept-process-output adapter--out-stream 0.05))))
  (kill-emacs 0))

(unless (getenv "ADAPTER_TEST_ONLY")
  (adapter--main))

(provide 'adapter)
