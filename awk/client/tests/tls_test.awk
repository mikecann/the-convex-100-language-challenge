# Language-local TLS transport test.
#
# The client only ever speaks TLS as a client, so this test needs a real TLS
# peer. The fixture provides one through convex_test_tls_accept, which is
# compiled only into the test build of the extension (CONVEX_TEST_HOOKS) and is
# absent from the runtime image.
#
#   SSL_CERT_FILE=<ca.crt> gawk -f client/tests/tls_test.awk \
#       -v FIXTURE=client/tests/fixture.awk -v CERTIFICATE=... -v KEY=...

@include "convex.awk"

BEGIN {
    if (FIXTURE == "" || CERTIFICATE == "" || KEY == "") {
        print "tls_test: -v FIXTURE, -v CERTIFICATE and -v KEY are required" > "/dev/stderr"
        exit 1
    }
    test_trust_store()
    if (!start_fixture()) {
        exit 1
    }
    test_verified_exchange()
    test_hostname_mismatch()
    stop_fixture()
    exit report("tls_test")
}

function check(condition, label) {
    CHECKS++
    if (!condition) {
        FAILURES++
        print "FAIL " label > "/dev/stderr"
    }
}

function report(name) {
    printf "%s: %d checks, %d failures\n", name, CHECKS, FAILURES
    fflush("/dev/stdout")
    return FAILURES > 0 ? 1 : 0
}

function start_fixture(    port) {
    COMMAND = "gawk -f " FIXTURE " -v ROLE=tls -v CERTIFICATE=" CERTIFICATE " -v KEY=" KEY
    if ((COMMAND |& getline port) <= 0) {
        print "tls_test: the fixture did not report a port" > "/dev/stderr"
        return 0
    }
    PORT = port + 0
    return PORT > 0
}

function stop_fixture() {
    print "quit" |& COMMAND
    fflush(COMMAND)
    close(COMMAND)
}

# The trust store the client will use has to be loadable in this image, with the
# certificate authorities actually parsed rather than merely referenced.
function test_trust_store(    probe) {
    check(convex_tls_probe(probe) > 0, "the configured trust store loads certificate authorities")
    check(probe["openssl"] ~ /OpenSSL/, "the OpenSSL provider reports its version")
}

function test_verified_exchange(    response) {
    check(convex_open("https://localhost:" PORT, "awk-test") == 1, "a TLS client opens")
    convex_set_timeouts(4000, 8000)
    check(convex_query("demo:state", "{\"room\":\"r\"}", response) == 1,
        "a verified TLS exchange completes")
    check(response["value"] ~ /"count":0/, "the TLS response body is decoded")
}

# A certificate that is valid for another name must be refused, otherwise
# verification is decoration rather than protection.
function test_hostname_mismatch(    response) {
    check(convex_open("https://127.0.0.1:" PORT, "awk-test") == 1, "the mismatched client opens")
    convex_set_timeouts(4000, 8000)
    check(convex_query("demo:state", "{\"room\":\"r\"}", response) == 0,
        "a certificate for another name is rejected")
    check(convex_error_name() == "TransportError", "the rejection is a transport failure")
}
