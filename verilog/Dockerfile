# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use
# (see vhdl/Dockerfile, which this stage's structure mirrors).
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: install the pinned Icarus Verilog toolchain, build native.c as a VPI
# module against vpi_user.h, and prove the toolchain gate this client's slot
# exists to prove before any Convex-specific code is written:
#
#   (a) a real TCP connection, driven from Verilog through the VPI boundary
#       (client/convex_transport.v -> $cx_dispatch -> client/native.c),
#       against a one-shot fixture TCP server built in this same stage.
#
#   (b) a real TLS handshake, WITH certificate and hostname verification,
#       to the approved test deployment usable-reindeer-44.convex.cloud:443,
#       through the same VPI boundary and OpenSSL in the same native.c.
#
# CHECKPOINT NOTE: this client has the toolchain gate, a JSON codec
# (client/convex_buffer.v), HTTP/1.1 request/response framing
# (client/convex_http.v, proven with a real POST /api/query round trip
# to the shared demo:state query - see the http_smoke stage below), a
# pure-Verilog SHA-1 and base64 encoder (client/convex_sha1.v,
# client/convex_base64.v, proven against RFC 6455's own worked
# Sec-WebSocket-Accept example - see sha1_test below) and now RFC 6455
# WebSocket framing (client/convex_websocket.v: masking, fragmentation
# reassembly, interleaved control frames, one-shot post-reassembly UTF-8
# validation - see ws_smoke below), and now the /api/sync Live state
# machine (client/convex_sync.v: subscribe, five real debugDisconnect
# reconnects with unchanged rehydration suppressed, QueryFailed and
# recovery, connectionCount/lastCloseReason/maxObservedTimestamp,
# exponential backoff - see sync_smoke below) so far. The canonical
# examples/basics program and the conformance adapter do not exist yet,
# so no capability is claimed; see verilog/README.md. This
# stage is built up incrementally and checkpoint-commented for the same
# reason vhdl/ - still unimplemented itself (status: planned) - would be
# organised the same way once it exists: each layer is proven against a
# real peer (or, for pure JSON encode/decode, a thorough language-local
# unit suite) before the next is built on top of it.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       iverilog \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       binutils \
    && rm -rf /var/lib/apt/lists/*

# Icarus Verilog's version and the exact Debian package revision are
# asserted and recorded so the (future) adapter cannot misreport the
# toolchain it actually ran on, matching this project's other from-source
# and translator-pinned native clients (see vhdl/Dockerfile's ghdl pin).
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    iverilog -V 2>&1 | tee /tmp/iverilog-version.log; \
    grep -Eq '^Icarus Verilog version 11\.0 \(stable\)' /tmp/iverilog-version.log; \
    dpkg-query -W -f='${Version}\n' iverilog | tee /tmp/iverilog-pkg-version.log; \
    grep -Fxq '11.0-1.1+b1' /tmp/iverilog-pkg-version.log; \
    printf 'iverilog-11.0-stable-debian-11.0-1.1+b1' > /project/runtime-version; \
    test -s /project/runtime-version

COPY client ./client

# Verilog has no single standard formatter in wide use, so the style gate
# is explicit: spaces only, no trailing blanks, a final newline, and a
# column limit - the same discipline vhdl/Dockerfile and the ALGOL 60
# client apply for the same reason (no ecosystem-blessed `gofmt`
# equivalent exists to defer to).
RUN set -eu; \
    files=$(find client -name '*.v' -o -name '*.vh'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      if awk 'length > 120 { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over 120 columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS verilog source style"

# The only native code in the client, built as an Icarus VPI module with
# the project's own build helper (iverilog-vpi, shipped by the iverilog
# package) so the exact compile/link flags Icarus itself expects are used
# rather than guessed. Its exported boundary is exactly the two system
# functions client/convex_transport.v calls: $cx_dispatch and $cx_now_ms.
RUN set -eu; \
    iverilog-vpi -lssl -lcrypto client/native.c; \
    test -f /project/native.vpi; \
    nm -D /project/native.vpi | grep -q 'vlog_startup_routines'

# ---------------------------------------------------------------------------
# Gate proof (a): a real TCP connection driven from Verilog through the VPI
# boundary. tcpfix is a tiny one-shot fixture server - test infrastructure
# only, never linked into the client itself - that accepts one connection,
# waits for an exact request, and replies with a canned response, the same
# role vhdl/Dockerfile's httpfix.c plays for the VHDL client's http_test.
# ---------------------------------------------------------------------------
RUN <<'TCPFIX_EOF'
set -eu
cat > /tmp/tcpfix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: tcpfix port\n"); return 1; }
    int port = atoi(argv[1]);
    const char *want = "PING verilog\n";
    const char *reply = "PONG fixture\n";

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(fd, 1);
    int c = accept(fd, NULL, NULL);
    if (c < 0) { perror("accept"); return 1; }

    char buf[64];
    size_t total = 0;
    size_t wantlen = strlen(want);
    while (total < wantlen) {
        ssize_t n = read(c, buf + total, sizeof(buf) - total);
        if (n <= 0) { fprintf(stderr, "tcpfix: read failed\n"); return 1; }
        total += (size_t)n;
    }
    if (memcmp(buf, want, wantlen) != 0) {
        fprintf(stderr, "tcpfix: unexpected request\n");
        return 1;
    }
    write(c, reply, strlen(reply));
    close(c);
    close(fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/tcpfix /tmp/tcpfix.c
TCPFIX_EOF

RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/tcp_smoke.vvp client/convex_transport.v client/tests/tcp_smoke.v; \
    /tmp/tcpfix 44201 & \
    fixture_pid=$!; \
    sleep 1; \
    timeout 15 vvp -M. -mnative /tmp/tcp_smoke.vvp | tee /tmp/tcp_smoke.out; \
    wait "$fixture_pid" || true; \
    grep -Fq 'PASS tcp_smoke' /tmp/tcp_smoke.out

# ---------------------------------------------------------------------------
# Gate proof (b): a real TLS handshake, with certificate AND hostname
# verification, to the approved test deployment
# usable-reindeer-44.convex.cloud:443, through the same VPI boundary.
# client/native.c's handle_connect only returns a non-negative handle for a
# TLS connection once SSL_connect succeeds AND
# SSL_get_verify_result(ssl) == X509_V_OK against the exact hostname pushed
# from Verilog (SSL_set1_host, matching SNI) - so a PASS here already is the
# cert+hostname proof. tls_smoke.v goes one step further and sends a real
# HTTP/1.1 request over that handshake, then checks a real HTTP status line
# comes back, so the evidence is "application bytes travel through it", not
# only "the handshake bit was set".
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/tls_smoke.vvp client/convex_transport.v client/tests/tls_smoke.v; \
    timeout 20 vvp -M. -mnative /tmp/tls_smoke.vvp | tee /tmp/tls_smoke.out; \
    grep -Fq 'PASS tls_smoke' /tmp/tls_smoke.out

# ---------------------------------------------------------------------------
# http_smoke: a real HTTP/1.1 POST /api/query round trip against the
# approved test deployment, over the same TLS-verified channel tls_smoke
# proves above, driven through convex_http.v's request/response framing
# and convex_buffer.v's JSON encode/decode - the first proof those two
# layers work together against the real backend, not merely that they
# compile. It calls the shared demo module's demo:state query for a
# scratch room and checks the real envelope shape Convex's HTTP API
# returns (status/value/errorMessage/logLines), including the returned
# count.
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/http_smoke.vvp client/convex_transport.v client/convex_buffer.v \
      client/convex_http.v client/tests/http_smoke.v; \
    timeout 20 vvp -M. -mnative /tmp/http_smoke.vvp | tee /tmp/http_smoke.out; \
    grep -Fq 'PASS http_smoke' /tmp/http_smoke.out

# ---------------------------------------------------------------------------
# json_test: convex_buffer.v's JSON encoder/decoder, including the
# integral-decimal-number regression AGENTS.md requires ("0.0"/"1.0" must
# decode as the integers 0/1; fractional, quoted, non-finite and
# overflowing values must be rejected). No transport is involved here, so
# this does not need the VPI module or -mnative.
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -I. \
      -o /tmp/json_test.vvp client/convex_buffer.v client/tests/json_test.v; \
    vvp /tmp/json_test.vvp | tee /tmp/json_test.out; \
    grep -Fq 'PASS json_test' /tmp/json_test.out

# ---------------------------------------------------------------------------
# sha1_test: client/convex_sha1.v and client/convex_base64.v, including
# RFC 6455's OWN worked example (SS1.3): the exact Sec-WebSocket-Key
# "dGhlIHNhbXBsZSBub25jZQ==" must produce the exact Sec-WebSocket-Accept
# "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" once combined with the magic GUID,
# hashed and base64-encoded - proving both files correct together, in
# exactly the composition the WebSocket handshake below uses them in, no
# live network required. No transport is involved, so -mnative is not
# needed.
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -I. \
      -o /tmp/sha1_test.vvp client/convex_buffer.v client/convex_sha1.v \
      client/convex_base64.v client/tests/sha1_test.v; \
    vvp /tmp/sha1_test.vvp | tee /tmp/sha1_test.out; \
    grep -Fq 'PASS sha1_test' /tmp/sha1_test.out

# ---------------------------------------------------------------------------
# RFC 6455 WebSocket layer: client/convex_websocket.v, built on
# convex_http.v's connection/request machinery and convex_sha1.v/
# convex_base64.v's Sec-WebSocket-Accept check. wsfix is a one-shot
# fixture WebSocket server (test infrastructure only, never linked into
# the client itself - the same role tcpfix plays above) that answers a
# real handshake with a correctly computed Accept header, drives a
# fragmented message with an interleaved PING across the fragment
# boundary of a split UTF-8 codepoint, and independently verifies the
# client's PONG and CLOSE frames arrived masked with the right content -
# see wsfix.c and client/tests/ws_smoke.v for the full choreography.
# ---------------------------------------------------------------------------
RUN <<'WSFIX_EOF'
set -eu
cat > /tmp/wsfix.c <<'CEOF'
/* wsfix.c - a one-shot RFC 6455 WebSocket fixture peer for ws_smoke.v.
 * Test infrastructure only, never linked into the client itself - the
 * same role tcpfix.c plays for tcp_smoke.v (see verilog/Dockerfile).
 *
 * Plays "server": answers the handshake with a correctly computed
 * Sec-WebSocket-Accept (RFC 6455 SS4.2.2, via OpenSSL's own SHA1/
 * EVP_EncodeBlock - this fixture is not the code under test, so it is
 * free to use a library the client itself is not allowed to), sends a
 * TEXT message as two fragments split in the middle of a 3-byte UTF-8
 * codepoint, sends a PING between those two fragments, checks the
 * client's PONG arrived masked and echoed the PING payload, sends a
 * CLOSE, and checks the client answered with its own masked CLOSE.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

static int accept_one(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("wsfix: bind"); exit(1); }
    listen(fd, 1);
    int c = accept(fd, NULL, NULL);
    if (c < 0) { perror("wsfix: accept"); exit(1); }
    close(fd);
    return c;
}

static int read_full(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char *)buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}

static void write_full(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)buf + off, n - off);
        if (w <= 0) { fprintf(stderr, "wsfix: write failed\n"); exit(1); }
        off += (size_t)w;
    }
}

/* Reads the HTTP/1.1 upgrade request one byte at a time until the
 * blank CRLFCRLF line, extracting the Sec-WebSocket-Key header's value
 * (case-insensitive name match, matching real HTTP semantics). */
