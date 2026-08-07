# Tests for behaviour that belongs to the canonical example itself: how it
# narrows a Convex value to a counter, and how it behaves when it is run.
#
# The example source is loaded as a library, so the exact file shown in the
# README and on the website is the one under test.
#
#   gawk -v EXAMPLE_LIBRARY_ONLY=1 -v EXAMPLE=examples/basics/main.awk \
#        -v FIXTURE=client/tests/fixture.awk \
#        -f examples/basics/main.awk -f examples/basics/main_test.awk

BEGIN {
    if (EXAMPLE == "" || FIXTURE == "") {
        print "main_test: -v EXAMPLE=<path> -v FIXTURE=<path> are required" > "/dev/stderr"
        exit 1
    }
    test_count_decoding()
    test_missing_configuration()
    test_full_journey()
    exit report("main_test")
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

function decode(value,    result) {
    EXAMPLE_FAILED = 0
    result = example_count(value, "test")
    return EXAMPLE_FAILED ? "rejected" : result
}

# Convex may send an integral count as 0 or as 0.0, and both have to decode to
# the same integer. Anything fractional, quoted, or out of range is refused
# rather than rounded.
function test_count_decoding() {
    check(decode("{\"count\":0}") == 0, "an integer count decodes")
    check(decode("{\"count\":0.0}") == 0, "an integral decimal count decodes")
    check(decode("{\"count\":1.0}") == 1, "1.0 decodes to 1")
    check(decode("{\"count\":1e2}") == 100, "an exponent form decodes")
    check(decode("{\"count\":0.5}") == "rejected", "a fractional count is refused")
    check(decode("{\"count\":-1}") == "rejected", "a negative count is refused")
    check(decode("{\"count\":1e400}") == "rejected", "an overflowing count is refused")
    check(decode("{\"count\":\"1\"}") == "rejected", "a quoted count is refused")
    check(decode("{\"other\":1}") == "rejected", "a missing count is refused")
    check(decode("[1]") == "rejected", "a non-object value is refused")
    EXAMPLE_FAILED = 0
}

# Without a deployment URL the example must fail loudly on stderr and print
# nothing at all on stdout, because stdout is the shared transcript.
function test_missing_configuration(    command, line, output, status) {
    command = "CONVEX_URL= gawk -f " EXAMPLE " -- test-room 2>&1 1>/dev/null"
    output = ""
    while ((command |& getline line) > 0) {
        output = output line "\n"
    }
    status = close(command)
    check(status != 0, "the example exits non-zero without CONVEX_URL")
    check(output ~ /CONVEX_URL is required/, "the example explains the missing configuration")

    command = "CONVEX_URL= gawk -f " EXAMPLE " -- test-room 2>/dev/null"
    output = ""
    while ((command |& getline line) > 0) {
        output = output line
    }
    close(command)
    check(output == "", "a failed example writes nothing to stdout")
}

# Run the real example against the fixture deployment and confirm the journey it
# reports. The shared verifier owns the byte-exact transcript comparison; this
# only proves the example completes its 0 -> 1 journey over HTTP and Live.
function test_full_journey(    fixture, port, command, line, count, lines, status) {
    fixture = "gawk -f " FIXTURE " -v ROLE=deployment"
    if ((fixture |& getline port) <= 0) {
        check(0, "the deployment fixture reported a port")
        return
    }
    command = "CONVEX_URL=http://127.0.0.1:" (port + 0) " gawk -f " EXAMPLE " -- example"
    count = 0
    while ((command |& getline line) > 0) {
        lines[++count] = line
    }
    status = close(command)
    check(status == 0, "the example exits cleanly (status " status ")")
    check(count == 6, "the example prints six transcript lines, got " count)
    check(lines[1] ~ /^current count: 0$/, "the HTTP query reports the current count")
    check(lines[2] ~ /^live initial count: 0$/, "the first Live value hydrates the same count")
    check(lines[4] ~ /^mutation count: 1$/, "the mutation reports the incremented count")
    check(lines[6] ~ /^verified count: 0 -> 1$/, "the example proves the whole journey")

    print "quit" |& fixture
    fflush(fixture)
    close(fixture)
}
