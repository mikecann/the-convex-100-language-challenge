;;; convex.el --- Native Emacs Lisp Convex client  -*- lexical-binding: t; -*-

;; This is an educational, unofficial Convex client written in batch-mode
;; Emacs Lisp. It is not a production SDK.
;;
;; Emacs has genuine network primitives, including TLS via GnuTLS
;; (`gnutls-available-p'), so this client is native end to end: no other
;; language's Convex client, and no shelled-out `curl' or `node', is
;; involved anywhere. HTTP uses Emacs's own `url' library. Emacs has no
;; WebSocket library at all, so the RFC 6455 handshake and frame format for
;; Live are hand-written here over `make-network-process', the same way
;; several other clients in this repository implement WebSockets by hand
;; over a raw socket. JSON, SHA-1, and base64 are all genuine Emacs
;; built-ins (`json-parse-string'/`json-serialize', `secure-hash',
;; `base64-encode-string'), used for their ordinary purpose and never
;; delegated to.
;;
;; The public surface is a small set of `convex-' functions operating on a
;; single global client, because the two callers in this repository - the
;; canonical example and the conformance adapter - never need more than one
;; Convex connection at a time; see `convex-configure'.

(require 'url)
(require 'json)
(require 'gnutls)
(require 'cl-lib)

;;;; ---------------------------------------------------------------------
;;;; Client state
;;;; ---------------------------------------------------------------------

(defvar convex--host nil "Deployment host.")
(defvar convex--port nil "Deployment port.")
(defvar convex--tls nil "Non-nil when the deployment uses https/wss.")
(defvar convex--url nil "The deployment's base URL, trailing slash trimmed.")
(defvar convex--auth "" "The current bearer token, or the empty string.")
(defvar convex--version "emacs-lisp-0.1.0" "Convex-Client header value.")
(defvar convex--last-logs nil "logLines from the most recent HTTP call.")

;; The error a failed call left behind, as a Convex-shaped plist:
;; (:name "FunctionError" | "ProtocolError" | "TransportError"
;;  :message STRING :data JSON-VALUE-OR-NIL)
(defvar convex--last-error nil)

(defun convex--fail (name message &optional data)
  "Record the error a caller can inspect via `convex--last-error', and
return nil so callers can write (or (convex--fail ...) ...) `and'
compositions without special-casing every intermediate step."
  (setq convex--last-error (list :name name :message message :data data))
  nil)

(defun convex-configure (url &optional token)
  "Point this client at URL (an absolute http(s) URL) with an optional
bearer TOKEN. Resets Live's own state, so a fresh client (or a fresh
adapter process) never inherits state from an earlier one."
  (let ((parsed (url-generic-parse-url url)))
    (unless (and parsed (url-type parsed) (url-host parsed)
                 (member (url-type parsed) '("http" "https")))
      (error "Convex deployment URL must be an absolute HTTP(S) URL"))
    (setq convex--tls (string= (url-type parsed) "https"))
    (setq convex--host (url-host parsed))
    (setq convex--port (or (url-port parsed) (if convex--tls 443 80)))
    (setq convex--url (format "%s://%s:%d" (url-type parsed)
                               convex--host convex--port))
    (setq convex--auth (or token ""))
    (convex-live-init)
    t))

(defun convex-set-auth (token)
  "Replace the bearer token used by every later HTTP call and the next
Live Connect. An empty TOKEN clears authentication."
  (setq convex--auth (or token "")))

;;;; ---------------------------------------------------------------------
;;;; HTTP: query / mutation / action
;;;; ---------------------------------------------------------------------

(defun convex--envelope-message (parsed fallback)
  "A human-readable message from a decoded envelope PARSED, or FALLBACK."
  (or (and (hash-table-p parsed) (gethash "errorMessage" parsed))
      (and (hash-table-p parsed) (gethash "message" parsed))
      fallback))

(cl-defun convex--http-call (op path args)
  "Call PATH (query|mutation|action) with ARGS, a hash table of JSON-safe
values. Returns the decoded `value' on success. On failure, returns nil
and leaves the reason in `convex--last-error'."
  (unless convex--url (error "convex-configure was never called"))
  (let* ((body (json-serialize
                (let ((h (make-hash-table :test 'equal)))
                  (puthash "path" path h)
                  (puthash "args" args h)
                  (puthash "format" "json" h)
                  h)))
         (url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json")
                    ("Accept" . "application/json"))
                  (list (cons "Convex-Client" convex--version))
                  (unless (string-empty-p convex--auth)
                    (list (cons "Authorization"
                                (concat "Bearer " convex--auth))))))
         (url-request-data (encode-coding-string body 'utf-8))
         (target (format "%s/api/%s" convex--url op))
         (response-buffer
          (condition-case err
              (url-retrieve-synchronously target t t 20)
            (error
             (setq err err) nil))))
    (unless response-buffer
      (cl-return-from convex--http-call
        (convex--fail "TransportError" "HTTP request did not complete")))
    (unwind-protect
        (with-current-buffer response-buffer
          (goto-char (point-min))
          (unless (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
            (cl-return-from convex--http-call
              (convex--fail "TransportError" "no HTTP status line")))
          (let ((code (string-to-number (match-string 1))))
            (goto-char (point-min))
            (unless (search-forward "\n\n" nil t)
              (setq convex--last-logs nil)
              (cl-return-from convex--http-call
                (convex--fail "ProtocolError" "HTTP response had no body")))
            (let* ((raw (buffer-substring-no-properties (point) (point-max)))
                   (decoded (condition-case nil
                                (json-parse-string raw :object-type 'hash-table)
                              (error :convex-not-json)))
                   (parsed (unless (eq decoded :convex-not-json) decoded))
                   (status (and (hash-table-p parsed) (gethash "status" parsed))))
              (setq convex--last-logs
                    (and (hash-table-p parsed) (gethash "logLines" parsed)))
              (cond
               ((and (equal status "success") (= code 200))
                (if (hash-table-p parsed)
                    (gethash "value" parsed)
                  (convex--fail "ProtocolError"
                                "HTTP success response omitted value")))
               ((or (equal status "error") (= code 560))
                (convex--fail
                 "FunctionError"
                 (convex--envelope-message parsed "Convex function failed")
                 (and (hash-table-p parsed) (gethash "errorData" parsed))))
               ((memql code '(500 502 503 504 408 429))
                (convex--fail
                 "TransportError"
                 (format "HTTP %d from Convex: %s" code
                         (convex--envelope-message parsed "no Convex error envelope"))))
               (t
                (convex--fail
                 "ProtocolError"
                 (format "HTTP %d from Convex: %s" code
                         (convex--envelope-message parsed "no Convex error envelope"))))))))
      (kill-buffer response-buffer))))

(defun convex-query (path args) (convex--http-call "query" path args))
(defun convex-mutation (path args) (convex--http-call "mutation" path args))
(defun convex-action (path args) (convex--http-call "action" path args))

;;;; ---------------------------------------------------------------------
;;;; Random bytes
;;;; ---------------------------------------------------------------------

(defun convex--random-bytes (n)
  "N cryptographically random bytes, read from /dev/urandom. RFC 6455
masking keys and the handshake nonce should not be predictable; every
target platform for this client is Linux, where /dev/urandom always
exists, so this has no fallback path to silently mask a real failure.
`insert-file-contents' refuses a bounded read (a BEG/END range) against a
character-special file like /dev/urandom - only regular, seekable files
support that - and an unbounded read blocks forever, since the device has
no end of file. `call-process' has no such restriction: it treats
/dev/urandom exactly like any other subprocess input, so `head' reads
precisely N bytes and stops."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((status (call-process "head" nil t nil "-c" (number-to-string n)
                                 "/dev/urandom")))
      (unless (and (eq status 0) (= (buffer-size) n))
        (error "convex--random-bytes: head did not produce %d bytes (status %s)"
               n status)))
    (buffer-substring-no-properties (point-min) (point-max))))