static void read_handshake(int fd, char *key_out, size_t key_cap) {
    char buf[8192];
    size_t len = 0;
    key_out[0] = '\0';
    for (;;) {
        if (len >= sizeof(buf) - 1) { fprintf(stderr, "wsfix: handshake too large\n"); exit(1); }
        ssize_t r = read(fd, buf + len, 1);
        if (r <= 0) { fprintf(stderr, "wsfix: handshake read failed\n"); exit(1); }
        len += (size_t)r;
        buf[len] = '\0';
        if (len >= 4 && memcmp(buf + len - 4, "\r\n\r\n", 4) == 0) break;
    }
    char *line = buf;
    for (;;) {
        char *eol = strstr(line, "\r\n");
        if (!eol) break;
        *eol = '\0';
        if (strncasecmp(line, "Sec-WebSocket-Key:", 18) == 0) {
            char *v = line + 18;
            while (*v == ' ') v++;
            snprintf(key_out, key_cap, "%s", v);
        }
        if (eol == line) break; /* blank line: end of headers */
        line = eol + 2;
    }
    if (key_out[0] == '\0') {
        fprintf(stderr, "wsfix: request had no Sec-WebSocket-Key; raw request follows:\n");
        for (size_t i = 0; i < len; i++) fputc((unsigned char)buf[i] >= 32 || buf[i] == '\n' ? buf[i] : '.', stderr);
        fprintf(stderr, "\n--- end of raw request ---\n");
        exit(1);
    }
}

static void compute_accept(const char *key, char *accept_out) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char joined[256];
    snprintf(joined, sizeof(joined), "%s%s", key, guid);
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)joined, strlen(joined), digest);
    int n = EVP_EncodeBlock((unsigned char *)accept_out, digest, SHA_DIGEST_LENGTH);
    accept_out[n] = '\0';
}

/* Sends one unmasked (server-to-client) frame - RFC 6455 SS5.1 forbids
 * a server from ever masking. */
static void send_frame(int fd, int fin, int opcode, const unsigned char *payload, size_t len) {
    unsigned char hdr[4];
    size_t hlen = 0;
    hdr[hlen++] = (unsigned char)((fin ? 0x80 : 0x00) | (opcode & 0x0F));
    if (len < 126) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xFF);
        hdr[hlen++] = (unsigned char)(len & 0xFF);
    }
    write_full(fd, hdr, hlen);
    if (len > 0) write_full(fd, payload, len);
}

/* Reads one client-to-server frame and unmasks it in place, exiting
 * with a diagnostic if the MASK bit is not set: RFC 6455 SS5.1 requires
 * every client-sent frame to be masked, and this fixture's whole job is
 * to prove the client under test actually does that, not just to relay
 * bytes back and forth. */
