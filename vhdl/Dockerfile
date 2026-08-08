# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: build native.c, analyze and elaborate every VHDL unit this client
# ships with GHDL, and run every language-local suite.
#
# CHECKPOINT NOTE: this client is still under construction. The foreign-
# boundary primitives (native.c, including the CMD_LISTEN/CMD_ACCEPT pair
# the adapter's TCP mode needs), the request/acknowledge circuit
# (convex_native.vhdl, convex_transport.vhdl), the byte-buffer helpers
# (convex_buffer.vhdl), a JSON codec (convex_json.vhdl), an HTTP/1.1 client
# (convex_http.vhdl), the public call facade (convex.vhdl), an RFC 6455
# WebSocket layer (convex_ws.vhdl) and the pinned /api/sync Live protocol
# (convex_sync.vhdl) exist so far, proven here by buffer_test,
# transport_smoke, json_test, http_test, convex_test, ws_test and
# sync_test. The conformance adapter and examples/basics do not exist
# yet, so this stage does not yet compile a canonical example or a
# conformance executable and no `runtime` or `example-runtime` stage
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

# convex_test proves convex.vhdl's client_call: the request envelope it
# builds, and both response envelope shapes Convex's HTTP API returns
# (success and function error), reusing httpfix.c's one-shot replay role
# again.
RUN set -eu; \
    printf '{"status":"success","value":{"count":3},"logLines":["log one"]}' > /tmp/s-body.txt; \
    sclen=$(wc -c < /tmp/s-body.txt | tr -d ' '); \
    { \
      printf 'HTTP/1.1 200 OK\r\n'; \
      printf 'Content-Length: %s\r\n\r\n' "$sclen"; \
      cat /tmp/s-body.txt; \
    } > /tmp/s-resp.bin; \
    printf '{"status":"error","errorMessage":"room is full","errorData":{"code":429},"logLines":[]}' > /tmp/e-body.txt; \
    eclen=$(wc -c < /tmp/e-body.txt | tr -d ' '); \
    { \
      printf 'HTTP/1.1 200 OK\r\n'; \
      printf 'Content-Length: %s\r\n\r\n' "$eclen"; \
      cat /tmp/e-body.txt; \
    } > /tmp/e-resp.bin; \
    /tmp/httpfix 44305 /tmp/s-resp.bin & \
    /tmp/httpfix 44306 /tmp/e-resp.bin & \
    sleep 1; \
    ghdl -a --std=08 --workdir=/project/work client/convex.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/tests/convex_test.vhdl; \
    ghdl -e --std=08 --workdir=/project/work \
      -Wl,/project/native.o -Wl,-lssl -Wl,-lcrypto convex_test; \
    timeout 20 ./convex_test | tee /tmp/convex_test.out; \
    wait; \
    grep -Fq 'PASS convex_test' /tmp/convex_test.out

# ws_test proves convex_ws.vhdl's handshake, masked encode, unmasked
# decode, fragmentation reassembly and transparent Ping/Pong against a
# real TCP peer. wsfix.c is another one-shot fixture server, playing the
# same test-infrastructure-only role as httpfix.c above; it also verifies
# (in C, independently of this client's own logic) that the Pong this
# client sends back for its Ping is masked and carries the exact payload
# it pinged with, printing "wsfix: PONG verified" to stderr when it does.
RUN <<'WSFIX_EOF'
set -eu
cat > /tmp/wsfix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

static int conn;

static void send_frame(int fin, int opcode, const char *payload, int len) {
    unsigned char hdr[10];
    int hlen = 0;
    hdr[hlen++] = (unsigned char)((fin ? 0x80 : 0x00) | (opcode & 0x0f));
    if (len <= 125) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xff);
        hdr[hlen++] = (unsigned char)(len & 0xff);
    }
    write(conn, hdr, (size_t)hlen);
    if (len > 0) write(conn, payload, (size_t)len);
}

