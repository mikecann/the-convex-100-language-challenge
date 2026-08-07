# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
# pike8.0-core is the Pike interpreter and its standard module library. This
# client uses Standards.JSON, Stdio, SSL, Crypto, and MIME from it and nothing
# else: no Convex client, no HTTP library, no WebSocket library.
#
# Pike's TLS is written in Pike over Nettle rather than layered on OpenSSL,
# which is why libnettle8 and libhogweed6 are pinned alongside the interpreter
# and why no OpenSSL configuration, engine, or provider module appears in the
# runtime images below. Every version is the exact bookworm revision, so a
# rebuild resolves the same packages or fails loudly instead of drifting.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       pike8.0-core=8.0.1738-1+b2 \
       libnettle8=3.8.1-2 \
       libhogweed6=3.8.1-2 \
       libnsl2=1.3.0-2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
    && rm -rf /var/lib/apt/lists/*
RUN ln -s /usr/bin/pike8.0 /usr/local/bin/pike
WORKDIR /project
COPY client ./client
COPY examples ./examples

# Assert the architecture and the exact module surface inside the image that
# will become the runtime, rather than inferring either from the host.
RUN test "$(uname -m)" = x86_64 \
    && pike --version \
    && pike -e 'Standards.JSON.encode(([])); SSL.Context(); \
                Crypto.SHA1.hash("x"); MIME.encode_base64("x", 1); \
                write("modules ok\n");'

RUN pike client/tests/style_test.pike
RUN pike -e 'compile_file("client/convex.pike"); \
             compile_file("examples/basics/main.pike"); \
             compile_file("client/tests/conformance/adapter.pike"); \
             write("every entry point compiles\n");'
RUN pike client/tests/json_test.pike
RUN pike client/tests/http_test.pike
RUN pike client/tests/socket_test.pike
RUN pike client/tests/websocket_test.pike
RUN pike client/tests/live_test.pike
RUN pike client/tests/conformance/adapter_test.pike
RUN pike examples/basics/main_test.pike

# The adapter lifecycle over stdin and stdout, with no deployment involved:
# hello must answer ready, close must answer closed, and stdout must carry
# exactly those two protocol lines and nothing else.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_CLIENT_PATH=/project/client \
      pike client/tests/conformance/adapter.pike > /tmp/adapter.ndjson \
    && grep -Fq '"type":"ready"' /tmp/adapter.ndjson \
    && grep -Fq '"language":"pike"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson \
    && test "$(wc -l < /tmp/adapter.ndjson)" -eq 2

# A real dispatch failure driven through the adapter binary, with no deployment
# involved. An unconfigured client must publish a structured TransportError
# against the request id rather than a value, a crash, or a silent drop.
RUN test -z "${CONVEX_URL:-}" \
    && printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"q1","op":"query","path":"demo:state","args":{}}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_CLIENT_PATH=/project/client \
      pike client/tests/conformance/adapter.pike > /tmp/adapter-error.ndjson \
    && grep -Fq '"id":"q1"' /tmp/adapter-error.ndjson \
    && grep -Fq '"type":"error"' /tmp/adapter-error.ndjson \
    && grep -Fq '"name":"TransportError"' /tmp/adapter-error.ndjson \
    && test "$(wc -l < /tmp/adapter-error.ndjson)" -eq 3

# End of input is the same lifecycle as an explicit close, minus the
# acknowledgement there is no longer anyone to read.
RUN timeout 10 sh -c 'CONVEX_CLIENT_PATH=/project/client \
      pike client/tests/conformance/adapter.pike </dev/null \
      >/tmp/adapter-eof.ndjson' \
    && test ! -s /tmp/adapter-eof.ndjson

# The TCP transport the shared harness actually uses, end to end with one
# accepted controller connection.
RUN timeout 60 sh -c 'set -eu; \
      CONVEX_CLIENT_PATH=/project/client ADAPTER_LISTEN=127.0.0.1:8099 \
        pike client/tests/conformance/adapter.pike & \
      adapter=$!; \
      pike client/tests/conformance/tcp_probe.pike 127.0.0.1:8099; \
      wait "$adapter"'

CMD ["pike", "-e", "if (uname()->machine != \"x86_64\") { werror(\"unexpected architecture\\n\"); exit(1); } write(\"%s\\n\", version());"]

FROM test AS runtime-rootfs
# Build the runtime closure from the package database rather than from a guessed
# module path: every regular file pike8.0-core installed, the interpreter, and
# the shared libraries the interpreter and its dynamic modules actually load.
RUN set -eu; \
    root=/runtime-root; \
    mkdir -p "$root/usr/local/bin" "$root/opt/convex/client"; \
    dpkg -L pike8.0-core | while IFS= read -r path; do \
      if [ -f "$path" ]; then cp -a --parents "$path" "$root"; fi; \
    done; \
    ln -s /usr/bin/pike8.0 "$root/usr/local/bin/pike"; \
    { ldd /usr/bin/pike8.0; \
      find "$root" -name '*.so' -type f -exec ldd {} + 2>/dev/null || true; } \
      | awk '{ if ($3 ~ /^\//) print $3; \
               if ($1 ~ /^\//) { p = $1; sub(/:$/, "", p); print p } }' \
      | sort -u \
      | while IFS= read -r library; do \
          if [ -f "$library" ]; then cp -a --parents "$library" "$root"; fi; \
        done; \
    cp -a --parents /etc/ssl "$root"; \
    cp -a --parents /usr/share/ca-certificates "$root"; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      if [ -e "$config" ]; then cp -a --parents "$config" "$root"; fi; \
    done; \
    for library in /lib/x86_64-linux-gnu/libnss_dns.so.2 \
                   /lib/x86_64-linux-gnu/libnss_files.so.2 \
                   /lib/x86_64-linux-gnu/libresolv.so.2; do \
      if [ -e "$library" ]; then cp -a --parents "$library" "$root"; fi; \
    done; \
    test -x "$root/usr/bin/pike8.0"; \
    test -L "$root/usr/local/bin/pike"; \
    test -s "$root/etc/ssl/certs/ca-certificates.crt"; \
    test -z "$(find "$root" \( -name 'apt*' -o -name 'dpkg*' -o -name 'perl*' \) \
                 -print -quit)"

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# Strip the pinned Debian carrier back to nothing using a BusyBox that only ever
# exists in the build stage, then rebuild the visible filesystem from the Pike
# closure above plus the handful of POSIX tools the shared image policy and
# example verifier require.
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root /run /sbin \
                /srv /usr /var; do \
      /busybox rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) /busybox rm -rf "$path" ;; \
      esac; \
    done; \
    /busybox mkdir -p /bin /lib64 /lib/x86_64-linux-gnu /usr/bin /usr/local/bin
COPY --from=runtime-rootfs /runtime-root /
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 \
                 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 \
                 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 \
                 /lib/x86_64-linux-gnu/libacl.so.1

# HOME points nowhere writable on purpose: the runtime filesystem is read-only
# and nothing in this client needs scratch space. There is deliberately no
# OpenSSL configuration or provider path here: Pike's TLS is implemented in
# Pike over Nettle, so the CA bundle copied above is the only TLS asset the
# runtime loads.
ENV PATH=/usr/local/bin:/usr/bin:/bin \
    HOME=/nonexistent \
    CONVEX_CLIENT_PATH=/opt/convex/client

COPY client/convex.pike client/errors.pike client/json.pike client/stream.pike \
     client/http.pike client/websocket.pike client/live.pike \
     /opt/convex/client/

USER 65532:65532
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test "$(uname -m)" = x86_64; \
    pike -e 'write("%s\n", version());'; \
    pike -e 'compile_file("/opt/convex/client/convex.pike"); \
             write("client compiles in the runtime image\n");'; \
    pike -e 'object convex = compile_file("/opt/convex/client/convex.pike")(); \
             int authorities = sizeof(convex->pem_certificates( \
               Stdio.read_file("/etc/ssl/certs/ca-certificates.crt") || "")); \
             if (authorities < 50) { \
               werror("trust store holds only %d authorities\n", authorities); \
               exit(1); \
             } \
             convex->tls_context(); \
             array(string) members = convex->tls_stream_members(); \
             foreach (({ "connect", "set_nonblocking", "set_write_callback" }), \
                      string needed) \
               if (search(members, needed) < 0) { \
                 werror("SSL.File lacks %s in this runtime\n", needed); \
                 exit(1); \
               } \
             write("TLS trust store loaded (%d authorities)\n", \
                   authorities);'; \
    for command in apt apt-get apt-cache dpkg busybox gcc cc make ld \
                   node npm npx python python3 pip pip3 curl wget nc telnet \
                   convex; do \
      if command -v "$command" >/dev/null 2>&1; then \
        echo "unexpected command in the runtime image: $command" >&2; \
        exit 1; \
      fi; \
    done

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.pike /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
# Exercise the installed entrypoint in the image that will actually ship it. A
# broken shebang or an example this stripped runtime cannot compile shows up
# here rather than during example verification. No deployment is contacted:
# without CONVEX_URL the example refuses with status 2 before it connects.
RUN set -eu; \
    pike -e 'compile_file("/usr/local/bin/convex-example"); \
             write("the installed example compiles\n");'; \
    status=0; \
    /usr/local/bin/convex-example >/dev/null 2>&1 || status=$?; \
    test "$status" -eq 2

FROM runtime-base AS runtime
# Pike resolves #include at compile time, relative to the file being compiled,
# so the adapter's two fragments have to sit beside it. They are data, not
# commands, and are installed read-only.
COPY --chmod=0444 client/tests/conformance/events.pike /usr/local/bin/events.pike
COPY --chmod=0444 client/tests/conformance/output.pike /usr/local/bin/output.pike
COPY --chmod=0555 client/tests/conformance/adapter.pike /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
# Drive the exact installed entrypoint through its whole lifecycle in the final
# image. This settles include resolution from /usr/local/bin and the client
# lookup at /opt/convex/client before a controller ever connects. The output is
# kept in a shell variable because this runtime has no way to remove a file.
RUN set -eu; \
    events=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | /usr/local/bin/convex-adapter); \
    echo "$events" | grep -Fq '"type":"ready"'; \
    echo "$events" | grep -Fq '"language":"pike"'; \
    echo "$events" | grep -Fq '"type":"closed"'; \
    test "$(echo "$events" | wc -l)" -eq 2
