# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM ${DEBIAN_IMAGE} AS busybox-builder
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
RUN apt-get update && apt-get install -y --no-install-recommends \
    bzip2=1.0.8-5+b1 gcc=4:12.2.0-3 libc6-dev=2.36-9+deb12u14 \
    make=4.3-4.1 musl-tools=1.2.3-1 \
    && rm -rf /var/lib/apt/lists/*
RUN tar -xjf /tmp/busybox.tar.bz2 -C /tmp
WORKDIR /tmp/busybox-1.37.0
RUN make allnoconfig >/dev/null && \
    for option in STATIC BUSYBOX ASH ASH_ECHO ASH_PRINTF ASH_TEST AWK BASENAME CAT CMP CUT DIRNAME ENV GREP HEAD ID SED TAIL TEST TR TRUE FALSE UNAME WC; do \
      sed -i "s/# CONFIG_${option} is not set/CONFIG_${option}=y/" .config; \
    done && \
    CC=musl-gcc make -j2 busybox >/dev/null && \
    test "$(./busybox --list | wc -l)" -eq 20 && \
    ! ./busybox --list | grep -E '^(wget|nc|telnet|ftp|ftpget|ftpput|httpd|tftp)$' && \
    install -Dm0555 busybox /out/busybox

FROM ${DEBIAN_IMAGE} AS test
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates=20230311+deb12u1 lua5.1=5.1.5-9 \
    lua-dkjson=2.6-2 lua-socket=3.1.0-1+b1 \
    lua-cqueues=20200726-1+b1 lua-http=0.4-1 \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:8d0c1e838c5604b42151ea8696a41251bebacf299273c3c5b3c99c0c5ad7d6d7 \
    https://fennel-lang.org/downloads/fennel-1.6.1 /usr/local/bin/fennel
RUN chmod 0555 /usr/local/bin/fennel && fennel --version | grep -Fx 'Fennel 1.6.1 on PUC Lua 5.1'
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN set -eu; \
    mkdir -p /generated/client/tests/conformance /generated/examples/basics; \
    fennel --compile client/json.fnl > /generated/client/json.lua; \
    fennel --compile client/live.fnl > /generated/client/live.lua; \
    fennel --compile client/convex.fnl > /generated/client/convex.lua; \
    fennel --compile client/tests/conformance/adapter_events.fnl > /generated/client/adapter_events.lua; \
    fennel --compile client/tests/conformance/adapter_output.fnl > /generated/client/adapter_output.lua; \
    fennel --compile client/tests/conformance/adapter.fnl > /generated/client/tests/conformance/adapter.lua; \
    fennel --compile client/tests/http_fixture_test.fnl > /generated/client/tests/http_fixture_test.lua; \
    fennel --compile client/tests/adapter_output_test.fnl > /generated/client/tests/adapter_output_test.lua; \
    fennel --compile client/tests/live_owner_test.fnl > /generated/client/tests/live_owner_test.lua; \
    fennel --compile client/tests/live_fixture_test.fnl > /generated/client/tests/live_fixture_test.lua; \
    fennel --compile examples/basics/main.fnl > /generated/examples/basics/main.lua; \
    find /generated -type f -name '*.lua' -exec luac5.1 -p '{}' ';'
RUN LUA_PATH='/generated/client/?.lua;;' lua5.1 /generated/client/tests/live_fixture_test.lua
RUN LUA_PATH='/generated/client/?.lua;;' lua5.1 /generated/client/tests/http_fixture_test.lua
RUN LUA_PATH='/generated/client/?.lua;;' lua5.1 /generated/client/tests/adapter_output_test.lua
RUN LUA_PATH='/generated/client/?.lua;;' lua5.1 /generated/client/tests/live_owner_test.lua
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
    LUA_PATH='/generated/client/?.lua;;' lua5.1 /generated/client/tests/conformance/adapter.lua >/tmp/adapter.ndjson && \
    grep -Fq '"language":"fennel"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["/bin/sh", "-c", "test \"$(uname -m)\" = x86_64 && lua5.1 -e 'assert(_VERSION == \"Lua 5.1\")'"]

FROM test AS runtime-rootfs
RUN set -eu; root=/runtime-root; \
    mkdir -p "$root/usr/lib/ssl" "$root/usr/local/bin" "$root/etc" "$root/opt/convex/client"; \
    cp /usr/bin/lua5.1 "$root/usr/local/bin/lua"; \
    lua_modules=' \
      /usr/share/lua/5.1/basexx.lua /usr/share/lua/5.1/binaryheap.lua \
      /usr/share/lua/5.1/compat53/module.lua \
      /usr/share/lua/5.1/cqueues.lua /usr/share/lua/5.1/cqueues/auxlib.lua \
      /usr/share/lua/5.1/cqueues/condition.lua /usr/share/lua/5.1/cqueues/errno.lua \
      /usr/share/lua/5.1/cqueues/socket.lua /usr/share/lua/5.1/dkjson.lua /usr/share/lua/5.1/fifo.lua \
      /usr/share/lua/5.1/http/bit.lua /usr/share/lua/5.1/http/client.lua \
      /usr/share/lua/5.1/http/connection_common.lua /usr/share/lua/5.1/http/cookie.lua \
      /usr/share/lua/5.1/http/h1_connection.lua /usr/share/lua/5.1/http/h1_reason_phrases.lua \
      /usr/share/lua/5.1/http/h1_stream.lua /usr/share/lua/5.1/http/h2_connection.lua \
      /usr/share/lua/5.1/http/h2_error.lua /usr/share/lua/5.1/http/h2_stream.lua \
      /usr/share/lua/5.1/http/headers.lua /usr/share/lua/5.1/http/hpack.lua \
      /usr/share/lua/5.1/http/hsts.lua /usr/share/lua/5.1/http/proxies.lua \
      /usr/share/lua/5.1/http/request.lua /usr/share/lua/5.1/http/socks.lua \
      /usr/share/lua/5.1/http/stream_common.lua /usr/share/lua/5.1/http/tls.lua \
      /usr/share/lua/5.1/http/util.lua /usr/share/lua/5.1/http/version.lua \
      /usr/share/lua/5.1/http/websocket.lua \
      /usr/share/lua/5.1/lpeg_patterns/IPv4.lua /usr/share/lua/5.1/lpeg_patterns/IPv6.lua \
      /usr/share/lua/5.1/lpeg_patterns/core.lua /usr/share/lua/5.1/lpeg_patterns/email.lua \
      /usr/share/lua/5.1/lpeg_patterns/http.lua /usr/share/lua/5.1/lpeg_patterns/language.lua \
      /usr/share/lua/5.1/lpeg_patterns/uri.lua /usr/share/lua/5.1/lpeg_patterns/util.lua \
      /usr/share/lua/5.1/openssl/digest.lua /usr/share/lua/5.1/openssl/pkey.lua \
      /usr/share/lua/5.1/openssl/rand.lua /usr/share/lua/5.1/openssl/ssl.lua \
      /usr/share/lua/5.1/openssl/ssl/context.lua /usr/share/lua/5.1/openssl/x509/verify_param.lua \
      /usr/share/lua/5.1/socket.lua'; \
    native_modules=' \
      /usr/lib/x86_64-linux-gnu/lua/5.1/_cqueues.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/_openssl.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/bit32.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/compat53/string.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/compat53/table.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/compat53/utf8.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/lpeg.so \
      /usr/lib/x86_64-linux-gnu/lua/5.1/socket/core.so'; \
    for module in $lua_modules; do cp --parents "$module" "$root"; done; \
    for module in $native_modules; do cp -L --parents "$module" "$root"; done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    ln -s /etc/ssl/certs "$root/usr/lib/ssl/certs"; \
    ln -s /etc/ssl/certs/ca-certificates.crt "$root/usr/lib/ssl/cert.pem"; \
    ln -s /etc/ssl/openssl.cnf "$root/usr/lib/ssl/openssl.cnf"; \
    { ldd /usr/bin/lua5.1; for module in $native_modules; do ldd "$module"; done; } | \
      awk '{ if ($3 ~ /^\//) print $3; if ($1 ~ /^\//) { path = $1; sub(/:$/, "", path); print path } }' | sort -u | \
      while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libresolv.so.2; do test ! -e "$library" || cp --parents "$library" "$root"; done; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done; \
    cp /generated/client/json.lua /generated/client/live.lua /generated/client/convex.lua \
      /generated/client/adapter_events.lua /generated/client/adapter_output.lua "$root/opt/convex/client/"; \
    cp /generated/client/tests/conformance/adapter.lua "$root/opt/convex/adapter.lua"; \
    cp /generated/examples/basics/main.lua "$root/opt/convex/example.lua"; \
    mkdir -p /entrypoints; \
    printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/lua /opt/convex/example.lua "$@"' > /entrypoints/convex-example; \
    printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/lua /opt/convex/adapter.lua "$@"' > /entrypoints/convex-adapter; \
    chmod 0555 /entrypoints/convex-example /entrypoints/convex-adapter

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-os
COPY --from=busybox-builder /out/busybox /tmp/restricted-busybox
RUN set -eu; mkdir /tmp/full; cp /bin/busybox /tmp/full/busybox; \
    for path in /bin/*; do /tmp/full/busybox rm -f "$path"; done; \
    for tool in sh awk basename cat cmp cut dirname env grep head id sed tail test tr true false uname wc; do \
      /tmp/full/busybox ln /tmp/restricted-busybox "/bin/$tool"; \
    done; \
    /tmp/full/busybox rm -rf /sbin /usr/bin /usr/sbin /tmp/restricted-busybox /tmp/full

FROM runtime-os AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV LUA_PATH=/opt/convex/client/?.lua;;
COPY --from=runtime-rootfs /runtime-root /
RUN set -eu; test "$(/usr/local/bin/lua -e 'io.write(_VERSION)')" = 'Lua 5.1'; \
    for command in busybox apk apt apt-get apt-cache dpkg fennel luac lua5.1 gcc cc make node npm npx python python3 pip pip3 curl wget nc telnet ftpget ftpput convex; do \
      ! command -v "$command" >/dev/null 2>&1; \
    done
FROM runtime-base AS example-runtime
COPY --from=runtime-rootfs /entrypoints/convex-example /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=runtime-rootfs /entrypoints/convex-adapter /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
