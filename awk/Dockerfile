# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: build gawk and the extension from pinned source, then run every
# language-local test suite.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV LC_ALL=C

# xz-utils is deliberately unpinned: it only unpacks an archive whose sha256 is
# already pinned below, and the exact bookworm revision has not been observed in
# a build of this image yet.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       make=4.3-4.1 \
       libssl-dev=3.0.20-1~deb12u2 \
       openssl=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
       xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The awk implementation itself is part of the pinned toolchain. BuildKit
# verifies the checksum before the archive is unpacked.
#
# Pinned to 5.3.2 rather than the newer 5.4.x series: a from-source 5.4.1
# build (verified both with gawk's default CFLAGS and with several other
# optimization levels, so this is not about -fPIC or -O2) miscompiles `if`
# conditions that combine two array-subscript `!=` comparisons populated
# through a function call, silently taking the wrong branch. Debian's
# packaged 5.2.1, Alpine's packaged 5.3.2, and a from-source 5.3.2 build all
# evaluate the same program correctly, so this looks like an upstream
# regression in the very new 5.4 series rather than anything in this build.
ADD --checksum=sha256:f8c3486509de705192138b00ef2c00bbbdd0e84c30d5c07d23fc73a9dc4cc9cc \
    https://ftp.gnu.org/gnu/gawk/gawk-5.3.2.tar.xz /tmp/gawk.tar.xz
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    mkdir -p /tmp/gawk; \
    tar -xJf /tmp/gawk.tar.xz -C /tmp/gawk --strip-components=1; \
    cd /tmp/gawk; \
    CFLAGS="-O2 -fPIC" ./configure --prefix=/usr/local --disable-nls >/dev/null; \
    make -j"$(nproc)" >/dev/null; \
    make install >/dev/null; \
    rm -rf /tmp/gawk /tmp/gawk.tar.xz; \
    /usr/local/bin/gawk --version | head -n 1 | grep -Fq 'GNU Awk 5.3.2'; \
    test -f /usr/local/include/gawkapi.h
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

COPY client ./client
COPY examples ./examples

# The extension is compiled from source here; no prebuilt object enters the
# image at any stage. The runtime build must not expose the test-only TLS
# server hook, and calling a function gawk does not know about is fatal, which
# is what makes that assertion meaningful.
RUN set -eu; \
    make -C client BUILD=/build; \
    file /build/runtime/convexext.so | grep -Eq 'ELF 64-bit.*x86-64'; \
    AWKLIBPATH=/build/runtime gawk -l convexext \
      'BEGIN { if (convex_version() !~ /convexext/) exit 1; print convex_version() }'; \
    ! AWKLIBPATH=/build/runtime gawk -l convexext \
      'BEGIN { convex_test_tls_accept(0, "x", "y", 1) }' >/dev/null 2>&1; \
    AWKLIBPATH=/build/test gawk -l convexext \
      'BEGIN { if (convex_test_tls_accept(0, "x", "y", 1) >= 0) exit 1 }'

# Parse and lint every checked-in Awk source. The injected first BEGIN exits
# before a test or fixture can open sockets, while gawk still parses the whole
# combined program before execution.
ENV AWKPATH=/project/client:/project/client/tests:/project/client/tests/conformance:/project/examples/basics
RUN set -eu; \
    export AWKLIBPATH=/build/test; \
    for source in client/convex.awk \
                  client/tests/conformance/adapter.awk \
                  client/tests/fixture.awk \
                  client/tests/ext_test.awk \
                  client/tests/json_test.awk \
                  client/tests/http_test.awk \
                  client/tests/live_test.awk \
                  client/tests/adapter_test.awk \
                  client/tests/tls_test.awk \
                  examples/basics/main.awk; do \
      gawk --lint --pretty-print=/dev/null \
        --source 'BEGIN { exit 0 }' -f "$source"; \
    done; \
    gawk --lint --pretty-print=/dev/null \
      --source 'BEGIN { exit 0 }' \
      -f examples/basics/main.awk -f examples/basics/main_test.awk

