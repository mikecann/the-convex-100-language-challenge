# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: build native.c, analyze and elaborate every VHDL unit this client
# ships with GHDL, and run every language-local suite.
#
# CHECKPOINT NOTE: this client is still under construction. Only the
# foreign-boundary primitives (native.c), the request/acknowledge circuit
# (convex_native.vhdl, convex_transport.vhdl), the byte-buffer helpers
# (convex_buffer.vhdl) and a JSON codec (convex_json.vhdl) exist so far,
# proven here by buffer_test, transport_smoke and json_test. convex_http,
# convex_ws, convex_sync, the conformance adapter and examples/basics do
# not exist yet, so this stage does not yet compile a canonical example or
# a conformance executable and no `runtime` or `example-runtime` stage
# exists below. No capability is claimed; see vhdl/README.md.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ghdl-llvm \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       binutils \
    && rm -rf /var/lib/apt/lists/*

# GHDL's version and code generator are asserted and recorded so the
# adapter (once it exists) cannot misreport the toolchain it actually ran
# on, matching this project's other from-source and translator-pinned
# native clients.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    ghdl --version 2>&1 | tee /tmp/ghdl-version.log; \
    grep -Eq '^GHDL 2\.0\.0 ' /tmp/ghdl-version.log; \
    grep -Fq 'llvm code generator' /tmp/ghdl-version.log; \
    printf 'ghdl-2.0.0-llvm' > /project/runtime-version; \
    test -s /project/runtime-version

COPY client ./client

# VHDL has no standard formatter, so the style gate is explicit: spaces
# only, no trailing blanks, a final newline, and a column limit -- the
# same discipline this project's ALGOL 60 client uses for the same reason.
RUN set -eu; \
    files=$(find client -name '*.vhdl'); \
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
    echo "PASS vhdl source style"

# The only native code in the client, compiled to an object file on its
# own so a missing or misnamed primitive is caught before GHDL ever tries
# to link against it. Its exported boundary is exactly the two scalar
# VHPIDIRECT functions declared in client/convex_native.vhdl.
RUN set -eu; \
    gcc -c -O2 -Wall -Wextra -Werror=implicit-function-declaration \
        -o /project/native.o client/native.c; \
    nm --defined-only /project/native.o | grep -q ' T cx_dispatch'; \
    nm --defined-only /project/native.o | grep -q ' T cx_now_ms'

# Analyze every unit into GHDL's work library, in dependency order: the
# bus and foreign declarations first, then the transport process that
# drives them, then the buffer helpers and the JSON codec built on them.
RUN set -eu; \
    mkdir -p /project/work; \
    ghdl -a --std=08 --workdir=/project/work client/convex_native.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/convex_transport.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/convex_buffer.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/convex_json.vhdl; \
    echo "PASS vhdl analyze"

# buffer_test and json_test need no transport, no network and no native
# call beyond elaboration itself.
RUN set -eu; \
    ghdl -a --std=08 --workdir=/project/work client/tests/buffer_test.vhdl; \
    ghdl -e --std=08 --workdir=/project/work buffer_test; \
    ./buffer_test | tee /tmp/buffer_test.out; \
    grep -Fq 'PASS buffer_test' /tmp/buffer_test.out

RUN set -eu; \
    ghdl -a --std=08 --workdir=/project/work client/tests/json_test.vhdl; \
    ghdl -e --std=08 --workdir=/project/work json_test; \
    ./json_test | tee /tmp/json_test.out; \
    grep -Fq 'PASS json_test' /tmp/json_test.out

# transport_smoke drives a real connection through the req/ack circuit,
# native.c and OpenSSL, so it needs a real TLS peer -- a local
# openssl s_server behind a private CA, matching this project's other
# native clients' hermetic TLS tests rather than reaching the live
# internet from inside a Docker build stage.
RUN set -eu; \
    mkdir -p /tmp/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=vhdl-test-ca' \
      -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
      -keyout /tmp/tls/server.key -out /tmp/tls/server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in /tmp/tls/server.csr \
      -CA /tmp/tls/ca.crt -CAkey /tmp/tls/ca.key -CAcreateserial \
      -copy_extensions copy -out /tmp/tls/server.crt >/dev/null 2>&1; \
    ghdl -a --std=08 --workdir=/project/work client/tests/transport_smoke.vhdl; \
    ghdl -e --std=08 --workdir=/project/work \
      -Wl,/project/native.o -Wl,-lssl -Wl,-lcrypto transport_smoke; \
    openssl s_server -accept 44300 -naccept 4 \
      -cert /tmp/tls/server.crt -key /tmp/tls/server.key -www \
      >/dev/null 2>&1 & \
    server_pid=$!; \
    sleep 1; \
    SSL_CERT_FILE=/tmp/tls/ca.crt timeout 20 ./transport_smoke | tee /tmp/transport_smoke.out; \
    kill "$server_pid" 2>/dev/null || true; \
    grep -Fq 'PASS transport_smoke' /tmp/transport_smoke.out

# http_test proves convex_http.vhdl's response decoding (plain
# Content-Length and chunked Transfer-Encoding) against a real TCP peer
# rather than a mocked transport. httpfix.c is a tiny one-shot fixture
# server -- test infrastructure only, never linked into the client itself
# -- that drains one request and replays exactly one canned response byte
# for byte, the same role this client's openssl s_server plays for TLS
# above. Written with a native Dockerfile heredoc (this Dockerfile already
# pins the 1.7 syntax that supports it) rather than the `\`-continued
# shell style used elsewhere in this file, because that continuation
# style joins lines together and would corrupt a real multi-line heredoc.
RUN <<'HTTPFIX_EOF'
set -eu
cat > /tmp/httpfix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: httpfix port responsefile\n"); return 1; }
    int port = atoi(argv[1]);
    FILE *rf = fopen(argv[2], "rb");
    if (!rf) { perror("fopen"); return 1; }
    fseek(rf, 0, SEEK_END);
    long rlen = ftell(rf);
    fseek(rf, 0, SEEK_SET);
    char *resp = malloc((size_t)rlen);
    if (fread(resp, 1, (size_t)rlen, rf) != (size_t)rlen) { return 1; }
    fclose(rf);
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
gcc -O2 -Wall -Wextra -o /tmp/httpfix /tmp/httpfix.c
HTTPFIX_EOF

RUN set -eu; \
    printf '{"status":"success","value":{"count":7}}' > /tmp/clen-body.txt; \
    clen=$(wc -c < /tmp/clen-body.txt | tr -d ' '); \
    { \
      printf 'HTTP/1.1 200 OK\r\n'; \
      printf 'Content-Type: application/json\r\n'; \
      printf 'Content-Length: %s\r\n\r\n' "$clen"; \
      cat /tmp/clen-body.txt; \
    } > /tmp/clen-response.bin; \
    { \
      printf 'HTTP/1.1 200 OK\r\n'; \
      printf 'Transfer-Encoding: chunked\r\n\r\n'; \
      printf '5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n'; \
    } > /tmp/chunked-response.bin; \
    /tmp/httpfix 44301 /tmp/clen-response.bin & \
    /tmp/httpfix 44302 /tmp/chunked-response.bin & \
    sleep 1; \
    ghdl -a --std=08 --workdir=/project/work client/convex_http.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/tests/http_test.vhdl; \
    ghdl -e --std=08 --workdir=/project/work \
      -Wl,/project/native.o -Wl,-lssl -Wl,-lcrypto http_test; \
    timeout 20 ./http_test | tee /tmp/http_test.out; \
    wait; \
    grep -Fq 'PASS http_test' /tmp/http_test.out
