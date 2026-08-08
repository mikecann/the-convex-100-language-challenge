# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# leanprover/lean4 is not a real Docker Hub or GHCR repository -- there is no
# published Lean 4 Docker image to pull at all (see the maintainers confirming
# the old Docker Hub images are abandoned: leanprover/lean4#6996; the
# community fork leanprovercommunity/lean4 only carries `latest` and one 2024
# snapshot tag, not v4.23.0). Lean 4's actual official distribution channel is
# prebuilt toolchain archives attached directly to each GitHub release. The
# toolchain here is lifted from that official x86_64 Linux release tarball,
# pinned by sha256, rather than from a nonexistent Docker image.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG LEAN_VERSION=4.23.0
ARG LEAN_LINUX_SHA256=ecd028d6f642b61b451c8687aeeb24dd53789fbfdcb7d4adb8f5cf60eb2022ba

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG LEAN_VERSION
ARG LEAN_LINUX_SHA256
# zstd decompresses the release archive; GNU tar shells out to it rather than
# reading .zst natively. It is not needed past this build-only stage.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes zstd=1.5.4+dfsg2-5 \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:${LEAN_LINUX_SHA256} \
    https://github.com/leanprover/lean4/releases/download/v${LEAN_VERSION}/lean-${LEAN_VERSION}-linux.tar.zst \
    /tmp/lean.tar.zst
RUN set -eu; \
    mkdir -p /opt/lean; \
    tar --zstd -xf /tmp/lean.tar.zst --strip-components=1 -C /opt/lean; \
    rm -f /tmp/lean.tar.zst; \
    test -x /opt/lean/bin/lean; \
    test -x /opt/lean/bin/lake; \
    /opt/lean/bin/lean --version | grep -Fq "${LEAN_VERSION}"

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG LEAN_VERSION
WORKDIR /build
# gcc compiles the one C shim; libssl-dev provides the TLS, digest, and CSPRNG
# surface the shim binds; ca-certificates brings the trust store and the
# openssl command used to mint the TLS fixture chain; busybox-static is the
# temporary pruner the runtime stage uses to remove itself. Debian's gcc
# metapackage does not itself depend on libc6-dev, so without it explicitly
# `cc` has no libc headers at all (errno.h, stdio.h, ...) to compile against.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       libssl-dev=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=toolchain /opt/lean /opt/lean
ENV PATH=/opt/lean/bin:/usr/local/bin:/usr/bin:/bin
RUN test "$(uname -m)" = x86_64 \
    && lean --version | grep -Fq "${LEAN_VERSION}" \
    && lake --version