static size_t read_masked_frame(int fd, int *fin, int *opcode, unsigned char *payload, size_t cap) {
    unsigned char hdr[2];
    if (read_full(fd, hdr, 2) < 0) { fprintf(stderr, "wsfix: frame header read failed\n"); exit(1); }
    *fin = (hdr[0] & 0x80) != 0;
    *opcode = hdr[0] & 0x0F;
    int masked = (hdr[1] & 0x80) != 0;
    if (!masked) { fprintf(stderr, "wsfix: FAIL client frame was NOT masked (RFC 6455 SS5.1 violation)\n"); exit(1); }
    uint64_t plen = hdr[1] & 0x7F;
    if (plen == 126) {
        unsigned char ext[2];
        if (read_full(fd, ext, 2) < 0) { fprintf(stderr, "wsfix: ext16 read failed\n"); exit(1); }
        plen = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (plen == 127) {
        unsigned char ext[8];
        if (read_full(fd, ext, 8) < 0) { fprintf(stderr, "wsfix: ext64 read failed\n"); exit(1); }
        plen = 0;
        for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
    }
    if (plen > cap) { fprintf(stderr, "wsfix: client frame too large\n"); exit(1); }
    unsigned char mkey[4];
    if (read_full(fd, mkey, 4) < 0) { fprintf(stderr, "wsfix: mask key read failed\n"); exit(1); }
    if (plen > 0 && read_full(fd, payload, plen) < 0) { fprintf(stderr, "wsfix: masked payload read failed\n"); exit(1); }
    for (uint64_t i = 0; i < plen; i++) payload[i] = (unsigned char)(payload[i] ^ mkey[i % 4]);
    return (size_t)plen;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: wsfix port\n"); return 1; }
    int port = atoi(argv[1]);
    int fd = accept_one(port);

    char key[512];
    read_handshake(fd, key, sizeof(key));
    char accept_val[64];
    compute_accept(key, accept_val);

    char resp[512];
    int rn = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n", accept_val);
    write_full(fd, resp, (size_t)rn);

    /* "ok:" + E2 82 AC (U+20AC, euro sign, UTF-8) + ":done", split so
     * fragment 1 ends mid-codepoint (after E2 82) and the continuation
     * frame supplies only the trailing byte (AC) plus the rest. A
     * per-fragment UTF-8 validator would wrongly reject fragment 1's
     * dangling two bytes; validating once after reassembly must accept
     * the complete, well-formed message - see ws_smoke.v/
     * convex_websocket.v's own comments for why that split was chosen. */
    unsigned char frag1[] = { 'o', 'k', ':', 0xE2, 0x82 };
    unsigned char frag2[] = { 0xAC, ':', 'd', 'o', 'n', 'e' };
    send_frame(fd, 0 /* fin */, 0x1 /* text */, frag1, sizeof(frag1));

    /* A control frame legally interleaved between the two fragments of
     * the still-open message above (RFC 6455 SS5.4). */
    const unsigned char ping_payload[] = "ping-mid-frag";
    send_frame(fd, 1, 0x9 /* ping */, ping_payload, sizeof(ping_payload) - 1);

    unsigned char client_buf[256];
    int cfin, copcode;
    size_t clen = read_masked_frame(fd, &cfin, &copcode, client_buf, sizeof(client_buf));
    if (copcode != 0xA) { fprintf(stderr, "wsfix: FAIL expected PONG (0xA), got opcode 0x%x\n", copcode); return 1; }
    if (clen != sizeof(ping_payload) - 1 || memcmp(client_buf, ping_payload, clen) != 0) {
        fprintf(stderr, "wsfix: FAIL PONG payload did not echo the PING payload exactly\n");
        return 1;
    }
    fprintf(stderr, "wsfix: PASS masked PONG echoed the PING payload correctly\n");

    send_frame(fd, 1 /* fin */, 0x0 /* continuation */, frag2, sizeof(frag2));

    unsigned char close_payload[2] = { 0x03, 0xE8 }; /* 1000, normal closure */
    send_frame(fd, 1, 0x8 /* close */, close_payload, sizeof(close_payload));

    clen = read_masked_frame(fd, &cfin, &copcode, client_buf, sizeof(client_buf));
    if (copcode != 0x8) { fprintf(stderr, "wsfix: FAIL expected CLOSE (0x8), got opcode 0x%x\n", copcode); return 1; }
    fprintf(stderr, "wsfix: PASS client answered with a masked CLOSE frame\n");

    close(fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/wsfix /tmp/wsfix.c -lssl -lcrypto
WSFIX_EOF

RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/ws_smoke.vvp client/convex_transport.v client/convex_buffer.v \
      client/convex_http.v client/convex_sha1.v client/convex_base64.v \
      client/convex_websocket.v client/tests/ws_smoke.v; \
    /tmp/wsfix 44202 2>/tmp/wsfix.log & \
    fixture_pid=$!; \
    sleep 1; \
    timeout 20 vvp -M. -mnative /tmp/ws_smoke.vvp | tee /tmp/ws_smoke.out; \
    wait "$fixture_pid" || true; \
    cat /tmp/wsfix.log >&2; \
    grep -Fq 'PASS ws_smoke' /tmp/ws_smoke.out; \
    grep -Fq 'PASS masked PONG echoed the PING payload correctly' /tmp/wsfix.log; \
    grep -Fq 'PASS client answered with a masked CLOSE frame' /tmp/wsfix.log

# ---------------------------------------------------------------------------
# /api/sync Live state machine: client/convex_sync.v, built on
# convex_websocket.v. syncfix is a one-shot fixture peer (test
# infrastructure only, never linked into the client itself - the same
# role wsfix/tcpfix play above) that accepts six sequential connections
# (one initial connect plus five debugDisconnect-triggered reconnects),
# independently checks each one's connectionCount and lastCloseReason,
# and drives an unchanged rehydration (must be suppressed) followed by
# a genuine external mutation (must be delivered) on every one of them,
# then, on the sixth connection only, a QueryFailed followed by
# recovery on the same subscription - see syncfix.c and
# client/tests/sync_smoke.v for the full choreography.
# ---------------------------------------------------------------------------
RUN <<'SYNCFIX_EOF'
set -eu
cat > /tmp/syncfix.c <<'CEOF'
/* syncfix.c - a one-shot fixture peer for the /api/sync protocol,
 * driving client/tests/sync_smoke.v through six sequential connections
 * (one initial connect plus five debugDisconnect-triggered reconnects)
 * over one listening socket. Test infrastructure only, never linked
 * into the client itself - the same role wsfix.c/tcpfix.c play for
 * their own gates (see verilog/Dockerfile).
 *
 * Each connection: completes the RFC 6455 handshake, reads the
 * client's Connect message and independently checks connectionCount
 * (0, 1, 2, 3, 4, 5) and lastCloseReason ("InitialConnect" on the
 * first, "debugDisconnect" on every reconnect), reads the client's
 * ModifyQuerySet (the rehydration replay of its one active
 * subscription), then sends two Transition messages: first the
 * CURRENT tracked value (a rehydration on every connection after the
 * first - the client must suppress this, since nothing changed), then
 * CURRENT+1 (a genuine external mutation the client must deliver).
 * On the sixth and final connection only, two more Transitions follow
 * the mutation: a QueryFailed, then a recovery QueryUpdated on the
 * same queryId - proving a client handles a failing query and its
 * later recovery, not only ordinary value updates.
 *
 * After all of that this fixture just blocks reading, which is how it
 * learns the client called debugDisconnect (TCP EOF) and moves on to
 * accept() the next connection - or, on the sixth and final
 * connection, how it learns the test itself finished ($finish tears
 * down the whole process, including this socket).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

#define TOTAL_CONNECTIONS 6

static int accept_one(int listen_fd) {
    int c = accept(listen_fd, NULL, NULL);
    if (c < 0) { perror("syncfix: accept"); exit(1); }
    return c;
}

static int read_full(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char *)buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}

static void write_full(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)buf + off, n - off);
        if (w <= 0) { fprintf(stderr, "syncfix: write failed\n"); exit(1); }
        off += (size_t)w;
    }
}

static void read_handshake(int fd, char *key_out, size_t key_cap) {
    char buf[8192];
    size_t len = 0;
    key_out[0] = '\0';
    for (;;) {
        if (len >= sizeof(buf) - 1) { fprintf(stderr, "syncfix: handshake too large\n"); exit(1); }
        ssize_t r = read(fd, buf + len, 1);
        if (r <= 0) { fprintf(stderr, "syncfix: handshake read failed\n"); exit(1); }
        len += (size_t)r;
        buf[len] = '\0';
        if (len >= 4 && memcmp(buf + len - 4, "\r\n\r\n", 4) == 0) break;
    }
    char *line = buf;
    for (;;) {
        char *eol = strstr(line, "\r\n");
        if (!eol) break;
        *eol = '\0';
        if (strncasecmp(line, "Sec-WebSocket-Key:", 18) == 0) {
            char *v = line + 18;
            while (*v == ' ') v++;
            snprintf(key_out, key_cap, "%s", v);
        }
        if (eol == line) break;
        line = eol + 2;
    }
    if (key_out[0] == '\0') { fprintf(stderr, "syncfix: request had no Sec-WebSocket-Key\n"); exit(1); }
}

static void compute_accept(const char *key, char *accept_out) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char joined[256];
    snprintf(joined, sizeof(joined), "%s%s", key, guid);
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)joined, strlen(joined), digest);
    int n = EVP_EncodeBlock((unsigned char *)accept_out, digest, SHA_DIGEST_LENGTH);
    accept_out[n] = '\0';
}

static void do_handshake(int fd) {
    char key[512], accept_val[64], resp[512];
    read_handshake(fd, key, sizeof(key));
    compute_accept(key, accept_val);
    int rn = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n", accept_val);
    write_full(fd, resp, (size_t)rn);
}

static void send_text_frame(int fd, const char *text) {
    size_t len = strlen(text);
    unsigned char hdr[4];
    size_t hlen = 0;
    hdr[hlen++] = 0x80 | 0x1; /* FIN, opcode 1 = text; server frames are never masked */
    if (len < 126) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xFF);
        hdr[hlen++] = (unsigned char)(len & 0xFF);
    }
    write_full(fd, hdr, hlen);
    write_full(fd, text, len);
}

/* Reads one masked client->server text frame's payload into out (NUL
 * terminated). Exits with a diagnostic if the frame was not masked -
 * RFC 6455 SS5.1 requires every client-sent frame to be masked. */
static void read_masked_text_frame(int fd, char *out, size_t cap) {
    unsigned char hdr[2];
    if (read_full(fd, hdr, 2) < 0) { fprintf(stderr, "syncfix: frame header read failed\n"); exit(1); }
    int masked = (hdr[1] & 0x80) != 0;
    if (!masked) { fprintf(stderr, "syncfix: FAIL client frame was NOT masked\n"); exit(1); }
    uint64_t plen = hdr[1] & 0x7F;
    if (plen == 126) {
        unsigned char ext[2];
        if (read_full(fd, ext, 2) < 0) exit(1);
        plen = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (plen == 127) {
        unsigned char ext[8];
        if (read_full(fd, ext, 8) < 0) exit(1);
        plen = 0;
        for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
    }
    if (plen >= cap) { fprintf(stderr, "syncfix: client frame too large\n"); exit(1); }
    unsigned char mkey[4];
    if (read_full(fd, mkey, 4) < 0) { fprintf(stderr, "syncfix: mask key read failed\n"); exit(1); }
    if (plen > 0 && read_full(fd, out, plen) < 0) { fprintf(stderr, "syncfix: masked payload read failed\n"); exit(1); }
    for (uint64_t i = 0; i < plen; i++) out[i] = (char)((unsigned char)out[i] ^ mkey[i % 4]);
    out[plen] = '\0';
}

/* Bare-bones field extraction: this fixture only ever parses JSON text
 * this project's own convex_sync.v emitted, so a substring search for
 * `"field":` is enough - it does not need to be a general JSON parser. */
static int extract_int_field(const char *json, const char *field) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\":", field);
    const char *p = strstr(json, needle);
    if (!p) return -1;
    p += strlen(needle);
    return atoi(p);
}

static int extract_string_field(const char *json, const char *field, char *out, size_t cap) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\":\"", field);
    const char *p = strstr(json, needle);
    if (!p) return 0;
    p += strlen(needle);
    const char *end = strchr(p, '"');
    if (!end) return 0;
    size_t n = (size_t)(end - p);
    if (n >= cap) n = cap - 1;
    memcpy(out, p, n);
    out[n] = '\0';
    return 1;
}

