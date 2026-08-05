(load "/project/client/load.lisp")
(load "/project/examples/basics/main.lisp")

(in-package #:convex)

(defun check-rejected-count (count description)
  (let ((rejected nil))
    (handler-case (example-count (json-object "count" count) description)
      (error () (setf rejected t)))
    (unless rejected (error "Example accepted ~A" description))))

(unless (= (example-count (json-object "count" 1.0) "integral decimal") 1)
  (error "Example rejected an integral decimal"))

(check-rejected-count 1/2 "fractional count")
(check-rejected-count "1" "quoted count")
(check-rejected-count (sb-kernel:make-single-float #x7f800000) "infinite count")
(check-rejected-count (sb-kernel:make-single-float #x7fc00000) "NaN count")
(check-rejected-count #x8000000000000000 "overflowing count")

(format t "PASS canonical example numeric decoding~%")
