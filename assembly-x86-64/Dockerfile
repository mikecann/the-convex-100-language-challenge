# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       nasm=2.16.01-1 \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       libssl-dev=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
       netcat-traditional=1.10-47 \
       iproute2=6.1.0-3 \
    && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples

# Every client translation unit assembles cleanly on its own (catches a
# missing `extern`, a bad struc offset, or a syntax slip before linking
# hides it inside a bigger error), then everything links into the
# conformance adapter and the canonical example.
RUN test "$(uname -m)" = x86_64 \
    && mkdir -p /build \
    && for unit in convex_buf convex_json convex_http convex_ws convex_live convex_client; do \
         nasm -f elf64 -Iclient client/$unit.s -o /build/$unit.o; \
       done \
    && nasm -f elf64 -Iclient client/tests/conformance/main.s -o /build/adapter.o \
    && nasm -f elf64 -Iclient examples/basics/main.s -o /build/example.o \
    && gcc -no-pie -o /build/convex-adapter \
         /build/adapter.o /build/convex_client.o /build/convex_http.o \
         /build/convex_ws.o /build/convex_live.o /build/convex_json.o \
         /build/convex_buf.o -lssl -lcrypto \
    && gcc -no-pie -o /build/convex-example \
         /build/example.o /build/convex_client.o /build/convex_http.o \
         /build/convex_ws.o /build/convex_live.o /build/convex_json.o \
         /build/convex_buf.o -lssl -lcrypto \
    && file /build/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64' \
    && file /build/convex-example | grep -Eq 'ELF 64-bit.*x86-64'

# Adapter protocol smoke test over stdin/stdout: malformed input, hello, an
# unknown operation, and a clean close -- mirrors the shared v1 schema's
# required event shapes without touching the network.
RUN <<'EOF'
set -eu
actual=$(/build/convex-adapter <<'COMMANDS'
{malformed
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"unknown","op":"notAnOperation"}
{"id":"close","op":"close"}
COMMANDS
)
printf '%s\n' "$actual" | grep -Fx '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'
printf '%s\n' "$actual" | grep -F '"id":"hello","protocolVersion":1,"type":"ready"'
printf '%s\n' "$actual" | grep -Fx '{"type":"error","id":"unknown","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'
printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
EOF

# The same protocol test again, but over the ADAPTER_LISTEN TCP path the
# shared harness actually drives verify/verify-hosted through.
#
# This uses bash's /dev/tcp instead of nc: on the verified build host, an
# `nc` client run inside a heredoc RUN step reliably hangs past its own
# `timeout` -- backgrounded or not, output captured through a pipe or not --
# even though the exact same adapter binary, reached the exact same way,
# answers correctly and instantly under a plain `docker run`/`docker exec`.
# That is a BuildKit/nc interaction specific to this RUN-step execution
# model, not a client bug, so the workaround lives here rather than in the
# client. /dev/tcp is a bash builtin (no netcat involved) and does not
# reproduce the nc hang -- but two /dev/tcp connections attempted in
# sequence from the *same* backgrounded-adapter RUN step reproduced a
# similar hang on the verified build host, so the non-loopback check and
# the real exchange are two separate RUN steps, each with its own freshly
# started adapter, rather than one script making two connections.
RUN <<'EOF'
#!/usr/bin/env bash
set -eu
ADAPTER_LISTEN=127.0.0.1:18080 /build/convex-adapter &
adapter_pid=$!
sleep 1
container_address=$(ip -4 addr show eth0 | awk '/inet / {sub("/.*", "", $2); print $2; exit}')
non_loopback=""
if exec 4<>"/dev/tcp/$container_address/18080" 2>/dev/null; then
  printf '%s\n%s\n' \
    '{"id":"wrong-host","protocolVersion":1,"op":"hello"}' \
    '{"id":"wrong-close","op":"close"}' >&4
  non_loopback=$(timeout 3 cat <&4 2>/dev/null || true)
  exec 4<&- 4>&- || true
fi
kill "$adapter_pid" 2>/dev/null || true
wait "$adapter_pid" 2>/dev/null || true
if test -n "$non_loopback"; then
  printf '%s\n' 'loopback adapter unexpectedly accepted a non-loopback connection' >&2
  exit 1
fi
EOF

RUN <<'EOF'
#!/usr/bin/env bash
set -eu
ADAPTER_LISTEN=127.0.0.1:18080 /build/convex-adapter &
adapter_pid=$!
sleep 1
attempt=1
actual=""
while test -z "$actual"; do
  actual=$(timeout 5 bash -c '
    exec 3<>/dev/tcp/127.0.0.1/18080
    printf "%s\n%s\n" \
      "{\"id\":\"tcp-hello\",\"protocolVersion\":1,\"op\":\"hello\"}" \
      "{\"id\":\"tcp-close\",\"op\":\"close\"}" >&3
    cat <&3
  ' || true)
  if test -n "$actual"; then
    break
  fi
  attempt=$((attempt + 1))
  if test "$attempt" -gt 5; then
    printf '%s\n' 'exhausted retries connecting to the ADAPTER_LISTEN adapter' >&2
    exit 1
  fi
  sleep 1
done
n=0
while kill -0 "$adapter_pid" 2>/dev/null; do
  if test "$n" -ge 10; then
    printf '%s\n' 'adapter did not exit after processing close' >&2
    exit 1
  fi
  sleep 1
  n=$((n + 1))
done
printf '%s\n' "$actual" | grep -F '"id":"tcp-hello","protocolVersion":1,"type":"ready"'
printf '%s\n' "$actual" | grep -Fx '{"id":"tcp-close","type":"closed"}'
EOF

# Missing CONVEX_URL must fail loudly rather than segfault or hang.
RUN <<'EOF'
set -eu
code=0
/build/convex-example some-room >/tmp/example.out 2>/tmp/example.err || code=$?
test "$code" -eq 1
test ! -s /tmp/example.out
grep -Fq 'CONVEX_URL is required' /tmp/example.err
EOF

# Start from the pinned non-scratch image, remove its broad filesystem with
# a temporary static helper, then copy back only the declared runtime
# closure. The default OpenSSL provider needs no ossl-modules/*.so on this
# distribution (the [provider_sect] in its openssl.cnf is commented out by
# default, so nothing beyond libcrypto/libssl themselves is loaded) --
# verified by inspecting the packaged config rather than assumed.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test ! -e /usr/bin \
    && test ! -e /bin \
    && set -- /usr/lib/x86_64-linux-gnu/* \
    && test "$#" -eq 2 \
    && set -- /lib/x86_64-linux-gnu/* \
    && test "$#" -eq 6 \
    && set -- /lib64/* \
    && test "$#" -eq 1

FROM runtime-base AS example-runtime
COPY --from=test /build/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /build/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
