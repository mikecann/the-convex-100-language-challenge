(in-package #:convex)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(sb-alien:load-shared-object "libssl.so.3")
(sb-alien:load-shared-object "libcrypto.so.3")

(sb-alien:define-alien-routine ("recv" %c-recv) sb-alien:long
  (fd sb-alien:int) (buffer (* sb-alien:unsigned-char))
  (length sb-alien:unsigned-long) (flags sb-alien:int))
(sb-alien:define-alien-routine ("send" %c-send) sb-alien:long
  (fd sb-alien:int) (buffer (* sb-alien:unsigned-char))
  (length sb-alien:unsigned-long) (flags sb-alien:int))
(sb-alien:define-alien-routine ("read" %c-read) sb-alien:long
  (fd sb-alien:int) (buffer (* sb-alien:unsigned-char))
  (length sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("write" %c-write) sb-alien:long
  (fd sb-alien:int) (buffer (* sb-alien:unsigned-char))
  (length sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("fcntl" %c-fcntl) sb-alien:int
  (fd sb-alien:int) (command sb-alien:int) (argument sb-alien:int))

(sb-alien:define-alien-routine ("TLS_client_method" %tls-client-method) (* t))
(sb-alien:define-alien-routine ("SSL_CTX_new" %ssl-ctx-new) (* t)
  (method (* t)))
(sb-alien:define-alien-routine ("SSL_CTX_free" %ssl-ctx-free) sb-alien:void
  (context (* t)))
(sb-alien:define-alien-routine ("SSL_CTX_set_default_verify_paths"
                                %ssl-ctx-default-paths) sb-alien:int
  (context (* t)))
(sb-alien:define-alien-routine ("SSL_CTX_load_verify_locations"
                                %ssl-ctx-load-verify-locations) sb-alien:int
  (context (* t)) (file sb-alien:c-string) (directory sb-alien:c-string))
(sb-alien:define-alien-routine ("SSL_CTX_set_verify" %ssl-ctx-set-verify)
    sb-alien:void
  (context (* t)) (mode sb-alien:int) (callback (* t)))
(sb-alien:define-alien-routine ("SSL_new" %ssl-new) (* t) (context (* t)))
(sb-alien:define-alien-routine ("SSL_free" %ssl-free) sb-alien:void (ssl (* t)))
(sb-alien:define-alien-routine ("SSL_set_fd" %ssl-set-fd) sb-alien:int
  (ssl (* t)) (fd sb-alien:int))
(sb-alien:define-alien-routine ("SSL_ctrl" %ssl-ctrl) sb-alien:long
  (ssl (* t)) (command sb-alien:int) (larg sb-alien:long)
  (parg sb-alien:c-string))
(sb-alien:define-alien-routine ("SSL_connect" %ssl-connect) sb-alien:int
  (ssl (* t)))
(sb-alien:define-alien-routine ("SSL_get_error" %ssl-get-error) sb-alien:int
  (ssl (* t)) (result sb-alien:int))
(sb-alien:define-alien-routine ("SSL_read" %ssl-read) sb-alien:int
  (ssl (* t)) (buffer (* sb-alien:unsigned-char)) (length sb-alien:int))
(sb-alien:define-alien-routine ("SSL_write" %ssl-write) sb-alien:int
  (ssl (* t)) (buffer (* sb-alien:unsigned-char)) (length sb-alien:int))
(sb-alien:define-alien-routine ("SSL_pending" %ssl-pending) sb-alien:int
  (ssl (* t)))
(sb-alien:define-alien-routine ("SSL_shutdown" %ssl-shutdown) sb-alien:int
  (ssl (* t)))
(sb-alien:define-alien-routine ("SSL_get_verify_result" %ssl-verify-result)
    sb-alien:long (ssl (* t)))
(sb-alien:define-alien-routine ("SSL_get1_peer_certificate" %ssl-peer-cert)
    (* t) (ssl (* t)))
(sb-alien:define-alien-routine ("X509_check_host" %x509-check-host) sb-alien:int
  (certificate (* t)) (name sb-alien:c-string) (name-length sb-alien:unsigned-long)
  (flags sb-alien:unsigned-int) (peername (* t)))
(sb-alien:define-alien-routine ("X509_free" %x509-free) sb-alien:void
  (certificate (* t)))
(sb-alien:define-alien-routine ("ERR_get_error" %err-get-error)
    sb-alien:unsigned-long)
(sb-alien:define-alien-routine ("ERR_error_string_n" %err-string) sb-alien:void
  (code sb-alien:unsigned-long) (buffer (* sb-alien:char))
  (length sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("EVP_MD_CTX_new" %evp-md-ctx-new) (* t))
(sb-alien:define-alien-routine ("EVP_MD_CTX_free" %evp-md-ctx-free) sb-alien:void
  (context (* t)))
(sb-alien:define-alien-routine ("EVP_sha256" %evp-sha256) (* t))
(sb-alien:define-alien-routine ("EVP_DigestInit_ex" %evp-digest-init) sb-alien:int
  (context (* t)) (type (* t)) (engine (* t)))
(sb-alien:define-alien-routine ("EVP_DigestUpdate" %evp-digest-update) sb-alien:int
  (context (* t)) (data (* t)) (length sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("EVP_DigestFinal_ex" %evp-digest-final) sb-alien:int
  (context (* t)) (output (* sb-alien:unsigned-char))
  (length (* sb-alien:unsigned-int)))

(defconstant +ssl-error-want-read+ 2)
(defconstant +ssl-error-want-write+ 3)
(defconstant +ssl-error-zero-return+ 6)
(defconstant +ssl-verify-peer+ 1)
(defconstant +ssl-ctrl-set-tlsext-hostname+ 55)

(defun null-pointer ()
  (sb-alien:sap-alien (sb-sys:int-sap 0) (* t)))

(define-condition transport-timeout (error)
  ((operation :initarg :operation :reader timeout-operation))
  (:report (lambda (condition stream)
             (format stream "Timed out during ~A" (timeout-operation condition)))))

(define-condition transport-io-error (error)
  ((operation :initarg :operation :reader transport-io-operation)
   (detail :initarg :detail :reader transport-io-detail))
  (:report (lambda (condition stream)
             (format stream "~A: ~A"
                     (transport-io-operation condition)
                     (transport-io-detail condition)))))

(defstruct url
  scheme host port path)

(defun safe-header-text-p (text)
  (and (stringp text)
       (not (find-if (lambda (character)
                       (let ((code (char-code character)))
                         (or (< code 32) (= code 127))))
                     text))))

(defun require-safe-header-text (text description)
  (unless (safe-header-text-p text)
    (error "~A contains an HTTP control character" description))
  text)

(defun parse-url (text)
  (require-safe-header-text text "Convex URL")
  (let* ((separator (search "://" text))
         (scheme (and separator (string-downcase (subseq text 0 separator)))))
    (unless (member scheme '("http" "https" "ws" "wss") :test #'string=)
      (error "Convex URL must use http or https"))
    (let* ((authority-start (+ separator 3))
           (path-start (or (position #\/ text :start authority-start) (length text)))
           (authority (subseq text authority-start path-start))
           (path (if (< path-start (length text)) (subseq text path-start) "/")))
      (when (or (zerop (length authority)) (find #\@ authority))
        (error "Convex URL has an invalid authority"))
      (when (or (find #\? path) (find #\# path))
        (error "Convex URL must not contain a query or fragment"))
      (multiple-value-bind (host port)
          (if (and (> (length authority) 0) (char= (char authority 0) #\[))
              (let ((close (or (position #\] authority)
                               (error "Invalid IPv6 URL authority"))))
                (values (subseq authority 1 close)
                        (if (< (1+ close) (length authority))
                            (parse-integer authority :start (+ close 2))
                            (if (member scheme '("https" "wss") :test #'string=) 443 80))))
              (let ((colon (position #\: authority :from-end t)))
                (if colon
                    (values (subseq authority 0 colon)
                            (parse-integer authority :start (1+ colon)))
                    (values authority
                            (if (member scheme '("https" "wss") :test #'string=) 443 80)))))
        (unless (<= 1 port 65535) (error "Invalid URL port"))
        (make-url :scheme scheme :host host :port port :path path)))))

(defun url-tls-p (url)
  (member (url-scheme url) '("https" "wss") :test #'string=))

(defun url-host-header (url)
  (let ((default (if (url-tls-p url) 443 80))
        (host (if (find #\: (url-host url))
                  (format nil "[~A]" (url-host url))
                  (url-host url))))
    (if (= (url-port url) default)
        host
        (format nil "~A:~D" host (url-port url)))))

(defun monotonic-seconds ()
  (/ (get-internal-real-time) internal-time-units-per-second 1.0d0))

(defun deadline-after (seconds) (+ (monotonic-seconds) seconds))

(defun deadline-remaining (deadline operation)
  (let ((remaining (- deadline (monotonic-seconds))))
    (when (<= remaining 0)
      (error 'transport-timeout :operation operation))
    remaining))

(defvar *dns-resolver* #'sb-bsd-sockets:get-host-by-name)

(defun wait-fd (fd direction deadline operation)
  (let ((remaining (- deadline (monotonic-seconds))))
    (when (<= remaining 0) (error 'transport-timeout :operation operation))
    (unless (sb-sys:wait-until-fd-usable fd direction remaining)
      (error 'transport-timeout :operation operation))))

(defun openssl-error (prefix)
  (let ((code (%err-get-error)))
    (if (zerop code)
        prefix
        (let ((bytes (make-array 256 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
          (sb-sys:with-pinned-objects (bytes)
            (%err-string code
                         (sb-alien:sap-alien (sb-sys:vector-sap bytes)
                                             (* sb-alien:char))
                         (length bytes)))
          (let ((end (or (position 0 bytes) (length bytes))))
            (format nil "~A: ~A" prefix
                    (sb-ext:octets-to-string (subseq bytes 0 end)
                                             :external-format :utf-8)))))))

(defstruct transport
  socket fd ssl context closed)

(defun set-nonblocking (fd)
  (let ((flags (%c-fcntl fd 3 0)))
    (when (< flags 0) (error "fcntl(F_GETFL) failed"))
    (when (< (%c-fcntl fd 4 (logior flags #x800)) 0)
      (error "fcntl(F_SETFL) failed"))))

(defun connect-socket (host port deadline)
  (let* ((entry
           ;; Name service is part of the connection deadline too. Some libc
           ;; resolvers can otherwise block before the nonblocking socket even
           ;; exists.
           (handler-case
               (sb-ext:with-timeout (deadline-remaining deadline "DNS resolution")
                 (funcall *dns-resolver* host))
             (sb-ext:timeout ()
               (error 'transport-timeout :operation "DNS resolution"))))
         (addresses (sb-bsd-sockets:host-ent-addresses entry))
         (last-error nil))
    (dolist (address addresses)
      (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
        (handler-case
            (progn
              ;; Socket-connect itself is bounded independently of later I/O.
              (sb-ext:with-timeout (deadline-remaining deadline "TCP connect")
                (sb-bsd-sockets:socket-connect socket address port))
              (set-nonblocking (sb-bsd-sockets:socket-file-descriptor socket))
              (return-from connect-socket socket))
          (sb-ext:timeout ()
            (setf last-error
                  (make-condition 'transport-timeout :operation "TCP connect"))
            (ignore-errors (sb-bsd-sockets:socket-close socket)))
          (error (condition)
            (setf last-error condition)
            (ignore-errors (sb-bsd-sockets:socket-close socket))))))
    (if (typep last-error 'transport-timeout)
        (error last-error)
        (error "Connect to ~A:~D failed: ~A" host port last-error))))

(defun ssl-await (ssl result fd deadline operation)
  (let ((kind (%ssl-get-error ssl result)))
    (case kind
      (#.+ssl-error-want-read+ (wait-fd fd :input deadline operation) :again)
      (#.+ssl-error-want-write+ (wait-fd fd :output deadline operation) :again)
      (#.+ssl-error-zero-return+ :eof)
      (otherwise
       (error 'transport-io-error :operation operation
              :detail (openssl-error operation))))))

(defun open-transport (url &key (timeout 10.0))
  (let* ((deadline (deadline-after timeout))
         (socket (connect-socket (url-host url) (url-port url) deadline))
         (fd (sb-bsd-sockets:socket-file-descriptor socket)))
    (if (not (url-tls-p url))
        (make-transport :socket socket :fd fd)
        (let ((context (null-pointer))
              (ssl (null-pointer)))
          (handler-case
              (progn
                (setf context (%ssl-ctx-new (%tls-client-method)))
                (when (sb-alien:null-alien context)
                  (error "~A" (openssl-error "SSL_CTX_new failed")))
                (unless (= 1 (%ssl-ctx-load-verify-locations
                              context "/etc/ssl/certs/ca-certificates.crt" nil))
                  (error "~A" (openssl-error "Loading CA roots failed")))
                (%ssl-ctx-set-verify context +ssl-verify-peer+ (null-pointer))
                (setf ssl (%ssl-new context))
                (when (sb-alien:null-alien ssl)
                  (error "~A" (openssl-error "SSL_new failed")))
                (unless (= 1 (%ssl-set-fd ssl fd))
                  (error "SSL_set_fd failed"))
                (when (zerop (%ssl-ctrl ssl +ssl-ctrl-set-tlsext-hostname+
                                       0 (url-host url)))
                  (error "Setting TLS SNI failed"))
                (loop for result = (%ssl-connect ssl)
                      until (= result 1)
                      do (ssl-await ssl result fd deadline "TLS handshake"))
                (unless (zerop (%ssl-verify-result ssl))
                  (error "TLS certificate chain verification failed"))
                (let ((certificate (%ssl-peer-cert ssl)))
                  (when (sb-alien:null-alien certificate)
                    (error "TLS peer supplied no certificate"))
                  (unwind-protect
                       (unless (= 1 (%x509-check-host certificate (url-host url)
                                                      (length (url-host url)) 0
                                                      (null-pointer)))
                         (error "TLS certificate does not match ~A" (url-host url)))
                    (%x509-free certificate)))
                (make-transport :socket socket :fd fd :ssl ssl :context context))
            (error (condition)
              (unless (sb-alien:null-alien ssl) (%ssl-free ssl))
              (unless (sb-alien:null-alien context) (%ssl-ctx-free context))
              (ignore-errors (sb-bsd-sockets:socket-close socket))
              (error condition)))))))

(defun close-transport (transport)
  (when (and transport (not (transport-closed transport)))
    (setf (transport-closed transport) t)
    (when (transport-ssl transport)
      (ignore-errors (%ssl-shutdown (transport-ssl transport)))
      (%ssl-free (transport-ssl transport))
      (%ssl-ctx-free (transport-context transport))
      (setf (transport-ssl transport) nil
            (transport-context transport) nil))
    (ignore-errors (sb-bsd-sockets:socket-close (transport-socket transport)))))

(defun transport-write-all (transport bytes &key (timeout 5.0))
  (let ((offset 0)
        (deadline (deadline-after timeout))
        (fd (transport-fd transport)))
    (loop while (< offset (length bytes))
          do (let ((count 0))
               (sb-sys:with-pinned-objects (bytes)
                 (let ((pointer (sb-alien:sap-alien
                                 (sb-sys:sap+ (sb-sys:vector-sap bytes) offset)
                                 (* sb-alien:unsigned-char))))
                   (setf count
                         (if (transport-ssl transport)
                             (%ssl-write (transport-ssl transport) pointer
                                         (- (length bytes) offset))
                             (%c-send fd pointer (- (length bytes) offset) #x4000)))))
               (cond
                 ((plusp count) (incf offset count))
                 ((transport-ssl transport)
                  (let ((state (ssl-await (transport-ssl transport) count fd deadline
                                          "transport write")))
                    (when (eq state :eof)
                      (error 'transport-io-error :operation "transport write"
                             :detail "peer closed"))))
                 ((member (sb-alien:get-errno) '(4 11))
                  (wait-fd fd :output deadline "transport write"))
                 (t
                  (error 'transport-io-error :operation "transport write"
                         :detail
                         (format nil "send failed with errno ~D"
                                 (sb-alien:get-errno))))))))
  t)

(defun transport-read-some (transport &key (timeout 5.0) (maximum 16384))
  "Read at least one byte, returning NIL only for a clean peer EOF."
  (let ((deadline (deadline-after timeout))
        (fd (transport-fd transport))
        (bytes (make-array maximum :element-type '(unsigned-byte 8))))
    (loop
      (when (and (transport-ssl transport)
                 (zerop (%ssl-pending (transport-ssl transport))))
        (wait-fd fd :input deadline "transport read"))
      (unless (transport-ssl transport)
        (wait-fd fd :input deadline "transport read"))
      (let ((count 0))
        (sb-sys:with-pinned-objects (bytes)
          (let ((pointer (sb-alien:sap-alien (sb-sys:vector-sap bytes)
                                             (* sb-alien:unsigned-char))))
            (setf count
                  (if (transport-ssl transport)
                      (%ssl-read (transport-ssl transport) pointer maximum)
                      (%c-recv fd pointer maximum 0)))))
        (cond
          ((plusp count) (return (subseq bytes 0 count)))
          ((and (not (transport-ssl transport)) (zerop count)) (return nil))
          ((transport-ssl transport)
           (let ((state (ssl-await (transport-ssl transport) count fd deadline
                                   "transport read")))
             (when (eq state :eof) (return nil))))
          ((member (sb-alien:get-errno) '(4 11)))
          (t
           (error 'transport-io-error :operation "transport read"
                  :detail
                  (format nil "recv failed with errno ~D"
                          (sb-alien:get-errno)))))))))

(defun fd-read-some (fd &key timeout (maximum 16384))
  (let ((bytes (make-array maximum :element-type '(unsigned-byte 8))))
    (when timeout (wait-fd fd :input (deadline-after timeout) "adapter read"))
    (loop
      for count =
        (sb-sys:with-pinned-objects (bytes)
          (%c-read fd
                   (sb-alien:sap-alien (sb-sys:vector-sap bytes)
                                       (* sb-alien:unsigned-char))
                   maximum))
      do (cond
           ((plusp count) (return (subseq bytes 0 count)))
           ((zerop count) (return nil))
           ((= (sb-alien:get-errno) 4) nil)
           ((= (sb-alien:get-errno) 11)
            (wait-fd fd :input (deadline-after (or timeout 30.0)) "adapter read"))
           (t (error "adapter read failed with errno ~D" (sb-alien:get-errno)))))))

(defun fd-write-all (fd bytes &key (timeout 5.0))
  (let ((offset 0) (deadline (deadline-after timeout)))
    (loop while (< offset (length bytes))
          for count =
            (sb-sys:with-pinned-objects (bytes)
              (%c-write fd
                        (sb-alien:sap-alien
                         (sb-sys:sap+ (sb-sys:vector-sap bytes) offset)
                         (* sb-alien:unsigned-char))
                        (- (length bytes) offset)))
          do (cond
               ((plusp count) (incf offset count))
               ((member (sb-alien:get-errno) '(4 11))
                (wait-fd fd :output deadline "adapter write"))
               (t (error "adapter write failed with errno ~D"
                         (sb-alien:get-errno))))))
  t)

(defun string-octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun octets-string (bytes)
  (sb-ext:octets-to-string bytes :external-format :utf-8))

(defun concatenate-octets (&rest vectors)
  (let* ((length (reduce #'+ vectors :key #'length :initial-value 0))
         (result (make-array length :element-type '(unsigned-byte 8)))
         (offset 0))
    (dolist (vector vectors result)
      (replace result vector :start1 offset)
      (incf offset (length vector)))))

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode (bytes)
  (with-output-to-string (output)
    (loop for index from 0 below (length bytes) by 3
          for remaining = (- (length bytes) index)
          for first = (aref bytes index)
          for second = (if (> remaining 1) (aref bytes (1+ index)) 0)
          for third = (if (> remaining 2) (aref bytes (+ index 2)) 0)
          for value = (logior (ash first 16) (ash second 8) third)
          do (write-char (char +base64-alphabet+ (ldb (byte 6 18) value)) output)
             (write-char (char +base64-alphabet+ (ldb (byte 6 12) value)) output)
             (write-char (if (> remaining 1)
                             (char +base64-alphabet+ (ldb (byte 6 6) value)) #\=)
                         output)
             (write-char (if (> remaining 2)
                             (char +base64-alphabet+ (ldb (byte 6 0) value)) #\=)
                         output))))

(defun base64-decode (text)
  (unless (and (plusp (length text)) (zerop (mod (length text) 4)))
    (error "Invalid base64 length"))
  (let ((result (make-array (* 3 (/ (length text) 4))
                            :element-type '(unsigned-byte 8)
                            :fill-pointer 0)))
    (labels ((digit (character)
               (or (position character +base64-alphabet+)
                   (and (char= character #\=) 0)
                   (error "Invalid base64 character"))))
      (loop for index from 0 below (length text) by 4
            for a = (digit (char text index))
            for b = (digit (char text (+ index 1)))
            for c-char = (char text (+ index 2))
            for d-char = (char text (+ index 3))
            for c = (digit c-char)
            for d = (digit d-char)
            for value = (logior (ash a 18) (ash b 12) (ash c 6) d)
            do (vector-push (ldb (byte 8 16) value) result)
               (unless (char= c-char #\=)
                 (vector-push (ldb (byte 8 8) value) result))
               (unless (char= d-char #\=)
                 (vector-push (ldb (byte 8 0) value) result))))
    result))

(defun rol32 (value count)
  (ldb (byte 32 0)
       (logior (ash value count) (ash value (- count 32)))))

(defun sha1 (bytes)
  (let* ((bit-length (* 8 (length bytes)))
         (padding (mod (- 56 (1+ (length bytes))) 64))
         (message (make-array (+ (length bytes) 1 padding 8)
                              :element-type '(unsigned-byte 8)
                              :initial-element 0))
         (h0 #x67452301) (h1 #xEFCDAB89) (h2 #x98BADCFE)
         (h3 #x10325476) (h4 #xC3D2E1F0))
    (replace message bytes)
    (setf (aref message (length bytes)) #x80)
    (dotimes (index 8)
      (setf (aref message (- (length message) 1 index))
            (ldb (byte 8 (* index 8)) bit-length)))
    (loop for block from 0 below (length message) by 64
          do (let ((words (make-array 80 :element-type '(unsigned-byte 32))))
               (dotimes (index 16)
                 (let ((offset (+ block (* index 4))))
                   (setf (aref words index)
                         (logior (ash (aref message offset) 24)
                                 (ash (aref message (+ offset 1)) 16)
                                 (ash (aref message (+ offset 2)) 8)
                                 (aref message (+ offset 3))))))
               (loop for index from 16 below 80
                     do (setf (aref words index)
                              (rol32 (logxor (aref words (- index 3))
                                             (aref words (- index 8))
                                             (aref words (- index 14))
                                             (aref words (- index 16))) 1)))
               (let ((a h0) (b h1) (c h2) (d h3) (e h4))
                 (dotimes (index 80)
                   (multiple-value-bind (function constant)
                       (cond
                         ((< index 20)
                          (values (logior (logand b c) (logand (lognot b) d))
                                  #x5A827999))
                         ((< index 40) (values (logxor b c d) #x6ED9EBA1))
                         ((< index 60)
                          (values (logior (logand b c) (logand b d) (logand c d))
                                  #x8F1BBCDC))
                         (t (values (logxor b c d) #xCA62C1D6)))
                     (let ((temporary
                             (ldb (byte 32 0)
                                  (+ (rol32 a 5) function e constant
                                     (aref words index)))))
                       (setf e d d c c (rol32 b 30) b a a temporary))))
                 (setf h0 (ldb (byte 32 0) (+ h0 a))
                       h1 (ldb (byte 32 0) (+ h1 b))
                       h2 (ldb (byte 32 0) (+ h2 c))
                       h3 (ldb (byte 32 0) (+ h3 d))
                       h4 (ldb (byte 32 0) (+ h4 e))))))
    (let ((result (make-array 20 :element-type '(unsigned-byte 8))))
      (loop for word in (list h0 h1 h2 h3 h4)
            for offset from 0 by 4
            do (dotimes (index 4)
                 (setf (aref result (+ offset index))
                       (ldb (byte 8 (* 8 (- 3 index))) word))))
      result)))

(defun json-sha256 (value)
  "Hash canonical JSON incrementally, retaining only the 32-byte digest."
  (let ((context (%evp-md-ctx-new))
        (result (make-array 32 :element-type '(unsigned-byte 8)))
        (result-length (sb-alien:make-alien sb-alien:unsigned-int)))
    (when (sb-alien:null-alien context)
      (error "OpenSSL could not allocate a SHA-256 context"))
    (unwind-protect
         (progn
           (unless (= (%evp-digest-init context (%evp-sha256) (null-pointer)) 1)
             (error "OpenSSL could not initialize SHA-256"))
           (call-with-json-utf8-chunks
            value
            (lambda (chunk length)
              (sb-sys:with-pinned-objects (chunk)
                (unless (= (%evp-digest-update
                            context
                            (sb-alien:sap-alien (sb-sys:vector-sap chunk) (* t))
                            length)
                           1)
                  (error "OpenSSL SHA-256 update failed")))))
           (sb-sys:with-pinned-objects (result)
             (unless (= (%evp-digest-final
                         context
                         (sb-alien:sap-alien (sb-sys:vector-sap result)
                                             (* sb-alien:unsigned-char))
                         result-length)
                        1)
               (error "OpenSSL SHA-256 finalization failed")))
           (unless (= (sb-alien:deref result-length) 32)
             (error "OpenSSL returned an unexpected SHA-256 length"))
           result)
      (%evp-md-ctx-free context)
      (sb-alien:free-alien result-length))))

(defun random-bytes (count)
  (with-open-file (input "/dev/urandom" :element-type '(unsigned-byte 8))
    (let ((result (make-array count :element-type '(unsigned-byte 8))))
      (unless (= (read-sequence result input) count)
        (error "Could not read secure randomness"))
      result)))

(defun random-hex-id (&optional (bytes 8))
  (with-output-to-string (output)
    (loop for byte across (random-bytes bytes)
          do (format output "~2,'0x" byte))))
