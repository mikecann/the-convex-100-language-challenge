# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: build Harbour from source, lint, compile every client and test
# program this image ships, and run every language-local suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/root
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       build-essential \
       git \
       libssl-dev \
       ca-certificates \
       openssl \
       file \
       binutils \
       netcat-traditional \
    && rm -rf /var/lib/apt/lists/*

# Harbour is not packaged for Debian, so it is built from the upstream
# harbour-project.org repository. Cloning by branch and then asserting the
# exact commit protects against the tag ever being force-moved upstream.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    git clone --quiet --branch v3.2.0 https://github.com/harbour/core.git /harbour-core; \
    cd /harbour-core; \
    test "$(git rev-parse HEAD)" = a7e5dd2b8c6b53d44c69b351f5fddf9c87854ada; \
    make >/tmp/hb-make.log 2>&1 || { tail -n 200 /tmp/hb-make.log; exit 1; }; \
    make install >/tmp/hb-install.log 2>&1 || { tail -n 100 /tmp/hb-install.log; exit 1; }; \
    hbmk2 --version 2>&1 | tee /project/runtime-version | grep -Eq '^Harbour Make \(hbmk2\) 3\.2\.0'; \
    test -s /project/runtime-version

COPY client ./client
COPY examples ./examples

# Harbour has no standard formatter, so the style gate is explicit: spaces
# only, no trailing blanks, and a final newline. The canonical example is
# held to 80 columns because it is rendered verbatim in the README and on
# the website; client code and test-only code are held to 120.
RUN set -eu; \
    files=$(find client examples -name '*.prg'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      case "$f" in examples/*) width=80 ;; *) width=120 ;; esac; \
      if awk -v width="$width" \
             'length > width { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over $width columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS harbour source style"

# Every hbmk2 invocation below shares the same fixed set of flags: -static
# links Harbour's own runtime (libcim... libharbour.a) rather than the
# shared libharbour.so hbmk2 would otherwise produce and a minimal runtime
# image would then need to carry too; -gtcgi selects Harbour's
# non-interactive console driver, because the default GTSTD driver writes
# ANSI cursor-positioning escape codes to stdout even when stdout is a
# pipe, which corrupts both the NDJSON adapter protocol and the byte-exact
# example transcript; -mt links the multithread-capable runtime that
# client/convexlive.prg's hb_threadStart() Live worker needs.
RUN set -eu; \
    hb_flags="-static -gtcgi -mt"; \
    client_files="client/convexcore.prg client/convexjson.prg client/convextls.prg \
      client/convextls_native.c \
      client/convexhttp.prg client/convexws.prg client/convexlive.prg client/convex.prg"; \
    mkdir -p /build; \
    cd /build; \
    hbmk2 $hb_flags $(printf '/project/%s ' $client_files) \
      /project/client/tests/client_test.prg hbssl.hbc -oclient-test; \
    hbmk2 $hb_flags $(printf '/project/%s ' $client_files) \
      /project/client/tests/tls_test.prg hbssl.hbc -otls-test; \
    hbmk2 $hb_flags $(printf '/project/%s ' $client_files) \
      /project/client/tests/conformance/adapter.prg hbssl.hbc -oconvex-adapter; \
    hbmk2 $hb_flags $(printf '/project/%s ' $client_files) \
      /project/examples/basics/main.prg hbssl.hbc -oconvex-example

RUN set -eu; /build/client-test

# TLS verification needs a peer, so a private CA and a local TLS server
# stand in for one. The untrusted and wrong-host modes are the ones that
# would still pass on a client that quietly skipped verification.
RUN set -eu; \
    mkdir -p /tmp/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=harbour-test-ca' \
      -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=harbour-other-ca' \
      -keyout /tmp/tls/other.key -out /tmp/tls/other.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
      -keyout /tmp/tls/server.key -out /tmp/tls/server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in /tmp/tls/server.csr \
      -CA /tmp/tls/ca.crt -CAkey /tmp/tls/ca.key -CAcreateserial \
      -copy_extensions copy -out /tmp/tls/server.crt >/dev/null 2>&1; \
    openssl s_server -accept 44300 -naccept 32 \
      -cert /tmp/tls/server.crt -key /tmp/tls/server.key -www \
      >/dev/null 2>&1 & \
    server_pid=$!; \
    sleep 2; \
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_MODE=trusted /build/tls-test; \
    SSL_CERT_FILE=/tmp/tls/other.crt TLS_MODE=untrusted /build/tls-test; \
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_MODE=wronghost /build/tls-test; \
    kill "$server_pid" 2>/dev/null || true

# The example must fail loudly without a deployment, and must print nothing
# on stdout when it does, because stdout is the shared happy-path transcript.
RUN set -eu; \
    code=0; \
    /build/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# The commands are written to a file first and read with < rather than
# piped directly, so the adapter's own read loop never races a
# concurrently running producer process for its very first bytes.
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    code=0; \
    CONVEX_URL=http://127.0.0.1:1 /build/convex-adapter \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out 2>/tmp/adapter-probe.err \
      || code=$?; \
    echo "adapter exit code: $code"; \
    echo "--- stdout ---"; cat /tmp/adapter-probe.out; \
    echo "--- stderr ---"; cat /tmp/adapter-probe.err; \
    echo "--- end ---"; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"harbour"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# The same hello/close probe over the ADAPTER_LISTEN TCP mode the shared
# harness actually drives the built image with. Polling /proc/net/tcp for
# the listening port (18080 = 0x46A0) rather than a fixed sleep avoids
# depending on how quickly the adapter happens to reach hb_inetServer(),
# matching the same pattern already used by seed7/Dockerfile.
RUN set -eu; \
    CONVEX_URL=http://127.0.0.1:1 ADAPTER_LISTEN=127.0.0.1:18080 /build/convex-adapter & \
    adapter_pid=$!; \
    waited=0; \
    until grep -Fq ':46A0 ' /proc/net/tcp 2>/dev/null; do \
      waited=$((waited + 1)); test "$waited" -lt 50; sleep 0.1; \
    done; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"tcp-hello","op":"hello"}' \
      '{"id":"tcp-close","op":"close"}' \
    > /tmp/adapter-tcp.in; \
    actual=$(cat /tmp/adapter-tcp.in | nc -w 2 127.0.0.1 18080); \
    wait "$adapter_pid"; \
    printf '%s\n' "$actual" | grep -Fq '"type":"ready"'; \
    printf '%s\n' "$actual" | grep -Fq '"id":"tcp-hello"'; \
    printf '%s\n' "$actual" | grep -Fq '"type":"closed"'; \
    printf '%s\n' "$actual" | grep -Fq '"id":"tcp-close"'

# Stage the shared part of the runtime closure -- everything except the two
# program binaries themselves, which are copied separately into their own
# final stage below so convex-example never ships beside convex-adapter or
# vice versa. Both binaries are genuine native ELF executables: Harbour's
# own runtime is linked statically (-static, above), so no hbmk2, no
# .hbc/.hbp project machinery and no Harbour compiler travels with them,
# and ldd resolves the small set of shared libraries each one actually
# needs (OpenSSL, libc, libm) plus glibc's NSS modules, which
# hb_inetConnect()'s hostname resolution loads at runtime through
# getaddrinfo() rather than linking directly. ldd is run once per binary
# rather than on the whole tree at once, because a multi-file ldd
# invocation prints one header line per binary ahead of its dependency
# list, which a naive parse would otherwise treat as a library path.
RUN set -eu; \
    mkdir -p /closure/bin /closure/usr/bin /closure/usr/local/bin \
             /closure/etc/ssl/certs \
             /closure/usr/lib/x86_64-linux-gnu/ossl-modules \
             /closure/usr/lib/x86_64-linux-gnu \
             /closure/tmp; \
    chmod 1777 /closure/tmp; \
    for name in cat cut head tail tr sort uniq wc uname grep sed id; do \
      cp -aL "$(command -v "$name")" /closure/usr/bin/"$name"; \
    done; \
    cp -aL /usr/bin/mawk /closure/usr/bin/awk; \
    cp -aL /bin/dash /closure/bin/sh; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /closure/etc/ssl/certs/; \
    cp -aL /etc/ssl/openssl.cnf /closure/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /closure/etc/nsswitch.conf; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
           /closure/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL /lib/x86_64-linux-gnu/"$lib" \
             /closure/usr/lib/x86_64-linux-gnu/"$lib"; \
    done; \
    for round in 1 2 3; do \
      for elf in /build/convex-example \
                 /build/convex-adapter \
                 /closure/bin/sh \
                 /closure/usr/bin/*; do \
        ldd "$elf" 2>/dev/null \
          | awk '{ for (i = 1; i <= NF; i++) \
                     if (substr($i, 1, 1) == "/") print $i }'; \
      done \
        | sort -u \
        | while read -r lib; do \
            test -e "/closure$lib" || { \
              mkdir -p "/closure$(dirname "$lib")"; \
              cp -aL "$lib" "/closure$(dirname "$lib")/"; \
            }; \
          done; \
    done

# The two entrypoints are staged separately so each minimal image carries
# only its own program. The room argument reaches the example through
# EXAMPLE_ROOM, matching every other native client in this project.
RUN set -eu; \
    mkdir -p /entry; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# The verifier passes a unique room as the first argument.' \
      'if [ "$#" -gt 0 ]; then' \
      '  EXAMPLE_ROOM="$1"' \
      '  export EXAMPLE_ROOM' \
      'fi' \
      'exec /usr/local/bin/convex-example' \
      > /entry/convex-example; \
    chmod 755 /entry/convex-example

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its filesystem removed and only the
# declared closure copied back
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# `rm` must be exec'd exactly once -- a loop calling `command -v` per path
# is unsafe once /bin or /usr starts being deleted mid-loop.
RUN set -eu; \
    set -- /bin /boot /home /lib /lib64 /media /mnt /opt /root \
           /run /sbin /srv /usr /var /etc/.pwd.lock; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) set -- "$@" "$path" ;; \
      esac; \
    done; \
    rm -rf "$@"
COPY --from=test /closure/ /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532

# Prove the policy the shared verifier depends on from inside the final
# filesystem, not from the build stage that produced it.
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test -s "$SSL_CERT_FILE"; \
    test "$(uname -m)" = x86_64; \
    test "$(printf 'ok\n' | cat)" = ok; \
    test "$(printf 'a:b\n' | cut -d: -f2)" = b; \
    test "$(printf 'first\nsecond\n' | head -n 1)" = first; \
    test "$(printf 'first\nsecond\n' | tail -n 1)" = second; \
    test "$(printf 'a\n' | tr a A)" = A; \
    test "$(printf 'b\na\n' | sort | head -n 1)" = a; \
    test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1; \
    printf 'needle\n' | grep -Fqx needle; \
    test "$(printf 'before\n' | sed 's/before/after/')" = after; \
    test "$(printf 'value\n' | awk '{print $1}')" = value; \
    test ! -e /etc/dpkg; \
    test ! -e /var; \
    test ! -e /usr/share/doc; \
    test ! -e /usr/include; \
    test ! -e /usr/src; \
    set -- /bin/*; test "$#" -eq 1; test "$1" = /bin/sh; \
    for command_name in gcc cc clang ld make cmake libtool hbmk2 harbour apt apt-get \
        dpkg curl wget nc netcat ssh openssl node python python3 ruby perl \
        java php go rustc cargo npm pip convex; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test --chmod=755 /build/convex-example /usr/local/bin/convex-example
COPY --from=test --chmod=755 /entry/convex-example /usr/local/bin/convex-example-entry
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example-entry; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example-entry"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build harbour` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test --chmod=755 /build/convex-adapter /usr/local/bin/convex-adapter
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out; \
    cat /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
