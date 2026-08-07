;;; unit_test.el --- pure-function regressions for the primitives every
;;; higher layer depends on: WebSocket frame encode/decode symmetry, the
;;; Convex timestamp/version comparison Live's reconnect and out-of-order
;;; guard rely on, and the delivery queue's bounding and generation-based
;;; invalidation. None of these need a socket.

(require 'cl-lib)

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

;;;; ---------------------------------------------------------------------
;;;; WebSocket frame encoding: masked, RFC 6455-shaped, and round-trips
;;;; through the same unmasking arithmetic the decoder in
;;;; convex-ws--try-read uses (masking is XOR, so re-applying it decodes).
;;;; ---------------------------------------------------------------------

(defun test--unmask (masked-with-header)
  "Undo convex-ws--frame-encode's own masking to recover the payload,
mirroring exactly what a real server does when it decodes a client frame -
the one piece of frame parsing convex.el itself never needs, since server
frames are never masked, but which this test still exercises to prove the
encoder's masking is genuinely reversible, not merely `well-formed'."
  (let* ((first (aref masked-with-header 0))
         (second (aref masked-with-header 1))
         (fin (/= 0 (logand first #x80)))
         (opcode (logand first #x0f))
         (masked-flag (/= 0 (logand second #x80)))
         (lengthbyte (logand second #x7f)))
    (unless (and fin masked-flag) (error "expected a final, masked frame"))
    (let* ((offset (if (<= lengthbyte 125) 2 4))
           (length (if (<= lengthbyte 125)
                       lengthbyte
                     (logior (ash (aref masked-with-header 2) 8)
                             (aref masked-with-header 3))))
           (mask (substring masked-with-header offset (+ offset 4)))
           (masked (substring masked-with-header (+ offset 4) (+ offset 4 length)))
           (out (make-string length 0)))
      (dotimes (i length)
        (aset out i (logxor (aref masked i) (aref mask (mod i 4)))))
      (list opcode out))))

(let ((frame (convex-ws--frame-encode 1 (encode-coding-string "hi" 'utf-8))))
  (test-same (aref frame 0) #x81 "text frame FIN+opcode byte")
  (test-same (logand (aref frame 1) #x80) #x80 "text frame is masked")
  (cl-destructuring-bind (opcode payload) (test--unmask frame)
    (test-same opcode 1 "text frame opcode round-trips")
    (test-same payload "hi" "text frame payload round-trips")))

(let* ((payload (make-string 200 ?a))
       (frame (convex-ws--frame-encode 1 payload)))
  (test-same (logand (aref frame 1) #x7f) 126 "126-255 byte frame uses the extended-16 length marker")
  (cl-destructuring-bind (opcode decoded) (test--unmask frame)
    (test-same opcode 1 "extended-length frame opcode round-trips")
    (test-same decoded payload "extended-length frame payload round-trips")))

(let ((frame (convex-ws--frame-encode 8 "")))
  (test-same (aref frame 0) #x88 "close frame FIN+opcode byte")
  (test-same (aref frame 1) #x80 "empty close frame has zero masked length"))

;;;; ---------------------------------------------------------------------
;;;; Convex version comparison: the 8-byte big-endian timestamp Live's
;;;; out-of-order-transition guard and reconnect logic both depend on.
;;;; ---------------------------------------------------------------------

(test-same (convex-live--ts-value "AAAAAAAAAAA=") 0 "zero timestamp decodes to 0")
(test-same (convex-live--ts-value (base64-encode-string (unibyte-string 0 0 0 0 0 0 0 1) t))
           1 "timestamp byte 1 decodes to 1")
(test-same (convex-live--ts-value (base64-encode-string (unibyte-string 0 0 0 0 0 0 1 0) t))
           256 "timestamp byte 256 decodes to 256 (big-endian, not little)")

(test-same (convex-live--same-version
            (list :query-set 1 :identity 0 :ts "AAAAAAAAAAA=")
            (list :query-set 1 :identity 0 :ts "AAAAAAAAAAA="))
           t "identical versions compare equal")
(test-same (convex-live--same-version
            (list :query-set 1 :identity 0 :ts "AAAAAAAAAAA=")
            (list :query-set 2 :identity 0 :ts "AAAAAAAAAAA="))
           nil "different querySet compares unequal")
(test-same (convex-live--same-version
            (list :query-set 1 :identity 0 :ts "AAAAAAAAAAA=")
            (list :query-set 1 :identity 0
                  :ts (base64-encode-string (unibyte-string 0 0 0 0 0 0 0 1) t)))
           nil "different timestamp compares unequal")

;;;; ---------------------------------------------------------------------
;;;; HTTP envelope classification: success/error/transport/protocol, using
;;;; convex--envelope-message directly since the full round trip already
;;;; has real loopback coverage in live_test.el.
;;;; ---------------------------------------------------------------------

(let ((h (make-hash-table :test 'equal)))
  (puthash "errorMessage" "boom" h)
  (test-same (convex--envelope-message h "fallback") "boom"
             "envelope message prefers errorMessage"))
(let ((h (make-hash-table :test 'equal)))
  (puthash "message" "boom2" h)
  (test-same (convex--envelope-message h "fallback") "boom2"
             "envelope message falls back to message"))
(test-same (convex--envelope-message nil "fallback") "fallback"
           "envelope message falls back when there is no envelope at all")

;;;; ---------------------------------------------------------------------
;;;; Live's delivery queue: bounded, oldest dropped first, and a stale
;;;; generation is silently discarded rather than delivered - the same
;;;; guarantee live_test.el proves end to end for a real unsubscribe; this
;;;; is the pure-data-structure half of it.
;;;; ---------------------------------------------------------------------

(convex-live-init)
(puthash 0 (list :path "demo:state" :args (make-hash-table :test 'equal)
                  :active t :last nil :gen 1)
         convex-live--subs)
(dotimes (i 70) (convex-live--enqueue "value" 0 (format "{\"n\":%d}" i) nil))
(test-same (<= (length convex-live--events) 64) t
           "the delivery queue never grows past its 64-event bound")
(let ((first-kind (convex-live-next-event)))
  (test-same first-kind "value" "oldest-dropped-first leaves a value event at the front")
  (test-same (gethash "n" (json-parse-string convex-live--event-payload :object-type 'hash-table))
             6 "the surviving oldest event is exactly the 65th of 70 enqueued (6 dropped)"))

(convex-live-init)
(puthash 0 (list :path "demo:state" :args (make-hash-table :test 'equal)
                  :active t :last nil :gen 1)
         convex-live--subs)
(convex-live--enqueue "value" 0 "{\"n\":1}" nil)
(puthash 0 (plist-put (gethash 0 convex-live--subs) :gen 2) convex-live--subs)
(test-same (convex-live-next-event) nil
           "an event queued under a since-invalidated generation is never delivered")

(message "%d / %d checks passed" (- test--checks test--failures) test--checks)
(kill-emacs (if (> test--failures 0) 1 0))