static void ts_b64(uint64_t v, char *out) {
    unsigned char bytes[8];
    for (int i = 0; i < 8; i++) { bytes[i] = (unsigned char)(v & 0xFF); v >>= 8; }
    int n = EVP_EncodeBlock((unsigned char *)out, bytes, 8);
    out[n] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: syncfix port\n"); return 1; }
    int port = atoi(argv[1]);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("syncfix: bind"); return 1; }
    listen(listen_fd, 1);

    int value_counter = 0;
    uint64_t ts_counter = 1;
    int qs_counter = 0;
    int failed = 0;

    for (int conn_num = 0; conn_num < TOTAL_CONNECTIONS; conn_num++) {
        int fd = accept_one(listen_fd);
        do_handshake(fd);

        char msg[8192];
        read_masked_text_frame(fd, msg, sizeof(msg)); /* Connect */

        int got_count = extract_int_field(msg, "connectionCount");
        char reason[128];
        extract_string_field(msg, "lastCloseReason", reason, sizeof(reason));
        const char *want_reason = (conn_num == 0) ? "InitialConnect" : "debugDisconnect";
        if (got_count != conn_num || strcmp(reason, want_reason) != 0) {
            fprintf(stderr,
                "syncfix: FAIL connection %d: connectionCount=%d (want %d), lastCloseReason=\"%s\" (want \"%s\")\n",
                conn_num, got_count, conn_num, reason, want_reason);
            failed = 1;
        } else {
            fprintf(stderr,
                "syncfix: PASS connection %d: connectionCount=%d, lastCloseReason=\"%s\"\n",
                conn_num, got_count, reason);
        }

        read_masked_text_frame(fd, msg, sizeof(msg)); /* ModifyQuerySet (rehydration Add) */
        int query_id = extract_int_field(msg, "queryId");
        if (query_id != 1) {
            fprintf(stderr, "syncfix: FAIL connection %d: queryId=%d (want 1)\n", conn_num, query_id);
            failed = 1;
        }

        /* Rehydration: the CURRENT value again, unchanged - the client
         * must suppress this on every connection after the first. */
        char ts1[16], ts2[16], text[1024];
        ts_b64(ts_counter, ts1); ts_counter++;
        snprintf(text, sizeof(text),
            "{\"type\":\"Transition\","
            "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":%d}]}",
            qs_counter, ts1, qs_counter + 1, ts1, value_counter);
        qs_counter++;
        send_text_frame(fd, text);

        /* External mutation: a genuinely new value. */
        value_counter++;
        ts_b64(ts_counter, ts2); ts_counter++;
        snprintf(text, sizeof(text),
            "{\"type\":\"Transition\","
            "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":%d}]}",
            qs_counter, ts2, qs_counter + 1, ts2, value_counter);
        qs_counter++;
        send_text_frame(fd, text);

        /* On the final connection only, once the ordinary
         * QueryUpdated path is already fully proven, also drive
         * QueryFailed followed by recovery on the SAME subscription -
         * the client must mark the subscription failed with the exact
         * error message, then clear that failure and deliver the next
         * real value once the query succeeds again. */
        if (conn_num == TOTAL_CONNECTIONS - 1) {
            char ts3[16], ts4[16];
            ts_b64(ts_counter, ts3); ts_counter++;
            snprintf(text, sizeof(text),
                "{\"type\":\"Transition\","
                "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
                "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
                "\"modifications\":[{\"type\":\"QueryFailed\",\"queryId\":1,"
                "\"errorMessage\":\"Uncaught Error: boom\"}]}",
                qs_counter, ts3, qs_counter + 1, ts3);
            qs_counter++;
            send_text_frame(fd, text);

            value_counter++;
            ts_b64(ts_counter, ts4); ts_counter++;
            snprintf(text, sizeof(text),
                "{\"type\":\"Transition\","
                "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
                "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
                "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":%d}]}",
                qs_counter, ts4, qs_counter + 1, ts4, value_counter);
            qs_counter++;
            send_text_frame(fd, text);
        }

        /* Block until the client disconnects (debugDisconnect) or the
         * whole test process tears down (the sixth connection's case).
         * Either way this is a plain read that will fail once that
         * happens; nothing else is expected on this connection past
         * this point in the script. */
        char discard[64];
        read(fd, discard, sizeof(discard));
        close(fd);
    }

    close(listen_fd);
    if (failed) {
        fprintf(stderr, "syncfix: FAIL one or more connections had the wrong connectionCount/lastCloseReason\n");
        return 1;
    }
    fprintf(stderr, "syncfix: PASS all %d connections had the correct connectionCount and lastCloseReason\n",
            TOTAL_CONNECTIONS);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/syncfix /tmp/syncfix.c -lssl -lcrypto
SYNCFIX_EOF

RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/sync_smoke.vvp client/convex_transport.v client/convex_buffer.v \
      client/convex_http.v client/convex_sha1.v client/convex_base64.v \
      client/convex_websocket.v client/convex_sync.v client/tests/sync_smoke.v; \
    /tmp/syncfix 44203 2>/tmp/syncfix.log & \
    fixture_pid=$!; \
    sleep 1; \
    timeout 60 vvp -M. -mnative /tmp/sync_smoke.vvp | tee /tmp/sync_smoke.out; \
    wait "$fixture_pid" || true; \
    cat /tmp/syncfix.log >&2; \
    grep -Fq 'PASS sync_smoke' /tmp/sync_smoke.out; \
    grep -Fq 'PASS all 6 connections had the correct connectionCount and lastCloseReason' /tmp/syncfix.log

COPY examples ./examples

RUN set -eu; \
    files=$(find examples -name '*.v' -o -name '*.vh'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      if awk 'length > 120 { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over 120 columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS verilog examples style"

# ---------------------------------------------------------------------------
# convex_test: client/convex.v's call() facade -- the request envelope it
# builds and both response shapes Convex's HTTP API returns (a successful
# query/mutation and a function-level failure with structured errorData) --
# against the approved test deployment, over the same TLS-verified channel
# tls_smoke and http_smoke already prove above. Real network, not a fixture,
# matching http_smoke's own already-approved precedent for this exact
# deployment and demo module.
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/convex_test.vvp client/convex_transport.v client/convex_buffer.v \
      client/convex_http.v client/convex_sha1.v client/convex_base64.v \
      client/convex_websocket.v client/convex_sync.v client/convex.v \
      client/tests/convex_test.v; \
    timeout 30 vvp -M. -mnative /tmp/convex_test.vvp | tee /tmp/convex_test.out; \
    grep -Fq 'PASS convex_test' /tmp/convex_test.out

# ---------------------------------------------------------------------------
# The NDJSON adapter protocol v1 executable (test infrastructure, not part
# of the educational client API -- AGENTS.md's "Conformance executable"
# section). Compiled once here; every scenario below reuses this same
# /tmp/adapter.vvp, the same "elaborate once, exercise repeatedly" shape
# vhdl/Dockerfile uses for its own adapter.
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/adapter.vvp client/convex_transport.v client/convex_buffer.v \
      client/convex_http.v client/convex_sha1.v client/convex_base64.v \
      client/convex_websocket.v client/convex_sync.v client/convex.v \
      client/tests/conformance/adapter.v; \
    echo "PASS adapter elaborate"

# adapterhttpfix.c: a one-shot HTTP fixture for the adapter's plain
# query/mutation/action calls -- the same drain-request-then-replay-one-
# canned-response role tcpfix.c plays above, factored out under its own
# name because this one speaks real HTTP framing (Content-Length) rather
# than tcpfix's fixed two-line exchange.
RUN <<'ADAPTERHTTPFIX_EOF'
set -eu
cat > /tmp/adapterhttpfix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: adapterhttpfix port responsefile\n"); return 1; }
    int port = atoi(argv[1]);
    FILE *rf = fopen(argv[2], "rb");
    if (!rf) { perror("fopen"); return 1; }
    fseek(rf, 0, SEEK_END);
    long rlen = ftell(rf);
    fseek(rf, 0, SEEK_SET);
    char *resp = malloc((size_t)rlen);
    if (fread(resp, 1, (size_t)rlen, rf) != (size_t)rlen) return 1;
    fclose(rf);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(fd, 1);
    int c = accept(fd, NULL, NULL);
    if (c < 0) { perror("accept"); return 1; }

    char drain[8192];
    int total = 0;
    while (total < (int)sizeof(drain)) {
        char b;
        ssize_t n = read(c, &b, 1);
        if (n <= 0) break;
        drain[total++] = b;
        if (total >= 4 && drain[total-4]=='\r' && drain[total-3]=='\n' &&
            drain[total-2]=='\r' && drain[total-1]=='\n') break;
    }
    ssize_t off = 0;
    while (off < rlen) {
        ssize_t n = write(c, resp + off, (size_t)(rlen - off));
        if (n <= 0) break;
        off += n;
    }
    close(c);
    close(fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/adapterhttpfix /tmp/adapterhttpfix.c
ADAPTERHTTPFIX_EOF

# Scenario A: a real query call through the adapter, over stdin/stdout.
RUN set -eu; \
    printf '{"status":"success","value":{"count":5},"logLines":[]}' > /tmp/a-body.txt; \
    aclen=$(wc -c < /tmp/a-body.txt | tr -d ' '); \
    { \
      printf 'HTTP/1.1 200 OK\r\n'; \
      printf 'Content-Type: application/json\r\n'; \
      printf 'Content-Length: %s\r\n\r\n' "$aclen"; \
      cat /tmp/a-body.txt; \
    } > /tmp/a-resp.bin; \
    /tmp/adapterhttpfix 44210 /tmp/a-resp.bin & \
    sleep 1; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"h1","op":"hello"}' \
      '{"id":"q1","op":"query","path":"demo:state","args":{}}' \
      '{"id":"c1","op":"close"}' \
    > /tmp/scenario-a.in; \
    CONVEX_URL=http://127.0.0.1:44210 timeout 20 vvp -M. -mnative /tmp/adapter.vvp \
      < /tmp/scenario-a.in > /tmp/scenario-a.out 2>/tmp/scenario-a.err; \
    code=$?; \
    wait; \
    echo "adapter exit: $code"; cat /tmp/scenario-a.out; cat /tmp/scenario-a.err >&2; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/scenario-a.out; \
    grep -Fq '"language":"verilog"' /tmp/scenario-a.out; \
    grep -Fq '"type":"result"' /tmp/scenario-a.out; \
    grep -Fq '"count":5' /tmp/scenario-a.out; \
    grep -Fq '"type":"closed"' /tmp/scenario-a.out

# adapterlivefix.c: a Live fixture for the adapter's own subscribe/
# debugDisconnect/unsubscribe wiring specifically -- deliberately NOT a
# repeat of syncfix.c's own six-connection reconnect proof above (that
# already proves convex_sync.v's reconnect semantics in full); this one
# only has to prove the ADAPTER carries a subscription value out over
# NDJSON and that debugDisconnect actually produces a second real TCP
# connection, so two connections and one value change are enough.
RUN <<'ADAPTERLIVEFIX_EOF'
set -eu
cat > /tmp/adapterlivefix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

static int read_full(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char *)buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}

