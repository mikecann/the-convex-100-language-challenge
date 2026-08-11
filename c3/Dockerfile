# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
FROM ${DEBIAN_IMAGE} AS build
ARG C3_VERSION=0.8.2
ARG CURL_VERSION=7.88.1-10+deb12u15
ARG OPENSSL_VERSION=3.0.20-1~deb12u2
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl=${CURL_VERSION} libcurl4-openssl-dev=${CURL_VERSION} \
      libssl-dev=${OPENSSL_VERSION} openssl=${OPENSSL_VERSION} gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:dda062e791359d01549c5d1aefbac5ac88dcd9c6f84e0b2d3309e92f8f6600aa \
  https://github.com/c3lang/c3c/releases/download/v${C3_VERSION}/c3-linux-static.tar.gz /tmp/c3.tar.gz
RUN tar -xzf /tmp/c3.tar.gz -C /opt && test "$(/opt/c3/c3c --version | awk '/C3 Compiler Version/ {print $4}')" = "$C3_VERSION"
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN gcc -std=c17 -Wall -Wextra -Werror -c client/platform.c -o /out-platform.o && \
    C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -l curl -l crypto -o /out-adapter client/adapter.c3 client/http.c3 client/live.c3 client/values.c3 client/response.c3 /opt/c3/lib/std/core/string_escape.c3 /out-platform.o && \
    C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -l curl -l crypto -o /out-example examples/basics/main.c3 client/http.c3 client/live.c3 client/response.c3 client/values.c3 /opt/c3/lib/std/core/string_escape.c3 /out-platform.o && \
    readelf -h /out-adapter | grep 'Advanced Micro Devices X86-64'
FROM build AS test
RUN openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=C3-WebSocket-Test-CA \
      -keyout /tmp/ws-ca-key.pem -out /tmp/ws-ca.pem >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost -keyout /tmp/ws-server-key.pem -out /tmp/ws-server.csr >/dev/null 2>&1 \
    && printf 'subjectAltName=DNS:localhost\n' >/tmp/ws-server.ext \
    && openssl x509 -req -days 1 -in /tmp/ws-server.csr -CA /tmp/ws-ca.pem -CAkey /tmp/ws-ca-key.pem \
      -CAcreateserial -extfile /tmp/ws-server.ext -out /tmp/ws-server.pem >/dev/null 2>&1 \
    && gcc -std=c17 -Wall -Wextra -Werror -c client/tests/http-platform-fixture.c -o /out-http-platform-fixture.o \
    && gcc -std=c17 -Wall -Wextra -Werror client/tests/websocket-platform-fixture.c client/platform.c \
      -lcurl -lssl -lcrypto -o /out-websocket-platform-fixture \
    && gcc -std=c17 -Wall -Wextra -Werror -c client/tests/live-protocol-platform-fixture.c \
      -o /out-live-protocol-platform-fixture.o \
    && gcc -std=c17 -Wall -Wextra -Werror client/tests/adapter-tcp-fixture.c -o /out-adapter-tcp-fixture \
    && C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -o /out-http-fixtures \
      client/tests/http-response-fixtures.c3 client/http.c3 client/response.c3 client/values.c3 /out-http-platform-fixture.o \
    && C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -l curl -l crypto -o /out-live-buffer-fixture \
      client/tests/live-buffer-fixture.c3 client/live.c3 /out-platform.o \
    && C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -o /out-live-protocol-fixture \
      client/tests/live-protocol-fixture.c3 client/live.c3 /out-live-protocol-platform-fixture.o \
    && C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -o /out-example-unexpected \
      examples/basics/main.c3 client/http.c3 client/live.c3 client/response.c3 client/values.c3 \
      /opt/c3/lib/std/core/string_escape.c3 /out-http-platform-fixture.o /out-live-protocol-platform-fixture.o \
    && /out-http-fixtures \
    && /out-websocket-platform-fixture \
    && /out-live-buffer-fixture \
    && /out-live-protocol-fixture \
    && if CONVEX_URL=https://fixture.invalid /out-example-unexpected fixture-room \
      >/tmp/unexpected.stdout 2>/tmp/unexpected.stderr; then exit 1; fi \
    && test ! -s /tmp/unexpected.stdout \
    && grep -Fx 'expected initial counter 0' /tmp/unexpected.stderr \
    && test "$(uname -m)" = x86_64 \
    && printf '%s\\n' '{"protocolVersion":1,"id":"hello-1","op":"hello"}' | /out-adapter | grep -Fx '{"protocolVersion":1,"id":"hello-1","type":"ready","language":"c3","implementation":"native","runtime":"C3 0.8.2"}' \
    && (ADAPTER_LISTEN=127.0.0.1:43123 /out-adapter & adapter_pid=$!; /out-adapter-tcp-fixture || { kill "$adapter_pid"; exit 1; }; wait "$adapter_pid") \
    && test -x /out-example

