(import scheme)
(import (chicken base))
(import (chicken condition))
(import (chicken io))
(import (chicken port))
(import (srfi 18))
(import openssl)

(define checks 0)
(define (check truth label)
  (set! checks (+ checks 1))
  (unless truth (error 'tls-test label)))

(define (ignore-errors thunk)
  (handle-exceptions _ (void) (thunk)))

(define certificate "/tmp/scheme-tls/server.crt")
(define private-key "/tmp/scheme-tls/server.key")

;; Keep every failure bounded. A hostname rejection ends the TLS handshake on
;; both sides, so cleanup must not wait for a cooperative close notification.
(ssl-handshake-timeout 2000)
(ssl-shutdown-timeout 500)

(define listener
  (ssl-listen* hostname: "127.0.0.1"
               port: 0
               certificate: certificate
               private-key: private-key
               verify?: #f))
(define port (ssl-listener-port listener))

;; Serve two real TLS connections. The first completes an HTTP-shaped exchange;
;; the second is expected to fail while the client verifies the peer name.
(define server
  (thread-start!
   (make-thread
    (lambda ()
      (let loop ((remaining 2))
        (when (> remaining 0)
          (call-with-values
            (lambda () (ssl-accept listener))
            (lambda (input output)
              (handle-exceptions _ (void)
                (let ((request-line (read-line input)))
                  (unless (eof-object? request-line)
                    (display "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"
                             output)
                    (flush-output output))))
              (ignore-errors (lambda () (close-output-port output)))
              (ignore-errors (lambda () (close-input-port input)))))
          (loop (- remaining 1))))
      (ssl-close listener))
    'tls-test-server)))

(define (exchange hostname)
  (call-with-values
    (lambda () (ssl-connect* hostname: hostname port: port))
    (lambda (input output)
      (display "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n" output)
      (flush-output output)
      (let ((status (read-line input)))
        (ignore-errors (lambda () (close-output-port output)))
        (ignore-errors (lambda () (close-input-port input)))
        status))))

(check (string=? (exchange "localhost") "HTTP/1.0 200 OK")
       "a trusted certificate for the requested hostname succeeds")

(define mismatch-rejected? #f)
(handle-exceptions _
  (set! mismatch-rejected? #t)
  (exchange "127.0.0.1"))
(check mismatch-rejected?
       "a trusted certificate for a different hostname is rejected")

(check (not (eq? (thread-join! server 4.0 'timed-out) 'timed-out))
       "the TLS fixture terminates within its bound")

(print "tls-test: " checks " checks")
