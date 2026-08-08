Rebol [
    Title: "x509.r3 test -- proves the hardened TLS verifier fails closed"
    Purpose: {
        The fork's own prot-tls.reb does no chain-of-trust or hostname
        checking (proved separately during the feasibility spike: it
        connects to self-signed, expired, and wrong-hostname certificates
        without error). This test proves that client/x509.r3's own
        verify-chain layered on top actually rejects all three, while
        still accepting the real, currently-valid Convex production
        certificate chain -- against live hosts, not fixtures, so a
        result here reflects the real internet PKI at run time.
    }
]

do %../x509.r3

bundle: load-trust-bundle %../ca-bundle/
if 4 <> length? bundle [
    print ["FAIL: expected 4 bundled roots, got" length? bundle]
    quit/return 1
]

failures: 0

expect: func [label [string!] host [string!] expect-ok [logic!] /local r] [
    r: connect-verified-tls host 443 bundle
    ok?: r/ok = expect-ok
    print [
        either ok? ["PASS"] ["FAIL"]
        "--" label "--" either r/ok ["accepted"] ["rejected"]
        "(" r/reason ")"
    ]
    unless ok? [failures: failures + 1]
]

;; The real, currently-valid Convex production chain must be accepted.
expect "accepts the real Convex chain" "usable-reindeer-44.convex.cloud" true

;; A self-signed leaf must be rejected: no bundled anchor issued it.
expect "rejects a self-signed certificate" "self-signed.badssl.com" false

;; A certificate outside its validity window must be rejected, even
;; though its name matches and its issuing CA is a real, trustable CA.
expect "rejects an expired certificate" "expired.badssl.com" false

;; A certificate that is otherwise validly chained and currently valid,
;; but names a different host than the one connected to, must be
;; rejected on the hostname/SAN check.
expect "rejects a certificate for the wrong hostname" "wrong.host.badssl.com" false

either failures = 0 [
    print "ALL TESTS PASSED"
    quit/return 0
] [
    print [failures "TEST(S) FAILED"]
    quit/return 1
]