# Lake expects one flat source tree. Docker builds it here so the educational
# repository keeps its `client/` and `examples/` layout.
COPY client/lakefile.lean ./lakefile.lean
COPY client/lean-toolchain ./lean-toolchain
COPY client/Convex.lean ./Convex.lean
COPY client/Convex ./Convex
COPY client/shim ./shim
COPY client/tests ./tests-source
COPY examples/basics/Main.lean ./ConvexExample.lean
RUN set -eu; \
    mkdir -p Tests/Conformance; \
    cp tests-source/*.lean Tests/; \
    cp tests-source/conformance/*.lean Tests/Conformance/; \
    rm -rf tests-source; \
    test -f Tests/Conformance/Adapter.lean; \
    test -f Tests/Conformance/Main.lean

# Lean 4 ships no standard formatter in its toolchain, so the checked-in style
# is enforced explicitly here instead of silently reformatting a build copy.
# The README and the website display these exact files, so the rules are about
# what a reader sees: no tabs, no trailing whitespace, no carriage returns, a
# final newline, and a column limit of 100 for Lean and 110 for the C shim.
RUN set -eu; \
    status=0; \
    for file in $(find Convex.lean ConvexExample.lean Convex Tests shim -type f \
                  \( -name '*.lean' -o -name '*.c' \) | sort); do \
      case "$file" in *.c) limit=110 ;; *) limit=100 ;; esac; \
      if grep -q "$(printf '\t')" "$file"; then \
        echo "$file: contains a tab" >&2; status=1; \
      fi; \
      if grep -q ' $' "$file"; then \
        echo "$file: has trailing whitespace" >&2; status=1; \
      fi; \
      if grep -q "$(printf '\r')" "$file"; then \
        echo "$file: has a carriage return" >&2; status=1; \
      fi; \
      if awk -v limit="$limit" 'length > limit { exit 1 }' "$file"; then :; else \
        echo "$file: has a line longer than $limit columns" >&2; status=1; \
      fi; \
      if test "$(tail -c 1 "$file" | wc -l)" -ne 1; then \
        echo "$file: does not end with a newline" >&2; status=1; \
      fi; \
    done; \
    exit "$status"

# Only `convex-adapter` is `@[default_target]` (deliberately: it is the sole
# entrypoint `./run build lean`'s separate runtime image needs), so a bare
# `lake build` does not produce any of the other executables this Docker
# stage needs to run below. Naming every executable explicitly builds them
# all in one pass rather than adding nine more individual `lake build <exe>`
# steps.
RUN lake build convex-adapter convex-example convex-fixture unit-tests \
      http-tests tls-tests websocket-tests live-tests adapter-tests example-tests \
    && test -x .lake/build/bin/convex-adapter \
    && test -x .lake/build/bin/convex-example \
    && test -x .lake/build/bin/convex-fixture \
    && file .lake/build/bin/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64'

# The pure codecs, bounds, and sync parser first: a failure here explains every
# later one.
RUN ./.lake/build/bin/unit-tests

# A private authority, a certificate that matches the fixture host, and one
# that does not. Short lived and confined to this build stage.
RUN set -eu; \
    mkdir -p /tls; \
    cd /tls; \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=lean-test-ca' -keyout ca.key -out ca.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
      -keyout server.key -out server.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in server.csr \
      -CA ca.crt -CAkey ca.key -CAcreateserial -copy_extensions copy \
      -out server.crt >/dev/null 2>&1; \
    openssl req -newkey rsa:2048 -sha256 -nodes \
      -subj '/CN=other.invalid' -addext 'subjectAltName=DNS:other.invalid' \
      -keyout other.key -out other.csr >/dev/null 2>&1; \
    openssl x509 -req -sha256 -days 1 -in other.csr \
      -CA ca.crt -CAkey ca.key -CAcreateserial -copy_extensions copy \
      -out other.crt >/dev/null 2>&1; \
    test -s /tls/ca.crt; test -s /tls/server.crt; test -s /tls/other.crt

ENV CONVEX_FIXTURE_BIN=/build/.lake/build/bin/convex-fixture \
    CONVEX_EXAMPLE_BIN=/build/.lake/build/bin/convex-example \
    CONVEX_TEST_CA=/tls/ca.crt \
    CONVEX_TEST_CERT=/tls/server.crt \
    CONVEX_TEST_KEY=/tls/server.key \
    CONVEX_TEST_OTHER_CERT=/tls/other.crt \
    CONVEX_TEST_OTHER_KEY=/tls/other.key

# Real chain validation and hostname verification against a real OpenSSL peer.
RUN ./.lake/build/bin/tls-tests
# Structured non-2xx envelopes, chunked framing, streaming size bounds, and an
# absolute deadline against a dribbling peer.
RUN ./.lake/build/bin/http-tests
# Frame bounds applied before allocation, fragmented UTF-8, and a suspended
# frame that resumes rather than resynchronising.
RUN ./.lake/build/bin/websocket-tests
# Five real reconnects with hydration, QueryFailed recovery, drift recovery,
# and a stopped reader that stays bounded.
RUN ./.lake/build/bin/live-tests
# Strict event shapes, strict command validation, output admission under a
# stopped reader, and the stale-relay barrier.
RUN ./.lake/build/bin/adapter-tests
# The exact canonical example binary against a scripted backend.
RUN ./.lake/build/bin/example-tests

# The adapter must speak protocol v1 over plain stdin and stdout as well as over
# ADAPTER_LISTEN, so the stdio path is exercised here directly.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | ./.lake/build/bin/convex-adapter > /tmp/adapter-probe.out \
    && grep -Fq '"language":"lean"' /tmp/adapter-probe.out \
    && grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# The example refuses to run without a deployment and prints nothing on stdout.
RUN set -eu; \
    code=0; \
    ./.lake/build/bin/convex-example > /tmp/example.out 2> /tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err
CMD ["/bin/sh", "-c", "true"]

FROM test AS build-artifacts
# Only the toolchain's own shared libraries need to travel; everything else the
# binaries need is glibc from the same pinned base.
RUN set -eu; \
    mkdir -p /out/lib; \
    cp .lake/build/bin/convex-adapter /out/convex-adapter; \
    cp .lake/build/bin/convex-example /out/convex-example; \
    ldd /out/convex-adapter /out/convex-example \
      | awk '$3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }' \
      | sort -u > /tmp/linked-libraries; \
    while IFS= read -r library; do \
      case "$library" in /opt/lean/*) cp -L "$library" /out/lib/ ;; esac; \
    done < /tmp/linked-libraries; \
    chmod 0555 /out/convex-adapter /out/convex-example; \
    if grep -q '=> not found' /tmp/linked-libraries; then \
      echo "unresolved runtime library" >&2; exit 1; \
    fi

# Start from the same pinned base, install the Lean runtime libraries, then
# delete everything that is not in the resulting closure or the small POSIX set
# the shared example verifier requires.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
COPY --from=test /etc/ssl/certs /etc/ssl/certs
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
# Copied explicitly rather than assumed: the slim base does not necessarily
# carry OpenSSL 3, and the client links it directly.
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules /usr/lib/x86_64-linux-gnu/ossl-modules
COPY --from=build-artifacts /out/lib/ /usr/lib/x86_64-linux-gnu/
COPY --from=build-artifacts /out/convex-example /tmp/closure-targets/convex-example
COPY --from=build-artifacts /out/convex-adapter /tmp/closure-targets/convex-adapter
RUN set -eu; \
    /sbin/ldconfig 2>/dev/null || true; \
    /usr/bin/rm -f /usr/bin/awk; \
    /usr/bin/ln -s mawk /usr/bin/awk; \
    for target in /tmp/closure-targets/convex-example /tmp/closure-targets/convex-adapter \
                  /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
                  /usr/bin/awk /usr/bin/mawk /usr/bin/basename /usr/bin/cat /usr/bin/cmp \
                  /usr/bin/cut /usr/bin/dash /usr/bin/dirname /usr/bin/env /usr/bin/find \
                  /usr/bin/grep /usr/bin/head /usr/bin/id /usr/bin/ls /usr/bin/printf \
                  /usr/bin/readlink /usr/bin/rm /usr/bin/sed /usr/bin/sh /usr/bin/sort \
                  /usr/bin/tail /usr/bin/tr /usr/bin/true /usr/bin/uname /usr/bin/wc; do \
      /usr/bin/ldd "$target" 2>/dev/null || true; \
    done | /usr/bin/awk '$3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }' \
      | /usr/bin/sort -u > /tmp/runtime-libraries; \
    while IFS= read -r library; do /usr/bin/readlink -f "$library"; done \
      < /tmp/runtime-libraries | /usr/bin/sort -u > /tmp/runtime-library-realpaths; \
    /usr/bin/find /usr/lib/x86_64-linux-gnu -xdev \( -type f -o -type l \) \
      ! -path '*/ossl-modules/*' -print > /tmp/runtime-library-candidates; \
    while IFS= read -r path; do \
      real_path=$(/usr/bin/readlink -f "$path" 2>/dev/null || true); \
      if test -n "$real_path" && /usr/bin/grep -Fxq "$real_path" /tmp/runtime-library-realpaths; then \
        continue; \
      fi; \
      /usr/bin/rm -f "$path"; \
    done < /tmp/runtime-library-candidates; \
    if test -d /usr/lib/x86_64-linux-gnu/ossl-modules; then \
      /usr/bin/find /usr/lib/x86_64-linux-gnu/ossl-modules -xdev -type f \
        ! -name 'legacy.so' -delete; \
    fi; \
    /usr/bin/find /usr/lib/x86_64-linux-gnu -xdev -depth -type d -empty -delete; \
    /usr/bin/find /usr/lib -mindepth 1 -maxdepth 1 ! -name x86_64-linux-gnu -exec /usr/bin/rm -rf {} +; \
    /usr/bin/find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cat|/usr/bin/cmp|/usr/bin/cut| \
        /usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head| \
        /usr/bin/id|/usr/bin/ls|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed| \
        /usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname| \
        /usr/bin/wc) ;; \
        *) /usr/bin/rm -f "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    /usr/bin/rm -rf /etc/apt /etc/alternatives /etc/cron.d /etc/cron.daily /etc/cron.hourly \
      /etc/cron.monthly /etc/cron.weekly /etc/crontab /etc/debconf.conf /etc/dpkg /etc/init.d \
      /etc/logrotate.conf /etc/logrotate.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d \
      /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d /etc/systemd /usr/libexec /usr/games \
      /usr/include /usr/share /usr/src /usr/local /var /opt; \
    /usr/bin/rm -rf /tmp/runtime-libraries /tmp/runtime-library-realpaths \
      /tmp/runtime-library-candidates /tmp/runtime-commands /tmp/closure-targets; \
    /usr/bin/find /etc -mindepth 1 -maxdepth 1 -print > /tmp/runtime-etc; \
    while IFS= read -r path; do \
      case "$path" in \
        /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf| \
        /etc/ld.so.conf.d|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl) ;; \
        *) /usr/bin/rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-etc; \
    /usr/bin/rm -f /tmp/runtime-etc; \
    if /usr/bin/find /etc /usr/lib /var -xdev -print 2>/dev/null \
       | /usr/bin/grep -Eq '(^|/)(apt|dpkg|debconf)([^/]*|/)|update-alternatives'; then \
      echo "forbidden runtime package-management residue" >&2; exit 1; \
    fi; \
    for path in /usr/local /usr/share /usr/libexec /var /opt; do \
      test ! -e "$path" || { echo "forbidden runtime artifact tree: $path" >&2; exit 1; }; \
    done; \
    /usr/bin/rm -f /usr/bin/rm; \
    for command in apt apt-get apt-cache dpkg dpkg-query getent hostname ping nc openssl curl \
      wget lean lake leanc elan gcc cc clang make ld as perl ruby go rustc cargo node npm npx \
      python python3 pip pip3 convex; do \
      if command -v "$command" >/dev/null 2>&1; then \
        echo "forbidden runtime command: $command" >&2; exit 1; \
      fi; \
    done
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
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
    printf 'needle\n' | grep -Fqx needle; \
    test "$(printf 'before\n' | sed 's/before/after/')" = after; \
    test "$(printf 'value\n' | awk '{print $1}')" = value

FROM runtime-base AS example-runtime
COPY --from=build-artifacts /out/convex-example /usr/local/bin/convex-example
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test "$(find /usr/local -xdev -type f | wc -l)" = 1
ENTRYPOINT ["/usr/local/bin/convex-example"]

# The adapter stays last so `./run build lean` uses the default target.
FROM runtime-base AS runtime
COPY --from=build-artifacts /out/convex-adapter /usr/local/bin/convex-adapter
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test "$(find /usr/local -xdev -type f | wc -l)" = 1; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | /usr/local/bin/convex-adapter \
    | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