# A short-lived certificate authority for the TLS test. It never leaves this
# stage.
RUN mkdir -p /tmp/awk-tls \
    && openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
       -subj '/CN=awk-test-ca' \
       -keyout /tmp/awk-tls/ca.key -out /tmp/awk-tls/ca.crt >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -sha256 -nodes \
       -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
       -keyout /tmp/awk-tls/server.key -out /tmp/awk-tls/server.csr >/dev/null 2>&1 \
    && openssl x509 -req -sha256 -days 1 -in /tmp/awk-tls/server.csr \
       -CA /tmp/awk-tls/ca.crt -CAkey /tmp/awk-tls/ca.key -CAcreateserial \
       -copy_extensions copy -out /tmp/awk-tls/server.crt >/dev/null 2>&1

# Every suite below runs against the extension the runtime images ship, except
# the TLS suite, which needs the test build's TLS server hook.
RUN AWKLIBPATH=/build/runtime gawk -f client/tests/ext_test.awk
RUN AWKLIBPATH=/build/runtime gawk -f client/tests/json_test.awk
RUN AWKLIBPATH=/build/runtime gawk -f client/tests/http_test.awk \
       -v FIXTURE=/project/client/tests/fixture.awk
RUN AWKLIBPATH=/build/runtime gawk -f client/tests/live_test.awk \
       -v FIXTURE=/project/client/tests/fixture.awk
RUN AWKLIBPATH=/build/runtime gawk -f client/tests/adapter_test.awk \
       -v ADAPTER_LIBRARY_ONLY=1 \
       -v ADAPTER=/project/client/tests/conformance/adapter.awk \
       -v FIXTURE=/project/client/tests/fixture.awk
RUN SSL_CERT_FILE=/tmp/awk-tls/ca.crt AWKLIBPATH=/build/test \
    gawk -f client/tests/tls_test.awk \
       -v FIXTURE=/project/client/tests/fixture.awk \
       -v CERTIFICATE=/tmp/awk-tls/server.crt \
       -v KEY=/tmp/awk-tls/server.key
RUN AWKLIBPATH=/build/runtime gawk -v EXAMPLE_LIBRARY_ONLY=1 \
       -v EXAMPLE=/project/examples/basics/main.awk \
       -v FIXTURE=/project/client/tests/fixture.awk \
       -f examples/basics/main.awk -f examples/basics/main_test.awk

# The adapter answers a hello/close session over stdin and stdout before any
# runtime image is built from it.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid AWKLIBPATH=/build/runtime \
      gawk -f client/tests/conformance/adapter.awk \
    | tee /tmp/adapter-probe.out \
    && grep -Fq '"language":"awk"' /tmp/adapter-probe.out \
    && grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Stage exactly the runtime closure: the two entry-point programs, gawk, the