;;;; ---------------------------------------------------------------------
;;;; WebSocket: RFC 6455 handshake and framing
;;;;
;;;; Emacs has no WebSocket library, so this is hand-written over
;;;; `open-network-stream', the same way several other clients in this
;;;; repository implement RFC 6455 by hand over a raw socket. Only
;;;; client->server frames are masked; RFC 6455 forbids a server from
;;;; masking, so decoding never needs the masking arithmetic at all.
;;;; ---------------------------------------------------------------------

(defvar convex-ws--process nil "The live WebSocket process, or nil.")
(defvar convex-ws--buffer nil "Bytes received but not yet parsed into a frame.")
(defvar convex-ws--frag-opcode nil "Opcode of an in-progress fragmented message.")
(defvar convex-ws--frag-payload nil "Accumulated bytes of that fragmented message.")
(defvar convex-ws--partial-deadline nil
  "Absolute deadline (float-time) for completing a frame once any byte of
it has arrived, independent of the caller's own polling deadline, so a
slow peer cannot hold the connection open with repeated short polls.")

(defconst convex-ws--partial-frame-timeout 8.0)
(defconst convex-ws--max-frame-bytes (* 2 1024 1024))

(defun convex--now () (float-time))

(defun convex-ws--reset ()
  (setq convex-ws--buffer "")
  (setq convex-ws--frag-opcode nil)
  (setq convex-ws--frag-payload nil)
  (setq convex-ws--partial-deadline nil))

(defun convex-ws--abort (proc)
  "Delete PROC and kill its process buffer. A failed handshake attempt
must not leak the buffer `convex-ws--connect' created for it."
  (let ((buffer (process-buffer proc)))
    (ignore-errors (delete-process proc))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(cl-defun convex-ws--connect (path deadline)
  "Open the WebSocket at PATH on the configured deployment, complete the
RFC 6455 handshake, and leave `convex-ws--process' ready for
`convex-ws--send'/`convex-ws--try-read'. DEADLINE is an absolute
`float-time'."
  (convex-ws--reset)
  (let* ((key (base64-encode-string (convex--random-bytes 16) t))
         (proc (condition-case err
                   (open-network-stream
                    "convex-live"
                    ;; Unibyte is required, not cosmetic: :coding 'binary
                    ;; controls how bytes are decoded off the wire, but a
                    ;; multibyte destination buffer still represents any
                    ;; byte >= 128 as Emacs's internal "raw byte in a
                    ;; multibyte string" codepoint, not the plain 0-255
                    ;; integer the frame parser's aref/logand arithmetic
                    ;; below assumes - every length byte and mask byte
                    ;; would silently decode wrong.
                    (let ((buf (generate-new-buffer " *convex-live*")))
                      (with-current-buffer buf (set-buffer-multibyte nil))
                      buf)
                    convex--host convex--port
                    :type (if convex--tls 'tls 'plain)
                    :coding 'binary :nowait nil
                    :nogreeting t)
                 (error
                  (cl-return-from convex-ws--connect
                    (convex--fail "TransportError"
                                   (format "connect failed: %s"
                                           (error-message-string err))))))))
    (set-process-query-on-exit-flag proc nil)
    (setq convex-ws--process proc)
    (let ((request
           (concat "GET " path " HTTP/1.1\r\n"
                   "Host: " convex--host "\r\n"
                   "Upgrade: websocket\r\n"
                   "Connection: Upgrade\r\n"
                   "Sec-WebSocket-Key: " key "\r\n"
                   "Sec-WebSocket-Version: 13\r\n"
                   "Convex-Client: " convex--version "\r\n\r\n")))
      (process-send-string proc (encode-coding-string request 'binary)))
    ;; Read the handshake response, which may arrive over several reads.
    (let ((response ""))
      (while (not (string-match "\r\n\r\n" response))
        (when (> (convex--now) deadline)
          (convex-ws--abort proc)
          (cl-return-from convex-ws--connect
            (convex--fail "TransportError" "WebSocket handshake timed out")))
        (unless (accept-process-output proc 0.2)
          (unless (process-live-p proc)
            (cl-return-from convex-ws--connect
              (convex--fail "TransportError" "peer closed during handshake"))))
        (setq response (concat response (convex-ws--drain-process-buffer proc))))
      (let* ((header-end (match-end 0))
             (headers (substring response 0 header-end))
             (status-line (car (split-string headers "\r\n"))))
        (unless (string-match "\\`HTTP/1\\.[01] 101" status-line)
          (convex-ws--abort proc)
          (cl-return-from convex-ws--connect
            (convex--fail "ProtocolError" "WebSocket upgrade was not 101")))
        (let ((accept nil))
          (dolist (line (split-string headers "\r\n"))
            (when (string-match "\\`Sec-WebSocket-Accept:[ \t]*\\(.*\\)\\'" line)
              (setq accept (match-string 1 line))))
          (let ((expected (base64-encode-string
                            (secure-hash 'sha1 (concat key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                                         nil nil t)
                            t)))
            (unless (equal accept expected)
              (convex-ws--abort proc)
              (cl-return-from convex-ws--connect
                (convex--fail "ProtocolError" "WebSocket accept mismatch")))))
        ;; Bytes after the header terminator already belong to the first frame.
        (setq convex-ws--buffer (substring response header-end))))
    t))

