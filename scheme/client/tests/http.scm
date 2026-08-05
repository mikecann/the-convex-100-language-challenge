(load "/project/client/convex.scm")

(define (check expected actual label)
  (unless (equal? expected actual) (error label expected actual)))

(check '(("room" . "a") ("nested" ("count" . 1)))
       (json-read-string "{\"room\":\"a\",\"nested\":{\"count\":1}}")
       "JSON object decoding")
(check "{\"room\":\"a\",\"count\":1}"
       (json-write-string '(("room" . "a") ("count" . 1)))
       "JSON object encoding")
(unless (safe-token "opaque.token") (error "opaque bearer token rejected"))
(when (safe-token "bad\nvalue") (error "newline bearer token accepted"))
(display "scheme HTTP unit checks passed\n")
