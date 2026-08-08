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
# (client/convex_buffer.v) and now HTTP/1.1 request/response framing
# (client/convex_http.v, proven with a real POST /api/query round trip
# to the shared demo:state query - see the http_smoke stage below) so
# far. The canonical examples/basics program, the RFC 6455 WebSocket
# layer, the /api/sync Live state machine and the conformance adapter do
# not exist yet, so no capability is claimed; see verilog/README.md. This
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
