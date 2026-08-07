# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /opt/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       regina-rexx=3.6-2.4 \
       libregina3=3.6-2.4 \
       libregina3-dev=3.6-2.4 \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       libssl-dev=3.0.20-1~deb12u2 \
       libssl3=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
    && rm -rf /var/lib/apt/lists/*

COPY client ./client
COPY examples ./examples

# The C shim is the only part of this client that is not Rexx: raw socket
# connect/listen/accept/send/recv and the OpenSSL TLS handshake, loaded by
# client/convex.rexx (and by the test-only fixtures and adapter) with
# RXFUNCADD -- the same mechanism Regina's own built-in packages use to
# reach the C library. -Wall -Wextra -Werror keeps it honest.
RUN gcc -Wall -Wextra -Werror -O2 -fpic -shared \
      -o client/libconvexshim.so client/shim.c -lssl -lcrypto

RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    test "$(regina -v 2>&1 | head -1)" = "REXX-Regina_3.6(MT) 5.00 31 Dec 2011"; \
    export LD_LIBRARY_PATH=/opt/convex/client; \
    regina client/tests/selftest_test.rexx; \
    regina client/tests/http_test.rexx; \
    regina client/tests/live_test.rexx; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | regina client/tests/conformance/adapter.rexx > /tmp/adapter.ndjson; \
    grep -Fq '"type":"ready","language":"rexx","implementation":"native-regina-rexx-0.1.0"' /tmp/adapter.ndjson; \
    grep -Fqx '{"id":"close","type":"closed"}' /tmp/adapter.ndjson; \
    ( unset CONVEX_URL; regina examples/basics/main.rexx demo-room 2>&1 1>/dev/null | grep -Fq 'CONVEX_URL is required' )

# Use a pinned non-scratch Debian carrier, then rebuild its visible
# filesystem from the explicit Regina/OpenSSL/CA closure. BusyBox exists
# only in this build stage to prune the carrier and never reaches either
# exported runtime image.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root /run /sbin /srv /usr /var; do /busybox rm -rf "$path"; done; \
    for path in /etc/*; do case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) /busybox rm -rf "$path" ;; esac; done; \
    /busybox mkdir -p /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin /opt/convex/client
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/libpthread.so.0
COPY --from=test /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/libdl.so.2
COPY --from=test /usr/lib/x86_64-linux-gnu/libregina.so.3.6 /usr/lib/x86_64-linux-gnu/libregina.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /usr/bin/regina /usr/local/bin/regina
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /usr/lib/x86_64-linux-gnu/libnss_dns.so.2 /usr/lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /usr/lib/x86_64-linux-gnu/libnss_files.so.2 /usr/lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /usr/lib/x86_64-linux-gnu/libresolv.so.2 /usr/lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/uname /usr/bin/uname
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    LD_LIBRARY_PATH=/opt/convex/client \
    PATH=/usr/local/bin:/usr/bin:/bin
COPY --from=test /opt/convex/client/convex.rexx /opt/convex/client/convex.rexx
COPY --from=test /opt/convex/client/libconvexshim.so /opt/convex/client/libconvexshim.so
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(uname -m)" = x86_64 \
    && test "$(regina -v 2>&1 | head -1)" = "REXX-Regina_3.6(MT) 5.00 31 Dec 2011"

# Both entrypoints are plain Rexx source starting with a "#!/usr/local/bin/
# regina" line: the kernel's own shebang handling execs regina against the
# file directly, so no separate launcher script is needed, and `regina
# <path>` (used throughout client/tests) runs the exact same file.
FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.rexx /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.rexx /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
