# Language-local tests for the convexext primitives.
#
# Both halves of a loopback connection live in this one process: a listening
# socket, a client that connects to it, and the accepted server end. Because
# every primitive takes a deadline, one thread can drive both sides and every
# case stays deterministic.

@load "convexext"

BEGIN {
    IO_OK = 1
    IO_TIMEOUT = 0
    IO_EOF = -1
    IO_ERROR = -2

    test_clock()
    test_digest_and_randomness()
    test_utf8()
    test_timestamps()
    if (open_pair()) {
        test_text_frames()
        test_large_frame()
        test_control_frames()
        test_partial_frame_state()
        test_masking_rules()
        test_absolute_frame_deadline()
        test_close()
    }
    exit report("ext_test")
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

function test_clock(    first, second) {
    first = convex_now_ms()
    second = convex_now_ms()
    check(first > 0, "the monotonic clock returns milliseconds")
    check(second >= first, "the monotonic clock never goes backwards")
    check(convex_version() ~ /convexext .*OpenSSL/, "the extension reports its versions")
}

function test_digest_and_randomness(    digest, hex, encoded) {
    # The RFC6455 accept value is SHA-1 then base64; this is the digest of the
    # empty string, so a wrong digest or encoding shows up immediately.
    check(convex_sha1_base64("") == "2jmj7l5rSw0yVb/vlWAYkK/YBwk=",
        "SHA-1 with base64 matches its known vector")
    check(convex_sha1_base64("abc") == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=",
        "SHA-1 of abc matches its known vector")

    hex = convex_random_hex(16)
    check(length(hex) == 32 && hex ~ /^[0-9a-f]+$/, "random hex has the requested length")
    check(convex_random_hex(16) != hex, "random hex differs between calls")
    check(convex_random_hex(0) == "", "an out-of-range byte count is refused")

    encoded = convex_random_base64(16)
    check(length(encoded) == 24 && encoded ~ /^[A-Za-z0-9+\/]+==$/,
        "a 16 byte nonce encodes to 24 base64 characters")
}

function test_utf8() {
    check(convex_utf8_valid("plain ascii") == 1, "ASCII is valid UTF-8")
    check(convex_utf8_valid("caf\303\251") == 1, "two byte sequences are valid")
    check(convex_utf8_valid("\344\270\226\347\225\214") == 1, "three byte sequences are valid")
    check(convex_utf8_valid("\360\237\221\213") == 1, "four byte sequences are valid")
    check(convex_utf8_valid("\200") == 0, "a stray continuation byte is invalid")
    check(convex_utf8_valid("\303") == 0, "a truncated sequence is invalid")
    check(convex_utf8_valid("\300\257") == 0, "an overlong encoding is invalid")
    check(convex_utf8_valid("\355\240\200") == 0, "a surrogate encoding is invalid")
}

function test_timestamps() {
    check(convex_ts_cmp("AAAAAAAAAAA=", "AAAAAAAAAAA=") == 0, "equal timestamps compare equal")
    check(convex_ts_cmp("AQAAAAAAAAA=", "AAAAAAAAAAA=") == 1, "a later timestamp is greater")
    check(convex_ts_cmp("AAAAAAAAAAA=", "AQAAAAAAAAA=") == -1, "an earlier timestamp is smaller")
    # 64 bit ordering has to survive the low bits an Awk double would lose.
    check(convex_ts_cmp("AAAAAAAAAAA=", "AAAAAAAAAAI=") == -1,
        "ordering uses the high bytes of the little-endian value")
    check(convex_ts_cmp("AAAA", "AAAAAAAAAAA=") == -2, "a short timestamp is refused")
    check(convex_ts_cmp("AAAAAAAAAAB=", "AAAAAAAAAAA=") == -2,
        "non-canonical padding bits are refused")
    check(convex_ts_cmp("AAAAAAAAAA==", "AAAAAAAAAAA=") == -2,
        "the wrong padding length is refused")
}

function open_pair(    port) {
    LISTENER = convex_listen("127.0.0.1", 0)
    if (LISTENER < 0) {
        check(0, "the loopback listener starts: " convex_last_error())
        return 0
    }
    port = convex_port(LISTENER)
    check(port > 0, "the listener reports its bound port")
    CLIENT = convex_connect("127.0.0.1", port, 0, 2000)
    check(CLIENT >= 0, "a plain TCP client connects")
    SERVER = convex_accept(LISTENER, 2000)
    check(SERVER >= 0, "the listener accepts the connection")
    if (CLIENT < 0 || SERVER < 0) {
        return 0
    }
    check(convex_ws_server(SERVER) == 1, "the accepted end takes the server role")
    return 1
}

function test_text_frames(    frame) {
    check(convex_ws_send(CLIENT, 1, "hello server", 1000) == IO_OK, "a client text frame sends")
    check(convex_ws_recv(SERVER, 1000, frame) == IO_OK, "the server reads the frame")
    check(frame["kind"] == "text", "the frame is text")
    check(frame["payload"] == "hello server", "the payload survives masking")

    check(convex_ws_send(SERVER, 1, "hello client \303\251", 1000) == IO_OK,
        "a server text frame sends")
    check(convex_ws_recv(CLIENT, 1000, frame) == IO_OK, "the client reads the frame")
    check(frame["payload"] == "hello client \303\251", "UTF-8 payloads are unchanged")

    check(convex_ws_recv(CLIENT, 50, frame) == IO_TIMEOUT, "an idle read times out")
    check(frame["kind"] == "timeout", "a timeout is reported as a timeout")
}

function test_large_frame(    payload, frame, index_) {
    payload = sprintf("%0100000d", 7)
    check(length(payload) == 100000, "the test payload is built")
    check(convex_ws_send(CLIENT, 1, payload, 2000) == IO_OK,
        "a payload needing 64 bit length encoding sends")
    check(convex_ws_recv(SERVER, 2000, frame) == IO_OK, "the large frame is received")
    check(length(frame["payload"]) == 100000, "the large payload keeps its length")
    check(frame["payload"] == payload, "the large payload is byte identical")
}

function test_control_frames(    frame) {
    check(convex_ws_send(SERVER, 9, "are you there", 1000) == IO_OK, "a ping sends")
    check(convex_ws_recv(CLIENT, 1000, frame) == IO_OK, "the ping is received")
    check(frame["kind"] == "ping" && frame["payload"] == "are you there",
        "a ping keeps its payload for the pong")

    check(convex_ws_send(CLIENT, 10, "here", 1000) == IO_OK, "a pong sends")
    check(convex_ws_recv(SERVER, 1000, frame) == IO_OK && frame["kind"] == "pong",
        "the pong is received")

    check(convex_ws_send(SERVER, 9, sprintf("%0126d", 1), 1000) == IO_ERROR,
        "an oversized control frame is refused before it reaches the wire")
}

# Once any byte of a message has been consumed, a read timeout must preserve the
# parser state rather than restarting at a false frame boundary.
function test_partial_frame_state(    frame, pending) {
    check(convex_ws_send_frame(SERVER, 0, 1, "first half ", 1000) == IO_OK,
        "a non-final frame sends")
    check(convex_ws_recv(CLIENT, 200, frame) == IO_TIMEOUT,
        "an incomplete message does not produce a value")
    pending = convex_ws_pending(CLIENT)
    check(pending > 0, "the parser still holds the consumed bytes")
    check(convex_ws_recv(CLIENT, 100, frame) == IO_TIMEOUT,
        "a second timeout does not discard the partial message")
    check(convex_ws_pending(CLIENT) == pending, "the retained state is unchanged")

    check(convex_ws_send_frame(SERVER, 1, 0, "second half", 1000) == IO_OK,
        "the final continuation frame sends")
    check(convex_ws_recv(CLIENT, 1000, frame) == IO_OK, "the message completes")
    check(frame["payload"] == "first half second half", "fragments reassemble in order")
    check(convex_ws_pending(CLIENT) == 0, "the parser buffer drains once complete")
}

# RFC6455 masking is asymmetric, and both directions matter: only one of them is
# ever exercised against a real deployment.
function test_masking_rules(    frame, port, first, second) {
    check(convex_ws_send(SERVER, 1, "unmasked", 1000) == IO_OK, "the server sends unmasked")
    check(convex_ws_recv(CLIENT, 1000, frame) == IO_OK, "the client accepts an unmasked frame")
    check(convex_ws_send(CLIENT, 1, "masked", 1000) == IO_OK, "the client sends masked")
    check(convex_ws_recv(SERVER, 1000, frame) == IO_OK, "the server accepts a masked frame")

    # Both ends stay in the client role, so the receiver sees a masked frame
    # from something claiming to be a server.
    port = convex_port(LISTENER)
    first = convex_connect("127.0.0.1", port, 0, 2000)
    second = convex_accept(LISTENER, 2000)
    convex_ws_send(first, 1, "masked", 1000)
    check(convex_ws_recv(second, 1000, frame) == IO_ERROR,
        "a masked frame from a server is rejected")
    check(frame["error"] ~ /masked/, "the masking violation is reported")
    convex_close(first)
    convex_close(second)

    # Both ends take the server role, so the receiver sees an unmasked frame
    # from something claiming to be a client.
    first = convex_connect("127.0.0.1", port, 0, 2000)
    second = convex_accept(LISTENER, 2000)
    convex_ws_server(first)
    convex_ws_server(second)
    convex_ws_send(first, 1, "unmasked", 1000)
    check(convex_ws_recv(second, 1000, frame) == IO_ERROR,
        "an unmasked frame from a client is rejected")
    convex_close(first)
    convex_close(second)
}

# Preserving partial bytes must still have an absolute end. Otherwise a peer
# can send one fragment and keep the owner occupied forever by dribbling.
function test_absolute_frame_deadline(    frame, port, server, client, started, elapsed) {
    port = convex_port(LISTENER)
    server = convex_connect("127.0.0.1", port, 0, 2000)
    client = convex_accept(LISTENER, 2000)
    convex_ws_server(server)
    check(convex_ws_send_frame(server, 0, 1, "never completed", 1000) == IO_OK,
        "the deadline peer sends one non-final fragment")
    started = convex_now_ms()
    check(convex_ws_recv(client, 6000, frame) == IO_ERROR,
        "an incomplete frame hits its absolute deadline")
    elapsed = convex_now_ms() - started
    check(elapsed >= 4500 && elapsed < 6500,
        "the absolute frame deadline is about five seconds (" int(elapsed) " ms)")
    check(frame["error"] ~ /did not complete/, "the frame deadline is diagnosed")
    convex_close(server)
    convex_close(client)
}

function test_close(    frame, started, elapsed) {
    check(convex_ws_send(SERVER, 8, sprintf("%c%c", 3, 232), 1000) == IO_OK, "a close frame sends")
    check(convex_ws_recv(CLIENT, 1000, frame) == IO_OK, "the close frame is received")
    check(frame["kind"] == "close", "the close frame is reported as a close")
    check(frame["code"] == 1000, "the close code is decoded")

    started = convex_now_ms()
    check(convex_close(CLIENT) == 1, "closing the client returns")
    check(convex_close(SERVER) == 1, "closing the server returns")
    check(convex_close(LISTENER) == 1, "closing the listener returns")
    elapsed = convex_now_ms() - started
    check(elapsed < 500, "closing is bounded (" int(elapsed) " ms)")

    check(convex_ws_recv(CLIENT, 100, frame) == IO_ERROR, "a closed handle is refused")
}
