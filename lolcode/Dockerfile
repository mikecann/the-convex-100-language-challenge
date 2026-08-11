# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS build
ARG LCI_COMMIT=2464d0c11712ba447747492e809d6a87a3af1922
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ca-certificates=20250419~deb12u1 \
       cmake=3.25.1-1 \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       libcurl4-openssl-dev=7.88.1-10+deb12u15 \
       libjansson-dev=2.14-2 \
       libreadline-dev=8.2-1.3 \
       libssl-dev=3.0.20-1~deb12u2 \
       make=4.3-4.1 \
       patch=2.7.6-7 \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:89390b01982067a35960f0232150fa25e771781ccbde06e34f99863153076349 \
    https://github.com/justinmeza/lci/archive/2464d0c11712ba447747492e809d6a87a3af1922.tar.gz /tmp/lci.tar.gz
WORKDIR /src
RUN tar -xzf /tmp/lci.tar.gz --strip-components=1 \
    && test "$(git --version 2>/dev/null || true)" = ""
COPY client/platform.c ./platform.c
COPY client/transport.c ./transport.c
COPY client/lci-runtime.patch /tmp/lci-runtime.patch
RUN patch -p1 < /tmp/lci-runtime.patch \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --parallel 2 \
    && test "$(uname -m)" = x86_64 \
    && readelf -h build/lci | grep -F 'Advanced Micro Devices X86-64'

COPY client /project/client
COPY examples /project/examples
FROM build AS test
RUN /src/build/lci /project/client/convex.lol /project/client/tests/smoke.lol \
    | grep -Fx 'lolcode runtime bindings: ok'
RUN /src/build/lci /project/client/convex.lol /project/client/live.lol \
      /project/client/tests/live_test.lol \
    | grep -Fx 'lolcode Live state fixtures: ok'
RUN /src/build/lci /project/client/convex.lol /project/client/live.lol \
      /project/client/tests/conformance/main.lol </dev/null
RUN set -eu; \
    gcc -std=c17 -Wall -Wextra -Werror /project/client/tests/adapter_tcp_fixture.c \
      -o /tmp/adapter-tcp-fixture; \
    ADAPTER_LISTEN=127.0.0.1:43123 \
      /src/build/lci /project/client/convex.lol /project/client/live.lol \
      /project/client/tests/conformance/main.lol & adapter_pid=$!; \
    trap 'kill "$adapter_pid" 2>/dev/null || true' EXIT; \
    /tmp/adapter-tcp-fixture | grep -Fx 'lolcode adapter TCP fixture: ok'; \
    fixture_status=$?; \
    wait "$adapter_pid"; adapter_status=$?; \
    trap - EXIT; \
    test "$fixture_status" -eq 0; test "$adapter_status" -eq 0
RUN openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=LOLCODE-WebSocket-Test-CA \
      -keyout /tmp/ws-ca-key.pem -out /tmp/ws-ca.pem >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost -keyout /tmp/ws-server-key.pem \
      -out /tmp/ws-server.csr >/dev/null 2>&1 \
    && printf 'subjectAltName=DNS:localhost\n' >/tmp/ws-server.ext \
    && openssl x509 -req -days 1 -in /tmp/ws-server.csr -CA /tmp/ws-ca.pem \
      -CAkey /tmp/ws-ca-key.pem -CAcreateserial -extfile /tmp/ws-server.ext \
      -out /tmp/ws-server.pem >/dev/null 2>&1 \
    && gcc -std=c17 -Wall -Wextra -Werror \
      /project/client/tests/websocket_fixture.c /project/client/transport.c \
      -lcurl -lssl -lcrypto -o /tmp/websocket-fixture \
    && /tmp/websocket-fixture | grep -Fx 'lolcode websocket transport fixture: ok'
RUN set -eu; \
    gcc -std=c17 -Wall -Wextra -Werror /project/client/tests/http_fixture.c \
      -o /tmp/http-fixture; \
    /tmp/http-fixture & fixture_pid=$!; \
    trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT; \
    CONVEX_URL=http://127.0.0.1:43140 \
      /src/build/lci /project/client/convex.lol /project/client/tests/http_test.lol \
      | grep -Fx 'lolcode HTTP fixtures: ok'; \
    test_status=$?; \
    if test "$test_status" -ne 0; then exit "$test_status"; fi; \
    wait "$fixture_pid"; fixture_status=$?; \
    trap - EXIT; \
    test "$fixture_status" -eq 0
RUN set -eu; \
    /tmp/http-fixture & fixture_pid=$!; \
    trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT; \
    output="$(printf '%s\n' \
      '{"protocolVersion":1,"id":"h","op":"hello"}' \
      '{"id":"q","op":"query","path":"counter:get","args":{}}' \
      '{"id":"a","op":"action","path":"counter:fail","args":{}}' \
      '{"id":"p","op":"query","path":"counter:missing","args":{}}' \
      '{"id":"c","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:43140 /src/build/lci \
        /project/client/convex.lol /project/client/live.lol \
        /project/client/tests/conformance/main.lol)"; \
    adapter_status=$?; wait "$fixture_pid"; fixture_status=$?; \
    trap - EXIT; \
    test "$adapter_status" -eq 0; test "$fixture_status" -eq 0; \
    test "$(printf '%s\n' "$output" | wc -l)" -eq 5; \
    printf '%s\n' "$output" | grep -Fx '{"protocolVersion":1,"id":"h","type":"ready","language":"lolcode","implementation":"native","runtime":"lci 0.11.2"}'; \
    printf '%s\n' "$output" | grep -Fx '{"id":"q","type":"result","value":0.0,"logs":["HAI"]}'; \
    printf '%s\n' "$output" | grep -Fx '{"id":"a","type":"error","error":{"name":"FunctionError","message":"fixture failed","data":{"code":7}},"logs":[]}'; \
    printf '%s\n' "$output" | grep -Fx '{"id":"p","type":"error","error":{"name":"ProtocolError","message":"Convex success omitted value"}}'; \
    printf '%s\n' "$output" | grep -Fx '{"id":"c","type":"closed"}'