(defun convex-ws--drain-process-buffer (proc)
  "Take whatever bytes are sitting in PROC's own buffer and remove them
from it, so the next `accept-process-output' only adds new bytes."
  (with-current-buffer (process-buffer proc)
    (prog1 (buffer-substring-no-properties (point-min) (point-max))
      (erase-buffer))))

(defun convex-ws--frame-encode (opcode payload)
  "One complete masked frame for PAYLOAD (a unibyte string)."
  (let* ((length (length payload))
         (header
          (cond
           ((<= length 125) (unibyte-string (logior #x80 opcode) (logior #x80 length)))
           ((<= length 65535)
            (concat (unibyte-string (logior #x80 opcode) (logior #x80 126))
                    (unibyte-string (logand (ash length -8) #xff) (logand length #xff))))
           (t (error "frame too large"))))
         (mask (convex--random-bytes 4))
         (masked (make-string length 0)))
    (dotimes (i length)
      (aset masked i (logxor (aref payload i) (aref mask (mod i 4)))))
    (concat header mask masked)))

(cl-defun convex-ws--send (payload _deadline)
  "Send PAYLOAD (a Lisp string, encoded as UTF-8) as one text frame.
_DEADLINE is accepted for symmetry with every other I/O primitive here
but unused: `process-send-string' is a blocking call with no timeout
parameter of its own."
  (unless (process-live-p convex-ws--process)
    (cl-return-from convex-ws--send
      (convex--fail "TransportError" "WebSocket is not connected")))
  (condition-case err
      (progn
        (process-send-string
         convex-ws--process
         (convex-ws--frame-encode 1 (encode-coding-string payload 'utf-8)))
        t)
    (error (convex--fail "TransportError" (error-message-string err)))))

(cl-defun convex-ws--try-read (deadline)
  "Return the next complete text message, or fail. Failing with a
`convex--last-error' name of \"again\" means nothing arrived before
DEADLINE, not an error - the caller polls again. A ping is answered and
skipped automatically; a pong is skipped; a close frame is reported as
ProtocolError \"peer closed\" so every path through this function that
ends the connection goes through the same reconnect logic."
  (let ((proc convex-ws--process))
    (unless (process-live-p proc)
      (cl-return-from convex-ws--try-read
        (convex--fail "TransportError" "WebSocket is not connected")))
    (while t
      ;; Try to parse a complete frame out of what has already arrived.
      (when (>= (length convex-ws--buffer) 2)
        (let* ((first (aref convex-ws--buffer 0))
               (second (aref convex-ws--buffer 1))
               (fin (/= 0 (logand first #x80)))
               (opcode (logand first #x0f))
               (lengthbyte (logand second #x7f))
               (offset 2) (len lengthbyte))
          (when (/= 0 (logand second #x80))
            (cl-return-from convex-ws--try-read
              (convex--fail "ProtocolError" "server frame was masked")))
          (cond
           ((= lengthbyte 126)
            (setq offset 4)
            (when (< (length convex-ws--buffer) 4) (setq len nil)))
           ((= lengthbyte 127)
            (setq offset 10)
            (when (< (length convex-ws--buffer) 10) (setq len nil))))
          (when (and len (= lengthbyte 126))
            (setq len (logior (ash (aref convex-ws--buffer 2) 8) (aref convex-ws--buffer 3))))
          (when (and len (= lengthbyte 127))
            (setq len 0)
            (dotimes (i 8) (setq len (logior (ash len 8) (aref convex-ws--buffer (+ 2 i))))))
          (when (and len (> len convex-ws--max-frame-bytes))
            (cl-return-from convex-ws--try-read
              (convex--fail "ProtocolError" "WebSocket frame exceeds 2 MiB")))
          (when (and len (>= opcode 8) (or (> len 125) (not fin)))
            (cl-return-from convex-ws--try-read
              (convex--fail "ProtocolError" "invalid WebSocket control frame")))
          (when (and len (>= (length convex-ws--buffer) (+ offset len)))
            (let ((payload (substring convex-ws--buffer offset (+ offset len))))
              (setq convex-ws--buffer (substring convex-ws--buffer (+ offset len)))
              (setq convex-ws--partial-deadline nil)
              (let ((delivered (convex-ws--dispatch-frame fin opcode payload)))
                (when delivered
                  (cl-return-from convex-ws--try-read delivered)))
              ;; A control frame or a non-final fragment: loop to see whether
              ;; another complete frame is already buffered.
              (cl-return-from convex-ws--try-read
                (convex-ws--try-read deadline))))))
      ;; No complete frame yet: wait for more, honoring both deadlines.
      (when (> (length convex-ws--buffer) 0)
        (unless convex-ws--partial-deadline
          (setq convex-ws--partial-deadline (+ (convex--now) convex-ws--partial-frame-timeout))))
      (let ((effective (if convex-ws--partial-deadline
                            (min convex-ws--partial-deadline deadline)
                          deadline)))
        (when (> (convex--now) effective)
          (cl-return-from convex-ws--try-read
            (if convex-ws--partial-deadline
                (convex--fail "TransportError" "partial WebSocket frame timed out")
              (convex--fail "again" ""))))
        (unless (process-live-p proc)
          (cl-return-from convex-ws--try-read
            (convex--fail "TransportError" "peer closed the WebSocket")))
        (accept-process-output proc (min 0.2 (max 0 (- effective (convex--now)))))
        (setq convex-ws--buffer (concat convex-ws--buffer (convex-ws--drain-process-buffer proc)))))))

(defun convex-ws--dispatch-frame (fin opcode payload)
  "Apply one already-extracted frame. Returns a decoded text message when
one is ready to deliver, or nil when this frame was a control frame or a
non-final fragment and the read loop should keep going."
  (cond
   ((= opcode 8) (convex--fail "ProtocolError" "peer closed the WebSocket"))
   ((= opcode 9) (convex-ws--send-pong payload) nil)
   ((= opcode 10) nil)
   ((= opcode 0)
    (unless convex-ws--frag-opcode (error "unexpected WebSocket continuation"))
    (setq convex-ws--frag-payload (concat convex-ws--frag-payload payload))
    (if fin
        (prog1 (convex-ws--finish-message convex-ws--frag-opcode convex-ws--frag-payload)
          (setq convex-ws--frag-opcode nil convex-ws--frag-payload nil))
      nil))
   ((memql opcode '(1 2))
    (if fin
        (convex-ws--finish-message opcode payload)
      (setq convex-ws--frag-opcode opcode convex-ws--frag-payload payload)
      nil))
   (t (convex--fail "ProtocolError" (format "unsupported WebSocket opcode %d" opcode)))))

(defun convex-ws--finish-message (opcode payload)
  (if (/= opcode 1)
      (convex--fail "ProtocolError" "binary WebSocket data is unsupported")
    (decode-coding-string payload 'utf-8 t)))

(defun convex-ws--send-pong (payload)
  (when (process-live-p convex-ws--process)
    (ignore-errors
      (process-send-string convex-ws--process (convex-ws--frame-encode 10 payload)))))

;;;; ---------------------------------------------------------------------
;;;; Live: the pinned Convex sync protocol over /api/sync
;;;;
;;;; Connect, ModifyQuerySet (Add/Remove), and Transition
;;;; (QueryUpdated/QueryFailed/QueryRemoved). Live delivery is a bounded
;;;; queue: at most `convex-live--max-events' pending events and
;;;; `convex-live--max-bytes' of conservatively charged encoded bytes,
;;;; oldest dropped first, drained by the adapter after every pump.
;;;; Unsubscribe (and a same-subscriptionId replacement) bump a per-query
;;;; generation counter that invalidates any already-queued event for that
;;;; query before its acknowledgement is published.
;;;; ---------------------------------------------------------------------

(defconst convex-live--max-events 64)
(defconst convex-live--max-bytes (* 8 1024 1024))
(defconst convex-live--reconnect-min 0.1)
(defconst convex-live--reconnect-max 15.0)
(defconst convex-live--connect-timeout 10.0)

(defvar convex-live--connected nil)
(defvar convex-live--closed nil)
(defvar convex-live--next-qid 0)
(defvar convex-live--query-set 0)
(defvar convex-live--remote nil "Decoded {querySet identity ts} of the last known server version.")
(defvar convex-live--max-ts-value nil "Highest ts (as an integer) ever observed, for maxObservedTimestamp.")
(defvar convex-live--connection-count 0)
(defvar convex-live--last-close-reason "InitialConnect")
(defvar convex-live--reconnect-delay convex-live--reconnect-min)
(defvar convex-live--next-reconnect-at 0)
(defvar convex-live--active-count 0)
(defvar convex-live--subs nil "queryId -> plist (:path :args :active :last :gen).")
(defvar convex-live--events nil "Pending delivery queue, oldest first.")
(defvar convex-live--event-bytes 0)
(defvar convex-live--event-payload nil "Payload of the most recently dequeued event.")
(defvar convex-live--event-logs nil)
(defvar convex-live--event-queryid nil)

(defun convex-live-init ()
  "Reset every piece of Live state, so a fresh client (or a fresh adapter
process) never inherits state from an earlier one."
  (setq convex-live--connected nil
        convex-live--closed nil
        convex-live--next-qid 0
        convex-live--query-set 0
        convex-live--remote (convex-live--zero-version)
        convex-live--max-ts-value nil
        convex-live--connection-count 0
        convex-live--last-close-reason "InitialConnect"
        convex-live--reconnect-delay convex-live--reconnect-min
        convex-live--next-reconnect-at 0
        convex-live--active-count 0
        convex-live--subs (make-hash-table :test 'equal)
        convex-live--events nil
        convex-live--event-bytes 0))

(defun convex-live--zero-version ()
  (list :query-set 0 :identity 0 :ts "AAAAAAAAAAA="))

(defun convex-live--ts-value (base64-ts)
  "The 8-byte base64 timestamp as a single big-endian integer."
  (let ((bytes (base64-decode-string base64-ts)) (value 0))
    (dotimes (i (length bytes)) (setq value (logior (ash value 8) (aref bytes i))))
    value))

(defun convex-live--same-version (a b)
  (and (= (plist-get a :query-set) (plist-get b :query-set))
       (= (plist-get a :identity) (plist-get b :identity))
       (= (convex-live--ts-value (plist-get a :ts)) (convex-live--ts-value (plist-get b :ts)))))

(defun convex-live--decode-version (h)
  (list :query-set (round (gethash "querySet" h 0))
        :identity (round (gethash "identity" h 0))
        :ts (gethash "ts" h)))

;;; --- outgoing messages ---

(defun convex-live--session-id ()
  (mapconcat (lambda (b) (format "%02x" b)) (append (convex--random-bytes 16) nil) ""))

(cl-defun convex-live--connect-once (deadline)
  (convex-ws--connect "/api/sync" deadline)
  (unless (process-live-p convex-ws--process)
    (cl-return-from convex-live--connect-once (convex-live--retire convex--last-error)))
  (let ((fields (make-hash-table :test 'equal)))
    (puthash "type" "Connect" fields)
    (puthash "sessionId" (convex-live--session-id) fields)
    (puthash "connectionCount" convex-live--connection-count fields)
    (puthash "lastCloseReason" convex-live--last-close-reason fields)
    (puthash "clientTs" 0 fields)
    (unless (convex-ws--send (json-serialize fields) deadline)
      (cl-return-from convex-live--connect-once (convex-live--retire convex--last-error))))
  (setq convex-live--connected t)
  (setq convex-live--reconnect-delay convex-live--reconnect-min)
  (convex-live--resubscribe-all)
  t)

(defun convex-live--resubscribe-all ()
  "After a fresh Connect, re-add every still-active subscription in one
ModifyQuerySet. Query IDs are not renumbered, so identity survives a
reconnect."
  (let (mods)
    (maphash (lambda (qid sub)
               (when (plist-get sub :active)
                 (push (convex-live--add-mod qid sub) mods)))
             convex-live--subs)
    (when mods (convex-live--send-modifications (nreverse mods)))))

(defun convex-live--add-mod (qid sub)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "type" "Add" h)
    (puthash "queryId" qid h)
    (puthash "udfPath" (plist-get sub :path) h)
    (puthash "args" (vector (plist-get sub :args)) h)
    h))

(defun convex-live--remove-mod (qid)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "type" "Remove" h)
    (puthash "queryId" qid h)
    h))

(defun convex-live--send-modifications (mods)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "type" "ModifyQuerySet" h)
    (puthash "baseVersion" convex-live--query-set h)
    (puthash "newVersion" (1+ convex-live--query-set) h)
    (puthash "modifications" (vconcat mods) h)
    (if (convex-ws--send (json-serialize h) (+ (convex--now) 5.0))
        (setq convex-live--query-set (1+ convex-live--query-set))
      (convex-live--retire convex--last-error))))

;;; --- subscribe / unsubscribe ---

(defun convex-live-subscribe (path args)
  "Subscribe to PATH with ARGS (a hash table). Returns a new query id.
Sends an Add immediately when connected; otherwise the query joins the
next connection's own resubscribe-everything Connect sequence."
  (let ((qid convex-live--next-qid))
    (setq convex-live--next-qid (1+ qid))
    (puthash qid (list :path path :args args :active t :last nil
                        :gen (1+ (convex-live--generation qid)))
             convex-live--subs)
    (setq convex-live--active-count (1+ convex-live--active-count))
    (when convex-live--connected
      (convex-live--send-modifications (list (convex-live--add-mod qid (gethash qid convex-live--subs)))))
    qid))

(defun convex-live--generation (qid)
  (or (plist-get (gethash qid convex-live--subs) :gen) 0))

(defun convex-live-unsubscribe (qid)
  "Mark QID inactive and send Remove when connected. Invalidates before
any acknowledgement is published: bumps the generation counter first, so
an event already queued for this query is discarded by
`convex-live-next-event' rather than delivered under an id the controller
has already been told is gone."
  (let ((sub (gethash qid convex-live--subs)))
    (when (and sub (plist-get sub :active))
      (setq convex-live--active-count (1- convex-live--active-count))
      (puthash qid (plist-put (plist-put (copy-sequence sub) :active nil)
                               :gen (1+ (plist-get sub :gen)))
               convex-live--subs)
      (when convex-live--connected
        (convex-live--send-modifications (list (convex-live--remove-mod qid)))))))

;;; --- delivery queue ---

(defun convex-live--enqueue (kind qid payload logs)
  (let ((cost (+ (length payload) (length (or logs "")) 256)))
    (setq convex-live--events
          (append convex-live--events
                  (list (list :kind kind :qid qid :payload payload :logs logs
                              :gen (convex-live--generation qid) :cost cost))))
    (setq convex-live--event-bytes (+ convex-live--event-bytes cost))
    (while (or (> (length convex-live--events) convex-live--max-events)
               (> convex-live--event-bytes convex-live--max-bytes))
      (let ((dropped (pop convex-live--events)))
        (setq convex-live--event-bytes (- convex-live--event-bytes (plist-get dropped :cost)))))))

(defun convex-live-next-event ()
  "Pop the oldest still-current pending event, setting
`convex-live--event-payload'/`-logs'/`-queryid', and return its kind
(\"value\" or \"error\"); or return nil when the queue is empty. Silently
discards any event whose generation no longer matches its query's
current generation."
  (catch 'done
    (while convex-live--events
      (let* ((event (pop convex-live--events)))
        (setq convex-live--event-bytes (- convex-live--event-bytes (plist-get event :cost)))
        (when (= (plist-get event :gen) (convex-live--generation (plist-get event :qid)))
          (setq convex-live--event-payload (plist-get event :payload))
          (setq convex-live--event-logs (plist-get event :logs))
          (setq convex-live--event-queryid (plist-get event :qid))
          (throw 'done (plist-get event :kind)))))
    nil))

;;; --- receiving ---

(defun convex-live--retire (reason-info)
  "Tear down the current connection (if any) and, when subscriptions are
still active and the client is not closed, schedule a reconnect after an
exponentially growing backoff. Every still-active subscription gets a
TransportError or ProtocolError event."
  (let ((reason (if (stringp reason-info) reason-info (plist-get reason-info :name))))
    (when convex-live--connected (convex-ws--close))
    (setq convex-live--connected nil)
    (setq convex-live--connection-count (1+ convex-live--connection-count))
    (setq convex-live--last-close-reason reason)
    (unless (equal reason "DebugDisconnect")
      (maphash (lambda (qid sub)
                 (when (plist-get sub :active)
                   (let ((h (make-hash-table :test 'equal)))
                     (puthash "name" reason h)
                     (puthash "message" (concat "Live connection lost: " reason) h)
                     (convex-live--enqueue "error" qid (json-serialize h) "[]"))))
               convex-live--subs))
    (setq convex-live--query-set 0)
    (setq convex-live--remote (convex-live--zero-version))
    (unless (or convex-live--closed (<= convex-live--active-count 0))
      (setq convex-live--next-reconnect-at (+ (convex--now) convex-live--reconnect-delay))
      (setq convex-live--reconnect-delay
            (min (* convex-live--reconnect-delay 2) convex-live--reconnect-max)))
    nil))

(defun convex-live-debug-disconnect ()
  "The adapter-only forced-reconnect hook. Retires the current connection
with no backoff at all, so the very next pump reconnects immediately."
  (if (not convex-live--connected)
      (convex--fail "ProtocolError" "debugDisconnect: not connected")
    (convex-live--retire "DebugDisconnect")
    (setq convex-live--next-reconnect-at (1- (convex--now)))
    (setq convex-live--reconnect-delay convex-live--reconnect-min)
    t))

(defun convex-live-close ()
  "Stop reconnecting and drop the socket."
  (setq convex-live--closed t)
  (when convex-live--connected (convex-ws--close))
  (setq convex-live--connected nil))

(defun convex-live-pump (deadline)
  "The adapter's only entry point into Live. Connects or reconnects when
due, then makes one attempt to read and process a server message before
DEADLINE. Never signals: a transport problem retires the connection
(scheduling its own retry) and this simply returns."
  (cond
   (convex-live--closed nil)
   ((<= convex-live--active-count 0) nil)
   ((not convex-live--connected)
    (when (> (convex--now) convex-live--next-reconnect-at)
      (convex-live--connect-once (+ (convex--now) convex-live--connect-timeout))))
   (t
    (let ((message (convex-ws--try-read deadline)))
      (if message
          (convex-live--handle-message message)
        (unless (equal (plist-get convex--last-error :name) "again")
          (convex-live--retire convex--last-error)))))))

(defun convex-live--handle-message (raw)
  (let* ((decoded (condition-case nil (json-parse-string raw :object-type 'hash-table)
                     (error :bad)))
         (type (and (hash-table-p decoded) (gethash "type" decoded))))
    (cond
     ((eq decoded :bad) (convex-live--retire (convex--fail "ProtocolError" "malformed Live message")))
     ((member type '("Ping" "MutationResponse" "ActionResponse")) nil)
     ((member type '("FatalError" "AuthError"))
      (convex-live--retire (convex--fail "ProtocolError" (concat type " from Convex"))))
     ((equal type "Transition") (convex-live--apply-transition decoded))
     (t (convex-live--retire (convex--fail "ProtocolError" "unsupported Live message"))))))

(defun convex-live--apply-transition (decoded)
  (let ((start (convex-live--decode-version (gethash "startVersion" decoded)))
        (end (convex-live--decode-version (gethash "endVersion" decoded)))
        (mods (gethash "modifications" decoded)))
    (unless (convex-live--same-version start convex-live--remote)
      (cl-return-from convex-live--apply-transition
        (convex-live--retire (convex--fail "ProtocolError" "out-of-order Live transition"))))
    (condition-case nil
        (seq-doseq (mod mods) (convex-live--apply-one-modification mod))
      (error (cl-return-from convex-live--apply-transition
               (convex-live--retire (convex--fail "ProtocolError" "malformed Live modification")))))
    (let ((end-ts (convex-live--ts-value (plist-get end :ts))))
      (when (or (null convex-live--max-ts-value) (> end-ts convex-live--max-ts-value))
        (setq convex-live--max-ts-value end-ts)))
    (setq convex-live--remote end)))

(cl-defun convex-live--apply-one-modification (mod)
  (let* ((kind (gethash "type" mod))
         (qid (round (gethash "queryId" mod 0)))
         (sub (gethash qid convex-live--subs)))
    (when (or (equal kind "QueryRemoved") (not (and sub (plist-get sub :active))))
      (cl-return-from convex-live--apply-one-modification))
    (cond
     ((equal kind "QueryUpdated")
      (let* ((value (gethash "value" mod))
             (logs (or (gethash "logLines" mod) []))
             (payload (json-serialize value)))
        (unless (equal payload (plist-get sub :last))
          (puthash qid (plist-put (copy-sequence sub) :last payload) convex-live--subs)
          (convex-live--enqueue "value" qid payload (json-serialize logs)))))
     ((equal kind "QueryFailed")
      (let* ((h (make-hash-table :test 'equal))
             (data (gethash "errorData" mod)))
        (puthash "name" "FunctionError" h)
        (puthash "message" (gethash "errorMessage" mod) h)
        (when data (puthash "data" data h))
        (puthash qid (plist-put (copy-sequence sub) :last nil) convex-live--subs)
        (convex-live--enqueue "error" qid (json-serialize h)
                               (json-serialize (or (gethash "logLines" mod) [])))))
     (t (error "unsupported modification %s" kind)))))

(defun convex-ws--close ()
  "Best-effort close, then a hard close. Never fails: a peer that is
already gone still leaves the local process and its buffer released, so a
long run of reconnects cannot leak either one."
  (when convex-ws--process
    (let ((buffer (process-buffer convex-ws--process)))
      (when (process-live-p convex-ws--process)
        (ignore-errors
          (process-send-string convex-ws--process (convex-ws--frame-encode 8 "")))
        (ignore-errors (delete-process convex-ws--process)))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (setq convex-ws--process nil))

(provide 'convex)
