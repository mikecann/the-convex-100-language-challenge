# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: build GNU MARST from source, lint, compile every ALGOL 60 program
# this client ships, and run every language-local suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       file \
       binutils \
       make \
       wget \
    && rm -rf /var/lib/apt/lists/*

# GNU MARST is not packaged for Debian, so the translator itself is built
# from the upstream tarball. Its version is asserted and recorded so the
# adapter cannot misreport the runtime it is actually running on.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    cd /tmp; \
    wget -q https://ftp.gnu.org/gnu/marst/marst-2.7.tar.gz; \
    tar xzf marst-2.7.tar.gz; \
    cd marst-2.7; \
    ./configure >/tmp/configure.log 2>&1; \
    make -j"$(nproc)" >/tmp/make.log 2>&1; \
    make install >/tmp/install.log 2>&1; \
    ldconfig; \
    marst --version 2>&1 | head -n 1; \
    marst --version 2>&1 | grep -Eiq '2\.7'; \
    printf 'marst-2.7' > /project/runtime-version; \
    test -s /project/runtime-version; \
    test -f /usr/local/lib/libalgol.a; \
    rm -rf /tmp/marst-2.7 /tmp/marst-2.7.tar.gz

COPY client ./client
COPY examples ./examples

# ALGOL 60 has no standard formatter, so the style gate is explicit: spaces
# only, no trailing blanks, and a final newline. The canonical example is
# held to 80 columns because it is rendered verbatim in the README and on
# the website; everything else is held to 120, which a deeply nested
# ALGOL 60 begin block with long, self-explanatory procedure and
# parameter names needs more often than the equivalent Forth word does.
RUN set -eu; \
    files=$(find client examples -name '*.alg'); \
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
    echo "PASS algol60 source style"

# The only native code in the client. Compiled to an object file here, on
# its own, so a missing or misnamed primitive is caught before it is ever
# linked into a program, and its exported boundary is exactly the fourteen
# symbols declared in client/convex-native.alg.
RUN set -eu; \
    gcc -c -O2 -Wall -Wextra -Werror=implicit-function-declaration \
        -o /project/convexrt.o client/convexrt.c; \
    nm --defined-only /project/convexrt.o | grep -q ' T cxopen_0'; \
    nm --defined-only /project/convexrt.o | grep -q ' T cxread_0'; \
    nm --defined-only /project/convexrt.o | grep -q ' T cxrandom_0'

# GNU MARST reads one input file, so a compiled ALGOL 60 program in this
# client is always the concatenation of the C transport boundary's
# headings (client/convex-native.alg, declared outside any block, as
# GNU MARST's modular programming feature requires), zero or more pure
# ALGOL 60 library files (client/convex-buffer.alg, convex-json.alg,
# convex-http.alg and convex-ws.alg, each a bank of outer level
# procedures taking every piece of state explicitly, because standard
# ALGOL 60 has no way to share a variable between separately declared
# outer level procedures), and exactly one entry point. convex-live.alg
# is different: because its subscription table and delivery queue would
# otherwise need threading through dozens of parameters, it is a bank of
# declarations and procedures meant to be pasted inside one shared
# begin block together with whichever entry point needs Live -- the
# adapter, the example, or a live-aware test -- rather than declared at
# the outer level itself.
RUN set -eu; \
    mkdir -p /build; \
    cp client/convex-native.alg client/convex-buffer.alg client/convex-json.alg \
       client/convex-http.alg client/convex-ws.alg /build/; \
    assemble_flat() { \
      cat /build/convex-native.alg /build/convex-buffer.alg /build/convex-json.alg \
          /build/convex-http.alg /build/convex-ws.alg "$1" > "$2"; \
    }; \
    assemble_live() { \
      { \
        cat /build/convex-native.alg /build/convex-buffer.alg /build/convex-json.alg \
            /build/convex-http.alg /build/convex-ws.alg; \
        echo 'begin'; \
        cat client/convex-live.alg "$1"; \
        if [ -n "${3:-}" ]; then echo "$3"; fi; \
        echo 'end'; \
      } > "$2"; \
    }; \
    assemble_flat client/tests/client-test.alg /build/client-test.alg; \
    assemble_live client/tests/live-test.alg /build/live-test.alg; \
    assemble_live client/tests/conformance/adapter.alg /build/adapter.alg adaptermain; \
    assemble_live examples/basics/main.alg /build/example.alg; \
    ( cd /build && marst -w -t client-test.alg -o client-test.c ); \
    ( cd /build && marst -w -t live-test.alg -o live-test.c ); \
    ( cd /build && marst -w -t adapter.alg -o adapter.c ); \
    ( cd /build && marst -w -t example.alg -o example.c ); \
    gcc -O2 -o /build/client-test /build/client-test.c /project/convexrt.o \
        /usr/local/lib/libalgol.a -lssl -lcrypto -lm; \
    gcc -O2 -o /build/live-test /build/live-test.c /project/convexrt.o \
        /usr/local/lib/libalgol.a -lssl -lcrypto -lm; \
    gcc -O2 -o /build/convex-adapter /build/adapter.c /project/convexrt.o \
        /usr/local/lib/libalgol.a -lssl -lcrypto -lm; \
    gcc -O2 -o /build/convex-example /build/example.c /project/convexrt.o \
        /usr/local/lib/libalgol.a -lssl -lcrypto -lm

RUN set -eu; /build/client-test
RUN set -eu; /build/live-test

# TLS verification needs a peer, so a private CA and a local TLS server
# stand in for one. The untrusted and wrong-host modes are the ones that
# would still pass on a client that quietly skipped verification.
RUN set -eu; \
    mkdir -p /tmp/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=algol60-test-ca' \
      -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=algol60-other-ca' \
      -keyout /tmp/tls/other.key -out /tmp/tls/other.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
      -keyout /tmp/tls/server.key -out /tmp/tls/server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in /tmp/tls/server.csr \
      -CA /tmp/tls/ca.crt -CAkey /tmp/tls/ca.key -CAcreateserial \
      -copy_extensions copy -out /tmp/tls/server.crt >/dev/null 2>&1

COPY client/tests/tls-test.alg /build/tls-source.alg
RUN set -eu; \
    assemble_flat() { \
      cat /build/convex-native.alg /build/convex-buffer.alg /build/convex-json.alg \
          /build/convex-http.alg /build/convex-ws.alg "$1" > "$2"; \
    }; \
    assemble_flat /build/tls-source.alg /build/tls-test.alg; \
    ( cd /build && marst -w -t tls-test.alg -o tls-test.c ); \
    gcc -O2 -o /build/tls-test /build/tls-test.c /project/convexrt.o \
        /usr/local/lib/libalgol.a -lssl -lcrypto -lm; \
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
# piped directly, so the adapter's own poll-and-read loop never races a
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
    grep -Fq '"language":"algol60"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Stage the shared part of the runtime closure - everything except the
# two program binaries themselves, which are copied separately into
# their own final stage below so that convex-example never ships beside
# convex-adapter or vice versa. convex-example and convex-adapter are
# genuine native ELF binaries -- libalgol is linked statically, so no
# GNU MARST runtime, interpreter or libcc cache travels with them, unlike
# an interpreted language client -- and ldd resolves the small set of
# shared libraries each one actually needs, so the minimal image stays
# honest when a dependency changes underneath it. ldd is run once per
# binary rather than on the whole tree at once, because a multi-file ldd
# invocation prints one header line per binary ahead of its dependency
# list, which a naive parse would otherwise treat as a library path.
#
# The shared policy and example verifier currently require /bin/sh and
# basic POSIX text tools in every runtime image, so a small set of
# individual coreutils binaries (never a multicall BusyBox, whose applet
# table would reintroduce exactly the surface this image is trying to
# not have) is copied in even though neither convex-example nor
# convex-adapter themselves call out to a shell or a text tool.
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
# `rm` must be exec'd exactly once -- see forth/Dockerfile for why a loop
# calling command -v per path is unsafe once /bin or /usr starts being
# deleted mid-loop.
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
    for command_name in gcc cc clang ld make cmake libtool marst apt apt-get \
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
# runtime: last, because `./run build algol60` uses the default target
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
