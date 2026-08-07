;;; main.el --- the canonical Convex-from-Emacs-Lisp walkthrough: one HTTP
;;; query, a Live subscription, an idempotent mutation, and the resulting
;;; Live update. This is the exact source rendered in the README and on the
;;; project website, so every step is commented for a reader who has never
;;; seen this client before. It uses the same client/convex.el the
;;; conformance adapter does, so this is precisely what the README shows
;;; running.

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../../client/convex.el" here) nil t))

(defun main--println (format-string &rest args)
  "Print one LF-terminated line to stdout. `message' is not usable here:
in --batch mode it writes to stderr, and this transcript must be
byte-identical, on stdout, to _shared/examples/basics.expected.txt."
  (princ (apply #'format format-string args))
  (princ "\n"))

(defun main--whole-count (value operation)
  "VALUE is the decoded `count' field of a Convex query, mutation, or Live
result. Convex JSON can spell a whole number as 0.0; accept that
mathematical integer, but reject fractions, strings, and non-finite
values, matching every other client's example in this project."
  (unless (numberp value)
    (error "%s omitted a numeric count" operation))
  (unless (= value (truncate value))
    (error "%s count was not a finite whole number" operation))
  (truncate value))

(defun main--wait-for-live-event (deadline-seconds)
  "Pump Live until an event is ready, or DEADLINE-SECONDS elapses. Returns
the event kind (\"value\"/\"error\"), or nil on timeout."
  (let ((deadline (+ (float-time) deadline-seconds)) kind)
    (while (and (not (setq kind (convex-live-next-event)))
                (< (float-time) deadline))
      (convex-live-pump (+ (float-time) 0.2)))
    kind))

(defun main ()
  (let ((deployment (getenv "CONVEX_URL")))
    (when (or (null deployment) (string-empty-p deployment))
      (error "CONVEX_URL is required"))
    (let* ((room (or (car command-line-args-left) "emacs-lisp-example"))
           (args (make-hash-table :test 'equal))
           (subscription nil))
      (puthash "room" room args)
      (convex-configure deployment)
      (unwind-protect
          (progn
            ;; Ask Convex once over HTTP before opening Live, to establish
            ;; the fresh room.
            (let* ((current (convex-query "demo:state" args)))
              (unless current
                (error "current query failed: %s" (plist-get convex--last-error :message)))
              (let ((current-count (main--whole-count (gethash "count" current) "current query")))
                (unless (= current-count 0)
                  (error "current count was %d, expected 0" current-count))
                (main--println "current count: %d" current-count)))

            ;; Start Live first. Its initial value proves no mutation can
            ;; slip between subscription setup and the later idempotent
            ;; write.
            (setq subscription (convex-live-subscribe "demo:state" args))
            (let ((kind (main--wait-for-live-event 20)))
              (unless (equal kind "value")
                (error "initial Live value: %s" (if kind "delivered an error" "timed out")))
              (let ((initial-count (main--whole-count
                                     (gethash "count"
                                              (json-parse-string convex-live--event-payload
                                                                  :object-type 'hash-table))
                                     "initial Live value")))
                (unless (= initial-count 0)
                  (error "initial Live count was %d, expected 0" initial-count))
                (main--println "live initial count: %d" initial-count)))

            ;; A unique runId is the mutation's idempotency key, so retrying
            ;; this logical request would not double-increment the room.
            (let* ((mutation-args (make-hash-table :test 'equal))
                   (mutation nil))
              (puthash "room" room mutation-args)
              (puthash "language" "emacs-lisp" mutation-args)
              (puthash "runId" (format "%x" (truncate (* (float-time) 1000000))) mutation-args)
              (setq mutation (convex-mutation "demo:increment" mutation-args))
              (unless mutation
                (error "mutation failed: %s" (plist-get convex--last-error :message)))
              (unless (eq (gethash "applied" mutation) t)
                (error "mutation was not applied"))
              (main--println "mutation applied: true")
              (let ((mutation-count (main--whole-count
                                      (gethash "count" (gethash "state" mutation))
                                      "mutation")))
                (unless (= mutation-count 1)
                  (error "mutation count was %d, expected 1" mutation-count))
                (main--println "mutation count: %d" mutation-count)))

            ;; Wait for the changed value from Live rather than issuing
            ;; another query.
            (let ((kind (main--wait-for-live-event 20)))
              (unless (equal kind "value")
                (error "updated Live value: %s" (if kind "delivered an error" "timed out")))
              (let ((updated-count (main--whole-count
                                     (gethash "count"
                                              (json-parse-string convex-live--event-payload
                                                                  :object-type 'hash-table))
                                     "updated Live value")))
                (unless (= updated-count 1)
                  (error "updated Live count was %d, expected 1" updated-count))
                (main--println "live updated count: %d" updated-count)))
            (main--println "verified count: 0 -> 1"))
        (when subscription (convex-live-unsubscribe subscription))
        (convex-live-close)))))

;; An uncaught Lisp error in --batch mode prints a full debugger backtrace
;; to stderr and exits 255, not the clean single-line message and exit
;; status 1 this project's Docker test stages assert on. Catch it here
;; instead: stdout stays untouched on failure (nothing above ever fails
;; after printing a line, only before), and stderr gets exactly the
;; message, not a backtrace.
(condition-case err
    (main)
  (error
   (princ (error-message-string err) #'external-debugging-output)
   (princ "\n" #'external-debugging-output)
   (kill-emacs 1)))
