# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Every toolchain and dependency version is pinned here. The build asserts the
# Poly/ML version and the linked library closure, so a drifting base image fails
# loudly instead of silently producing a different client.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG POLYML_VERSION=5.7.1-5
# The version the compiler reports about itself, checked against the package pin.
ARG POLYML_COMPILER_VERSION=5.7.1
# polyc links the exported heap with g++, so the C++ driver is pinned too.
ARG GCC_VERSION=4:12.2.0-3
ARG GXX_VERSION=4:12.2.0-3
ARG OPENSSL_DEV_VERSION=3.0.20-1~deb12u2
ARG OPENSSL_VERSION=3.0.20-1~deb12u2
ARG CA_CERTIFICATES_VERSION=20230311+deb12u1
ARG BUSYBOX_VERSION=1:1.35.0-4+deb12u1+b1
ARG FILE_VERSION=1:5.44-3

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG POLYML_VERSION
ARG POLYML_COMPILER_VERSION
ARG GCC_VERSION
ARG GXX_VERSION
ARG OPENSSL_DEV_VERSION
ARG OPENSSL_VERSION
ARG CA_CERTIFICATES_VERSION
ARG BUSYBOX_VERSION
ARG FILE_VERSION
WORKDIR /project

RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       polyml=${POLYML_VERSION} \
       libpolyml-dev=${POLYML_VERSION} \
       libpolyml9=${POLYML_VERSION} \
       gcc=${GCC_VERSION} \
       g++=${GXX_VERSION} \
       libssl-dev=${OPENSSL_DEV_VERSION} \
       openssl=${OPENSSL_VERSION} \
       ca-certificates=${CA_CERTIFICATES_VERSION} \
       busybox-static=${BUSYBOX_VERSION} \
       file=${FILE_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# Fail early and clearly if the pinned toolchain is not what this client expects.
# The compiler is also asked its own version, which is the value the adapter
# reports back to the shared controller in its hello response.
RUN test "$(uname -m)" = x86_64 \
    && command -v poly \
    && command -v polyc \
    && command -v cc \
    && command -v g++ \
    && printf '%s\n' 'TextIO.print (PolyML.Compiler.compilerVersion ^ "\n");' \
       > /tmp/poly-version.sml \
    && poly -q --use /tmp/poly-version.sml < /dev/null > /tmp/poly-version.txt \
    && cat /tmp/poly-version.txt \
    && grep -Fq "${POLYML_COMPILER_VERSION}" /tmp/poly-version.txt

# Every path the runtime stage copies must exist here, so a drifting base image
# fails with the offending path instead of an opaque COPY error.
RUN set -eu; \
    for path in \
      /bin/busybox /bin/dash \
      /lib64/ld-linux-x86-64.so.2 \
      /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
      /lib/x86_64-linux-gnu/libc.so.6 \
      /lib/x86_64-linux-gnu/libm.so.6 \
      /lib/x86_64-linux-gnu/libgcc_s.so.1 \
      /lib/x86_64-linux-gnu/libnss_dns.so.2 \
      /lib/x86_64-linux-gnu/libnss_files.so.2 \
      /lib/x86_64-linux-gnu/libresolv.so.2 \
      /lib/x86_64-linux-gnu/libselinux.so.1 \
      /lib/x86_64-linux-gnu/libpcre2-8.so.0 \
      /lib/x86_64-linux-gnu/libacl.so.1 \
      /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
      /usr/lib/x86_64-linux-gnu/libffi.so.8 \
      /usr/lib/x86_64-linux-gnu/libpolyml.so.9 \
      /usr/lib/x86_64-linux-gnu/libssl.so.3 \
      /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
      /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
      /etc/ssl/certs/ca-certificates.crt /etc/ssl/openssl.cnf /etc/nsswitch.conf \
      /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head /usr/bin/tail \
      /usr/bin/tr /usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/uname \
      /usr/bin/grep /usr/bin/sed /usr/bin/mawk; do \
      if ! test -e "$path"; then \
        printf '%s\n' "Declared runtime path is missing from the build stage: $path" >&2; \
        exit 1; \
      fi; \
    done

# polyc links the exported Poly/ML heap with g++. Building linux/amd64 under
# emulation on an arm64 host makes collect2 die intermittently with an internal
# segmentation fault - an emulator defect, not a defect in this source. Retry
# only that exact signature, a bounded number of times, and surface every
# attempt. A genuine Standard ML error still fails on the first attempt.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'attempt=1' \
      'while : ; do' \
      '  if polyc "$@" 2>/tmp/polyc-stderr; then cat /tmp/polyc-stderr >&2; exit 0; fi' \
      '  cat /tmp/polyc-stderr >&2' \
      '  if ! grep -q "internal compiler error" /tmp/polyc-stderr; then exit 1; fi' \
      '  if [ "$attempt" -ge 4 ]; then' \
      '    echo "polyc: emulated toolchain failed $attempt times; giving up" >&2' \
      '    exit 1' \
      '  fi' \
      '  echo "polyc: emulated collect2 fault on attempt $attempt; retrying" >&2' \
      '  attempt=$((attempt + 1))' \
      'done' \
      > /usr/local/bin/polyc-retry \
    && chmod 755 /usr/local/bin/polyc-retry

COPY client ./client
COPY examples ./examples

RUN mkdir -p /build /out

# Layer 1: the style and lint gate. Poly/ML ships no formatter, so this is the
# repository's mechanical stand-in for one: encoding, width, termination,
# comment nesting, and forbidden constructs across every checked-in Standard ML
# source. It runs before anything is compiled for behaviour.
RUN polyc-retry -o /build/style-test client/tests/style-test.sml && /build/style-test

# Layer 2: encodings. Strict JSON, SHA-1, base64, the Convex sync timestamp
# spelling, and deployment URL parsing.
RUN polyc-retry -o /build/json-test client/tests/json-test.sml && /build/json-test

# Layer 3: real TLS. A private authority issues a certificate for `localhost`
# only, so the name check is exercised in both directions against a real
# OpenSSL server.
RUN set -eu; \
    mkdir -p /tmp/tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=standard-ml-test-ca' \
      -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
      -keyout /tmp/tls/server.key -out /tmp/tls/server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in /tmp/tls/server.csr \
      -CA /tmp/tls/ca.crt -CAkey /tmp/tls/ca.key -CAcreateserial \
      -copy_extensions copy -out /tmp/tls/server.crt >/dev/null 2>&1
RUN set -eu; \
    polyc-retry -o /build/tls-test client/tests/tls-test.sml; \
    openssl s_server -quiet -www -accept 19600 \
      -cert /tmp/tls/server.crt -key /tmp/tls/server.key >/dev/null 2>&1 & \
    sleep 2; \
    SSL_CERT_FILE=/tmp/tls/ca.crt TLS_TEST_PORT=19600 /build/tls-test

# Layer 4: real HTTP over kernel sockets, including the bearer-token lifecycle,
# a structured function error, a non-Convex body, and the connect deadline.
RUN polyc-retry -o /build/http-test client/tests/http-test.sml && /build/http-test

# Layer 5: Live acceptance against a raw WebSocket fixture - malformed
# envelopes, fragmentation, deadlines, QueryFailed recovery, and five genuine
# reconnect and hydration cycles.
RUN polyc-retry -o /build/live-test client/tests/live-test.sml && /build/live-test

# Layer 6: the adapter protocol - strict command schemas, malformed envelopes,
# the bounded stopped-reader output budget, and the TCP transport.
RUN polyc-retry -o /build/adapter-test client/tests/adapter-test.sml && /build/adapter-test

# Layer 7: the adapter driving real Live traffic, including stale relay
# rejection. The Standard ML Basis Library can read the environment but not
# modify it, so the fixture URL is supplied here.
RUN polyc-retry -o /build/adapter-live-test client/tests/adapter-live-test.sml \
    && CONVEX_URL=http://127.0.0.1:19400 /build/adapter-live-test

# Build the two shipped executables from the exact same client sources.
RUN polyc-retry -o /out/convex-adapter client/build-adapter.sml \
    && polyc-retry -o /out/convex-example client/build-example.sml \
    && file /out/convex-adapter /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64' \
    && file /out/convex-adapter

# The runtime image copies an explicit library closure. Assert here that the
# closure below is complete, so a missing dependency fails the build with the
# offending path instead of failing at run time in the minimal image.
# Keep this list and the COPY lines in the runtime-base stage in step.
RUN set -eu; \
    allowed=" \
      /lib64/ld-linux-x86-64.so.2 \
      /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
      /lib/x86_64-linux-gnu/libc.so.6 \
      /lib/x86_64-linux-gnu/libm.so.6 \
      /lib/x86_64-linux-gnu/libgcc_s.so.1 \
      /lib/x86_64-linux-gnu/libffi.so.8 \
      /lib/x86_64-linux-gnu/libstdc++.so.6 \
      /usr/lib/x86_64-linux-gnu/libc.so.6 \
      /usr/lib/x86_64-linux-gnu/libm.so.6 \
      /usr/lib/x86_64-linux-gnu/libgcc_s.so.1 \
      /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
      /usr/lib/x86_64-linux-gnu/libffi.so.8 \
      /usr/lib/x86_64-linux-gnu/libssl.so.3 \
      /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
    "; \
    for binary in /out/convex-adapter /out/convex-example; do \
      ldd "$binary" | awk '{ for (i = 1; i <= NF; i++) if (substr($i, 1, 1) == "/") print $i }' \
        | sort -u > /tmp/needed.txt; \
      while read -r path; do \
        case "$path" in \
          */libpolyml.so.*) continue ;; \
        esac; \
        case " $allowed " in \
          *" $path "*) ;; \
          *) printf '%s\n' "Undeclared runtime dependency in $binary: $path" >&2; exit 1 ;; \
        esac; \
      done < /tmp/needed.txt; \
    done; \
    ldd /out/convex-adapter | grep -Fq libpolyml

# Prove the compiled adapter really speaks the protocol before it is copied
# into an image with no compiler.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | /out/convex-adapter > /tmp/adapter-probe.out \
    && grep -Fq '"type":"ready"' /tmp/adapter-probe.out \
    && grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# The example without configuration must fail with an empty stdout, because
# stdout is the universal happy-path transcript.
RUN code=0; \
    /out/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1 \
    && test ! -s /tmp/example.out \
    && grep -Fq 'CONVEX_URL is required' /tmp/example.err

# Layer 8: execute the exact shipped example binary against a fixture that
# answers with Convex's integral decimal spelling, and prove a fractional count
# is refused with no stdout at all.
RUN polyc-retry -o /build/main-test examples/basics/main-test.sml \
    && EXAMPLE_BINARY=/out/convex-example /build/main-test

# Layer 9: the bounded-writer runtime audit. The real adapter sink runs while
# nothing reads stdout, so the queue and an in-flight write are both under
# pressure. That fault injection is compiled only into this test-only build.
RUN set -eu; \
    polyc-retry -o /build/convex-adapter-flood client/tests/flood-adapter.sml; \
    /build/convex-adapter-flood 2>/tmp/flood.err | ( sleep 4; cat >/dev/null ); \
    grep -Fq 'adapter flood queue ready' /tmp/flood.err

# The shipped adapter must carry no trace of that audit: not the retired
# environment switch, not its diagnostics, and no behaviour that responds to
# either. The strings would be in the exported heap if they were compiled in.
RUN set -eu; \
    if grep -aq 'ADAPTER_FLOOD_TEST' /out/convex-adapter; then \
      printf '%s\n' 'The shipped adapter still names the flood-test switch' >&2; \
      exit 1; \
    fi; \
    if grep -aq 'adapter flood queue ready' /out/convex-adapter; then \
      printf '%s\n' 'The shipped adapter still carries the flood-audit diagnostics' >&2; \
      exit 1; \
    fi; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | ADAPTER_FLOOD_TEST=1 /out/convex-adapter \
      >/tmp/flood-probe.out 2>/tmp/flood-probe.err; \
    grep -Fq '"type":"ready"' /tmp/flood-probe.out; \
    grep -Fq '"type":"closed"' /tmp/flood-probe.out; \
    if grep -Fq 'adapter flood queue ready' /tmp/flood-probe.err; then \
      printf '%s\n' 'The shipped adapter still answers the flood-test switch' >&2; \
      exit 1; \
    fi

CMD ["/bin/sh", "-c", "echo 'standard-ml: style, unit, Live, adapter, TLS, and example tests all ran during the build'"]

# Start from the pinned non-scratch image, remove its broad filesystem with a
# temporary static helper, then copy back only the declared runtime closure.
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

# The dynamic loader and the C runtime.
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/libgcc_s.so.1
# The Poly/ML runtime library and what it links against. It is a language
# runtime, not a compiler: the assertions below prove no compiler command and
# no Poly/ML frontend survive in this image.
COPY --from=test /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/x86_64-linux-gnu/libstdc++.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libffi.so.8 /usr/lib/x86_64-linux-gnu/libffi.so.8
COPY --from=test /usr/lib/x86_64-linux-gnu/libpolyml.so.9 /usr/lib/x86_64-linux-gnu/libpolyml.so.9
# TLS: the libraries, the configuration, the provider module, and the roots.
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
# Name resolution.
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
# The shared policy verifier requires /bin/sh and a few POSIX text tools.
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

# There is no /etc/ld.so.cache in this image, so name the two library
# directories explicitly. The TLS libraries are opened by name at run time.
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu \
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
    && for library in \
         /lib64/ld-linux-x86-64.so.2 \
         /lib/x86_64-linux-gnu/libc.so.6 \
         /lib/x86_64-linux-gnu/libm.so.6 \
         /lib/x86_64-linux-gnu/libgcc_s.so.1 \
         /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
         /usr/lib/x86_64-linux-gnu/libffi.so.8 \
         /usr/lib/x86_64-linux-gnu/libpolyml.so.9 \
         /usr/lib/x86_64-linux-gnu/libssl.so.3 \
         /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
         /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; do \
         test -e "$library"; \
       done \
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /etc/update-motd.d \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /usr/lib/x86_64-linux-gnu/gconv \
    && test ! -e /usr/lib/polyml \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && set -- /lib64/* \
    && test "$#" -eq 1 \
    && set -- /usr/lib/x86_64-linux-gnu/ossl-modules/* \
    && test "$#" -eq 1 \
    && for command_name in poly polyc polyimport polyml cc gcc clang make cmake ld \
         as ar apt apt-get dpkg curl wget nc netcat ssh openssl node python python3 \
         ruby perl java php go rustc cargo npm pip busybox convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter
# Execute the exact published entrypoint from this exact image, rather than
# inferring that it works because the build stage ran the same bytes with a
# different library path, user, and filesystem. Without configuration it must
# exit 1 with an empty stdout, because stdout is the universal happy-path
# transcript, and say why on stderr. Nothing is written to disk: this stage runs
# as 65532 over a filesystem that has already had /tmp removed.
RUN set -eu; \
    code=0; \
    out=$(/usr/local/bin/convex-example 2>/dev/null) || code=$?; \
    test "$code" -eq 1; \
    test -z "$out"; \
    err=$(/usr/local/bin/convex-example 2>&1 >/dev/null || true); \
    printf '%s\n' "$err" | grep -Fq 'CONVEX_URL is required'
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last: `./run build standard-ml` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
