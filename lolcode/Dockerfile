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
RUN gcc -std=c17 -Wall -Wextra -Werror /project/client/tests/http_fixture.c \
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

FROM test AS runtime
ENTRYPOINT ["/src/build/lci"]

FROM test AS example-runtime
ENTRYPOINT ["/src/build/lci", "/project/client/convex.lol", "/project/examples/basics/main.lol"]