static void write_full(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)buf + off, n - off);
        if (w <= 0) { fprintf(stderr, "adapterlivefix: write failed\n"); exit(1); }
        off += (size_t)w;
    }
}

static void read_handshake(int fd, char *key_out, size_t key_cap) {
    char buf[8192];
    size_t len = 0;
    key_out[0] = '\0';
    for (;;) {
        if (len >= sizeof(buf) - 1) exit(1);
        ssize_t r = read(fd, buf + len, 1);
        if (r <= 0) exit(1);
        len += (size_t)r;
        buf[len] = '\0';
        if (len >= 4 && memcmp(buf + len - 4, "\r\n\r\n", 4) == 0) break;
    }
    char *line = buf;
    for (;;) {
        char *eol = strstr(line, "\r\n");
        if (!eol) break;
        *eol = '\0';
        if (strncasecmp(line, "Sec-WebSocket-Key:", 18) == 0) {
            char *v = line + 18;
            while (*v == ' ') v++;
            snprintf(key_out, key_cap, "%s", v);
        }
        if (eol == line) break;
        line = eol + 2;
    }
    if (key_out[0] == '\0') exit(1);
}

static void compute_accept(const char *key, char *accept_out) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char joined[256];
    snprintf(joined, sizeof(joined), "%s%s", key, guid);
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)joined, strlen(joined), digest);
    int n = EVP_EncodeBlock((unsigned char *)accept_out, digest, SHA_DIGEST_LENGTH);
    accept_out[n] = '\0';
}

static void send_text_frame(int fd, const char *text) {
    size_t len = strlen(text);
    unsigned char hdr[4];
    size_t hlen = 0;
    hdr[hlen++] = 0x81;
    if (len < 126) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xFF);
        hdr[hlen++] = (unsigned char)(len & 0xFF);
    }
    write_full(fd, hdr, hlen);
    write_full(fd, text, len);
}

static void read_masked_text_frame(int fd, char *out, size_t cap) {
    unsigned char hdr[2];
    if (read_full(fd, hdr, 2) < 0) exit(1);
    uint64_t plen = hdr[1] & 0x7F;
    if (plen == 126) {
        unsigned char ext[2];
        if (read_full(fd, ext, 2) < 0) exit(1);
        plen = ((uint64_t)ext[0] << 8) | ext[1];
    }
    unsigned char mkey[4];
    if (read_full(fd, mkey, 4) < 0) exit(1);
    if (plen >= cap) exit(1);
    if (plen > 0 && read_full(fd, out, plen) < 0) exit(1);
    for (uint64_t i = 0; i < plen; i++) out[i] = (char)((unsigned char)out[i] ^ mkey[i % 4]);
    out[plen] = '\0';
}


static void ts_b64(uint64_t v, char *out) {
    unsigned char bytes[8];
    for (int i = 0; i < 8; i++) { bytes[i] = (unsigned char)(v & 0xFF); v >>= 8; }
    int n = EVP_EncodeBlock((unsigned char *)out, bytes, 8);
    out[n] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: adapterlivefix port\n"); return 1; }
    int port = atoi(argv[1]);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(listen_fd, 2);

    uint64_t ts_counter = 1;
    int qs_counter = 0;

    for (int conn_num = 0; conn_num < 2; conn_num++) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) { perror("accept"); return 1; }
        fprintf(stderr, "adapterlivefix: accepted connection %d\n", conn_num);
        char key[512], accept_val[64], resp[512];
        read_handshake(fd, key, sizeof(key));
        compute_accept(key, accept_val);
        int rn = snprintf(resp, sizeof(resp),
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n", accept_val);
        write_full(fd, resp, (size_t)rn);

        char msg[8192];
        read_masked_text_frame(fd, msg, sizeof(msg)); /* Connect */
        read_masked_text_frame(fd, msg, sizeof(msg)); /* ModifyQuerySet Add */
        int query_id = 1;
        (void)query_id;

        char ts1[16], text[1024];
        ts_b64(ts_counter, ts1); ts_counter++;
        snprintf(text, sizeof(text),
            "{\"type\":\"Transition\","
            "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":%d}}]}",
            qs_counter, ts1, qs_counter + 1, ts1, conn_num);
        qs_counter++;
        send_text_frame(fd, text);

        if (conn_num == 0) {
            /* One genuine external mutation on the first connection only,
             * so the transcript shows two distinct delivered values
             * (0, then 1) before the debugDisconnect this scenario's
             * own script drives next. */
            char ts2[16];
            ts_b64(ts_counter, ts2); ts_counter++;
            snprintf(text, sizeof(text),
                "{\"type\":\"Transition\","
                "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
                "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
                "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":1}}]}",
                qs_counter, ts2, qs_counter + 1, ts2);
            qs_counter++;
            send_text_frame(fd, text);
        }

        char discard[64];
        read(fd, discard, sizeof(discard)); /* blocks until debugDisconnect (EOF) or teardown */
        close(fd);
    }
    close(listen_fd);
    fprintf(stderr, "adapterlivefix: PASS both connections completed\n");
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/adapterlivefix /tmp/adapterlivefix.c -lssl -lcrypto
ADAPTERLIVEFIX_EOF

# Scenario B: a Live subscription, an asynchronous subscription event
# delivered with no new command pending, a debugDisconnect (a real second
# TCP connection to adapterlivefix, proving the command actually reaches
# convex_sync.v's own force_disconnect rather than only being acked), and
# the post-reconnect value -- fed through a FIFO so the adapter's stdin
# genuinely blocks between commands instead of a regular file's always-
# ready poll semantics reporting EOF the instant static input runs out.
RUN set -eu; \
    timeout 25 /tmp/adapterlivefix 44211 2>/tmp/adapterlivefix.log & \
    sleep 1; \
    mkfifo /tmp/scenario-b.fifo; \
    ( \
      exec 3> /tmp/scenario-b.fifo; \
      printf '%s\n' '{"protocolVersion":1,"id":"h1","op":"hello"}' >&3; \
      printf '%s\n' '{"id":"s1","op":"subscribe","subscriptionId":"sub1","path":"demo:state","args":{}}' >&3; \
      sleep 3; \
      printf '%s\n' '{"id":"d1","op":"debugDisconnect"}' >&3; \
      sleep 3; \
      printf '%s\n' '{"id":"u1","op":"unsubscribe","subscriptionId":"sub1"}' >&3; \
      printf '%s\n' '{"id":"c1","op":"close"}' >&3; \
      exec 3>&-; \
    ) & \
    CONVEX_URL=http://127.0.0.1:44211 timeout 30 vvp -M. -mnative /tmp/adapter.vvp \
      < /tmp/scenario-b.fifo > /tmp/scenario-b.out 2>/tmp/scenario-b.err; \
    code=$?; \
    wait; \
    echo "adapter exit: $code"; cat /tmp/scenario-b.out; cat /tmp/scenario-b.err >&2; cat /tmp/adapterlivefix.log >&2; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/scenario-b.out; \
    grep -Fq '"type":"subscription","subscriptionId":"sub1","value":{"count":0}' /tmp/scenario-b.out; \
    grep -Fq '"type":"subscription","subscriptionId":"sub1","value":{"count":1}' /tmp/scenario-b.out; \
    grep -Fq '"id":"d1","type":"ack"' /tmp/scenario-b.out; \
    grep -Fq '"id":"u1","type":"ack"' /tmp/scenario-b.out; \
    grep -Fq '"id":"c1","type":"closed"' /tmp/scenario-b.out; \
    grep -Fq 'adapterlivefix: PASS both connections completed' /tmp/adapterlivefix.log

# Scenario C: ADAPTER_LISTEN's TCP mode, proving CMD_LISTEN/CMD_ACCEPT
# actually carry the adapter protocol, not only stdin/stdout. hello/close
# need no CONVEX_URL, so no fixture backend is needed here. Uses bash
# explicitly for its /dev/tcp pseudo-device, which this image's default
# /bin/sh (dash) does not support.
RUN bash -c '\
    set -eu; \
    ADAPTER_LISTEN=127.0.0.1:44212 timeout 20 vvp -M. -mnative /tmp/adapter.vvp \
      > /tmp/scenario-c.out 2>/tmp/scenario-c.err & \
    server_pid=$!; \
    sleep 1; \
    exec 3<>/dev/tcp/127.0.0.1/44212; \
    printf "%s\n" "{\"protocolVersion\":1,\"id\":\"h1\",\"op\":\"hello\"}" >&3; \
    timeout 5 head -n1 <&3 > /tmp/scenario-c.client.out; \
    printf "%s\n" "{\"id\":\"c1\",\"op\":\"close\"}" >&3; \
    timeout 5 head -n1 <&3 >> /tmp/scenario-c.client.out; \
    exec 3>&-; \
    wait "$server_pid"; \
    code=$?; \
    echo "adapter exit: $code"; cat /tmp/scenario-c.client.out; cat /tmp/scenario-c.err >&2; \
    test "$code" -eq 0; \
    grep -Fq "\"type\":\"ready\"" /tmp/scenario-c.client.out; \
    grep -Fq "\"type\":\"closed\"" /tmp/scenario-c.client.out \
'

