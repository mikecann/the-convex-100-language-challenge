# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Idris 2 has no Debian package, so the toolchain is bootstrapped from a pinned
# source tarball using Chez Scheme, exactly once, in a build-only stage.
#
# CHEZ_VERSION is the chezscheme package version resolved from the pinned
# debian:bookworm-slim base image (verified via `apt-cache madison chezscheme`
# inside that exact image digest on 2026-08-07). IDRIS2_SHA256 is the sha256 of
# the v${IDRIS2_VERSION} GitHub source tarball, computed by downloading it once
# on the build host.
ARG CHEZ_VERSION=9.5.8+dfsg-1
ARG IDRIS2_VERSION=0.7.0
ARG IDRIS2_SHA256=7a8612a1cd9f1f737893247260c6942bf93f193375d4b3df0148f7abf74d6e14

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG CHEZ_VERSION
ARG IDRIS2_VERSION
ARG IDRIS2_SHA256
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       chezscheme=${CHEZ_VERSION} \
       gcc=4:12.2.0-3 \
       make=4.3-4.1 \
       libgmp-dev=2:6.2.1+dfsg1-1.1 \
       libssl-dev=3.0.20-1~deb12u2 \
       zlib1g-dev=1:1.2.13.dfsg-1 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       openssl=3.0.20-1~deb12u2 \
       file=1:5.44-3 \
    && rm -rf /var/lib/apt/lists/*

# BuildKit fetches the tarball, so no network client is installed in the image.
# The digest is then checked explicitly, which keeps the pin enforced whichever
# ADD flags the frontend supports.
ADD https://github.com/idris-lang/Idris2/archive/refs/tags/v${IDRIS2_VERSION}.tar.gz \
    /tmp/idris2.tar.gz
RUN printf '%s  %s\n' "${IDRIS2_SHA256}" /tmp/idris2.tar.gz | sha256sum -c -

# IDRIS2_PREFIX is intentionally not exported yet. idris2's own runtime
# (src/Idris/Driver.idr) reads IDRIS2_PREFIX from the environment to locate
# its data files (e.g. chez/support.ss). `make bootstrap` self-hosts: the
# freshly bootstrapped stage-1 compiler recompiles the real idris2 from
# source, and if IDRIS2_PREFIX already points at the install prefix while
# that prefix is still empty (install has not run yet), the self-hosting
# compile fails looking for data files that only exist after `make install`.
# Only PATH is needed to run `idris2`/`scheme` during the build.
ENV PATH=/opt/idris2/bin:/usr/local/bin:/usr/bin:/bin
RUN set -eu; \
    mkdir -p /tmp/idris2-src; \
    tar -xzf /tmp/idris2.tar.gz -C /tmp/idris2-src --strip-components=1; \
    scheme_binary=$(command -v chezscheme || command -v scheme); \
    test -n "$scheme_binary"; \
    make -C /tmp/idris2-src bootstrap SCHEME="$scheme_binary" PREFIX=/opt/idris2; \
    make -C /tmp/idris2-src install PREFIX=/opt/idris2; \
    rm -rf /tmp/idris2-src /tmp/idris2.tar.gz
# Now that install has populated /opt/idris2, it is safe for idris2's runtime
# to resolve its data files there.
ENV IDRIS2_PREFIX=/opt/idris2
RUN idris2 --version | grep -Fq "${IDRIS2_VERSION}"

FROM toolchain AS test
ARG IDRIS2_VERSION
WORKDIR /project
COPY client ./client
COPY examples ./examples

# The transport shim is compiled once into a static archive. Linking it
# statically keeps it out of the runtime library closure entirely; only the
# libraries it genuinely needs -- OpenSSL, GMP, libc -- remain.
RUN set -eu; \
    mkdir -p /opt/convex-support; \
    cp client/support/convex_support.h /opt/convex-support/; \
    gcc -std=c11 -O2 -Wall -Wextra -Werror -fPIC \
        -c client/support/convex_support.c -o /opt/convex-support/convex_support.o; \
    ar rcs /opt/convex-support/libconvexsupport.a /opt/convex-support/convex_support.o

# Idris 2's RefC backend assembles its own compiler command line. Wrapping `cc`
# is how the shim, OpenSSL, and the shim's header reach every RefC invocation
# without depending on which flags a given Idris release happens to forward.
RUN set -eu; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# RefC compiles and links generated C through this wrapper.' \
      'exec /usr/bin/gcc -I/opt/convex-support -include /opt/convex-support/convex_support.h "$@" -L/opt/convex-support -lconvexsupport -lssl -lcrypto -lm' \
      > /usr/local/bin/convex-cc; \
    chmod 0755 /usr/local/bin/convex-cc; \
    /usr/local/bin/convex-cc --version >/dev/null
ENV CC=/usr/local/bin/convex-cc \
    IDRIS2_CC=/usr/local/bin/convex-cc

# Idris 2 ships no standard formatter, so the checked-in sources are held to a
# deterministic style gate instead: no tabs, no trailing whitespace, a bounded
# line length, and no statements compressed onto one line to save space.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    files=$(find client examples -name '*.idr' | sort); \
    test -n "$files"; \
    for file in $files; do \
      awk -v name="$file" \
          '/\t/ { print "tab in " name > "/dev/stderr"; bad = 1 } \
           / $/ { print "trailing space in " name > "/dev/stderr"; bad = 1 } \
           length > 100 { print "line over 100 columns in " name > "/dev/stderr"; bad = 1 } \
           END { exit bad }' "$file"; \
    done; \
    for file in client/support/convex_support.c client/support/convex_support.h; do \
      awk -v name="$file" \
          '/\t/ { print "tab in " name > "/dev/stderr"; bad = 1 } \
           / $/ { print "trailing space in " name > "/dev/stderr"; bad = 1 } \
           length > 100 { print "line over 100 columns in " name > "/dev/stderr"; bad = 1 } \
           END { exit bad }' "$file"; \
    done

# The example lives under examples/ in the repository for readers. Idris wants
# a source directory whose layout matches its module names, so the build copies
# it rather than reshaping the educational tree.
RUN mkdir -p client/example && cp examples/basics/Main.idr client/example/Main.idr

RUN set -eu; \
    cd client; \
    idris2 --install convex.ipkg; \
    idris2 --install conformance.ipkg

# Every *.ipkg below declares its entry point as `main = Main`, and each one
# points `sourcedir` at a different directory with its own distinct
# `Main.idr` (tests/wire, tests/http, ...). Idris2's incremental build cache
# keys a compiled module purely by its namespace path under `client/build/`,
# not by which package or sourcedir it came from, and every one of these RUN
# steps builds from the same `client/` working directory without cleaning in
# between. Left alone, the second and every later `--build` here would see
# `build/ttc/*/Main.ttc` already present, decide the (unrelated) previous
# suite's compiled Main is still valid, and silently link and run *that*
# executable instead of its own -- verified by hand: without the `rm -rf
# build` below, `./build/exec/convex-tests-http` (and everything after it,
# including the shipped convex-example and convex-adapter binaries) actually
# ran the wire suite and printed "wire tests passed". Clearing the local
# build directory before each `--build` forces a real recompile every time.
RUN set -eu; \
    cd client; \
    idris2 --codegen refc --build tests-wire.ipkg; \
    ./build/exec/convex-tests-wire

