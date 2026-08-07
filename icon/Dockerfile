# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG UNICON_COMMIT=16bebbfde1b335daf1a019f94c782e2afea94f56

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG UNICON_COMMIT
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       git ca-certificates m4 bison flex \
       gcc=4:12.2.0-3 g++=4:12.2.0-3 make libc6-dev=2.36-9+deb12u14 \
       libssl-dev=3.0.20-1~deb12u2 libssl3=3.0.20-1~deb12u2 \
       libgdbm-dev libgdbm-compat-dev \
    && rm -rf /var/lib/apt/lists/*
# Debian does not package Unicon, so the toolchain is built from a pinned
# upstream commit. Two source patches are required to build at all on a
# current glibc/gcc: time.c's millisec() declares its working variables in
# an inner block but uses them after it closes (a real scoping bug,
# unrelated to this platform), and sys.h unconditionally wants <ndbm.h>
# even with the built-in database disabled (satisfied by
# libgdbm-compat-dev). Graphics, 3D graphics, audio, VOIP, concurrency, the
# built-in pattern type, and the built-in database are disabled: none of
# them apply to a headless network client, and disabling them removes a
# large build surface this client never exercises. `--enable-thin` looks
# like the obvious way to shed the same surface, but it also silently
# turns off `plugins`, which is what loadfunc() needs -- this client's
# whole transport depends on that, so the individual --disable-* flags are
# used instead, keeping plugins on.
RUN git clone -q https://github.com/uniconproject/unicon.git /src \
    && cd /src && git checkout -q "${UNICON_COMMIT}"
RUN sed -i '59d;69d' /src/src/common/time.c
WORKDIR /src
RUN ./configure --disable-graphics --disable-graphics3d --disable-audio --disable-voip --disable-database --disable-concurrency --disable-pattern
# The emulated build host occasionally loses gcc's cc1 to an unrelated
# segfault mid-build (an environment artifact, not a source defect: never
# the same file twice, and a bare retry always proceeds from where it left
# off since make only rebuilds what failed). Retry a bounded number of
# times rather than fail the whole toolchain build on that flake.
RUN set -eu; attempt=1; status=1; \
    while [ "$attempt" -le 15 ] && [ "$status" -ne 0 ]; do \
      make -j2 -k && status=0 || status=$?; \
      attempt=$((attempt + 1)); \
    done; \
    test "$status" -eq 0
ENV PATH=/src/bin:$PATH

FROM toolchain AS test
WORKDIR /opt/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates busybox-static=1:1.35.0-4+deb12u1+b1 \
    && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples

# The C shim is the only part of this client that is not Unicon: raw
# socket connect/listen/accept/send/recv and the OpenSSL TLS handshake,
# loaded by client/convex.icn (and by the test-only fixtures and adapter)
# with loadfunc() -- Unicon's documented foreign-function interface.
RUN gcc -Wall -Wextra -Werror -O2 -fpic -shared \
      -I/src/ipl/cfuncs -o client/libconvexshim.so client/shim.c -lssl -lcrypto

# `unicon -c` compiles client/convex.icn to convex.u in the current working
# directory (not next to convex.icn itself), and `link "convex"` in every
# dependent file below only ever locates an already-compiled .u file by
# that same current-working-directory rule -- it never auto-discovers or
# compiles a sibling .icn source. So convex.icn is compiled exactly once,
# from this fixed /opt/convex working directory, before anything that
# links it.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    unicon -c client/convex.icn; \
    unicon -o client/tests/fixtures/http_fixture client/tests/fixtures/http_fixture.icn; \
    unicon -o client/tests/fixtures/ws_fixture client/tests/fixtures/ws_fixture.icn; \
    unicon -o client/tests/selftest_test client/tests/selftest_test.icn; \
    LD_LIBRARY_PATH=/opt/convex/client client/tests/selftest_test; \
    unicon -o client/tests/http_test client/tests/http_test.icn; \
    LD_LIBRARY_PATH=/opt/convex/client client/tests/http_test; \
    unicon -o client/tests/live_test client/tests/live_test.icn; \
    LD_LIBRARY_PATH=/opt/convex/client client/tests/live_test; \
    unicon -o client/tests/conformance/adapter client/tests/conformance/adapter.icn; \
    unicon -o examples/basics/convex-example examples/basics/main.icn; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | LD_LIBRARY_PATH=/opt/convex/client client/tests/conformance/adapter > /tmp/adapter.ndjson; \
    # Checked field by field rather than as one exact line: Unicon's table()
    # is a genuine hash table with no insertion-order guarantee (unlike,
    # say, Tcl's dict), so json_encode's key order for the same object can
    # legitimately differ from one run to the next. JSON semantics never
    # promised an order to begin with; only the field values matter here.
    grep -Fq '"type":"ready"' /tmp/adapter.ndjson; \
    grep -Fq '"language":"unicon"' /tmp/adapter.ndjson; \
    grep -Fq '"implementation":"native-unicon-0.1.0"' /tmp/adapter.ndjson; \
    grep -Fq '"id":"close"' /tmp/adapter.ndjson; \
    grep -Fq '"type":"closed"' /tmp/adapter.ndjson; \
    ( unset CONVEX_URL; LD_LIBRARY_PATH=/opt/convex/client examples/basics/convex-example demo-room 2>&1 1>/dev/null | grep -Fq 'CONVEX_URL is required' )

# Use a pinned non-scratch Debian carrier, then rebuild its visible
# filesystem from the explicit closure the compiled binaries actually
# need. BusyBox exists only in this build stage to prune the carrier and
# never reaches either exported runtime image.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root /run /sbin /srv /usr /var; do /busybox rm -rf "$path"; done; \
    for path in /etc/*; do case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) /busybox rm -rf "$path" ;; esac; done; \
    /busybox mkdir -p /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin /opt/convex/client
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/libpthread.so.0
COPY --from=test /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/libdl.so.2
COPY --from=test /lib/x86_64-linux-gnu/libcrypt.so.1 /lib/x86_64-linux-gnu/libcrypt.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libnsl.so.2 /usr/lib/x86_64-linux-gnu/libnsl.so.2
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
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
# `unicon -o out file.icn` does not produce a native ELF binary: it emits
# a small "#!/bin/sh" wrapper (which looks for iconx at $ICONX, next to
# itself, or on PATH) followed by the compiled icode. iconx is the actual
# genuinely-dynamically-linked interpreter that has to be present at
# runtime; pinning $ICONX sidesteps needing the wrapper's path-relative
# fallback to line up.
COPY --from=test --chmod=0555 /src/bin/iconx /usr/local/bin/iconx
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    LD_LIBRARY_PATH=/opt/convex/client \
    PATH=/usr/local/bin:/usr/bin:/bin \
    ICONX=/usr/local/bin/iconx
COPY --from=test /opt/convex/client/libconvexshim.so /opt/convex/client/libconvexshim.so
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(uname -m)" = x86_64

FROM runtime-base AS example-runtime
COPY --from=test --chmod=0555 /opt/convex/examples/basics/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test --chmod=0555 /opt/convex/client/tests/conformance/adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