# ---------------------------------------------------------------------------
# Scenario D: this adapter's own Live-delivery buffering choice, proven
# under a stopped reader (AGENTS.md's "Conformance executable" section).
# client/tests/conformance/adapter.v's own header comment explains the
# design: conv.sync already stores at most one CURRENT value per active
# subscription (client/convex_sync.v's sub_value_json, overwritten in
# place, never a per-update history), so this adapter's own "queue" is
# just a fixed MAX_SUBS=8-sized array of "have I emitted the CURRENT
# version yet" flags. The conservative byte budget this proves: MAX_SUBS
# (8) subscription mailbox slots at up to convex_websocket.v's own
# MSG_CAP (1 MiB, the largest a single reassembled /api/sync message may
# be) each, plus the adapter's own outbuf (1 MiB) and conv.sync's shared
# ws.msg scratch (1 MiB) -- about 11 MiB, comfortably under the shared
# 128 MiB adapter memory limit.
#
# adapterfloodfix connects once, completes the Add handshake, then sends
# FLOOD_COUNT Transitions (~350 KB total, comfortably over a 64 KB pipe
# buffer) back to back with no pacing at all while this stage
# deliberately holds the adapter's own stdout unread for several
# seconds: the pipe's read descriptor is opened (so the adapter's writes
# do not block forever on open()) but nothing drains it, so the kernel
# pipe buffer fills and every write past that point blocks the adapter's
# own single I/O worker -- and because that same worker also owns the
# WebSocket read loop (this file's own header comment, and the Live
# acceptance section of AGENTS.md, require exactly this single-owner
# shape), a blocked stdout write stalls new Live reads too, so the
# fixture's own sends back up over real TCP flow control rather than
# this client ever buffering an unbounded backlog to catch up on later.
# This run's own unsubscribe/close commands race the flood (the same
# single loop fairly interleaves a ready command with draining one more
# Live event each tick), so the exact number of flood values delivered
# before unsubscribe is not deterministic and this stage does not assert
# one; what it does assert is the concrete, load-bearing claim: peak
# VmRSS while the pipe was blocked stays far under the shared 128 MiB
# adapter memory limit, at least one well-formed value was delivered,
# and the session still ends in a clean ack/closed rather than a hang
# or a crash.
# ---------------------------------------------------------------------------
RUN <<'ADAPTERFLOODFIX_EOF'
set -eu
cat > /tmp/adapterfloodfix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

#define FLOOD_COUNT 4000

static int read_full(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char *)buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}
static void write_full(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)buf + off, n - off);
        if (w <= 0) exit(1);
        off += (size_t)w;
    }
}
static void read_handshake(int fd, char *key_out, size_t key_cap) {
    char buf[8192];
    size_t len = 0;
    key_out[0] = '\0';
    for (;;) {
        if (len >= sizeof(buf) - 1) exit(1);
        ssize_t r = read(fd, buf + len, 1);
        if (r <= 0) exit(1);
        len += (size_t)r;
        buf[len] = '\0';
        if (len >= 4 && memcmp(buf + len - 4, "\r\n\r\n", 4) == 0) break;
    }
    char *line = buf;
    for (;;) {
        char *eol = strstr(line, "\r\n");
        if (!eol) break;
        *eol = '\0';
        if (strncasecmp(line, "Sec-WebSocket-Key:", 18) == 0) {
            char *v = line + 18;
            while (*v == ' ') v++;
            snprintf(key_out, key_cap, "%s", v);
        }
        if (eol == line) break;
        line = eol + 2;
    }
    if (key_out[0] == '\0') exit(1);
}
static void compute_accept(const char *key, char *accept_out) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char joined[256];
    snprintf(joined, sizeof(joined), "%s%s", key, guid);
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)joined, strlen(joined), digest);
    int n = EVP_EncodeBlock((unsigned char *)accept_out, digest, SHA_DIGEST_LENGTH);
    accept_out[n] = '\0';
}
static void send_text_frame(int fd, const char *text) {
    size_t len = strlen(text);
    unsigned char hdr[4];
    size_t hlen = 0;
    hdr[hlen++] = 0x81;
    if (len < 126) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xFF);
        hdr[hlen++] = (unsigned char)(len & 0xFF);
    }
    write_full(fd, hdr, hlen);
    write_full(fd, text, len);
}
static void read_masked_text_frame(int fd, char *out, size_t cap) {
    unsigned char hdr[2];
    if (read_full(fd, hdr, 2) < 0) exit(1);
    uint64_t plen = hdr[1] & 0x7F;
    if (plen == 126) {
        unsigned char ext[2];
        if (read_full(fd, ext, 2) < 0) exit(1);
        plen = ((uint64_t)ext[0] << 8) | ext[1];
    }
    unsigned char mkey[4];
    if (read_full(fd, mkey, 4) < 0) exit(1);
    if (plen >= cap) exit(1);
    if (plen > 0 && read_full(fd, out, plen) < 0) exit(1);
    for (uint64_t i = 0; i < plen; i++) out[i] = (char)((unsigned char)out[i] ^ mkey[i % 4]);
    out[plen] = '\0';
}
static void ts_b64(uint64_t v, char *out) {
    unsigned char bytes[8];
    for (int i = 0; i < 8; i++) { bytes[i] = (unsigned char)(v & 0xFF); v >>= 8; }
    int n = EVP_EncodeBlock((unsigned char *)out, bytes, 8);
    out[n] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: adapterfloodfix port\n"); return 1; }
    int port = atoi(argv[1]);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(listen_fd, 1);

    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) { perror("accept"); return 1; }
    char key[512], accept_val[64], resp[512];
    read_handshake(fd, key, sizeof(key));
    compute_accept(key, accept_val);
    int rn = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n", accept_val);
    write_full(fd, resp, (size_t)rn);

    char msg[8192];
    read_masked_text_frame(fd, msg, sizeof(msg)); /* Connect */
    read_masked_text_frame(fd, msg, sizeof(msg)); /* ModifyQuerySet Add */

    uint64_t ts_counter = 1;
    for (int i = 0; i < FLOOD_COUNT; i++) {
        char ts[16], text[256];
        ts_b64(ts_counter, ts); ts_counter++;
        snprintf(text, sizeof(text),
            "{\"type\":\"Transition\","
            "\"startVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"endVersion\":{\"querySet\":%d,\"identity\":0,\"ts\":\"%s\"},"
            "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":%d}}]}",
            i, ts, i + 1, ts, i);
        send_text_frame(fd, text);
    }
    fprintf(stderr, "adapterfloodfix: sent %d Transitions with no pacing\n", FLOOD_COUNT);

    char discard[64];
    read(fd, discard, sizeof(discard));
    close(fd);
    close(listen_fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/adapterfloodfix /tmp/adapterfloodfix.c -lssl -lcrypto
ADAPTERFLOODFIX_EOF

RUN bash -c '\
    set -eu; \
    timeout 25 /tmp/adapterfloodfix 44213 2>/tmp/adapterfloodfix.log & \
    fixture_pid=$!; \
    sleep 1; \
    mkfifo /tmp/scenario-d-in.fifo /tmp/scenario-d-out.fifo; \
    ( \
      exec 3> /tmp/scenario-d-in.fifo; \
      printf "%s\n" "{\"protocolVersion\":1,\"id\":\"h1\",\"op\":\"hello\"}" >&3; \
      printf "%s\n" "{\"id\":\"s1\",\"op\":\"subscribe\",\"subscriptionId\":\"sub1\",\"path\":\"demo:state\",\"args\":{}}" >&3; \
      sleep 12; \
      printf "%s\n" "{\"id\":\"u1\",\"op\":\"unsubscribe\",\"subscriptionId\":\"sub1\"}" >&3; \
      printf "%s\n" "{\"id\":\"c1\",\"op\":\"close\"}" >&3; \
      exec 3>&-; \
    ) & \
    CONVEX_URL=http://127.0.0.1:44213 timeout 30 vvp -M. -mnative /tmp/adapter.vvp \
      < /tmp/scenario-d-in.fifo > /tmp/scenario-d-out.fifo 2>/tmp/scenario-d.err & \
    adapter_pid=$!; \
    ( \
      exec 4< /tmp/scenario-d-out.fifo; \
      sleep 6; \
      peak=0; \
      for i in 1 2 3 4 5; do \
        rss=$(awk "/VmRSS/{print \$2}" /proc/"$adapter_pid"/status 2>/dev/null || echo 0); \
        test "$rss" -gt "$peak" 2>/dev/null && peak=$rss || true; \
        sleep 1; \
      done; \
      echo "peak VmRSS while stdout was unread: ${peak} kB" > /tmp/scenario-d.rss; \
      cat <&4 > /tmp/scenario-d.out; \
    ) & \
    reader_pid=$!; \
    wait "$adapter_pid"; \
    code=$?; \
    wait "$reader_pid" "$fixture_pid" || true; \
    echo "adapter exit: $code"; \
    cat /tmp/scenario-d.rss; \
    cat /tmp/adapterfloodfix.log >&2; \
    wc -l /tmp/scenario-d.out; \
    tail -c 4096 /tmp/scenario-d.out; \
    cat /tmp/scenario-d.err >&2; \
    test "$code" -eq 0; \
    grep -Fq "adapterfloodfix: sent 4000 Transitions with no pacing" /tmp/adapterfloodfix.log; \
    grep -Fq "\"id\":\"c1\",\"type\":\"closed\"" /tmp/scenario-d.out; \
    sub_lines=$(grep -c "\"type\":\"subscription\"" /tmp/scenario-d.out); \
    echo "subscription events actually emitted before unsubscribe: $sub_lines (of 4000 sent, ~350KB total, over a 64KB pipe buffer)"; \
    test "$sub_lines" -gt 0; \
    last_value=$(grep -o "\"subscriptionId\":\"sub1\",\"value\":{\"count\":[0-9]*}" /tmp/scenario-d.out | tail -n1); \
    echo "last delivered value before unsubscribe: $last_value"; \
    test -n "$last_value"; \
    peak_kb=$(grep -oE "[0-9]+ kB" /tmp/scenario-d.rss | awk "{print \$1}"); \
    test -n "$peak_kb"; \
    echo "peak VmRSS while stdout was unread: ${peak_kb} kB (bound: 131072 kB = 128 MiB)"; \
    test "$peak_kb" -lt 131072 \
'

# ---------------------------------------------------------------------------
# The canonical example. Compiled once, first proven to fail loudly (nothing
# on stdout, "CONVEX_URL is required" on stderr, exit 1) with no deployment
# configured, matching this project's other native clients' no-configuration
# failure path.
# ---------------------------------------------------------------------------
RUN set -eu; \
    iverilog -g2012 -L. -mnative -I. \
      -o /tmp/example.vvp client/convex_transport.v client/convex_buffer.v \
      client/convex_http.v client/convex_sha1.v client/convex_base64.v \
      client/convex_websocket.v client/convex_sync.v client/convex.v \
      examples/basics/main.v; \
    code=0; \
    vvp -M. -mnative /tmp/example.vvp >/tmp/example-noconfig.out 2>/tmp/example-noconfig.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example-noconfig.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example-noconfig.err

# Then proven against a real deployment: examplefix.c answers /api/query,
# /api/mutation and the /api/sync WebSocket upgrade on one port (forking a
# handler per accepted connection so the persistent Live connection and the
# one-shot HTTP calls run concurrently), and only sends the post-mutation
# Live Transition after a delay generous enough for the example's own HTTP
# mutation call to have already completed on its own separate connection --
# so "live updated count" is a real, separately arriving Live event, not a
# value already known from the mutation response. The exact transcript is
# checked against this project's shared expected output (the same six lines
# _shared/examples/basics.expected.txt records), not merely "did it exit 0".
RUN <<'EXAMPLEFIX_EOF'
set -eu
cat > /tmp/examplefix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

static void send_http_response(int c, const char *body) {
    char hdr[256];
    int hlen = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n",
        (int)strlen(body));
    write(c, hdr, (size_t)hlen);
    write(c, body, strlen(body));
}