# Assemble an allowlisted runtime filesystem with the complete dynamic TLS,
# DNS, and CA closure. The final image remains Debian-based, but carries no
# compiler, package manager, curl command, or undeclared language runtime.
FROM test AS runtime-rootfs
RUN set -eu; \
    root=/runtime; \
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" "$root/etc" \
      "$root/usr/lib/x86_64-linux-gnu"; \
    cp /bin/dash "$root/bin/sh"; \
    cp /usr/bin/id "$root/usr/bin/id"; \
    cp /usr/bin/grep "$root/usr/bin/grep"; \
    cp /out-example "$root/usr/local/bin/convex-example"; \
    cp /out-adapter "$root/usr/local/bin/convex-adapter"; \
    libraries="$({ for binary in /bin/dash /usr/bin/id /usr/bin/grep /out-example /out-adapter; do ldd "$binary"; done; } \
      | awk '$3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' | sort -u)"; \
    for library in $libraries; do cp --parents -L "$library" "$root"; done; \
    for nss in /usr/lib/x86_64-linux-gnu/libnss_dns.so.2 \
      /usr/lib/x86_64-linux-gnu/libnss_files.so.2 \
      /usr/lib/x86_64-linux-gnu/libresolv.so.2; do \
      test -e "$nss" && cp --parents -L "$nss" "$root" || true; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/lib/x86_64-linux-gnu/engines-3 "$root/usr/lib/x86_64-linux-gnu/"; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$root/usr/lib/x86_64-linux-gnu/"; \
    cp /etc/nsswitch.conf /etc/hosts "$root/etc/"
RUN set -eu; \
    test -r /runtime/etc/ssl/certs/ca-certificates.crt; \
    events="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | chroot /runtime /usr/local/bin/convex-adapter)"; \
    echo "$events" | grep -Fq '"language":"c3"'; \
    echo "$events" | grep -Fq '"type":"closed"'

FROM ${DEBIAN_IMAGE} AS runtime-base
RUN set -eu; \
    for entry in /etc/*; do \
      case "$entry" in /etc/hostname|/etc/hosts|/etc/resolv.conf) ;; *) /usr/bin/rm -rf "$entry" ;; esac; \
    done; \
    /usr/bin/rm -rf /bin /sbin /usr /lib /lib64 /var /opt /root /home /tmp
COPY --from=runtime-rootfs /runtime /
RUN set -eu; \
    for command in sh id grep; do command -v "$command" >/dev/null; done; \
    for candidate in /bin/* /usr/bin/* /usr/local/bin/*; do \
      case "$candidate" in \
        /bin/sh|/usr/bin/id|/usr/bin/grep|/usr/local/bin/convex-example|/usr/local/bin/convex-adapter) ;; \
        *) test ! -x "$candidate" ;; \
      esac; \
    done; \
    for command in apk apt apt-get dpkg gcc g++ cc clang make curl wget nc netcat \
      node npm python python3 pip ruby java go rustc cargo c3c convex; do \
      ! command -v "$command" >/dev/null 2>&1; \
    done; \
    test "$(/usr/local/bin/convex-example 2>&1 || true)" = "usage: convex-example ROOM"; \
    events="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | /usr/local/bin/convex-adapter)"; \
    echo "$events" | grep -Fq '"language":"c3"'; \
    echo "$events" | grep -Fq '"type":"closed"'
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
