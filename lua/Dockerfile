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
    lua-cjson=2.1.0+dfsg-2.2 lua-socket=3.1.0-1+b1 \
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
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib" "$root/usr/share" "$root/usr/local/bin" "$root/etc" "$root/opt/convex/client"; \
    cp /bin/dash "$root/bin/dash"; ln -s dash "$root/bin/sh"; \
    cp /usr/bin/id /usr/bin/grep "$root/usr/bin/"; \
    cp /usr/bin/lua5.1 "$root/usr/local/bin/lua"; \
    mkdir -p "$root/usr/lib/x86_64-linux-gnu"; cp -a /usr/lib/x86_64-linux-gnu/lua "$root/usr/lib/x86_64-linux-gnu/"; \
    cp -a /usr/lib/x86_64-linux-gnu/liblua* "$root/usr/lib/x86_64-linux-gnu/"; \
    cp -a /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3 "$root/usr/lib/x86_64-linux-gnu/"; \
    mkdir -p "$root/lib/x86_64-linux-gnu"; cp -a /lib/x86_64-linux-gnu/*.so.* "$root/lib/x86_64-linux-gnu/"; \
    cp -a /usr/share/lua "$root/usr/share/"; \
    cp -a /etc/ssl "$root/etc/ssl"; cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/share/ca-certificates "$root/usr/share/ca-certificates"; \
    { ldd /bin/dash /usr/bin/id /usr/bin/grep /usr/bin/lua5.1; find /usr/lib/x86_64-linux-gnu/lua -type f -name '*.so' -exec ldd '{}' ';'; } | \
      awk '{ if ($3 ~ /^\//) print $3; if ($1 ~ /^\//) { path = $1; sub(/:$/, "", path); print path } }' | sort -u | while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done

FROM scratch AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
COPY --from=runtime-rootfs /runtime-root /
COPY client/convex.lua /opt/convex/client/convex.lua
COPY client/live.lua /opt/convex/client/live.lua
COPY client/tests/conformance/adapter_events.lua /opt/convex/client/adapter_events.lua
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.lua /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.lua /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