static int read_full(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, (char *)buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return 0;
}
static void write_full(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, (const char *)buf + off, n - off);
        if (w <= 0) exit(1);
        off += (size_t)w;
    }
}
static void compute_accept(const char *key, char *accept_out) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char joined[256];
    snprintf(joined, sizeof(joined), "%s%s", key, guid);
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)joined, strlen(joined), digest);
    int n = EVP_EncodeBlock((unsigned char *)accept_out, digest, SHA_DIGEST_LENGTH);
    accept_out[n] = '\0';
}
static void send_text_frame(int fd, const char *text) {
    size_t len = strlen(text);
    unsigned char hdr[4];
    size_t hlen = 0;
    hdr[hlen++] = 0x81;
    if (len < 126) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xFF);
        hdr[hlen++] = (unsigned char)(len & 0xFF);
    }
    write_full(fd, hdr, hlen);
    write_full(fd, text, len);
}
static void read_masked_text_frame(int fd, char *out, size_t cap) {
    unsigned char hdr[2];
    if (read_full(fd, hdr, 2) < 0) exit(1);
    uint64_t plen = hdr[1] & 0x7F;
    if (plen == 126) {
        unsigned char ext[2];
        if (read_full(fd, ext, 2) < 0) exit(1);
        plen = ((uint64_t)ext[0] << 8) | ext[1];
    }
    unsigned char mkey[4];
    if (read_full(fd, mkey, 4) < 0) exit(1);
    if (plen >= cap) exit(1);
    if (plen > 0 && read_full(fd, out, plen) < 0) exit(1);
    for (uint64_t i = 0; i < plen; i++) out[i] = (char)((unsigned char)out[i] ^ mkey[i % 4]);
    out[plen] = '\0';
}
static void ts_b64(uint64_t v, char *out) {
    unsigned char bytes[8];
    for (int i = 0; i < 8; i++) { bytes[i] = (unsigned char)(v & 0xFF); v >>= 8; }
    int n = EVP_EncodeBlock((unsigned char *)out, bytes, 8);
    out[n] = '\0';
}
static int contains(const unsigned char *buf, int len, const char *needle) {
    int nlen = (int)strlen(needle);
    for (int i = 0; i + nlen <= len; i++) {
        if (memcmp(buf + i, needle, (size_t)nlen) == 0) return 1;
    }
    return 0;
}

