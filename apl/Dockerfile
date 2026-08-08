# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:sid@sha256:24c766c06ebdbda66a026e92361ede7d9212819701b2fca82e347ef0c240cb2c
# Official GNU APL source release. Debian does package GNU APL (only in
# sid, not yet in trixie/bookworm, and only there with --with-gtk3,
# which pulls in the whole GTK/cairo/pango stack for a headless network
# client that never touches ⎕GTK/⎕PLOT/⎕PNG). Building the plain
# upstream tarball instead gets the same GPL, Debian-adjacent GNU APL
# 2.0 with none of that: --with-gtk3 defaults to off, so the built
# binary's own runtime closure is just libstdc++/libm/libc/libgcc_s
# (verified with ldd below).
ARG APL_VERSION=2.0
ARG APL_SHA256=24bbb744fce47e62837234a053bdeecee51b9ea61c82c79f7cc191bc6a54c0a1

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG APL_VERSION
ARG APL_SHA256
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ca-certificates=20260601 curl \
       g++=4:16.1.0-3 gcc=4:16.1.0-3 make libc6-dev bison flex \
       libssl-dev=3.6.3-1 libssl3t64=3.6.3-1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN curl -fsSL -o apl.tar.gz "https://ftp.gnu.org/gnu/apl/apl-${APL_VERSION}.tar.gz" \
    && echo "${APL_SHA256}  apl.tar.gz" | sha256sum -c - \
    && tar xzf apl.tar.gz && mv "apl-${APL_VERSION}" apl-src
WORKDIR /tmp/apl-src
# CXX_WERROR=no matches upstream's own recommended default build (its
# -Wall output includes known, documented false positives -- see
# README-11-bogus-compiler-warnings in this same tree); --without-sqlite3
# drops ⎕SQL, unused by a network client, and its libsqlite3 dependency.
RUN CXX_WERROR=no ./configure --without-sqlite3 \
    && make -j"$(nproc)"
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    ./src/apl --version >/dev/null

FROM toolchain AS test
WORKDIR /opt/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates busybox-static=1:1.38.0-3 \
    && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN test -f client/convexlive.apl

# The C++ native function is the only part of this client that is not
# APL: DNS resolution, the OpenSSL TLS handshake, and SHA-1 (needed only
# for the RFC 6455 handshake), loaded by client/convex.apl (and by the
# adapter and example) with dyadic ⎕FX -- GNU APL's documented mechanism
# for exactly this, the same one its own shipped lib_file_io.so uses.
# -isystem (not -I) for the GNU APL source tree: its own headers trip
# -Wall on several genuine but pre-existing issues (deprecated-copy,
# unused-parameter) unrelated to this file, documented in the same
# README-11-bogus-compiler-warnings; -isystem silences warnings from
# those headers while -Werror still catches anything in this file.
RUN g++ -std=gnu++17 -isystem /tmp/apl-src -isystem /tmp/apl-src/src \
      -Wall -Wextra -Werror -g -O2 -fPIC -shared \
      -o client/shim.so client/shim.cc -lssl -lcrypto

# Loads the library, the adapter, and the example, proving all three
# parse and link against the native function cleanly; then runs the
# language-local behavioural checks (JSON round-trip, HTTP against the
# local self-hosted backend is exercised in verify-example/verify, not
# here -- this stage has no network dependency).
COPY client/tests/selftest.apl client/tests/selftest.apl
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    APL=/tmp/apl-src/src/apl; \
    "$APL" -s -f client/tests/selftest.apl 2>&1 | tee /tmp/selftest.out; \
    grep -Fq 'ALL TESTS PASSED' /tmp/selftest.out; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | "$APL" -s -f client/tests/conformance/adapter.apl > /tmp/adapter.ndjson; \
    grep -Fq '"type":"ready"' /tmp/adapter.ndjson; \
    grep -Fq '"language":"apl"' /tmp/adapter.ndjson; \
    grep -Fq '"implementation":"native-gnu-apl-0.1.0"' /tmp/adapter.ndjson; \
    grep -Fq '"id":"close"' /tmp/adapter.ndjson; \
    grep -Fq '"type":"closed"' /tmp/adapter.ndjson; \
    ( unset CONVEX_URL; "$APL" -s -f examples/basics/main.apl -- demo-room 2>&1 1>/dev/null | grep -Fq 'CONVEX_URL is required' )

# Use a pinned non-scratch Debian carrier, then rebuild its visible
# filesystem from the explicit closure the compiled binaries actually
# need. BusyBox exists only in this build stage to prune the carrier and
# never reaches either exported runtime image.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root /run /sbin /srv /usr /var; do /busybox rm -rf "$path"; done; \
    for path in /etc/*; do case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) /busybox rm -rf "$path" ;; esac; done; \
    /busybox mkdir -p /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin \
      /opt/convex/client/tests/conformance /opt/convex/examples/basics; \
    /busybox chmod -R a+rX /opt/convex
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/libgcc_s.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/x86_64-linux-gnu/libstdc++.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libz.so.1 /usr/lib/x86_64-linux-gnu/libz.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libzstd.so.1 /usr/lib/x86_64-linux-gnu/libzstd.so.1
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /usr/lib/x86_64-linux-gnu/libnss_dns.so.2 /usr/lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /usr/lib/x86_64-linux-gnu/libnss_files.so.2 /usr/lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /usr/lib/x86_64-linux-gnu/libresolv.so.2 /usr/lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=test /bin/dash /bin/sh
# Debian's coreutils links id against libselinux even where SELinux is
# unused, and its own dependency libpcre2 comes with it.
COPY --from=test /usr/lib/x86_64-linux-gnu/libselinux.so.1 /usr/lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0 /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test --chmod=0555 /tmp/apl-src/src/apl /usr/local/bin/apl
COPY --from=test --chmod=0555 /opt/convex/client/shim.so /opt/convex/client/shim.so
COPY --from=test --chmod=0444 /opt/convex/client/convex.apl /opt/convex/client/convex.apl
COPY --from=test --chmod=0444 /opt/convex/client/convexlive.apl /opt/convex/client/convexlive.apl
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(uname -m)" = x86_64

FROM runtime-base AS example-runtime
COPY --from=test --chmod=0444 /opt/convex/examples/basics/main.apl /opt/convex/examples/basics/main.apl
COPY --from=test --chmod=0555 /opt/convex/examples/basics/entrypoint.sh /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test --chmod=0444 /opt/convex/client/tests/conformance/adapter.apl /opt/convex/client/tests/conformance/adapter.apl
COPY --from=test --chmod=0555 /opt/convex/client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