# extension, a shell, the POSIX text tools the shared policy expects, and every
# shared object those binaries actually load.
RUN set -eu; \
    mkdir -p /staging/bin /staging/usr/bin /staging/usr/local/bin \
             /staging/opt/convex/client /staging/opt/convex/lib \
             /staging/etc/ssl/certs /staging/usr/lib/x86_64-linux-gnu/ossl-modules; \
    cp -a /usr/local/bin/gawk /staging/usr/local/bin/gawk; \
    cp -a /build/runtime/convexext.so /staging/opt/convex/lib/convexext.so; \
    cp -a /bin/dash /staging/bin/sh; \
    for tool in id cat cut head tail tr sort uniq wc uname grep sed; do \
      cp -a "/usr/bin/$tool" "/staging/usr/bin/$tool"; \
    done; \
    ln -s /usr/local/bin/gawk /staging/usr/bin/awk; \
    for object in /staging/usr/local/bin/gawk /staging/opt/convex/lib/convexext.so \
                  /staging/bin/sh /staging/usr/bin/*; do \
      test -f "$object" || continue; \
      ldd "$object" 2>/dev/null \
        | gawk '{ for (field = 1; field <= NF; field++) if ($field ~ /^\//) print $field }' \
        | while read -r library; do \
            mkdir -p "/staging$(dirname "$library")"; \
            cp -aL "$library" "/staging$library"; \
          done; \
    done; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
       /staging/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    cp -aL /etc/ssl/openssl.cnf /staging/etc/ssl/openssl.cnf; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /staging/etc/ssl/certs/ca-certificates.crt; \
    cp -aL /etc/nsswitch.conf /staging/etc/nsswitch.conf; \
    for resolver in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL "/lib/x86_64-linux-gnu/$resolver" "/staging/lib/x86_64-linux-gnu/$resolver"; \
    done; \
    cp -a client/convex.awk /staging/opt/convex/client/convex.awk

# Entry points. Each one is a two line launcher for the exact checked-in Awk
# program; LC_ALL=C keeps every string operation byte oriented, which is what
# lets UTF-8 payloads pass through untouched.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'export LC_ALL=C AWKPATH=/opt/convex/client AWKLIBPATH=/opt/convex/lib' \
      'exec /usr/local/bin/gawk -f /opt/convex/examples/basics/main.awk -- "$@"' \
      > /staging/usr/local/bin/convex-example \
    && printf '%s\n' \
      '#!/bin/sh' \
      'export LC_ALL=C AWKPATH=/opt/convex/client AWKLIBPATH=/opt/convex/lib' \
      'exec /usr/local/bin/gawk -f /opt/convex/adapter.awk -- "$@"' \
      > /staging/usr/local/bin/convex-adapter \
    && chmod 0555 /staging/usr/local/bin/convex-example /staging/usr/local/bin/convex-adapter

# `./run test awk` runs the same suites again from the built image, so the
# evidence is not limited to what happened during the build.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'cd /project' \
      'export LC_ALL=C' \
      'export AWKPATH=/project/client:/project/client/tests:/project/client/tests/conformance' \
      'export AWKLIBPATH=/build/runtime' \
      'F=/project/client/tests/fixture.awk' \
      'gawk -f client/tests/ext_test.awk' \
      'gawk -f client/tests/json_test.awk' \
      'gawk -f client/tests/http_test.awk -v FIXTURE=$F' \
      'gawk -f client/tests/live_test.awk -v FIXTURE=$F' \
      'gawk -f client/tests/adapter_test.awk -v ADAPTER_LIBRARY_ONLY=1 -v ADAPTER=/project/client/tests/conformance/adapter.awk -v FIXTURE=$F' \
      'gawk -v EXAMPLE_LIBRARY_ONLY=1 -v EXAMPLE=/project/examples/basics/main.awk -v FIXTURE=$F -f examples/basics/main.awk -f examples/basics/main_test.awk' \
      > /usr/local/bin/run-language-tests \
    && chmod 0555 /usr/local/bin/run-language-tests
CMD ["/usr/local/bin/run-language-tests"]

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its broad filesystem removed, then only
# the staged closure copied back.
# ---------------------------------------------------------------------------
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
    exec "$pruner" rm -rf /tmp
COPY --from=test /staging /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LC_ALL=C \
    AWKPATH=/opt/convex/client \
    AWKLIBPATH=/opt/convex/lib \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(uname -m)" = x86_64 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && gawk --version | head -n 1 | grep -Fq 'GNU Awk 5.3.2' \
    && gawk -l convexext 'BEGIN { if (convex_version() !~ /OpenSSL/) exit 1 }' \
    && ! gawk -l convexext 'BEGIN { convex_test_tls_accept(0, "x", "y", 1) }' >/dev/null 2>&1

# TLS has to be provable inside the final image rather than at hosted
# verification time. This loads the shipped trust store through the same code
# path the client uses and fails if no authority parses. It is not a handshake;
# the build stage's TLS suite covers that.
RUN gawk -l convexext 'BEGIN { \
      authorities = convex_tls_probe(probe); \
      if (authorities < 1) { \
        print "no certificate authority loaded: " convex_last_error() > "/dev/stderr"; \
        exit 1; \
      } \
      printf "trust store: %d authorities via %s (%s)\n", authorities, probe["bundle"], probe["openssl"]; \
    }'

RUN test ! -e /etc/dpkg \
    && test ! -e /etc/apt \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /busybox \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && for command_name in cc gcc g++ clang make ld as ar cmake apt apt-get dpkg \
         apk rpm curl wget nc netcat socat openssl busybox node npm npx python \
         python3 pip pip3 perl ruby php java go rustc cargo convex jq; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /project/examples/basics/main.awk /opt/convex/examples/basics/main.awk
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter \
    && test ! -e /opt/convex/adapter.awk
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# Keep the adapter last: `./run build awk` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /project/client/tests/conformance/adapter.awk /opt/convex/adapter.awk
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && test ! -e /opt/convex/examples \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://example.invalid /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
