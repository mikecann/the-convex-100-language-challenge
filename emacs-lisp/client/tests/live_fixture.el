;;; live_fixture.el --- Deterministic loopback peer for the Live test suite.
;;
;; A real TCP server, in the same process as the client under test. This
;; works (unlike stdio, see adapter.el's own header comment) because sockets
;; are ordinary Emacs processes: accept-process-output already multiplexes
;; every process's filter, including this fixture's listener and the
;; client's own WebSocket connection, from whichever call site happens to
;; invoke it. Nothing here is asynchronous relative to the test script: each
;; step blocks (via a bounded accept-process-output loop) until the exact
;; bytes it is waiting for have arrived, so the sequence in live_test.el and
;; the sequence here must match step for step.

(require 'cl-lib)
(require 'json)

(defvar fixture--listener nil)
(defvar fixture--accepted nil)
(defvar fixture--buffer "")

(defun fixture--filter (_proc chunk)
  (setq fixture--buffer (concat fixture--buffer chunk)))

(defun fixture-listen (port)
  (setq fixture--accepted nil)
  (setq fixture--listener
        (make-network-process
         :name "fixture-listener" :service port :host "127.0.0.1" :server t
         :family 'ipv4 :coding 'binary
         :log (lambda (_server client _msg)
                (set-process-coding-system client 'binary 'binary)
                (setq fixture--buffer "")
                (set-process-filter client #'fixture--filter)
                (setq fixture--accepted client))))
  ;; accept-process-output does not reliably drive a *listening* process's
  ;; own :log callback (see adapter.el); sleep-for does.
  (let ((deadline (+ (float-time) 15)))
    (while (and (not fixture--accepted) (< (float-time) deadline))
      (sleep-for 0.05)))
  (unless fixture--accepted (error "fixture: no connection within deadline"))
  fixture--accepted)

(defun fixture--wait-for (predicate timeout-seconds)
  (let ((deadline (+ (float-time) timeout-seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline)
                (process-live-p fixture--accepted))
      (accept-process-output fixture--accepted 0.05))
    (funcall predicate)))

(defun fixture-read-http-request ()
  "Block until a full HTTP request (headers, then any declared body) has
arrived, then consume and return the parsed (METHOD PATH HEADERS BODY)."
  (unless (fixture--wait-for
           (lambda () (string-match "\r\n\r\n" fixture--buffer)) 15)
    (error "fixture: no HTTP request within deadline"))
  (let* ((header-end (match-end 0))
         (headers-text (substring fixture--buffer 0 header-end))
         (lines (split-string headers-text "\r\n" t))
         (request-line (split-string (car lines) " "))
         (headers (make-hash-table :test 'equal))
         (content-length 0))
    (dolist (line (cdr lines))
      (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
        (let ((name (downcase (match-string 1 line))) (value (match-string 2 line)))
          (puthash name value headers)
          (when (string= name "content-length")
            (setq content-length (string-to-number value))))))
    (unless (fixture--wait-for
             (lambda () (>= (length fixture--buffer) (+ header-end content-length)))
             15)
      (error "fixture: HTTP body did not fully arrive"))
    (let ((body (substring fixture--buffer header-end (+ header-end content-length))))
      (setq fixture--buffer (substring fixture--buffer (+ header-end content-length)))
      (list (nth 0 request-line) (nth 1 request-line) headers body))))

(defun fixture-respond-http (status body)
  (let ((response (concat "HTTP/1.1 " status "\r\n"
                           "Content-Type: application/json\r\n"
                           "Content-Length: " (number-to-string (length body)) "\r\n"
                           "Connection: close\r\n\r\n" body)))
    (process-send-string fixture--accepted response)))

(defun fixture-ws-accept-upgrade (headers)
  (let* ((key (gethash "sec-websocket-key" headers))
         (accept (base64-encode-string
                  (secure-hash 'sha1 (concat key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                               nil nil t)
                  t))
         (response (concat "HTTP/1.1 101 Switching Protocols\r\n"
                            "Upgrade: websocket\r\n"
                            "Connection: Upgrade\r\n"
                            "Sec-WebSocket-Accept: " accept "\r\n\r\n")))
    (process-send-string fixture--accepted response)))

(defun fixture-ws-send (payload)
  "Send PAYLOAD (a unibyte string) as one unmasked text frame. Server
frames must never be masked (RFC 6455)."
  (let* ((bytes (encode-coding-string payload 'utf-8))
         (length (length bytes))
         (header (cond
                  ((<= length 125) (unibyte-string 129 length))
                  ((<= length 65535)
                   (concat (unibyte-string 129 126)
                           (unibyte-string (logand (ash length -8) 255) (logand length 255))))
                  (t (error "fixture: frame too large")))))
    (process-send-string fixture--accepted (concat header bytes))))

(defun fixture-ws-read ()
  "Block until one complete client->server frame has arrived, unmask it,
and return its payload as a UTF-8 string. Client frames must be masked."
  (unless (fixture--wait-for (lambda () (>= (length fixture--buffer) 2)) 15)
    (error "fixture: no WS frame header within deadline"))
  (let* ((second (aref fixture--buffer 1))
         (lengthbyte (logand second 127)))
    (cond
     ((< lengthbyte 126)
      (fixture--ws-read-body 2 lengthbyte))
     ((= lengthbyte 126)
      (unless (fixture--wait-for (lambda () (>= (length fixture--buffer) 4)) 15)
        (error "fixture: no extended WS length within deadline"))
      (let ((length (logior (ash (aref fixture--buffer 2) 8) (aref fixture--buffer 3))))
        (fixture--ws-read-body 4 length)))
     (t (error "fixture: 64-bit WS lengths are not used by this protocol")))))

(defun fixture--ws-read-body (offset length)
  (unless (fixture--wait-for
           (lambda () (>= (length fixture--buffer) (+ offset 4 length))) 15)
    (error "fixture: WS payload did not fully arrive"))
  (let* ((mask (substring fixture--buffer offset (+ offset 4)))
         (masked (substring fixture--buffer (+ offset 4) (+ offset 4 length)))
         (out (make-string length 0)))
    (dotimes (i length)
      (aset out i (logxor (aref masked i) (aref mask (mod i 4)))))
    (setq fixture--buffer (substring fixture--buffer (+ offset 4 length)))
    (decode-coding-string out 'utf-8)))

(defun fixture-timestamp-base64 (byte-value)
  "The 8-byte big-endian Convex timestamp encoding of a single small
integer BYTE-VALUE, base64 encoded - enough distinct values for every
scripted step in live_test.el without needing a real monotonic counter."
  (base64-encode-string
   (unibyte-string 0 0 0 0 0 0 0 byte-value) t))

(defun fixture-version-json (query-set identity ts-byte)
  (format "{\"querySet\":%d,\"identity\":%d,\"ts\":\"%s\"}"
          query-set identity (fixture-timestamp-base64 ts-byte)))

(defun fixture-send-transition (start-json end-json modifications-json)
  (fixture-ws-send
   (format "{\"type\":\"Transition\",\"startVersion\":%s,\"endVersion\":%s,\"modifications\":%s}"
           start-json end-json modifications-json)))

(defun fixture-close ()
  (when (process-live-p fixture--accepted) (delete-process fixture--accepted))
  (when (process-live-p fixture--listener) (delete-process fixture--listener))
  (setq fixture--accepted nil fixture--listener nil fixture--buffer ""))

(defun fixture-reaccept (port)
  "Accept the next connection on the same listener, replacing the
previous one. Used for reconnect scenarios: the old socket is not
touched here (the client owns closing its own side)."
  (setq fixture--accepted nil)
  (setq fixture--buffer "")
  (let ((deadline (+ (float-time) 15)))
    (while (and (not fixture--accepted) (< (float-time) deadline))
      (sleep-for 0.05)))
  (unless fixture--accepted (error "fixture: no reconnect within deadline"))
  (ignore port)
  fixture--accepted)

(provide 'live_fixture)
