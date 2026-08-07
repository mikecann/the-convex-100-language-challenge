# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base other clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# CSNOBOL4 is not packaged for Debian, so its source is pinned by URL and
# checksum and built from scratch. 2.3.4 is the current release published at
# https://ftp.regressive.org/snobol/.
ARG CSNOBOL4_URL=https://ftp.regressive.org/snobol/snobol4-2.3.4.tar.gz
ARG CSNOBOL4_SHA256=702f73b4107438bd251ebc253d335994f37bb40379242360d876e2de6dc03f78

# ---------------------------------------------------------------------------
# test: build CSNOBOL4 from source, build the native transport shim, lint
# every source file, and run every language-local test suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG CSNOBOL4_URL
ARG CSNOBOL4_SHA256
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       m4 \
       make \
       file \
       binutils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/convex

RUN set -eu; test "$(uname -m)" = x86_64

# Fetch and verify CSNOBOL4 by URL and checksum, matching the project's own
# pin-by-digest policy for anything not packaged by the distribution.
ADD --checksum=sha256:${CSNOBOL4_SHA256} ${CSNOBOL4_URL} /tmp/snobol4.tar.gz
RUN set -eu; \
    mkdir -p /opt/csnobol4-src; \
    tar xzf /tmp/snobol4.tar.gz -C /opt/csnobol4-src --strip-components=1; \
    rm -f /tmp/snobol4.tar.gz

# Build the interpreter itself. GCC's cc1 has reproducibly segfaulted on
# this project's QEMU-emulated linux/amd64 build host while building
# CSNOBOL4 from a clean tree - observed compiling a different, unrelated
# translation unit each time, including during plain dependency scanning
# (`cc -MM`, which does not even reach code generation), so this is not
# specific to CSNOBOL4's own -O3 default or to any one file. This matches
# the class of environment artifact AGENTS.md documents for other heavy
# toolchains on QEMU hosts: a toolchain crash that precedes the client's own
# code, not a CSNOBOL4 or client defect. The mitigation here is the same
# shape as retrying on a different layer - a bounded retry of the exact same
# build, which has always succeeded within a small number of attempts.
# Parallel make is unsupported by CSNOBOL4's own build and is deliberately
# not used here.
RUN set -eu; \
    cd /opt/csnobol4-src; \
    ./configure --add-opt=-O0; \
    attempt=1; \
    until make; do \
      attempt=$((attempt + 1)); \
      if [ "$attempt" -gt 5 ]; then \
        echo "CSNOBOL4 build did not succeed after 5 attempts" >&2; \
        exit 1; \
      fi; \
      echo "CSNOBOL4 build attempt failed (likely a QEMU cc1 crash); retrying (attempt $attempt/5)" >&2; \
      find . -name '*.o' -delete; \
      rm -f Makefile2 Makefile2.tmp Makefile2.tmp.tmp; \
    done; \
    printf '    output = "boot ok"\nend\n' > /tmp/boot.sno; \
    ./snobol4 -b /tmp/boot.sno | grep -Fq 'boot ok'; \
    cp snobol4 /usr/local/bin/snobol4

COPY client ./client
COPY examples ./examples

