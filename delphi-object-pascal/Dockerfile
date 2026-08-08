# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f
ARG RUNTIME_BASE_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Ubuntu 22.04 ships Free Pascal 3.2.2 in `-Mdelphi' mode with everything
# this client needs already bundled: fpjson/jsonparser for JSON,
# fphttpclient for HTTP/1.1, and ssockets/sslsockets/opensslsockets for
# raw TCP and TLS sockets. Unlike EiffelStudio's inline-C bodies (see this
# project's Eiffel client), fpc has no C-bundling bug to route around, so
# no separate C shim is needed here.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
       ca-certificates=20260601~22.04.1 \
       fpc=3.2.2+dfsg-9ubuntu1 \
       libssl-dev=3.0.2-0ubuntu1.26 \
    && rm -rf /var/lib/apt/lists/*
RUN fpc -iV | grep -Fq '3.2.2'

WORKDIR /project
COPY client/ client/
COPY examples/ examples/

# fpc's OpenSSL binding resolves `libssl'/`libcrypto' at runtime through
# `dlopen', trying a hardcoded list of historical SONAME suffixes
# (packages/openssl/src/openssl.pas's `DLLVersions': '', '.1.1', '.11',
# '.10', down through the 1.0.x and 0.9.x series) that predates OpenSSL
# 3.x and has no `.3' entry. Debian's `libssl3' package ships only the
# versioned `libssl.so.3'/`libcrypto.so.3', with no unversioned symlink
# (that symlink normally comes from the `-dev' package, which has no
# place in a runtime image), so a program built and even briefly probed
# against `libssl-dev' here would still find nothing at `dlopen' time in
# a minimal runtime and fail TLS silently. This was reproduced directly
# against both `example.com' and this project's own hosted deployment
# before being fixed here (see README): with only `libssl3' installed
# and no symlink, every HTTPS/WSS call failed with a generic "connect
# failed"; adding the two symlinks below was sufficient and is the
# standard fix for this well-known fpc/Debian gap.
RUN mkdir -p /out \
    && (cd client/tests && fpc -Mdelphi -O2 -Fu.. ConvexClientTests.pas -o/out/convex-tests) \
    && (cd client/tests/conformance && fpc -Mdelphi -O2 -Fu../.. ConvexAdapterApp.pas -o/out/convex-adapter) \
    && (cd examples/basics && fpc -Mdelphi -O2 -Fu../../client ConvexExampleApp.pas -o/out/convex-example)
RUN readelf -h /out/convex-adapter | grep -Fq 'Advanced Micro Devices X86-64' \
    && readelf -h /out/convex-example | grep -Fq 'Advanced Micro Devices X86-64'
RUN strip /out/convex-tests /out/convex-adapter /out/convex-example

FROM build AS test
RUN /out/convex-tests | grep -Fqx ALL_TESTS_PASSED
# The plaintext check proves the adapter's NDJSON framing and clean-close
# path; port 9 refuses the connection immediately, so the mismatched
# `demo:count' path never actually resolves against a real deployment and
# this alone is not TLS or Live evidence. `./run verify-example' and
# `./run verify' exercise both against the real approved deployments.
RUN set -eu; \
    actual="$(printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 /out/convex-adapter)"; \
    printf '%s\n' "$actual" | grep -Fq '"id":"hello","type":"ready"'; \
    printf '%s\n' "$actual" | grep -Fqx '{"id":"close","type":"closed"}'
CMD ["/bin/sh", "-c", "true"]

FROM --platform=linux/amd64 ${RUNTIME_BASE_IMAGE} AS runtime-base
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
       ca-certificates=20230311+deb12u1 \
       libssl3=3.0.20-1~deb12u2 \
    && rm -rf /var/lib/apt/lists/*
# See the build stage's comment: fpc's OpenSSL binding never appears as
# an ordinary `ldd' dependency (it is `dlopen'd, not link-time linked),
# and its hardcoded SONAME search list has no entry for OpenSSL 3.x's
# `libssl.so.3'/`libcrypto.so.3'. These two symlinks are the entire fix;
# nothing else about the OpenSSL install changes.
RUN ln -s libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so \
    && ln -s libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so
COPY --from=build /out/convex-adapter /out/convex-example /tmp/
RUN set -eu; \
    for command_path in /usr/bin/mawk /usr/bin/basename /usr/bin/cat /usr/bin/cut \
        /usr/bin/dash /usr/bin/dirname /usr/bin/env /usr/bin/find /usr/bin/grep \
        /usr/bin/head /usr/bin/id /usr/bin/sed /usr/bin/sort /usr/bin/tail \
        /usr/bin/tr /usr/bin/true /usr/bin/uname /usr/bin/uniq /usr/bin/wc; do \
      test -e "$command_path" || { echo "missing expected command: $command_path" >&2; exit 1; }; \
    done
RUN set -eu; \
    rm -f /usr/bin/awk; ln -s mawk /usr/bin/awk; \
    find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cat|/usr/bin/cut| \
        /usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep| \
        /usr/bin/head|/usr/bin/id|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh| \
        /usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname| \
        /usr/bin/uniq|/usr/bin/wc) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    rm -rf /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily /etc/cron.hourly \
      /etc/cron.monthly /etc/cron.weekly /etc/crontab /etc/debconf.conf /etc/dpkg \
      /etc/init.d /etc/logrotate.conf /etc/logrotate.d /etc/rc0.d /etc/rc1.d \
      /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d \
      /etc/systemd /usr/games /usr/include /usr/lib/apt /usr/lib/dpkg \
      /usr/lib/systemd /usr/libexec /usr/share /usr/src /usr/local/man \
      /usr/local/share /var/backups /var/cache /var/lib /var/local /var/mail \
      /var/opt /var/spool /var/tmp /var/log/* /tmp/convex-adapter \
      /tmp/convex-example /tmp/runtime-commands; \
    for command_name in fpc ppcx64 gcc cc clang make ld as apt apt-get dpkg \
        curl wget nc netcat openssl node python python3 ruby perl java php go \
        rustc cargo npm pip convex busybox mv chmod chown; do \
      ! command -v "$command_name" >/dev/null 2>&1 || { echo "forbidden runtime command: $command_name" >&2; exit 1; }; \
    done
RUN test -d /usr/local/bin
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64

FROM runtime-base AS example-runtime
COPY --from=build /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
       | grep -Fqx '{"id":"close","type":"closed"}'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
