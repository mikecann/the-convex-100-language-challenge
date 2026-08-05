(in-package #:convex)

;; Distinct sentinels preserve JSON false and null instead of conflating either
;; with Lisp NIL, which is also the natural representation of an empty array.
(defparameter +json-null+ (make-symbol "JSON-NULL"))
(defparameter +json-false+ (make-symbol "JSON-FALSE"))

(defun json-object (&rest pairs)
  "Build a string-keyed JSON object from alternating keys and values."
  (unless (evenp (length pairs))
    (error "JSON-OBJECT needs alternating keys and values"))
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key object) value))
    object))

(defun json-get (object key &optional default)
  (multiple-value-bind (value present) (gethash key object)
    (if present value default)))

(defun json-has-key-p (object key)
  (nth-value 1 (gethash key object)))

(defun %hex-digit (character)
  (or (digit-char-p character 16)
      (error "Invalid JSON hexadecimal digit ~S" character)))

(defconstant +json-depth-limit+ 128)
(defconstant +json-node-limit+ 8192)

(defun json-decode (text &key (max-depth +json-depth-limit+)
                              (max-nodes +json-node-limit+))
  "Decode one complete UTF-8 JSON text into ordinary Lisp values."
  (let ((index 0)
        (length (length text))
        (depth 0)
        (nodes 0))
    (labels ((peek () (and (< index length) (char text index)))
             (take ()
               (or (and (< index length) (prog1 (char text index) (incf index)))
                   (error "Unexpected end of JSON input")))
             (space ()
               (loop while (and (peek)
                                (member (peek)
                                        '(#\Space #\Tab #\Return #\Newline)))
                     do (incf index)))
             (literal (word value)
               (loop for expected across word
                     unless (char= (take) expected)
                       do (error "Invalid JSON literal"))
               value)
             (unicode-unit ()
               (let ((value 0))
                 (dotimes (ignored 4 value)
                   (declare (ignore ignored))
                   (setf value (+ (* value 16) (%hex-digit (take)))))))
             (string-value ()
               (unless (char= (take) #\") (error "Expected JSON string"))
               (with-output-to-string (output)
                 (loop
                   for character = (take)
                   do (cond
                        ((char= character #\") (return))
                        ((char= character #\\)
                         (let ((escape (take)))
                           (case escape
                             (#\" (write-char #\" output))
                             (#\\ (write-char #\\ output))
                             (#\/ (write-char #\/ output))
                             (#\b (write-char #\Backspace output))
                             (#\f (write-char #\Page output))
                             (#\n (write-char #\Newline output))
                             (#\r (write-char #\Return output))
                             (#\t (write-char #\Tab output))
                             (#\u
                              (let ((first (unicode-unit)))
                                (cond
                                  ((<= #xD800 first #xDBFF)
                                   (unless (and (char= (take) #\\)
                                                (char= (take) #\u))
                                     (error "High surrogate lacks a low surrogate"))
                                   (let ((second (unicode-unit)))
                                     (unless (<= #xDC00 second #xDFFF)
                                       (error "Invalid low surrogate"))
                                     (write-char
                                      (code-char
                                       (+ #x10000
                                          (ash (- first #xD800) 10)
                                          (- second #xDC00)))
                                      output)))
                                  ((<= #xDC00 first #xDFFF)
                                   (error "Unexpected low surrogate"))
                                  (t (write-char (code-char first) output)))))
                             (otherwise (error "Invalid JSON escape ~S" escape)))))
                        ((< (char-code character) 32)
                         (error "Unescaped control character in JSON string"))
                        (t (write-char character output))))))
             (number-value ()
               (let ((start index))
                 (when (char= (or (peek) #\Null) #\-) (incf index))
                 (cond
                   ((char= (or (peek) #\Null) #\0) (incf index))
                   ((and (peek) (digit-char-p (peek))
                         (not (char= (peek) #\0)))
                    (loop while (and (peek) (digit-char-p (peek))) do (incf index)))
                   (t (error "Invalid JSON number at index ~D near ~S"
                             index (subseq text start (min length (+ start 16))))))
                 (when (char= (or (peek) #\Null) #\.)
                   (incf index)
                   (unless (and (peek) (digit-char-p (peek)))
                     (error "Invalid JSON fraction"))
                   (loop while (and (peek) (digit-char-p (peek))) do (incf index)))
                 (when (find (or (peek) #\Null) "eE")
                   (incf index)
                   (when (find (or (peek) #\Null) "+-") (incf index))
                   (unless (and (peek) (digit-char-p (peek)))
                     (error "Invalid JSON exponent"))
                   (loop while (and (peek) (digit-char-p (peek))) do (incf index)))
                 (let* ((token (subseq text start index))
                        (*read-eval* nil)
                        (value (read-from-string token)))
                   (unless (realp value)
                     (error "Invalid JSON number token ~S" token))
                   value)))
             (array-value ()
               (take)
               (space)
               (when (char= (or (peek) #\Null) #\])
                 (take)
                 (return-from array-value '()))
               (loop with values = '()
                     do (push (value) values)
                        (space)
                        (case (take)
                          (#\, (space))
                          (#\] (return (nreverse values)))
                          (otherwise (error "Expected comma or ] in JSON array")))))
             (object-value ()
               (take)
               (space)
               (let ((object (make-hash-table :test #'equal)))
                 (when (char= (or (peek) #\Null) #\})
                   (take)
                   (return-from object-value object))
                 (loop
                   (unless (char= (or (peek) #\Null) #\")
                     (error "Expected JSON object key"))
                   (incf nodes)
                   (when (> nodes max-nodes)
                     (error "JSON exceeds the structural node limit"))
                   (let ((key (string-value)))
                     (space)
                     (unless (char= (take) #\:) (error "Expected colon"))
                     (space)
                     (setf (gethash key object) (value)))
                   (space)
                   (case (take)
                     (#\, (space))
                     (#\} (return object))
                     (otherwise (error "Expected comma or } in JSON object"))))))
             (value ()
               (space)
               (incf nodes)
               (when (> nodes max-nodes)
                 (error "JSON exceeds the structural node limit"))
               (case (or (peek) (error "Expected JSON value"))
                 (#\" (string-value))
                 (#\{
                  (when (>= depth max-depth)
                    (error "JSON exceeds the nesting depth limit"))
                  (incf depth)
                  (unwind-protect (object-value) (decf depth)))
                 (#\[
                  (when (>= depth max-depth)
                    (error "JSON exceeds the nesting depth limit"))
                  (incf depth)
                  (unwind-protect (array-value) (decf depth)))
                 (#\t (literal "true" t))
                 (#\f (literal "false" +json-false+))
                 (#\n (literal "null" +json-null+))
                 (otherwise (number-value)))))
      (let ((decoded (value)))
        (space)
        (unless (= index length)
          (error "Trailing data after JSON value"))
        decoded))))

(defun %write-json-string (value stream)
  (write-char #\" stream)
  (loop for character across value
        for code = (char-code character)
        do (case character
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Backspace (write-string "\\b" stream))
             (#\Page (write-string "\\f" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Return (write-string "\\r" stream))
             (#\Tab (write-string "\\t" stream))
             (otherwise
              (if (< code 32)
                  (format stream "\\u~4,'0X" code)
                  (write-char character stream)))))
  (write-char #\" stream))

(defun %write-json (value stream)
  (cond
    ((eq value +json-null+) (write-string "null" stream))
    ((eq value +json-false+) (write-string "false" stream))
    ((eq value t) (write-string "true" stream))
    ((stringp value) (%write-json-string value stream))
    ((integerp value) (princ value stream))
    ((floatp value)
     (when (or (sb-ext:float-nan-p value)
               (sb-ext:float-infinity-p value))
       (error "Non-finite floats are not JSON numbers"))
     ;; Convex accepts decimal JSON. Lisp's default float printer may use D
     ;; exponents, so normalize them to JSON's E spelling.
     (let ((rendered (write-to-string value :readably t :base 10)))
       (write-string (substitute #\e #\d (substitute #\e #\D rendered)) stream)))
    ((rationalp value)
     ;; Integers were handled above. A ratio would print as 1/2, which is Lisp
     ;; syntax rather than JSON and must never reach the wire.
     (error "Ratios are not JSON numbers: ~S" value))
    ((hash-table-p value)
     (write-char #\{ stream)
     (let ((first t)
           (keys (sort (loop for key being the hash-keys of value collect key)
                       #'string<)))
       (dolist (key keys)
         (unless first (write-char #\, stream))
         (setf first nil)
         (%write-json-string key stream)
         (write-char #\: stream)
         (%write-json (gethash key value) stream)))
     (write-char #\} stream))
    ((or (listp value) (vectorp value))
     (write-char #\[ stream)
     (loop with first = t
           for item across (coerce value 'vector)
           do (unless first (write-char #\, stream))
              (setf first nil)
              (%write-json item stream))
     (write-char #\] stream))
    (t (error "Cannot encode ~S as JSON" value))))

(defun json-encode (value)
  (with-output-to-string (output)
    (%write-json value output)))

(defun call-with-json-utf8-chunks (value consumer)
  "Emit canonical JSON as bounded UTF-8 chunks without a full Lisp string."
  (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8)))
        (used 0))
    (labels
        ((flush ()
           (when (plusp used)
             (funcall consumer buffer used)
             (setf used 0)))
         (emit-byte (value)
           (when (= used (length buffer)) (flush))
           (setf (aref buffer used) value)
           (incf used))
         (ascii (text)
           (loop for character across text do (emit-byte (char-code character))))
         (utf8-character (character)
           (let ((code (char-code character)))
             (cond
               ((<= code #x7f) (emit-byte code))
               ((<= code #x7ff)
                (emit-byte (logior #xc0 (ash code -6)))
                (emit-byte (logior #x80 (logand code #x3f))))
               ((<= code #xffff)
                (emit-byte (logior #xe0 (ash code -12)))
                (emit-byte (logior #x80 (logand (ash code -6) #x3f)))
                (emit-byte (logior #x80 (logand code #x3f))))
               (t
                (emit-byte (logior #xf0 (ash code -18)))
                (emit-byte (logior #x80 (logand (ash code -12) #x3f)))
                (emit-byte (logior #x80 (logand (ash code -6) #x3f)))
                (emit-byte (logior #x80 (logand code #x3f)))))))
         (json-string (text)
           (emit-byte (char-code #\"))
           (loop for character across text
                 for code = (char-code character)
                 do (case character
                      (#\" (ascii "\\\""))
                      (#\\ (ascii "\\\\"))
                      (#\Backspace (ascii "\\b"))
                      (#\Page (ascii "\\f"))
                      (#\Newline (ascii "\\n"))
                      (#\Return (ascii "\\r"))
                      (#\Tab (ascii "\\t"))
                      (otherwise
                       (if (< code 32)
                           (progn
                             (ascii "\\u")
                             (dotimes (position 4)
                               (emit-byte
                                (char-code
                                 (char "0123456789ABCDEF"
                                       (ldb (byte 4 (* 4 (- 3 position))) code))))))
                           (utf8-character character)))))
           (emit-byte (char-code #\")))
         (write-value (item)
           (cond
             ((eq item +json-null+) (ascii "null"))
             ((eq item +json-false+) (ascii "false"))
             ((eq item t) (ascii "true"))
             ((stringp item) (json-string item))
             ((integerp item) (ascii (write-to-string item :base 10)))
             ((floatp item)
              (when (or (sb-ext:float-nan-p item)
                        (sb-ext:float-infinity-p item))
                (error "Non-finite floats are not JSON numbers"))
              (ascii (substitute
                      #\e #\d
                      (substitute #\e #\D
                                  (write-to-string item :readably t :base 10)))))
             ((rationalp item) (error "Ratios are not JSON numbers: ~S" item))
             ((hash-table-p item)
              (emit-byte (char-code #\{))
              (loop with first = t
                    for key in (sort
                                (loop for key being the hash-keys of item collect key)
                                #'string<)
                    do (unless first (emit-byte (char-code #\,)))
                       (setf first nil)
                       (json-string key)
                       (emit-byte (char-code #\:))
                       (write-value (gethash key item)))
              (emit-byte (char-code #\})))
             ((listp item)
              (emit-byte (char-code #\[))
              (loop for child in item
                    for first = t then nil
                    do (unless first (emit-byte (char-code #\,)))
                       (write-value child))
              (emit-byte (char-code #\])))
             ((vectorp item)
              (emit-byte (char-code #\[))
              (loop for child across item
                    for first = t then nil
                    do (unless first (emit-byte (char-code #\,)))
                       (write-value child))
              (emit-byte (char-code #\])))
             (t (error "Cannot encode ~S as JSON" item)))))
      (write-value value)
      (flush))))

(defun json-encode-octets (value &key newline)
  (let* ((encoded-length (json-encoded-byte-length value))
         (result (make-array (+ encoded-length (if newline 1 0))
                             :element-type '(unsigned-byte 8)))
         (offset 0))
    (call-with-json-utf8-chunks
     value
     (lambda (chunk length)
       (replace result chunk :start1 offset :end2 length)
       (incf offset length)))
    (when newline (setf (aref result encoded-length) 10))
    result))

(defun json-string-encoded-byte-length (value)
  (+ 2
     (loop for character across value
           for code = (char-code character)
           sum (case character
                 ((#\" #\\ #\Backspace #\Page #\Newline #\Return #\Tab) 2)
                 (otherwise
                  (cond ((< code 32) 6)
                        ((<= code #x7f) 1)
                        ((<= code #x7ff) 2)
                        ((<= code #xffff) 3)
                        (t 4)))))))

(defun json-encoded-byte-length (value)
  "Return JSON's exact UTF-8 byte length without materializing the JSON text."
  (cond
    ((eq value +json-null+) 4)
    ((eq value +json-false+) 5)
    ((eq value t) 4)
    ((stringp value) (json-string-encoded-byte-length value))
    ((integerp value) (length (write-to-string value :base 10)))
    ((floatp value)
     (when (or (sb-ext:float-nan-p value)
               (sb-ext:float-infinity-p value))
       (error "Non-finite floats are not JSON numbers"))
     (length (write-to-string value :readably t :base 10)))
    ((rationalp value) (error "Ratios are not JSON numbers: ~S" value))
    ((hash-table-p value)
     (+ 2
        (loop with first = t
              for key being the hash-keys of value
              sum (+ (if (prog1 first (setf first nil)) 0 1)
                     (json-string-encoded-byte-length key) 1
                     (json-encoded-byte-length (gethash key value))))))
    ((listp value)
     (+ 2
        (loop for item in value
              for first = t then nil
              sum (+ (if first 0 1) (json-encoded-byte-length item)))))
    ((vectorp value)
     (+ 2
        (loop for item across value
              for first = t then nil
              sum (+ (if first 0 1) (json-encoded-byte-length item)))))
    (t (error "Cannot encode ~S as JSON" value))))

(defun json-runtime-overhead (value)
  "Conservatively charge decoded Common Lisp structure beyond wire bytes.

The constants intentionally exceed SBCL's current headers, cons cells, hash
table control vectors and slots. Strings are charged here as objects while the
four-times-wire term pays for their character storage and encoded copy."
  (cond
    ((hash-table-p value)
     (+ 512
        (* 128 (hash-table-count value))
        (loop for key being the hash-keys of value
                using (hash-value child)
              sum (+ 64 (json-runtime-overhead key)
                     (json-runtime-overhead child)))))
    ((listp value)
     (+ 64
        (* 64 (length value))
        (loop for child in value sum (json-runtime-overhead child))))
    ((vectorp value)
     (+ 128
        (* 32 (length value))
        (loop for child across value sum (json-runtime-overhead child))))
    ((stringp value) 64)
    (t 32)))
