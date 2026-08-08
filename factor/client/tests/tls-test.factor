! TLS closure test.
!
! A runtime image can carry the client and still fail its first HTTPS call
! because a provider module, an OpenSSL configuration file, or the CA bundle
! is missing. This test runs a real TLS listener and drives the real client
! through a verified handshake, so the closure is proved inside the image
! rather than discovered during hosted verification.

USING: accessors continuations destructors io.encodings.binary
io.files io.files.info io.sockets io.sockets.secure kernel locals
math math.parser namespaces sequences threads convex convex.json
convex.transport convex.tests.support ;
IN: convex.tests.tls

CONSTANT: server-pem "/tmp/factor-tls/server.pem"

: tls-server-config ( -- config )
    <secure-config>
        server-pem >>key-file
        f >>verify ;

! The listener is secure, so accepting a connection performs a real
! handshake with the certificate the build stage generated.
:: start-tls-fixture ( response -- port )
    "127.0.0.1" 0 <inet4> "localhost" <secure> :> addr
    tls-server-config :> config
    f :> port!
    config [
        addr binary <server> :> server
        server addr>> port>> port!
        [
            [
                config [
                    server accept drop :> stream
                    stream read-request drop drop
                    stream response write-text
                    stream dispose
                ] with-secure-context
            ] [ drop ] recover
        ] "convex-tls-fixture" spawn drop
    ] with-secure-context
    port ;

:: success-envelope ( value -- text )
    { "{\"status\":\"success\",\"value\":" } value suffix
    ",\"logLines\":[]}" suffix concat ;

! The CA bundle has to exist and be non-empty, because verification is on and
! a missing bundle would otherwise look like a certificate failure.
: test-ca-bundle-present ( -- )
    ca-bundle-path file-exists? t "CA bundle exists" check-equal
    ca-bundle-path file-info size>> 0 > t "CA bundle is non-empty"
    check-equal ;

:: test-verified-https-call ( -- )
    200 "application/json" "{\"count\":4}" success-envelope
    http-fixture-response start-tls-fixture :> port
    "https://localhost:" port number>string append <convex-client>
    "demo:state" "{\"room\":\"r\"}" client-query result-value
    "{\"count\":4}" "verified TLS round trip" check-equal ;

! Verification must actually be enforced. Connecting by an address the
! certificate does not cover has to fail rather than silently succeed.
:: test-verification-is-enforced ( -- )
    200 "application/json" "null" success-envelope
    http-fixture-response start-tls-fixture :> port
    [
        "https://127.0.0.1:" port number>string append <convex-client>
        "demo:state" "{\"room\":\"r\"}" client-query drop
    ] "certificate name mismatch is refused" check-raises ;

: run-tls-tests ( -- )
    "tls/ca-bundle-present" [ test-ca-bundle-present ] run-test
    "tls/verified-https-call" [ test-verified-https-call ] run-test
    "tls/verification-is-enforced" [ test-verification-is-enforced ] run-test
    finish-tests ;

MAIN: run-tls-tests
