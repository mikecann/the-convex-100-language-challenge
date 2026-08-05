(load "/project/client/load.lisp")

(in-package #:convex)

(defun check (condition message)
  (unless condition (error "JSON test failed: ~A" message)))

(let* ((source "{\"array\":[true,false,null,-12,1.25e2],\"text\":\"snowman ☃ and 🟨\"}")
       (decoded (json-decode source))
       (round-trip (json-decode (json-encode decoded))))
  (check (string= (json-get round-trip "text") "snowman ☃ and 🟨")
         "Unicode round trip")
  (check (= (fourth (json-get round-trip "array")) -12) "integer round trip")
  (check (= (fifth (json-get round-trip "array")) 125) "exponent decode")
  (check (eq (second (json-get round-trip "array")) +json-false+)
         "false sentinel")
  (check (eq (third (json-get round-trip "array")) +json-null+)
         "null sentinel"))

(let ((rejected nil))
  (handler-case (json-decode "{\"bad\":1} trailing")
    (error () (setf rejected t)))
  (check rejected "malformed JSON rejection"))

(check (string= (base64-encode (string-octets "hello")) "aGVsbG8=")
       "base64 encoding")
(check (string= (octets-string (base64-decode "aGVsbG8=")) "hello")
       "base64 decoding")
(check (string= (base64-encode (sha1 (string-octets "abc")))
                "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
       "SHA-1")
(check (string-equal
        (with-output-to-string (output)
          (loop for byte across (json-sha256 "abc")
                do (format output "~2,'0x" byte)))
        "6cc43f858fbb763301637b5af970e2a46b46f461f27e5a0f41e009c59b827b25")
       "streaming canonical JSON SHA-256")

(dolist (invalid (list 1/2
                       (sb-kernel:make-single-float #x7f800000)
                       (sb-kernel:make-single-float #x7fc00000)))
  (let ((rejected nil))
    (handler-case (json-encode invalid)
      (error () (setf rejected t)))
    (check rejected "invalid JSON number rejection")))

;; Queue accounting counts bytes without allocating a second complete JSON
;; string. Keep it exactly aligned with the real encoder across every spelling
;; that changes UTF-8 or escape length.
(let ((values
        (list "ascii"
              "snowman ☃ and 🟨"
              (format nil "quote \" slash \\ controls ~C~C~C" #\Newline #\Tab
                      (code-char 1))
              (json-object
               "nested" (list (json-object "truth" t "false" +json-false+)
                              +json-null+ -123456789 1.25d2)
               "array" #(1 2 3)))))
  (dolist (value values)
    (check (= (json-encoded-byte-length value)
              (length (string-octets (json-encode value))))
           "allocation-light JSON byte count parity")
    (check (string= (octets-string (json-encode-octets value))
                    (json-encode value))
           "allocation-light UTF-8 encoder parity")))

(dolist (too-structured
          (list
           (concatenate 'string (make-string 129 :initial-element #\[)
                        "0" (make-string 129 :initial-element #\]))
           (concatenate 'string "["
                        (with-output-to-string (output)
                          (dotimes (index 8200)
                            (unless (zerop index) (write-char #\, output))
                            (write-string "{}" output)))
                        "]")))
  (let ((rejected nil))
    (handler-case (json-decode too-structured)
      (error () (setf rejected t)))
    (check rejected "JSON structural bound")))

(format t "PASS JSON, base64, and SHA-1~%")
