(in-package #:convex)

(defconstant +websocket-limit+ (* 2 1024 1024))

(defstruct websocket
  transport
  (buffer (make-array 0 :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0))
  fragment-opcode
  (fragment (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0))
  closed)

(defvar *websocket-before-handshake-write-hook* nil)

;; Deterministic tests use this to write a real frame prefix before failing or
;; pausing the remainder. Production always leaves it NIL.
(defvar *websocket-frame-write-hook* nil)

(define-condition websocket-idle-timeout (transport-timeout) ())

(defun handshake-remaining (deadline operation)
  (let ((remaining (- deadline (monotonic-seconds))))
    (when (<= remaining 0)
      (error 'transport-timeout :operation operation))
    remaining))

(defun append-octets (target source)
  (loop for byte across source do (vector-push-extend byte target))
  target)

(defun websocket-url (deployment)
  (make-url :scheme (if (string= (url-scheme deployment) "https") "wss" "ws")
            :host (url-host deployment)
            :port (url-port deployment)
            :path (format nil "~A/api/sync"
                          (string-right-trim "/" (url-path deployment)))))

(defun websocket-connect (deployment client-version &key (timeout 10.0))
  (require-safe-header-text client-version "WebSocket client version")
  (let* ((deadline (deadline-after timeout))
         (url (websocket-url deployment))
         (transport (open-transport
                     url :timeout (handshake-remaining deadline
                                                       "WebSocket transport")))
         (key (base64-encode (random-bytes 16)))
         (expected (base64-encode
                    (sha1 (string-octets
                           (concatenate 'string key
                                        "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))))
         (request
           (with-output-to-string (output)
             (format output "GET ~A HTTP/1.1~C~C" (url-path url) #\Return #\Newline)
             (format output "Host: ~A~C~C" (url-host-header url) #\Return #\Newline)
             (format output "Upgrade: websocket~C~C" #\Return #\Newline)
             (format output "Connection: Upgrade~C~C" #\Return #\Newline)
             (format output "Sec-WebSocket-Version: 13~C~C" #\Return #\Newline)
             (format output "Sec-WebSocket-Key: ~A~C~C" key #\Return #\Newline)
             (format output "Convex-Client: ~A~C~C~C~C"
                     client-version #\Return #\Newline #\Return #\Newline))))
    (handler-case
        (progn
          (when *websocket-before-handshake-write-hook*
            (handler-case
                (sb-ext:with-timeout
                    (handshake-remaining deadline "WebSocket handshake write")
                  (funcall *websocket-before-handshake-write-hook*))
              (sb-ext:timeout ()
                (error 'transport-timeout
                       :operation "WebSocket handshake write"))))
          (transport-write-all
           transport (string-octets request)
           :timeout (handshake-remaining deadline "WebSocket handshake write"))
          (let ((received (make-array 0 :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0))
                (header-end nil))
            (loop until (setf header-end (find-octets +header-end+ received))
                  do (when (> (length received) (* 64 1024))
                       (error "WebSocket handshake headers exceed 64 KiB"))
                     (let ((part
                             (transport-read-some
                              transport
                              :timeout
                              (handshake-remaining deadline
                                                   "WebSocket handshake read"))))
                       (unless part (error "EOF during WebSocket handshake"))
                       (append-octets received part)))
            (multiple-value-bind (status headers body-offset)
                (parse-http-headers received)
              (unless (= status 101)
                (error "WebSocket handshake returned HTTP ~D" status))
              (unless (and (search "websocket" (or (gethash "upgrade" headers) "")
                                   :test #'char-equal)
                           (search "upgrade" (or (gethash "connection" headers) "")
                                   :test #'char-equal))
                (error "WebSocket handshake omitted Upgrade headers"))
              (unless (string= expected (or (gethash "sec-websocket-accept" headers) ""))
                (error "WebSocket handshake accept hash did not match"))
              (let ((websocket (make-websocket :transport transport)))
                (append-octets (websocket-buffer websocket)
                               (subseq received body-offset))
                websocket))))
      (error (condition)
        (close-transport transport)
        (error condition)))))

(defun websocket-frame-bytes (opcode payload &key (final t) (masked t))
  (let* ((length (length payload))
         (extended (cond ((< length 126) 0) ((<= length #xffff) 2) (t 8)))
         (mask-length (if masked 4 0))
         (result (make-array (+ 2 extended mask-length length)
                             :element-type '(unsigned-byte 8)))
         (offset 2)
         (mask (and masked (random-bytes 4))))
    (setf (aref result 0) (logior (if final #x80 0) opcode))
    (cond
      ((zerop extended)
       (setf (aref result 1) (logior (if masked #x80 0) length)))
      ((= extended 2)
       (setf (aref result 1) (logior (if masked #x80 0) 126)
             (aref result 2) (ldb (byte 8 8) length)
             (aref result 3) (ldb (byte 8 0) length)
             offset 4))
      (t
       (setf (aref result 1) (logior (if masked #x80 0) 127))
       (dotimes (index 8)
         (setf (aref result (+ 2 index))
               (ldb (byte 8 (* 8 (- 7 index))) length)))
       (setf offset 10)))
    (when masked
      (replace result mask :start1 offset)
      (incf offset 4))
    (dotimes (index length)
      (setf (aref result (+ offset index))
            (if masked
                (logxor (aref payload index) (aref mask (mod index 4)))
                (aref payload index))))
    result))

(defun websocket-send-frame (websocket opcode payload &key (timeout 5.0) (final t))
  (when (websocket-closed websocket) (error "WebSocket is closed"))
  (let ((frame (websocket-frame-bytes opcode payload :final final)))
    (if *websocket-frame-write-hook*
        (funcall *websocket-frame-write-hook*
                 websocket opcode payload frame timeout)
        (transport-write-all (websocket-transport websocket) frame
                             :timeout timeout))))

(defun websocket-send-text (websocket text &key (timeout 5.0))
  (websocket-send-frame websocket 1 (string-octets text) :timeout timeout))

(defun websocket-take-frame (websocket)
  "Parse one complete frame, or return NIL while retaining every partial byte."
  (let ((buffer (websocket-buffer websocket)))
    (when (< (length buffer) 2) (return-from websocket-take-frame nil))
    (let* ((first (aref buffer 0))
           (second (aref buffer 1))
           (final (not (zerop (logand first #x80))))
           (reserved (logand first #x70))
           (opcode (logand first #x0f))
           (masked (not (zerop (logand second #x80))))
           (length-code (logand second #x7f))
           (offset 2)
           (length 0))
      (unless (zerop reserved) (error "WebSocket reserved bits are set"))
      (when masked (error "WebSocket server frame is unexpectedly masked"))
      (cond
        ((< length-code 126) (setf length length-code))
        ((= length-code 126)
         (when (< (length buffer) 4) (return-from websocket-take-frame nil))
         (setf length (logior (ash (aref buffer 2) 8) (aref buffer 3))
               offset 4)
         (when (< length 126) (error "Non-canonical WebSocket length")))
        (t
         (when (< (length buffer) 10) (return-from websocket-take-frame nil))
         (when (not (zerop (logand (aref buffer 2) #x80)))
           (error "WebSocket length exceeds signed 63-bit range"))
         (setf length 0)
         (dotimes (index 8)
           (setf length (+ (ash length 8) (aref buffer (+ 2 index)))))
         (setf offset 10)
         (when (<= length #xffff) (error "Non-canonical WebSocket length"))))
      (when (> length +websocket-limit+) (error "WebSocket frame exceeds 2 MiB"))
      (when (and (>= opcode 8) (or (not final) (> length 125)))
        (error "Invalid fragmented or oversized WebSocket control frame"))
      (when (< (length buffer) (+ offset length))
        (return-from websocket-take-frame nil))
      (let ((payload (subseq buffer offset (+ offset length))))
        (replace buffer buffer :start1 0 :start2 (+ offset length))
        (decf (fill-pointer buffer) (+ offset length))
        (list opcode final payload)))))

(defun websocket-complete-message (websocket frame)
  (destructuring-bind (opcode final payload) frame
    (case opcode
      (0
       (unless (websocket-fragment-opcode websocket)
         (error "Unexpected WebSocket continuation frame"))
       (append-octets (websocket-fragment websocket) payload)
       (when (> (length (websocket-fragment websocket)) +websocket-limit+)
         (error "Fragmented WebSocket message exceeds 2 MiB"))
       (when final
         (let ((complete-opcode (websocket-fragment-opcode websocket))
               (complete (copy-seq (websocket-fragment websocket))))
           (setf (websocket-fragment-opcode websocket) nil
                 (fill-pointer (websocket-fragment websocket)) 0)
           (list complete-opcode complete))))
      ((1 2)
       (when (websocket-fragment-opcode websocket)
         (error "New WebSocket data frame interrupted a fragmented message"))
       (if final
           (list opcode payload)
           (progn
             (setf (websocket-fragment-opcode websocket) opcode
                   (fill-pointer (websocket-fragment websocket)) 0)
             (append-octets (websocket-fragment websocket) payload)
             nil)))
      (8 (list 8 payload))
      (9 (list 9 payload))
      (10 (list 10 payload))
      (otherwise (error "Unknown WebSocket opcode ~D" opcode)))))

(defun websocket-receive (websocket &key (timeout 0.1))
  "Return text or :CLOSED. Only a clean frame-boundary timeout is idle."
  (loop
    (let ((frame (websocket-take-frame websocket)))
      (when frame
        (let ((message (websocket-complete-message websocket frame)))
          (when message
            (case (first message)
              (1
               (return
                 (handler-case (octets-string (second message))
                   (error () (error "Malformed UTF-8 in WebSocket text message")))))
              (2 (error "Binary WebSocket message is unsupported"))
              (8
               (unless (websocket-closed websocket)
                 (ignore-errors
                   (websocket-send-frame websocket 8 (second message) :timeout 0.25)))
               (setf (websocket-closed websocket) t)
               (return (list :closed (second message))))
              (9
               (websocket-send-frame websocket 10 (second message) :timeout 0.25)
               (return :control))
              (10 (return :control)))))))
    (let ((part
            (handler-case
                (transport-read-some (websocket-transport websocket)
                                     :timeout timeout)
              (transport-timeout (condition)
                ;; The owner may ignore a timeout only before any frame byte or
                ;; fragmented message has been consumed. A partial parser state
                ;; belongs to this connection and must be retired with it.
                (if (and (zerop (length (websocket-buffer websocket)))
                         (null (websocket-fragment-opcode websocket)))
                    (error 'websocket-idle-timeout
                           :operation (timeout-operation condition))
                    (error condition))))))
      (unless part
        (setf (websocket-closed websocket) t)
        (return (list :closed #())))
      (append-octets (websocket-buffer websocket) part))))

(defun websocket-close (websocket &key (reason "client closed"))
  (when (and websocket (not (websocket-closed websocket)))
    (let* ((reason-bytes (string-octets reason))
           (bounded (subseq reason-bytes 0 (min 123 (length reason-bytes))))
           (payload (concatenate-octets #(3 232) bounded)))
      (ignore-errors (websocket-send-frame websocket 8 payload :timeout 0.25))
      (setf (websocket-closed websocket) t)))
  (when websocket (close-transport (websocket-transport websocket)))
  t)

(defun timestamp-integer (timestamp)
  (let ((bytes (base64-decode timestamp)))
    (unless (= (length bytes) 8) (error "Timestamp must contain uint64 bytes"))
    (unless (string= timestamp (base64-encode bytes))
      (error "Timestamp base64 is not canonical"))
    ;; Convex protocol timestamps are canonical little-endian uint64 values.
    (loop for byte across bytes
          for shift from 0 by 8
          sum (ash byte shift))))

(defun canonical-timestamp-p (timestamp)
  (handler-case (progn (timestamp-integer timestamp) t) (error () nil)))

(defun timestamp-greater-p (left right)
  (> (timestamp-integer left) (timestamp-integer right)))