# CSNOBOL4 has no standard formatter, so the style gate is explicit: spaces
# only, no trailing blanks, a final newline, and a line-width bound. SNOBOL4's
# label / statement / branch-target layout with fully qualified dotted names
# reads naturally wider than a stack-based language's, so the bound is more
# generous than other clients in this repository use; it still catches a
# genuinely runaway line; the canonical example is held to a tighter bound
# because it is rendered verbatim on the website.
RUN set -eu; \
    files=$(find client examples -name '*.sno'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      case "$f" in examples/*) width=120 ;; *) width=240 ;; esac; \
      if awk -v width="$width" \
             'length > width { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over $width columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS snobol4 source style"

# The only native code in the client. It is a real shared library rather
# than something generated during the build, so what is compiled here is
# exactly what is reviewed in client/convexrt.c. It links against CSNOBOL4's
# own build tree so its LOAD_PROTO / descr layout always matches the exact
# interpreter this image ships, not a system-wide CSNOBOL4 install that does
# not exist.
RUN set -eu; \
    mkdir -p /usr/local/lib/convex-snobol4; \
    gcc -O0 -fPIC -shared -Wall -Wextra \
        -Werror=implicit-function-declaration \
        -DHAVE_CONFIG_H -I/opt/csnobol4-src/include -I/opt/csnobol4-src \
        -o /usr/local/lib/convex-snobol4/libconvexrt.so \
        client/convexrt.c -lssl -lcrypto; \
    nm -D --defined-only /usr/local/lib/convex-snobol4/libconvexrt.so \
      | grep -q ' T CVXOPEN'

# SNOBOL4's -INCLUDE mechanism searches the current directory, so the build
# flattens the educational layout into one staging directory, exactly as the
# runtime images do; what the tests exercise and what ships are byte
# identical. main.sno -includes host.sno for its command-line room argument;
# host.sno is CSNOBOL4's own standard library file (not this client's code),
# normally resolved through an installed snolib search path this build never
# populates via `make install`, so it is staged next to main.sno explicitly
# instead, here and wherever main.sno itself ships.
RUN set -eu; \
    mkdir -p /stage; \
    cp client/*.sno /stage/; \
    cp client/tests/*.sno /stage/; \
    cp client/tests/conformance/adapter.sno /stage/; \
    cp examples/basics/main.sno /stage/; \
    cp /opt/csnobol4-src/host.sno /stage/

RUN set -eu; cd /stage; snobol4 -b unit_test.sno

# live_test.sno needs a second, real OS process to be its wire-protocol
# peer (see the block comment at the top of both files for why this cannot
# be one process): the fixture is started first and the test waits for it.
RUN set -eu; \
    cd /stage; \
    snobol4 -b live_test_fixture.sno >/tmp/live_test_fixture.out 2>&1 & \
    fixture_pid=$!; \
    sleep 2; \
    snobol4 -b live_test.sno; \
    wait "$fixture_pid" || { cat /tmp/live_test_fixture.out >&2; exit 1; }

# The conformance adapter must compile and answer hello/close correctly
# before any Docker socket exists to test it against a real deployment.
RUN set -eu; \
    cd /stage; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 snobol4 -b adapter.sno \
    | tee /tmp/adapter-probe.out; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"snobol4"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# The same probe over the TCP mode the shared harness actually uses.
RUN set -eu; \
    cd /stage; \
    CONVEX_URL=http://127.0.0.1:1 ADAPTER_LISTEN=0.0.0.0:18080 snobol4 -b adapter.sno & \
    adapter_pid=$!; \
    sleep 1; \
    { printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"close","op":"close"}'; \
      sleep 1; \
    } | timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080; cat >&3; cat <&3' \
    | tee /tmp/adapter-tcp-probe.out; \
    grep -Fq '"type":"ready"' /tmp/adapter-tcp-probe.out; \
    wait "$adapter_pid" || true

# The example must fail loudly without a deployment, and must print nothing
# on stdout when it does, because stdout is the shared happy-path transcript.
RUN set -eu; \
    cd /stage; \
    code=0; \
    snobol4 -b main.sno >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# Stage the exact runtime closure. Resolving shared libraries with ldd
# (once per binary, since ldd on multiple arguments prints a "path:" header
# line per binary rather than one flat list) instead of listing them by hand
# keeps the minimal image honest when a dependency changes underneath it.
RUN set -eu; \
    mkdir -p /closure/bin /closure/usr/local/bin \
             /closure/usr/local/lib/convex-snobol4 /closure/etc/ssl/certs \
             /closure/lib/x86_64-linux-gnu /closure/lib64 \
             /closure/usr/lib/x86_64-linux-gnu/ossl-modules; \
    for name in cat cut head tail tr sort uniq wc uname grep sed id; do \
      cp -aL "$(command -v "$name")" /closure/usr/local/bin/"$name"; \
    done; \
    cp -aL /usr/bin/mawk /closure/usr/local/bin/awk; \
    cp -aL /bin/dash /closure/bin/sh; \
    cp -aL /usr/local/bin/snobol4 /closure/usr/local/bin/snobol4; \
    cp -aL /usr/local/lib/convex-snobol4/libconvexrt.so \
           /closure/usr/local/lib/convex-snobol4/libconvexrt.so; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
           /closure/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /closure/etc/ssl/certs/; \
    cp -aL /etc/ssl/openssl.cnf /closure/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /closure/etc/nsswitch.conf; \
    for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL /lib/x86_64-linux-gnu/"$lib" /closure/lib/x86_64-linux-gnu/"$lib"; \
    done; \
    for round in 1 2 3; do \
      find /closure -type f -exec sh -c ' \
        for elf; do \
          case "$(head -c4 "$elf" | od -An -tx1 | tr -d " \n")" in \
            7f454c46) echo "$elf" ;; \
          esac; \
        done' sh {} + \
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
    cp client/*.sno /closure/usr/local/lib/convex-snobol4/; \
    printf 'csnobol4-2.3.4\n' > /closure/usr/local/lib/convex-snobol4/runtime

RUN set -eu; \
    mkdir -p /entry; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# The verifier passes a unique room as the first argument.' \
      'cd /usr/local/lib/convex-snobol4' \
      'exec /usr/local/bin/snobol4 -b main.sno "$@"' \
      > /entry/convex-example; \
    printf '%s\n' \
      '#!/bin/sh' \
      'cd /usr/local/lib/convex-snobol4' \
      'exec /usr/local/bin/snobol4 -b adapter.sno' \
      > /entry/convex-adapter; \
    chmod 755 /entry/convex-example /entry/convex-adapter

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its filesystem removed and only the
# declared closure copied back
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# `rm` must be exec'd exactly once: looking it up on $PATH once per path in a
# loop means the first iteration that deletes /bin or /usr removes the `rm`
# binary itself, so the shell fails to find it on the next iteration. Every
# path is collected into positional parameters first, then handed to one
# `rm -rf` call, so exec happens only once while rm's own code and libraries
# are still resident.
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
    PATH=/usr/local/bin:/bin
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

# snobol4 is the target language runtime and is expected here; prove it can
# run with no compiler present.
RUN set -eu; \
    printf '    output = 1 + 0\nend\n' > /tmp/boot.sno; \
    snobol4 -b /tmp/boot.sno | grep -Fq 1

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /entry/convex-example /usr/local/bin/convex-example
COPY --from=test /stage/main.sno /usr/local/lib/convex-snobol4/main.sno
COPY --from=test /stage/host.sno /usr/local/lib/convex-snobol4/host.sno
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/lib/convex-snobol4/adapter.sno
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build snobol4` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test /entry/convex-adapter /usr/local/bin/convex-adapter
COPY --from=test /stage/adapter.sno /usr/local/lib/convex-snobol4/adapter.sno
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /usr/local/lib/convex-snobol4/main.sno; \
    test ! -e /usr/local/lib/convex-snobol4/host.sno; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
    | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
