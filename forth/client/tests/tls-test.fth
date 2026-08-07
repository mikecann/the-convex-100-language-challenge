\ tls-test.fth - proof that TLS verification is really on.
\
\ Certificate checking is the one thing a client can get wrong while every
\ happy-path test still passes, so it needs a peer rather than a fixture. The
\ Docker test stage starts a local TLS server with a private CA and runs this
\ file three times, once per mode:
\
\   trusted     the CA is trusted and the name matches, so the handshake and a
\               real request must both succeed
\   untrusted   a different CA is trusted, so the handshake must fail
\   wronghost   the CA is trusted but the name does not match the certificate,
\               so the handshake must still fail
\
\ Only the first would pass on a client that skipped verification, which is
\ exactly why the other two are here.

require test-support.fth

1024 buf-new constant line-buf

: tls-mode ( -- addr u )  s" TLS_MODE" getenv ;
: tls-port ( -- addr u )  s" 44300" ;

variable tls-stream

: tls-connect ( host-addr host-u -- )
    tls-port 1 cvx-connect-deadline deadline+ stream-open tls-stream ! ;

: probe-localhost ( -- )  s" localhost" tls-connect ;
: probe-address ( -- )  s" 127.0.0.1" tls-connect ;

: test-trusted ( -- )
    ['] probe-localhost s" a trusted certificate completes the handshake"
    succeeds
    tls-stream @ 0= if exit then
    s\" GET / HTTP/1.0\r\n\r\n" tls-stream @ 5000 deadline+ stream-write
    tls-stream @ 5000 deadline+ line-buf stream-line
    line-buf buf-span s" HTTP/1.0 200" str-prefix?
    s" the encrypted stream carries a real response" ok
    tls-stream @ stream-close ;

: test-untrusted ( -- )
    ['] probe-localhost s" an untrusted issuer is rejected" raises
    s" TransportError" s" a rejected certificate is a TransportError"
    raised-name ;

: test-wrong-host ( -- )
    ['] probe-address s" a certificate for another name is rejected" raises
    s" TransportError" s" a name mismatch is a TransportError" raised-name ;

tls-mode s" trusted" str= [if] test-trusted [then]
tls-mode s" untrusted" str= [if] test-untrusted [then]
tls-mode s" wronghost" str= [if] test-wrong-host [then]

checks-run @ 0= [if]
    s" TLS_MODE was not one of trusted, untrusted or wronghost" note-line
    1 convex-exit
[then]

s" tls-test" tests-done
0 convex-exit
