# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM ${DEBIAN_IMAGE} AS formatter
ADD --checksum=sha256:bcb0d855e91f102f28a370e850f8566b3b44b79e6274d806ea5246837c0fd5ab \
    https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/stylua-linux-x86_64.zip /tmp/stylua.zip
RUN apt-get update && apt-get install -y --no-install-recommends unzip=6.0-28 && \
    unzip /tmp/stylua.zip -d /usr/local/bin && chmod 0555 /usr/local/bin/stylua && \
    rm -rf /var/lib/apt/lists/* /tmp/stylua.zip

FROM ${DEBIAN_IMAGE} AS test
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates=20230311+deb12u1 lua5.1=5.1.5-9 \
    lua-dkjson=2.6-2 lua-socket=3.1.0-1+b1 \
    lua-cqueues=20200726-1+b1 lua-http=0.4-1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
COPY client ./client
COPY examples ./examples
COPY --from=formatter /usr/local/bin/stylua /usr/local/bin/stylua

# Parse every source with Lua 5.1, then require canonical StyLua formatting
# before any language-local behavior or adapter lifecycle tests run.
RUN find client examples -type f -name '*.lua' -exec luac5.1 -p '{}' ';'
RUN stylua --check client examples
RUN lua5.1 client/tests/client_test.lua
RUN openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost \
	    -keyout /tmp/tls-key.pem -out /tmp/tls-cert.pem -days 1 >/dev/null 2>&1; \
	    openssl s_server -quiet -accept 19443 -key /tmp/tls-key.pem -cert /tmp/tls-cert.pem -www \
	    >/tmp/tls-server.log 2>&1 & tls_pid=$!; sleep 0.2; \
	    lua5.1 client/tests/tls_test.lua; test_status=$?; kill "$tls_pid"; wait "$tls_pid" 2>/dev/null; \
	    test "$test_status" -eq 0
RUN lua5.1 client/tests/live_test.lua
RUN lua5.1 client/tests/websocket_test.lua server & fixture_pid=$!; \
	    sleep 0.2; lua5.1 client/tests/websocket_test.lua client; client_status=$?; \
	    wait "$fixture_pid"; server_status=$?; test "$client_status" -eq 0; test "$server_status" -eq 0
RUN lua5.1 client/tests/conformance/events_test.lua
RUN lua5.1 client/tests/conformance/output_test.lua
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
	    LUA_PATH='./client/tests/conformance/?.lua;./client/?.lua;;' lua5.1 client/tests/conformance/adapter.lua >/tmp/adapter.ndjson && \
	    grep -Fq '"language":"lua"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
RUN timeout 2 sh -c "LUA_PATH='./client/tests/conformance/?.lua;./client/?.lua;;' \
	    lua5.1 client/tests/conformance/adapter.lua </dev/null >/tmp/adapter-eof.ndjson" && \
	    test ! -s /tmp/adapter-eof.ndjson
CMD ["/bin/sh", "-c", "test \"$(uname -m)\" = x86_64 && lua5.1 -e 'assert(_VERSION == \"Lua 5.1\")'"]

FROM test AS runtime-rootfs
# Copy only Lua, its declared runtime modules, TLS/CA data, loader closure,
# and the POSIX commands required by the shared runtime policy. Package tools
# stay behind in the build stage.
RUN set -eu; root=/runtime-root; \
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib/ssl" "$root/usr/local/bin" "$root/etc" "$root/opt/convex/client"; \
    cp /bin/dash "$root/bin/dash"; ln -s dash "$root/bin/sh"; \
    cp /usr/bin/id /usr/bin/grep "$root/usr/bin/"; \
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
    cp -a /usr/share/ca-certificates "$root/usr/share/ca-certificates"; \
    { ldd /bin/dash; ldd /usr/bin/id; ldd /usr/bin/grep; ldd /usr/bin/lua5.1; \
      for module in $native_modules; do ldd "$module"; done; } | \
      awk '{ if ($3 ~ /^\//) print $3; if ($1 ~ /^\//) { path = $1; sub(/:$/, "", path); print path } }' | sort -u | while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libresolv.so.2; do test ! -e "$library" || cp --parents "$library" "$root"; done; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done; \
    test ! -e "$root/usr/bin/lua5.1"; \
    for version in 5.2 5.3 5.4; do test ! -d "$root/usr/share/lua/$version"; test ! -d "$root/usr/lib/x86_64-linux-gnu/lua/$version"; done; \
    for unused in socket/ftp.lua socket/smtp.lua http/server.lua openssl/pkcs12.lua openssl/cipher.lua cqueues/thread.lua; do test ! -e "$root/usr/share/lua/5.1/$unused"; done; \
    test ! -e "$root/usr/lib/x86_64-linux-gnu/lua/5.1/socket/serial.so"; \
    test -z "$(find "$root" -type f \( -name 'libapt*' -o -name 'libpam*' -o -name 'libsystemd*' -o -name 'libext2fs*' \) -print -quit)"

FROM scratch AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
COPY --from=runtime-rootfs /runtime-root /
COPY client/convex.lua /opt/convex/client/convex.lua
COPY client/live.lua /opt/convex/client/live.lua
COPY client/json.lua /opt/convex/client/json.lua
COPY client/tests/conformance/adapter_events.lua /opt/convex/client/adapter_events.lua
COPY client/tests/conformance/adapter_output.lua /opt/convex/client/adapter_output.lua
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.lua /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.lua /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