static void handle_connection(int c) {
    unsigned char req[8192];
    int total = 0;
    while (total < (int)sizeof(req)) {
        unsigned char b;
        ssize_t n = read(c, &b, 1);
        if (n <= 0) { close(c); _exit(0); }
        req[total++] = b;
        if (total >= 4 && req[total-4]=='\r' && req[total-3]=='\n' &&
            req[total-2]=='\r' && req[total-1]=='\n') break;
    }
    if (contains(req, total, "Upgrade: websocket") || contains(req, total, "Upgrade: WebSocket")) {
        /* The generic header loop above already consumed the whole
         * handshake up to CRLFCRLF into req[], so the Sec-WebSocket-Key
         * is parsed out of that same buffer here rather than re-reading
         * it from the socket a second time. */
        char key[512] = {0};
        char *line = (char *)req;
        req[total] = '\0';
        for (;;) {
            char *eol = strstr(line, "\r\n");
            if (!eol) break;
            *eol = '\0';
            if (strncasecmp(line, "Sec-WebSocket-Key:", 18) == 0) {
                char *v = line + 18;
                while (*v == ' ') v++;
                snprintf(key, sizeof(key), "%s", v);
            }
            if (eol == line) break;
            line = eol + 2;
        }
        char accept_val[64], resp[512];
        compute_accept(key, accept_val);
        int rn = snprintf(resp, sizeof(resp),
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_val);
        write_full(c, resp, (size_t)rn);

        char msg[8192];
        read_masked_text_frame(c, msg, sizeof(msg)); /* Connect */
        read_masked_text_frame(c, msg, sizeof(msg)); /* ModifyQuerySet Add */

        char ts1[16], text[512];
        ts_b64(1, ts1);
        snprintf(text, sizeof(text),
            "{\"type\":\"Transition\","
            "\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"%s\"},"
            "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},"
            "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":0}}]}",
            ts1, ts1);
        send_text_frame(c, text);

        sleep(3);

        char ts2[16];
        ts_b64(2, ts2);
        snprintf(text, sizeof(text),
            "{\"type\":\"Transition\","
            "\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"%s\"},"
            "\"endVersion\":{\"querySet\":1,\"identity\":1,\"ts\":\"%s\"},"
            "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":1}}]}",
            ts1, ts2);
        send_text_frame(c, text);

        char discard[64];
        read(c, discard, sizeof(discard));
    } else if (contains(req, total, "/api/query")) {
        send_http_response(c, "{\"status\":\"success\",\"value\":{\"count\":0},\"logLines\":[]}");
    } else if (contains(req, total, "/api/mutation")) {
        send_http_response(c,
            "{\"status\":\"success\","
            "\"value\":{\"applied\":true,\"state\":{\"count\":1}},"
            "\"logLines\":[]}");
    }
    close(c);
    _exit(0);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: examplefix port\n"); return 1; }
    int port = atoi(argv[1]);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(fd, 8);

    /* Exactly three TCP connections: one plain HTTP /api/query, one
     * WebSocket connection that stays open for the whole Live
     * subscription, and one plain HTTP /api/mutation. */
    for (int i = 0; i < 3; i++) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) continue;
        pid_t pid = fork();
        if (pid == 0) {
            close(fd);
            handle_connection(c);
            _exit(0);
        }
        close(c);
    }
    while (wait(NULL) > 0) {}
    close(fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/examplefix /tmp/examplefix.c -lssl -lcrypto
EXAMPLEFIX_EOF

RUN set -eu; \
    printf '%s\n' \
      'current count: 0' \
      'live initial count: 0' \
      'mutation applied: true' \
      'mutation count: 1' \
      'live updated count: 1' \
      'verified count: 0 -> 1' \
    > /tmp/example-expected.txt; \
    timeout 25 /tmp/examplefix 44214 & \
    sleep 1; \
    CONVEX_URL=http://127.0.0.1:44214 \
      timeout 20 vvp -M. -mnative /tmp/example.vvp +room=verilog-docker-test > /tmp/example.out; \
    code=$?; \
    wait; \
    echo "example exit: $code"; cat /tmp/example.out; \
    test "$code" -eq 0; \
    diff /tmp/example.out /tmp/example-expected.txt; \
    echo "PASS example transcript matches the fixture's expected values"

# ---------------------------------------------------------------------------
# Stage the two shipped bytecode programs and probe the adapter's own
# probe (hello, then close) from the exact bytecode that will ship.
# Icarus is a compile-then-interpret toolchain: `iverilog` (the front end)
# turns Verilog source into a `.vvp` bytecode file, and `vvp` (a completely
# separate binary, the actual runtime executor) interprets that bytecode --
# there is no linked native ELF the way GHDL's LLVM backend produces for
# vhdl/. The runtime images below therefore ship `vvp` plus this client's
# own `native.vpi` plus the two `.vvp` bytecode files, and never ship
# `iverilog`/`ivl`/`ivlpp` (the compiler front end and code generator) --
# `vvp` genuinely cannot compile a design, only execute one already
# compiled, so shipping it is not shipping a toolchain the way shipping
# `iverilog` itself would be.
# ---------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p /build; \
    cp /tmp/adapter.vvp /build/convex-adapter.vvp; \
    cp /tmp/example.vvp /build/convex-example.vvp; \
    cp /project/native.vpi /build/native.vpi

RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    code=0; \
    CONVEX_URL=http://127.0.0.1:1 vvp -M/build -mnative /build/convex-adapter.vvp \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out 2>/tmp/adapter-probe.err \
      || code=$?; \
    echo "adapter exit code: $code"; \
    echo "--- stdout ---"; cat /tmp/adapter-probe.out; \
    echo "--- stderr ---"; cat /tmp/adapter-probe.err; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"verilog"' /tmp/adapter-probe.out; \
    grep -Fq '"runtime":"iverilog-11.0-stable-debian-11.0-1.1+b1"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# ---------------------------------------------------------------------------
# Build the runtime closure: `vvp` itself, the small subset of Icarus's own
# default VPI plugins vvp needs for ordinary system tasks ($display,
# $finish, $value$plusargs and friends -- system.vpi/v2005_math.vpi/
# v2009.vpi/va_math.vpi, plus vvp's own module-search .conf files), and
# this client's own native.vpi and its OpenSSL/libc closure -- deliberately
# NOT the compiler-only files that live in the exact same package and the
# exact same directory (ivl, ivlpp, every *.tgt code-generator backend,
# vhdlpp, cadpli.vpl, and the C headers under include/), which are never
# copied into /closure at all. iverilog-vpi (the build helper script) is
# similarly never copied; native.vpi was already built once above, in the
# test stage, and ships as a prebuilt artifact instead.
#
# AGENTS.md requires /bin/sh and basic POSIX text tools in every runtime
# image until the shared example verifier is redesigned (see vhdl/Dockerfile
# for the identical requirement and the identical small coreutils set),
# even though neither convex-adapter nor convex-example themselves call out
# to a shell or a text tool.
# ---------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p /closure/bin /closure/usr/bin /closure/usr/lib/x86_64-linux-gnu/ivl \
             /closure/etc/ssl/certs \
             /closure/usr/lib/x86_64-linux-gnu/ossl-modules \
             /closure/usr/lib/x86_64-linux-gnu \
             /closure/usr/local/bin /closure/usr/local/lib \
             /closure/tmp; \
    chmod 1777 /closure/tmp; \
    chmod 755 /closure/usr/local /closure/usr/local/bin /closure/usr/local/lib; \
    cp -aL /usr/bin/vvp /closure/usr/bin/vvp; \
    for name in system.vpi v2005_math.vpi v2009.vpi va_math.vpi \
                vhdl_sys.vpi vhdl_textio.vpi vvp.conf vvp-s.conf; do \
      cp -aL /usr/lib/x86_64-linux-gnu/ivl/"$name" \
             /closure/usr/lib/x86_64-linux-gnu/ivl/"$name"; \
    done; \
    for name in cat cut head tail tr sort uniq wc uname grep sed id; do \
      cp -aL "$(command -v "$name")" /closure/usr/bin/"$name"; \
    done; \
    cp -aL /usr/bin/mawk /closure/usr/bin/awk; \
    cp -aL /bin/dash /closure/bin/sh; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /closure/etc/ssl/certs/; \
    cp -aL /etc/ssl/openssl.cnf /closure/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /closure/etc/nsswitch.conf; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
           /closure/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL /lib/x86_64-linux-gnu/"$lib" \
             /closure/usr/lib/x86_64-linux-gnu/"$lib"; \
    done; \
    for round in 1 2 3; do \
      for elf in /closure/usr/bin/vvp \
                 /closure/usr/lib/x86_64-linux-gnu/ivl/*.vpi \
                 /build/native.vpi \
                 /closure/bin/sh \
                 /closure/usr/bin/*; do \
        ldd "$elf" 2>/dev/null \
          | awk '{ for (i = 1; i <= NF; i++) \
                     if (substr($i, 1, 1) == "/") print $i }'; \
      done \
        | sort -u \
        | while read -r lib; do \
            test -e "/closure$lib" || { \
              mkdir -p "/closure$(dirname "$lib")"; \
              cp -aL "$lib" "/closure$(dirname "$lib")/"; \
            }; \
          done; \
    done; \
    cp -aL /build/native.vpi /closure/usr/lib/x86_64-linux-gnu/ivl/native.vpi

# The room argument reaches the example through Icarus's own real plusarg
# passthrough (`vvp script.vvp +room=...`), unlike vhdl/'s GHDL-generated
# standalone executable, which does not accept a real host argv the same
# way (see vhdl/Dockerfile's own comment on why it uses EXAMPLE_ROOM
# instead) -- Icarus's vvp genuinely forwards its own trailing `+...` argv
# into the running design's $value$plusargs/$test$plusargs calls, confirmed
# directly against this exact toolchain rather than assumed.
RUN set -eu; \
    mkdir -p /entry; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# The verifier passes a unique room as the first argument.' \
      'if [ "$#" -gt 0 ]; then' \
      '  exec /usr/bin/vvp -M/usr/lib/x86_64-linux-gnu/ivl -mnative \' \
      '    /usr/local/lib/convex-example.vvp "+room=$1"' \
      'fi' \
      'exec /usr/bin/vvp -M/usr/lib/x86_64-linux-gnu/ivl -mnative \' \
      '  /usr/local/lib/convex-example.vvp' \
      > /entry/convex-example; \
    chmod 755 /entry/convex-example

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its filesystem removed and only the
# declared closure copied back.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN set -eu; \
    set -- /bin /boot /home /lib /lib64 /media /mnt /opt /root \
           /run /sbin /srv /usr /var /etc/.pwd.lock; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) set -- "$@" "$path" ;; \
      esac; \
    done; \
    rm -rf "$@"
COPY --from=test /closure/ /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532

# Prove the policy the shared verifier depends on from inside the final
# filesystem, not from the build stage that produced it: `/bin/sh` and a
# small POSIX text-tool set exist only because AGENTS.md currently requires
# them in every runtime image; no compiler, package manager, or `iverilog`/
# `ivl` compiler front end exists anywhere in this image, so there is no
# boot-time or run-time path from the shipped `/bin/sh` back to a compiler
# -- `vvp` can only interpret bytecode already handed to it, never produce
# new bytecode from source.
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test -s "$SSL_CERT_FILE"; \
    test "$(uname -m)" = x86_64; \
    test "$(printf 'ok\n' | cat)" = ok; \
    test "$(printf 'a:b\n' | cut -d: -f2)" = b; \
    test "$(printf 'first\nsecond\n' | head -n 1)" = first; \
    test "$(printf 'first\nsecond\n' | tail -n 1)" = second; \
    test "$(printf 'a\n' | tr a A)" = A; \
    test "$(printf 'b\na\n' | sort | head -n 1)" = a; \
    test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1; \
    printf 'needle\n' | grep -Fqx needle; \
    test "$(printf 'before\n' | sed 's/before/after/')" = after; \
    test "$(printf 'value\n' | awk '{print $1}')" = value; \
    test ! -e /etc/dpkg; \
    test ! -e /var; \
    test ! -e /usr/share/doc; \
    test ! -e /usr/include; \
    test ! -e /usr/src; \
    set -- /bin/*; test "$#" -eq 1; test "$1" = /bin/sh; \
    for command_name in iverilog ivl ivlpp iverilog-vpi vhdlpp gcc cc clang \
        ld make cmake libtool apt apt-get dpkg curl wget nc netcat ssh \
        openssl node python python3 ruby perl java php go rustc cargo \
        npm pip convex bash; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test --chmod=644 --chown=65532:65532 /build/convex-example.vvp /usr/local/lib/convex-example.vvp
COPY --from=test --chmod=755 --chown=65532:65532 /entry/convex-example /usr/local/bin/convex-example-entry
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example-entry; \
    test -s /usr/local/lib/convex-example.vvp; \
    test ! -e /usr/local/lib/convex-adapter.vvp
ENTRYPOINT ["/usr/local/bin/convex-example-entry"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build verilog` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test --chmod=644 --chown=65532:65532 /build/convex-adapter.vvp /usr/local/lib/convex-adapter.vvp
USER 65532:65532
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    CONVEX_URL=http://127.0.0.1:1 \
      /usr/bin/vvp -M/usr/lib/x86_64-linux-gnu/ivl -mnative \
      /usr/local/lib/convex-adapter.vvp < /tmp/adapter-probe.in > /tmp/adapter-probe.out; \
    cat /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out
ENTRYPOINT ["/usr/bin/vvp", "-M/usr/lib/x86_64-linux-gnu/ivl", "-mnative", "/usr/local/lib/convex-adapter.vvp"]
