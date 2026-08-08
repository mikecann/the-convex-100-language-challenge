! Regressions for the canonical example's own decoding.
!
! These exercise the exact source file the README and website display. There
! is deliberately no second, test-only copy of the example, and nothing here
! contacts a deployment.

USING: kernel locals math sequences convex.example
convex.tests.support ;
IN: convex.example.tests

! Convex may spell an integral count as 0.0, so the example has to accept
! that while still refusing a real fraction or a quoted number.
: test-integral-decimals ( -- )
    "{\"count\":0}" "q" example-count 0 "integer count" check-equal
    "{\"count\":0.0}" "q" example-count 0 "integral decimal zero"
    check-equal
    "{\"count\":1.0}" "q" example-count 1 "integral decimal one" check-equal
    "{\"count\":10.000}" "q" example-count 10 "integral decimal ten"
    check-equal ;

: test-rejected-counts ( -- )
    [ "{\"count\":1.5}" "q" example-count drop ] "fractional count"
    check-raises
    [ "{\"count\":\"1\"}" "q" example-count drop ] "quoted count"
    check-raises
    [ "{\"count\":null}" "q" example-count drop ] "null count" check-raises
    [ "{\"count\":true}" "q" example-count drop ] "boolean count"
    check-raises
    [ "{\"count\":-1}" "q" example-count drop ] "negative count"
    check-raises
    [ "{\"count\":1e3}" "q" example-count drop ] "exponent count"
    check-raises
    [ "{\"count\":9223372036854775808}" "q" example-count drop ]
    "overflowing count" check-raises
    [ "{\"other\":1}" "q" example-count drop ] "missing count" check-raises
    [ f "q" example-count drop ] "absent value" check-raises ;

! The idempotency key must be fresh on every run, or a retried example would
! silently reuse a previous mutation's result.
: test-run-id ( -- )
    run-id length 32 "run id length" check-equal
    run-id run-id = f "run ids differ" check-equal ;

: run-example-tests ( -- )
    "example/integral-decimals" [ test-integral-decimals ] run-test
    "example/rejected-counts" [ test-rejected-counts ] run-test
    "example/run-id" [ test-run-id ] run-test
    finish-tests ;

MAIN: run-example-tests
