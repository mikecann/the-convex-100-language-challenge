# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS test
WORKDIR /project
RUN apk add --no-cache \
    hare=0.24.2-r3 harec=0.24.2-r1 qbe=1.2-r3 \
    openssl=3.5.7-r0 openssl-dev=3.5.7-r0 openssl-libs-static=3.5.7-r0 \
    musl-dev=1.2.5-r12 file=5.46-r2 binutils=2.44-r3
# Hare's build driver always shells out to the platform toolchain's `cc` to
# link, but exposes no flag of its own to request static linking. A thin `cc`
# wrapper earlier on PATH appends `-static` to every link this image performs,
# so both binaries built below (and `hare test`'s own transient test binary)
# come out statically linked against musl with no further flags anywhere else
# in this file.
RUN mkdir -p /wrap && printf '#!/bin/sh\nexec /usr/bin/cc -static "$@"\n' >/wrap/cc && chmod +x /wrap/cc
ENV PATH=/wrap:/usr/bin:/bin:/sbin:/usr/sbin
RUN hare version | grep -Fx 'hare 0.24.2-alpine'
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md
# Hare 0.24 (current when this client was written) ships no `hare fmt` or
# other blessed formatter; a community `hare-fmt` project exists but is not
# part of the toolchain this image installs. Source in this directory is
# therefore hand-formatted against the tabs-for-indentation, brace-on-same-
# line style Hare's own standard library uses throughout
# /usr/src/hare/stdlib, rather than machine-checked here.
#
# Hare resolves `use convex;` against a directory named `convex` on HAREPATH;
# this project's layout keeps the public client tree at `client/` instead, so
# the build stages below copy it into a `convex/`-named module root rather
# than reshaping the checked-in source tree around Hare's own naming
# convention.
RUN mkdir -p /build/convex && cp client/*.ha /build/convex/
# `hare test` covers the client's local, network-independent unit behaviour
# (JSON encode/decode, and every fixture-free regression in the suite). The
# three real-backend regressions in this suite (one real TLS handshake, one
# HTTP query/mutation, and one Live subscribe/reconnect) each check for an
# opt-in environment variable and no-op when it is absent, so this step
# proves everything it can without a network dependency, matching this
# project's layered split between `test` and `./run verify`/`verify-hosted`.
RUN HAREPATH=/build:/usr/src/hare/stdlib:/usr/src/hare/third-party hare test -lssl -lcrypto /build/convex
RUN mkdir -p /build/example && cp examples/basics/main.ha /build/example/
RUN mkdir -p /build/conformance && cp client/tests/conformance/main.ha /build/conformance/
RUN mkdir -p /out \
    && HAREPATH=/build:/usr/src/hare/stdlib:/usr/src/hare/third-party hare build -lssl -lcrypto -o /out/convex-example /build/example \
    && HAREPATH=/build:/usr/src/hare/stdlib:/usr/src/hare/third-party hare build -lssl -lcrypto -o /out/convex-adapter /build/conformance
RUN test "$(uname -m)" = x86_64 \
    && file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64.*statically linked' \
    && file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64.*statically linked' \
    && readelf -h /out/convex-example | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
# Prove the real adapter binary's hello/close NDJSON lifecycle at build time,
# against the exact binary shipped in /out. CONVEX_URL is a dummy value
# scoped to this one RUN: hello and close never open a network connection, so
# the adapter only needs the variable to be present.
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:9 /out/convex-adapter >/tmp/convex-adapter-hello.ndjson \
    && grep -Fq '"language":"hare"' /tmp/convex-adapter-hello.ndjson \
    && grep -Fq '"type":"closed"' /tmp/convex-adapter-hello.ndjson
# The default command only has to be an honest, CONVEX_URL-free sanity check
# rather than repeat a probe that would fail before reading a single command:
# running the adapter here with no deployment URL would abort in
# client_init before it ever sees "hello".
CMD ["/bin/sh", "-ec", "test \"$(uname -m)\" = x86_64 && echo 'hare test and the adapter hello/close probe already passed while building this image'"]

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260611-r0

# Both /out binaries are statically linked (proved above), so this image
# needs no libc closure and no dynamic loader — the only genuine runtime
# dependency is the CA bundle for the TLS handshake regression already
# proved against the exact binaries shipped here. That makes a stock
# BusyBox base actively counterproductive: it starts this image FROM a
# multicall binary shipping httpd, ftpd, inetd, wget, nc, telnet, ar, dpkg
# and rpm as applets of the very same binary that would provide /bin/sh,
# none of which a statically linked Hare program needs or uses. This stage
# compiles a from-source BusyBox with only the applets the shared
# verifier's image_policy and this Dockerfile's own checks require, and
# the final image is built FROM scratch rather than the stock image, so
# there is no ancestry to strip in the first place — only the files
# assembled below ever exist in it.
FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS busybox-builder
RUN apk add --no-cache \
      build-base=0.5-r3 \
      linux-headers=6.14.2-r0
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
WORKDIR /src
RUN tar -xjf /tmp/busybox.tar.bz2 && \
    cd busybox-1.37.0 && \
    printf '%s\n' \
      'CONFIG_STATIC=y' \
      'CONFIG_BUSYBOX=y' \
      'CONFIG_ASH=y' \
      'CONFIG_ASH_TEST=y' \
      'CONFIG_ASH_CMDCMD=y' \
      'CONFIG_SH_IS_ASH=y' \
      'CONFIG_TEST=y' \
      'CONFIG_TEST1=y' \
      'CONFIG_TEST2=y' \
      'CONFIG_ID=y' \
      'CONFIG_GREP=y' \
      > /tmp/minimal.config && \
    make allnoconfig >/dev/null && \
    while IFS= read -r setting; do \
      name="${setting%%=*}"; \
      sed -i "s/^# $name is not set$/$setting/" .config; \
    done < /tmp/minimal.config && \
    make oldconfig </dev/null >/dev/null && \
    make -j2 busybox && \
    mkdir -p /out && \
    cp busybox /out/busybox
RUN cd busybox-1.37.0 && \
    file ./busybox | grep -q 'statically linked' && \
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" && \
    for tool in apk apt apt-get curl dpkg nc rpm wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS runtime-rootfs
COPY --from=busybox-builder /out/busybox /restricted-busybox
# BusyBox's multicall dispatcher only enters "top-level" mode (--list,
# explicit `busybox <applet>`) when argv[0]'s basename is literally
# "busybox"; invoked under any other name it looks that name up directly in
# the compiled applet table. The applet table is checked byte-for-byte
# through a copy at a path still named "busybox" (this stage's own ambient
# shell is Alpine's stock, fully-featured BusyBox throughout, so ordering
# does not matter here), then installed into /rootfs under the applet names
# it actually serves and never again written to a path literally named
# busybox.
RUN set -eu; \
    mkdir -p /verify; \
    cp /restricted-busybox /verify/busybox; \
    test "$(/verify/busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)"; \
    for tool in apk apt apt-get curl dpkg nc rpm wget; do \
      test "$(/verify/busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done; \
    rm -rf /verify; \
    mkdir -p /rootfs/bin /rootfs/usr/bin; \
    mv /restricted-busybox /rootfs/bin/sh; \
    ln /rootfs/bin/sh /rootfs/usr/bin/id; \
    ln /rootfs/bin/sh /rootfs/usr/bin/grep

FROM scratch AS runtime-base
COPY --from=runtime-rootfs /rootfs /
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
FROM runtime-base AS runtime-checked
RUN set -eu; \
    test -x /bin/sh; \
    test -x /usr/bin/id; \
    test -x /usr/bin/grep; \
    for name in apk apt apt-get curl dpkg nc rpm wget; do \
      /bin/sh -c "exec -a $name /bin/sh" >/dev/null 2>&1 && exit 1; \
    done; \
    for name in apk apt apt-get busybox curl dpkg gcc cc hare harec make netcat nc python python3 npm pip qbe rpm wget convex; do \
      ! command -v "$name" >/dev/null 2>&1 || exit 1; \
    done; \
    for directory in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do \
      test -d "$directory" || continue; \
      for entry in "$directory"/*; do \
        test -e "$entry" || continue; \
        name="${entry##*/}"; \
        case "$name" in \
          apk|apt|apt-get|busybox|curl|dpkg|nc|rpm|wget) exit 1 ;; \
        esac; \
      done; \
    done

FROM runtime-checked AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because the root build command selects the
# default Docker target when it builds a language.
FROM runtime-checked AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
