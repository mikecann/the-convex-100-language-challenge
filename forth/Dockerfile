# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: lint, build the native support library, run every language-local suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gforth \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       file \
       binutils \
       libtool-bin \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/convex

# The demonstration targets linux/amd64, and gforth's Forth-2012 locals and
# escaped string literals need the 0.7 series. Both are asserted rather than
# assumed, and the exact version is recorded so the adapter cannot misreport
# the runtime it is actually running on.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    gforth --version 2>&1 | head -n 1; \
    gforth --version 2>&1 | grep -Eiq 'Gforth 0\.7\.'; \
    gforth --version 2>&1 | sed -n 's/.*[Gg]forth \([0-9.]*\).*/gforth-\1/p' \
      > /project/runtime-version; \
    test -s /project/runtime-version

COPY client ./client
COPY examples ./examples

# Forth has no standard formatter, so the style gate is explicit: spaces only,
# no trailing blanks, and a final newline. The canonical example is held to 80
# columns because it is rendered verbatim in the README and on the website;
# everything else is held to 100, which is what a protocol header literal or a
# JSON fixture needs to stay on one readable line.
RUN set -eu; \
    files=$(find client examples -name '*.fth'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      case "$f" in examples/*) width=80 ;; *) width=100 ;; esac; \
      if awk -v width="$width" \
             'length > width { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over $width columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS forth source style"

# The only native code in the client. It is a real shared library rather than
# something generated during the build, so what is compiled is exactly what is
# reviewed in client/convexrt.c.
RUN set -eu; \
    gcc -O2 -fPIC -shared -Wall -Wextra \
        -Werror=implicit-function-declaration \
        -o /usr/lib/x86_64-linux-gnu/libconvexrt.so \
        client/convexrt.c -lssl -lcrypto; \
    ldconfig; \
    nm -D --defined-only /usr/lib/x86_64-linux-gnu/libconvexrt.so \
      | grep -q ' T cvx_open'

# gforth loads Forth source by searching the current directory, so the build
# flattens the educational layout into one staging directory. The runtime
# images use the same flat layout, which keeps what the tests exercise and what
# ships byte identical.
RUN set -eu; \
    mkdir -p /stage; \
    cp client/*.fth /stage/; \
    cp client/tests/*.fth /stage/; \
    cp client/tests/conformance/adapter.fth /stage/; \
    cp examples/basics/main.fth /stage/

# Loading the transport layer once makes gforth generate and compile its thin
# stack-marshalling wrapper into the libcc cache. That cache ships in the
# runtime image, which is what lets the final image call C with no compiler
# present. The runtime stage proves it independently.
RUN set -eu; \
    cd /stage; \
    gforth convex-io.fth -e bye; \
    find /home/convex -name 'convexrt*' -print | sort; \
    find /home/convex -name 'convexrt*.so' | grep -q .

RUN set -eu; cd /stage; gforth json-test.fth
RUN set -eu; cd /stage; gforth http-test.fth
RUN set -eu; cd /stage; gforth live-test.fth
RUN set -eu; cd /stage; ADAPTER_LIBRARY_ONLY=1 gforth adapter-test.fth

# TLS verification needs a peer, so a private CA and a local TLS server stand in
# for one. The untrusted and wrong-host modes are the ones that would still
# pass on a client that quietly skipped verification.
RUN set -eu; \
    mkdir -p /tmp/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=forth-test-ca' \
      -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=forth-other-ca' \
      -keyout /tmp/tls/other.key -out /tmp/tls/other.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
      -keyout /tmp/tls/server.key -out /tmp/tls/server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in /tmp/tls/server.csr \
      -CA /tmp/tls/ca.crt -CAkey /tmp/tls/ca.key -CAcreateserial \
      -copy_extensions copy -out /tmp/tls/server.crt >/dev/null 2>&1

RUN set -eu; \
    cd /stage; \
    openssl s_server -accept 44300 -naccept 32 \
      -cert /tmp/tls/server.crt -key /tmp/tls/server.key -www \
      >/dev/null 2>&1 & \
    server_pid=$!; \
    sleep 2; \
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_MODE=trusted gforth tls-test.fth; \
    SSL_CERT_FILE=/tmp/tls/other.crt TLS_MODE=untrusted gforth tls-test.fth; \
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_MODE=wronghost gforth tls-test.fth; \
    kill "$server_pid" 2>/dev/null || true

# The example must fail loudly without a deployment, and must print nothing on
# stdout when it does, because stdout is the shared happy-path transcript.
RUN set -eu; \
    cd /stage; \
    code=0; \
    gforth main.fth -e bye >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

RUN set -eu; \
    cd /stage; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 gforth adapter.fth -e bye \
    | tee /tmp/adapter-probe.out; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"forth"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Stage the exact runtime closure. Resolving shared libraries with ldd instead
# of listing them by hand keeps the minimal image honest when a dependency
# changes underneath it.
#
# Directory trees are copied via an explicit `mkdir -p` of the parent plus a
# plain `cp -a`, not `cp -a --parents`: this coreutils build's --parents
# intermediate-directory handling on an absolute source path fails with
# "No such file or directory" for some trees (observed on /usr/share/gforth)
# despite the source existing, seemingly while trying to preserve attributes
# on a parent it mis-resolves as relative.
#
# /usr/lib/gforth holds only the architecture-independent site-forth
# directory; the interpreter's actual core VM image, gforth.fi, lives under
# the architecture-specific /usr/lib/x86_64-linux-gnu/gforth instead, so that
# tree needs its own explicit copy or the runtime image has a gforth binary
# with no image to load.
RUN set -eu; \
    mkdir -p /closure/bin /closure/usr/bin /closure/usr/local/bin \
             /closure/usr/local/lib/convex-forth /closure/etc/ssl/certs \
             /closure/usr/lib/x86_64-linux-gnu/ossl-modules; \
    for name in gforth cat cut head tail tr sort uniq wc uname grep sed id; do \
      cp -aL "$(command -v "$name")" /closure/usr/bin/"$name"; \
    done; \
    cp -aL /usr/bin/mawk /closure/usr/bin/awk; \
    cp -aL /bin/dash /closure/bin/sh; \
    cp -aL /usr/lib/x86_64-linux-gnu/libconvexrt.so \
           /closure/usr/lib/x86_64-linux-gnu/libconvexrt.so; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
           /closure/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    mkdir -p /closure/usr/lib /closure/usr/share /closure/home; \
    cp -a /usr/lib/gforth /closure/usr/lib/; \
    cp -a /usr/share/gforth /closure/usr/share/; \
    cp -a /usr/lib/x86_64-linux-gnu/gforth /closure/usr/lib/x86_64-linux-gnu/; \
    cp -a /home/convex /closure/home/; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /closure/etc/ssl/certs/; \
    cp -aL /etc/ssl/openssl.cnf /closure/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /closure/etc/nsswitch.conf; \
    for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL /lib/x86_64-linux-gnu/"$lib" \
             /closure/usr/lib/x86_64-linux-gnu/"$lib"; \
    done; \
    for round in 1 2 3; do \
      find /closure -type f -exec file {} + \
        | grep 'ELF ' | cut -d: -f1 \
        | while read -r elf; do \
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
    done; \
    cp client/*.fth /closure/usr/local/lib/convex-forth/; \
    cp /project/runtime-version /closure/usr/local/lib/convex-forth/runtime

# The two entrypoints are staged separately so each minimal image carries only
# its own program. gforth reserves its command line for files to load, so the
# room argument reaches the example through the environment, and `-e bye`
# guarantees neither program can fall through into an interactive interpreter.
RUN set -eu; \
    mkdir -p /entry; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# The verifier passes a unique room as the first argument.' \
      'if [ "$#" -gt 0 ]; then' \
      '  EXAMPLE_ROOM="$1"' \
      '  export EXAMPLE_ROOM' \
      'fi' \
      'cd /usr/local/lib/convex-forth' \
      'exec /usr/bin/gforth main.fth -e bye' \
      > /entry/convex-example; \
    printf '%s\n' \
      '#!/bin/sh' \
      'FORTH_RUNTIME="$(cat /usr/local/lib/convex-forth/runtime)"' \
      'export FORTH_RUNTIME' \
      'cd /usr/local/lib/convex-forth' \
      'exec /usr/bin/gforth adapter.fth -e bye' \
      > /entry/convex-adapter; \
    chmod 755 /entry/convex-example /entry/convex-adapter

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its filesystem removed and only the
# declared closure copied back
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# `rm` must be exec'd exactly once. When it is looked up on $PATH once per
# path in a loop, the first iteration that deletes /bin or /usr removes the
# `rm` binary itself, so the shell fails to find it for every later
# iteration ("rm: not found"). A single invocation avoids this: exec happens
# only once, while the executable and its shared libraries are still on
# disk, and the kernel keeps rm's already-mapped code and libraries resident
# for the life of the process even as it unlinks the files backing them.
# Every path is therefore collected into positional parameters first (so
# each survives word-splitting/quoting untouched) and handed to one `rm -rf`
# call at the end.
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
ENV HOME=/home/convex \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
    GFORTHCCPATH=/home/convex/.gforth/libcc-named \
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
    for command_name in gcc cc clang ld make cmake libtool apt apt-get dpkg \
        curl wget nc netcat ssh openssl node python python3 ruby perl java \
        php go rustc cargo npm pip convex; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done

# gforth is the target language runtime and is expected here. It must be able
# to reach the native support library with no compiler present, which is only
# true because the libcc wrapper was precompiled in the test stage.
RUN set -eu; \
    cd /usr/local/lib/convex-forth; \
    gforth -e 'require convex-io.fth  now 0> abs . cr bye' | grep -Fq 1

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /entry/convex-example /usr/local/bin/convex-example
COPY --from=test /stage/main.fth /usr/local/lib/convex-forth/main.fth
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/lib/convex-forth/adapter.fth
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build forth` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test /entry/convex-adapter /usr/local/bin/convex-adapter
COPY --from=test /stage/adapter.fth /usr/local/lib/convex-forth/adapter.fth
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /usr/local/lib/convex-forth/main.fth; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
    | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