static void read_full(unsigned char *buf, int n) {
    int total = 0;
    while (total < n) {
        ssize_t r = read(conn, buf + total, (size_t)(n - total));
        if (r <= 0) { fprintf(stderr, "wsfix: read_full failed\n"); exit(1); }
        total += (int)r;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: wsfix port\n"); return 1; }
    int port = atoi(argv[1]);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(fd, 1);
    conn = accept(fd, NULL, NULL);
    if (conn < 0) { perror("accept"); return 1; }

    unsigned char drain[8192];
    int total = 0;
    while (total < (int)sizeof(drain)) {
        unsigned char b;
        ssize_t n = read(conn, &b, 1);
        if (n <= 0) { fprintf(stderr, "wsfix: request drain failed\n"); return 1; }
        drain[total++] = b;
        if (total >= 4 && drain[total-4]=='\r' && drain[total-3]=='\n' &&
            drain[total-2]=='\r' && drain[total-1]=='\n') break;
    }

    const char *resp =
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "\r\n";
    write(conn, resp, strlen(resp));

    send_frame(1, 0x1, "hello", 5);

    send_frame(0, 0x1, "foo", 3);
    send_frame(1, 0x0, "bar", 3);

    send_frame(1, 0x9, "pingdata", 8);
    unsigned char head[2];
    read_full(head, 2);
    int fin = (head[0] & 0x80) != 0;
    int opcode = head[0] & 0x0f;
    int masked = (head[1] & 0x80) != 0;
    int plen = head[1] & 0x7f;
    if (!fin || opcode != 0xa || !masked) {
        fprintf(stderr, "wsfix: expected a single masked PONG frame, got fin=%d opcode=%d masked=%d\n",
                fin, opcode, masked);
        return 1;
    }
    if (plen == 126) {
        unsigned char ext[2];
        read_full(ext, 2);
        plen = (ext[0] << 8) | ext[1];
    }
    unsigned char mask[4];
    read_full(mask, 4);
    unsigned char payload[256];
    if (plen > (int)sizeof(payload)) { fprintf(stderr, "wsfix: PONG payload too large\n"); return 1; }
    read_full(payload, plen);
    for (int i = 0; i < plen; i++) payload[i] = (unsigned char)(payload[i] ^ mask[i % 4]);
    if (plen != 8 || memcmp(payload, "pingdata", 8) != 0) {
        fprintf(stderr, "wsfix: PONG payload mismatch (len=%d)\n", plen);
        return 1;
    }
    fprintf(stderr, "wsfix: PONG verified\n");

    send_frame(1, 0x8, NULL, 0);

    close(conn);
    close(fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/wsfix /tmp/wsfix.c
WSFIX_EOF

RUN set -eu; \
    /tmp/wsfix 44303 & \
    sleep 1; \
    ghdl -a --std=08 --workdir=/project/work client/convex_ws.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/tests/ws_test.vhdl; \
    ghdl -e --std=08 --workdir=/project/work \
      -Wl,/project/native.o -Wl,-lssl -Wl,-lcrypto ws_test; \
    timeout 20 ./ws_test | tee /tmp/ws_test.out; \
    wait; \
    grep -Fq 'PASS ws_test' /tmp/ws_test.out

# sync_test proves convex_sync.vhdl's Connect/ModifyQuerySet/Transition
# handling, including a real reconnect: syncfix.c accepts two
# connections in sequence, answers each subscription's Add with a
# Transition whose value differs by connection, and this stage forces
# the client through debugDisconnect between them, so seeing the second
# connection's different value is genuine end-to-end proof that
# reconnect resends Add rather than only that the code compiles.
RUN <<'SYNCFIX_EOF'
set -eu
cat > /tmp/syncfix.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

static int conn;

static void send_frame(const char *payload, int len) {
    unsigned char hdr[4];
    int hlen = 0;
    hdr[hlen++] = 0x81;
    if (len <= 125) {
        hdr[hlen++] = (unsigned char)len;
    } else {
        hdr[hlen++] = 126;
        hdr[hlen++] = (unsigned char)((len >> 8) & 0xff);
        hdr[hlen++] = (unsigned char)(len & 0xff);
    }
    write(conn, hdr, (size_t)hlen);
    write(conn, payload, (size_t)len);
}

static int read_client_frame(unsigned char *out, int cap) {
    unsigned char head[2];
    if (read(conn, head, 2) != 2) return -1;
    int masked = (head[1] & 0x80) != 0;
    int plen = head[1] & 0x7f;
    if (plen == 126) {
        unsigned char ext[2];
        if (read(conn, ext, 2) != 2) return -1;
        plen = (ext[0] << 8) | ext[1];
    }
    unsigned char mask[4] = {0, 0, 0, 0};
    if (masked) {
        if (read(conn, mask, 4) != 4) return -1;
    }
    if (plen > cap) return -1;
    int total = 0;
    while (total < plen) {
        ssize_t n = read(conn, out + total, (size_t)(plen - total));
        if (n <= 0) return -1;
        total += (int)n;
    }
    if (masked) {
        for (int i = 0; i < plen; i++) out[i] = (unsigned char)(out[i] ^ mask[i % 4]);
    }
    return plen;
}

static int extract_query_id(const unsigned char *buf, int len) {
    const char *needle = "\"queryId\":";
    for (int i = 0; i + (int)strlen(needle) < len; i++) {
        if (memcmp(buf + i, needle, strlen(needle)) == 0) {
            return atoi((const char *)buf + i + (int)strlen(needle));
        }
    }
    return -1;
}

static int contains(const unsigned char *buf, int len, const char *needle) {
    int nlen = (int)strlen(needle);
    for (int i = 0; i + nlen <= len; i++) {
        if (memcmp(buf + i, needle, (size_t)nlen) == 0) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: syncfix port\n"); return 1; }
    int port = atoi(argv[1]);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(fd, 2);

    for (int seq = 0; seq < 2; seq++) {
        conn = accept(fd, NULL, NULL);
        if (conn < 0) { perror("accept"); return 1; }
        fprintf(stderr, "syncfix: accepted connection %d\n", seq);

        unsigned char drain[8192];
        int total = 0;
        while (total < (int)sizeof(drain)) {
            unsigned char b;
            ssize_t n = read(conn, &b, 1);
            if (n <= 0) { fprintf(stderr, "syncfix: handshake drain failed\n"); return 1; }
            drain[total++] = b;
            if (total >= 4 && drain[total-4]=='\r' && drain[total-3]=='\n' &&
                drain[total-2]=='\r' && drain[total-1]=='\n') break;
        }
        const char *resp =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "\r\n";
        write(conn, resp, strlen(resp));

        int query_id = -1;
        unsigned char frame[8192];
        for (;;) {
            int n = read_client_frame(frame, (int)sizeof(frame));
            if (n < 0) { fprintf(stderr, "syncfix: connection %d ended\n", seq); break; }
            if (contains(frame, n, "\"type\":\"ModifyQuerySet\"") && contains(frame, n, "\"Add\"")) {
                query_id = extract_query_id(frame, n);
                fprintf(stderr, "syncfix: saw Add for queryId=%d on connection %d\n", query_id, seq);

                char body[512];
                int blen = snprintf(body, sizeof(body),
                    "{\"type\":\"Transition\","
                    "\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},"
                    "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},"
                    "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":%d,\"value\":{\"count\":%d}}]}",
                    query_id, seq);
                send_frame(body, blen);
            }
        }
    }

    close(fd);
    return 0;
}
CEOF
gcc -O2 -Wall -Wextra -o /tmp/syncfix /tmp/syncfix.c
SYNCFIX_EOF

RUN set -eu; \
    /tmp/syncfix 44304 & \
    sleep 1; \
    ghdl -a --std=08 --workdir=/project/work client/convex_sync.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/tests/sync_test.vhdl; \
    ghdl -e --std=08 --workdir=/project/work \
      -Wl,/project/native.o -Wl,-lssl -Wl,-lcrypto sync_test; \
    timeout 30 ./sync_test | tee /tmp/sync_test.out; \
    wait; \
    grep -Fq 'PASS sync_test' /tmp/sync_test.out

# The NDJSON adapter protocol v1 executable. Analyzed and elaborated
# here; exercised below against three scenarios covering stdin/stdout
# calls, the TCP ADAPTER_LISTEN mode, and asynchronous Live delivery
# interleaved with commands.
RUN set -eu; \
    ghdl -a --std=08 --workdir=/project/work client/convex.vhdl; \
    ghdl -a --std=08 --workdir=/project/work client/tests/conformance/adapter.vhdl; \
    ghdl -e --std=08 --workdir=/project/work \
      -Wl,/project/native.o -Wl,-lssl -Wl,-lcrypto adapter; \
    echo "PASS adapter elaborate"

# Scenario A: a real query call through the adapter, over stdin/stdout.
RUN set -eu; \
    printf '{"status":"success","value":{"count":5},"logLines":[]}' > /tmp/a-body.txt; \
    aclen=$(wc -c < /tmp/a-body.txt | tr -d ' '); \
    { \
      printf 'HTTP/1.1 200 OK\r\n'; \
      printf 'Content-Length: %s\r\n\r\n' "$aclen"; \
      cat /tmp/a-body.txt; \
    } > /tmp/a-resp.bin; \
    /tmp/httpfix 44307 /tmp/a-resp.bin & \
    sleep 1; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"h1","op":"hello"}' \
      '{"id":"q1","op":"query","path":"demo:state","args":{}}' \
      '{"id":"c1","op":"close"}' \
    > /tmp/scenario-a.in; \
    CONVEX_URL=http://127.0.0.1:44307 timeout 20 ./adapter \
      < /tmp/scenario-a.in > /tmp/scenario-a.out 2>/tmp/scenario-a.err; \
    code=$?; \
    echo "adapter exit: $code"; cat /tmp/scenario-a.out; cat /tmp/scenario-a.err >&2; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/scenario-a.out; \
    grep -Fq '"type":"result"' /tmp/scenario-a.out; \
    grep -Fq '"count":5' /tmp/scenario-a.out; \
    grep -Fq '"type":"closed"' /tmp/scenario-a.out

# Scenario B: a Live subscription, an asynchronous subscription event
# delivered with no new command pending, a debugDisconnect, and the
# post-reconnect value -- fed through a FIFO (not a plain redirected
# file) so the adapter's stdin genuinely blocks between commands instead
# of a regular file's always-ready poll semantics reporting EOF the
# instant the static input would otherwise run out.
RUN set -eu; \
    /tmp/syncfix 44308 & \
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
    CONVEX_URL=http://127.0.0.1:44308 timeout 30 ./adapter \
      < /tmp/scenario-b.fifo > /tmp/scenario-b.out 2>/tmp/scenario-b.err; \
    code=$?; \
    wait; \
    echo "adapter exit: $code"; cat /tmp/scenario-b.out; cat /tmp/scenario-b.err >&2; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/scenario-b.out; \
    grep -Fq '"type":"subscription","subscriptionId":"sub1","value":{"count":0}' /tmp/scenario-b.out; \
    grep -Fq '"type":"subscription","subscriptionId":"sub1","value":{"count":1}' /tmp/scenario-b.out; \
    grep -Fq '"id":"d1","type":"ack"' /tmp/scenario-b.out; \
    grep -Fq '"id":"u1","type":"ack"' /tmp/scenario-b.out; \
    grep -Fq '"id":"c1","type":"closed"' /tmp/scenario-b.out

# Scenario C: ADAPTER_LISTEN's TCP mode, proving CMD_LISTEN/CMD_ACCEPT
# actually carry the adapter protocol, not only stdin/stdout. Uses
# bash explicitly for its /dev/tcp pseudo-device, which this image's
# default /bin/sh (dash) does not support.
RUN bash -c '\
    set -eu; \
    ADAPTER_LISTEN=127.0.0.1:44309 timeout 20 ./adapter \
      > /tmp/scenario-c.out 2>/tmp/scenario-c.err & \
    server_pid=$!; \
    sleep 1; \
    exec 3<>/dev/tcp/127.0.0.1/44309; \
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