RUN set -eu; \
    cd client; \
    rm -rf build; \
    idris2 --codegen refc --build tests-http.ipkg; \
    ./build/exec/convex-tests-http

RUN set -eu; \
    cd client; \
    rm -rf build; \
    idris2 --codegen refc --build tests-live.ipkg; \
    ./build/exec/convex-tests-live

# A throwaway CA and leaf certificate for the TLS fixture. They live only in
# this build stage and never reach a runtime image.
RUN set -eu; \
    mkdir -p /tmp/idris-tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=idris-test-ca' \
      -keyout /tmp/idris-tls/ca.key -out /tmp/idris-tls/ca.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
      -keyout /tmp/idris-tls/server.key -out /tmp/idris-tls/server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in /tmp/idris-tls/server.csr \
      -CA /tmp/idris-tls/ca.crt -CAkey /tmp/idris-tls/ca.key -CAcreateserial \
      -copy_extensions copy -out /tmp/idris-tls/server.crt >/dev/null 2>&1
RUN set -eu; \
    cd client; \
    rm -rf build; \
    idris2 --codegen refc --build tests-tls.ipkg; \
    IDRIS_TLS_DIR=/tmp/idris-tls ./build/exec/convex-tests-tls

RUN set -eu; \
    cd client; \
    rm -rf build; \
    idris2 --codegen refc --build tests-adapter.ipkg; \
    ./build/exec/convex-tests-adapter

RUN set -eu; \
    mkdir -p /out; \
    cd client; \
    rm -rf build; \
    idris2 --codegen refc --build example.ipkg; \
    cp build/exec/convex-example /out/convex-example; \
    rm -rf build; \
    idris2 --codegen refc --build adapter.ipkg; \
    cp build/exec/convex-adapter /out/convex-adapter; \
    cp "$IDRIS2_PREFIX"/idris2-*/lib/libidris2_support.so /out/libidris2_support.so; \
    chmod 0555 /out/convex-example /out/convex-adapter; \
    file /out/convex-example /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64'

# The canonical example must refuse to run without a deployment, and must not
# put anything on stdout when it does, because stdout is the shared transcript.
RUN set -eu; \
    code=0; \
    /out/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# The compiled adapter, not a test harness, answers the protocol on stdio.
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 /out/convex-adapter >/tmp/adapter.out; \
    grep -Fq '"language":"idris"' /tmp/adapter.out; \
    grep -Fq '"type":"closed"' /tmp/adapter.out
CMD ["/bin/sh", "-c", "true"]

# Start from the pinned base, remove its filesystem with a temporary static
# helper, then copy back only the declared runtime closure.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libgmp.so.10 /usr/lib/x86_64-linux-gnu/libgmp.so.10
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
# The RefC runtime library is the only Idris artefact the binaries still need.
# It is a support library, not a compiler: no Idris frontend reaches the image.
COPY --from=test /out/libidris2_support.so /usr/lib/x86_64-linux-gnu/libidris2_support.so
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /opt \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && set -- /lib64/* \
    && test "$#" -eq 1 \
    && set -- /usr/lib/x86_64-linux-gnu/ossl-modules/* \
    && test "$#" -eq 1 \
    && for command_name in idris2 idris chezscheme scheme gcc cc clang make cmake ar ld \
         apt apt-get dpkg curl wget nc netcat openssl node python python3 ruby perl \
         java php go rustc cargo npm pip convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter \
    && set -- /usr/local/bin/* \
    && test "$#" -eq 1
ENTRYPOINT ["/usr/local/bin/convex-example"]

# The adapter is last because `./run build idris` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && set -- /usr/local/bin/* \
    && test "$#" -eq 1 \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
