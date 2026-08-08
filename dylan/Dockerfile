# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: install Open Dylan from its official release tarball, compile
# every target this client ships, and run every language-local suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       binutils \
       wget \
       bzip2 \
    && rm -rf /var/lib/apt/lists/*

# Open Dylan ships as a prebuilt x86_64 Linux release tarball (MIT
# licence); there is no source build. The checksum pins the exact bytes
# this client is built and reviewed against.
ARG OPENDYLAN_VERSION=2026.2
ARG OPENDYLAN_URL=https://github.com/dylan-lang/opendylan/releases/download/v2026.2.0/opendylan-2026.2-x86_64-linux.tar.bz2
ARG OPENDYLAN_SHA256=d917efed6d82aae3a31746eee0a46e8095a898d183d730ad8198961b5efa2197
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    cd /tmp; \
    wget -q "$OPENDYLAN_URL" -O opendylan.tar.bz2; \
    echo "$OPENDYLAN_SHA256  opendylan.tar.bz2" | sha256sum -c -; \
    tar xjf opendylan.tar.bz2; \
    mv "opendylan-$OPENDYLAN_VERSION" /opt/opendylan; \
    rm opendylan.tar.bz2; \
    /opt/opendylan/bin/dylan-compiler -version 2>&1 | head -n 1; \
    /opt/opendylan/bin/dylan-compiler -version 2>&1 | grep -Fq "$OPENDYLAN_VERSION"; \
    printf 'opendylan-%s' "$OPENDYLAN_VERSION" > /project/runtime-version
ENV PATH=/opt/opendylan/bin:$PATH

COPY client ./client
COPY examples ./examples

# Open Dylan has no standard source formatter, so -- matching this
# project's ALGOL 60 and Forth clients, which are in the same position --
# the style gate is explicit: spaces only, no trailing blanks, a final
# newline, and a column limit (80 for the example, which is rendered
# verbatim in the README and on the website; 120 elsewhere, since a
# C-FFI declaration block or a fully-spelled-out Dylan keyword argument
# list needs more room than the equivalent in a terser language).
RUN set -eu; \
    files=$(find client examples -name '*.dylan'); \
    test -n "$files"; \
    for f in $files; do \
      if grep -Pq '\t' "$f"; then echo "tab in $f" >&2; exit 1; fi; \
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
    echo "PASS dylan source style"

# Every compiled target is built in its own directory containing the
# shared "convex" library sources plus that target's own entry-point
# file and LID, because Open Dylan resolves a library's own sources by
# plain relative filename rather than through a registry entry this
# project's public layout has nowhere honest to put (see
# client/convex-library.dylan's header comment). This mirrors how
# algol60/Dockerfile assembles each of its own targets.
RUN set -eu; \
    for target in client-test live-test tls-test; do \
      mkdir -p "/build/$target"; \
      cp client/convex-library.dylan client/convex-native.dylan client/convex-json.dylan \
         client/convex-http.dylan client/convex-ws.dylan client/convex-sync.dylan \
         "/build/$target/"; \
      cp "client/tests/$target.dylan" "client/tests/$target.lid" "/build/$target/"; \
    done; \
    mkdir -p /build/adapter /build/example; \
    cp client/convex-library.dylan client/convex-native.dylan client/convex-json.dylan \
       client/convex-http.dylan client/convex-ws.dylan client/convex-sync.dylan \
       /build/adapter/; \
    cp client/tests/conformance/adapter.dylan client/tests/conformance/adapter.lid /build/adapter/; \
    cp client/convex-library.dylan client/convex-native.dylan client/convex-json.dylan \
       client/convex-http.dylan client/convex-ws.dylan client/convex-sync.dylan \
       /build/example/; \
    cp examples/basics/main.dylan examples/basics/main.lid /build/example/; \
    for target in client-test live-test tls-test adapter example; do \
      ( cd "/build/$target" && dylan-compiler -build *.lid ); \
    done; \
    test -x /build/client-test/_build/bin/client-test; \
    test -x /build/live-test/_build/bin/live-test; \
    test -x /build/tls-test/_build/bin/tls-test; \
    test -x /build/adapter/_build/bin/convex-adapter; \
    test -x /build/example/_build/bin/convex-example

RUN set -eu; /build/client-test/_build/bin/client-test
RUN set -eu; /build/live-test/_build/bin/live-test

# TLS verification needs a peer, so a private CA and a local TLS server
# stand in for one. The untrusted and wrong-host modes are the ones that
# would still pass on a client that quietly skipped verification.
RUN set -eu; \
    mkdir -p /tmp/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=dylan-test-ca' \
      -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=dylan-other-ca' \
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
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_MODE=trusted /build/tls-test/_build/bin/tls-test; \
    SSL_CERT_FILE=/tmp/tls/other.crt TLS_MODE=untrusted /build/tls-test/_build/bin/tls-test; \
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_MODE=wronghost /build/tls-test/_build/bin/tls-test; \
    kill "$server_pid" 2>/dev/null || true

# The example must fail loudly without a deployment, and must print
# nothing on stdout when it does, because stdout is the shared
# happy-path transcript.
RUN set -eu; \
    code=0; \
    /build/example/_build/bin/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# The commands are written to a file first and read with < rather than
# piped directly, so the adapter's own poll-and-read loop never races a
# concurrently running producer process for its very first bytes.
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    code=0; \
    CONVEX_URL=http://127.0.0.1:1 /build/adapter/_build/bin/convex-adapter \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out 2>/tmp/adapter-probe.err \
      || code=$?; \
    echo "adapter exit code: $code"; \
    echo "--- stdout ---"; cat /tmp/adapter-probe.out; \
    echo "--- stderr ---"; cat /tmp/adapter-probe.err; \
    echo "--- end ---"; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"dylan"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Stage one runtime closure per final image, not one shared between them:
# each of client-test/live-test/tls-test/adapter/example was built by its
# own independent `dylan-compiler -build`, and Open Dylan stamps every
# compiled library with a version check against the exact build of each
# library it depends on. Pairing convex-example's own libconvex-example.so
# with, say, the adapter build's libc-ffi.so trips that check at runtime
# ("library ... was compiled ... against an older version") even though
# the two came from the same Open Dylan release -- so /closure-adapter and
# /closure-example below each pull their generic Dylan runtime libraries
# from their own build directory, never the other one's.
RUN set -eu; \
    for target in adapter example; do \
      mkdir -p "/closure-$target/usr/local/bin" "/closure-$target/usr/local/lib" \
               "/closure-$target/usr/bin" "/closure-$target/bin" \
               "/closure-$target/etc/ssl/certs" \
               "/closure-$target/usr/lib/x86_64-linux-gnu/ossl-modules" \
               "/closure-$target/usr/lib/x86_64-linux-gnu" \
               "/closure-$target/tmp"; \
      chmod 1777 "/closure-$target/tmp"; \
      for name in cat cut head tail tr sort uniq wc uname grep sed id; do \
        cp -aL "$(command -v "$name")" "/closure-$target/usr/bin/$name"; \
      done; \
      cp -aL /usr/bin/mawk "/closure-$target/usr/bin/awk"; \
      cp -aL /bin/dash "/closure-$target/bin/sh"; \
      cp -aL /etc/ssl/certs/ca-certificates.crt "/closure-$target/etc/ssl/certs/"; \
      cp -aL /etc/ssl/openssl.cnf "/closure-$target/etc/ssl/openssl.cnf"; \
      cp -aL /etc/nsswitch.conf "/closure-$target/etc/nsswitch.conf"; \
      cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
             "/closure-$target/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so"; \
      for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
        cp -aL /lib/x86_64-linux-gnu/"$lib" \
               "/closure-$target/usr/lib/x86_64-linux-gnu/$lib"; \
      done; \
      for name in libdylan.so libcommon-dylan.so libio.so libc-ffi.so \
                  libgc.so.1 libunwind.so.1; do \
        cp -aL "/build/$target/_build/lib/$name" "/closure-$target/usr/local/lib/$name"; \
      done; \
    done; \
    binary_name=convex-adapter; \
    for target in adapter example; do \
      for round in 1 2 3; do \
        for elf in "/build/$target/_build/bin/$binary_name" \
                   "/closure-$target/bin/sh" \
                   "/closure-$target/usr/bin/"* \
                   "/closure-$target/usr/local/lib/"*; do \
          ldd "$elf" 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) \
                       if (substr($i, 1, 1) == "/") print $i }'; \
        done \
          | sort -u \
          | while read -r lib; do \
              test -e "/closure-$target$lib" || { \
                mkdir -p "/closure-$target$(dirname "$lib")"; \
                cp -aL "$lib" "/closure-$target$(dirname "$lib")/"; \
              }; \
            done; \
      done; \
      binary_name=convex-example; \
    done; \
    find /closure-adapter /closure-example -xtype l | (! grep .)

# The room argument reaches the example through EXAMPLE_ROOM, matching
# every other native client in this project.
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
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib \
    PATH=/usr/local/bin:/usr/bin:/bin

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /closure-example/ /
COPY --from=test --chmod=755 /build/example/_build/bin/convex-example /usr/local/bin/convex-example
COPY --from=test --chmod=755 /build/example/_build/lib/libconvex-example.so /usr/local/lib/libconvex-example.so
COPY --from=test --chmod=755 /entry/convex-example /usr/local/bin/convex-example-entry
USER 65532:65532

# Prove the policy the shared verifier depends on, and that this image
# carries only its own program, from inside the final filesystem rather
# than from the build stage that produced it.
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
    for command_name in gcc cc clang ld make cmake libtool dylan-compiler apt apt-get \
        dpkg curl wget nc netcat ssh openssl node python python3 ruby perl \
        java php go rustc cargo npm pip convex; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done; \
    test -x /usr/local/bin/convex-example-entry; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/lib/libconvex-adapter.so
ENTRYPOINT ["/usr/local/bin/convex-example-entry"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build dylan` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test /closure-adapter/ /
COPY --from=test --chmod=755 /build/adapter/_build/bin/convex-adapter /usr/local/bin/convex-adapter
COPY --from=test --chmod=755 /build/adapter/_build/lib/libconvex-adapter.so /usr/local/lib/libconvex-adapter.so
USER 65532:65532
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
    for command_name in gcc cc clang ld make cmake libtool dylan-compiler apt apt-get \
        dpkg curl wget nc netcat ssh openssl node python python3 ruby perl \
        java php go rustc cargo npm pip convex; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /usr/local/lib/libconvex-example.so; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out; \
    cat /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