RUN set -eu; \
    output="$(printf '%s\n' \
      'not-json' \
      '{"id":"t","op":"query","path":"counter:get","args":{}}' \
      '{"id":"c","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 /src/build/lci \
        /project/client/convex.lol /project/client/live.lol \
        /project/client/tests/conformance/main.lol)"; \
    test "$(printf '%s\n' "$output" | wc -l)" -eq 3; \
    printf '%s\n' "$output" | grep -Fx '{"type":"error","error":{"name":"ProtocolError","message":"invalid adapter JSON"}}'; \
    printf '%s\n' "$output" | grep -F '"id":"t","type":"error","error":{"name":"TransportError"' \
      | grep -Fv '"data"' | grep -Fv '"logs"'; \
    printf '%s\n' "$output" | grep -Fx '{"id":"c","type":"closed"}'
RUN set -eu; \
    gcc -std=c17 -Wall -Wextra -Werror /project/client/tests/live_protocol_fixture.c \
      -lcrypto -o /tmp/live-protocol-fixture; \
    rm -f /tmp/live-server.ready; \
    /tmp/live-protocol-fixture > /tmp/live-server.out & server_pid=$!; \
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT; \
    attempt=0; \
    while ! test -f /tmp/live-server.ready; do \
      kill -0 "$server_pid"; \
      attempt=$((attempt + 1)); \
      test "$attempt" -lt 100; \
      sleep 0.01; \
    done; \
    output="$( { \
      printf '%s\n' \
        '{"protocolVersion":1,"id":"h","op":"hello"}' \
        '{"id":"s","op":"subscribe","subscriptionId":"sub","path":"counter:get","args":{}}'; \
      sleep 1; \
      printf '%s\n' '{"id":"d1","op":"debugDisconnect"}'; sleep 1; \
      printf '%s\n' '{"id":"d2","op":"debugDisconnect"}'; sleep 1; \
      printf '%s\n' '{"id":"d3","op":"debugDisconnect"}'; sleep 1; \
      printf '%s\n' '{"id":"d4","op":"debugDisconnect"}'; sleep 1; \
      printf '%s\n' '{"id":"d5","op":"debugDisconnect"}'; sleep 1; \
      printf '%s\n' \
        '{"id":"u","op":"unsubscribe","subscriptionId":"sub"}' \
        '{"id":"c","op":"close"}'; \
    } | CONVEX_URL=http://127.0.0.1:43142 /src/build/lci \
      /project/client/convex.lol /project/client/live.lol \
      /project/client/tests/conformance/main.lol )"; \
    adapter_status=$?; wait "$server_pid"; server_status=$?; trap - EXIT; \
    test "$adapter_status" -eq 0; test "$server_status" -eq 0; \
    grep -Fx 'lolcode Live protocol fixture: ok' /tmp/live-server.out; \
    test "$(printf '%s\n' "$output" | grep -Fc '"type":"subscription"')" -eq 2; \
    printf '%s\n' "$output" | grep -Fx '{"type":"subscription","subscriptionId":"sub","value":0,"logs":[]}'; \
    printf '%s\n' "$output" | grep -Fx '{"type":"subscription","subscriptionId":"sub","value":1,"logs":[]}'; \
    test "$(printf '%s\n' "$output" | grep -Ec '\"id\":\"d[1-5]\",\"type\":\"ack\"')" -eq 5; \
    printf '%s\n' "$output" | grep -Fx '{"id":"u","type":"ack"}'; \
    printf '%s\n' "$output" | grep -Fx '{"id":"c","type":"closed"}'
RUN gcc -std=c17 -Wall -Wextra -Werror \
      /project/client/tests/stopped_reader_fixture.c \
      -o /usr/local/bin/lolcode-stopped-reader-fixture

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ca-certificates=20250419~deb12u1 \
       libcurl4=7.88.1-10+deb12u15 \
       libjansson4=2.14-2 \
       libreadline8=8.2-1.3 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* \
       /usr/bin/openssl /usr/bin/perl /usr/bin/perl5* \
    && test "$(uname -m)" = x86_64 \
    && test -x /bin/sh
COPY --from=build /src/build/lci /usr/local/bin/lci
COPY client/convex.lol /opt/lolcode/client/convex.lol
COPY client/live.lol /opt/lolcode/client/live.lol
COPY client/tests/conformance/main.lol /opt/lolcode/client/tests/conformance/main.lol
COPY examples/basics/main.lol /opt/lolcode/examples/basics/main.lol
COPY client/run-adapter.sh /usr/local/bin/convex-adapter
COPY client/run-example.sh /usr/local/bin/convex-example
RUN chmod 0555 /usr/local/bin/lci /usr/local/bin/convex-adapter \
      /usr/local/bin/convex-example \
    && ldd /usr/local/bin/lci \
    && /usr/local/bin/lci --version 2>&1 | grep -F 'lci v0.11.2' \
    && for command in apt apt-get dpkg gcc cc make cmake curl openssl \
         python python3 node npm perl convex; do \
         ! command -v "$command"; \
       done
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
