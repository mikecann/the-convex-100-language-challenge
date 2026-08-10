# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Alpine's BusyBox package exposes every applet through symlinks, including
# tools such as nc that the Bash client neither needs nor declares. Build a
# small static BusyBox instead: removing symlinks alone is not enough because
# the stock binary can recover any applet through a forged argv[0].
FROM ${DEBIAN_IMAGE} AS busybox-builder
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
RUN apt-get update && apt-get install -y --no-install-recommends \
    bzip2=1.0.8-5+b1 gcc=4:12.2.0-3 libc6-dev=2.36-9+deb12u14 \
    make=4.3-4.1 musl-tools=1.2.3-1 \
    && rm -rf /var/lib/apt/lists/*
RUN tar -xjf /tmp/busybox.tar.bz2 -C /tmp
WORKDIR /tmp/busybox-1.37.0
# Use BusyBox's OpenSSL-backed wget mode because its internal TLS client does
# not authenticate certificates or hostnames. Do not enable the internal mode:
# that would permit an insecure fallback if the OpenSSL helper went missing.
RUN make allnoconfig >/dev/null && \
    for option in STATIC BUSYBOX ASH ASH_CMDCMD ASH_ECHO ASH_PRINTF ASH_TEST \
        CHMOD DD FEATURE_DD_IBS_OBS FEATURE_DD_STATUS DIRNAME ID OD SED \
        TR WC WGET FEATURE_WGET_OPENSSL \
        DESKTOP LONG_OPTS FEATURE_WGET_LONG_OPTIONS FEATURE_WGET_TIMEOUT; do \
      sed -i "s/# CONFIG_${option} is not set/CONFIG_${option}=y/" .config; \
    done && \
    yes '' | make oldconfig >/dev/null && \
    CC=musl-gcc make -j2 busybox >/dev/null && \
    install -Dm0555 busybox /out/busybox

FROM busybox-builder AS timeout-builder
COPY client/timeout.c /tmp/timeout.c
# This is intentionally a one-command static helper. Copying Alpine's GNU
# coreutils multicall binary would expose every one of its applets at runtime.
RUN musl-gcc -Os -static -s -o /out/timeout /tmp/timeout.c

FROM ${ALPINE} AS test
RUN apk add --no-cache bash=5.2.37-r0 jq=1.8.1-r0 openssl=3.5.7-r0 socat=1.8.1.3-r0 ca-certificates=20260611-r0 \
 shellcheck=0.10.0-r2 shfmt=3.11.0-r5
WORKDIR /opt/convex
COPY client ./client
COPY examples ./examples
RUN printf '%s\n' '#!/bin/sh' 'if test -n "$ADAPTER_LISTEN"; then listen_host=${ADAPTER_LISTEN%:*}; listen_port=${ADAPTER_LISTEN##*:}; exec socat "TCP-LISTEN:$listen_port,bind=$listen_host,reuseaddr" EXEC:"bash /opt/convex/client/tests/conformance/adapter.sh"; fi' 'exec bash /opt/convex/client/tests/conformance/adapter.sh "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
RUN test "$(uname -m)" = x86_64 && \
 shfmt -d client/convex.sh client/live.sh client/tests/conformance/adapter.sh client/tests/fixture.sh client/tests/test.sh examples/basics/main.sh && \
 shellcheck --exclude=SC2016 client/convex.sh client/live.sh client/tests/conformance/adapter.sh client/tests/fixture.sh client/tests/test.sh examples/basics/main.sh && \
 bash -n client/convex.sh client/live.sh client/tests/conformance/adapter.sh client/tests/fixture.sh client/tests/test.sh examples/basics/main.sh && \
 printf '%s\n' '{"protocolVersion":1,"id":"h","op":"hello"}' '{"id":"c","op":"close"}' | CONVEX_URL=http://example.invalid bash client/tests/conformance/adapter.sh | grep -F '"language":"bash"'
RUN bash client/tests/test.sh

FROM ${ALPINE} AS runtime-os
RUN apk add --no-cache bash=5.2.37-r0 jq=1.8.1-r0 busybox=1.37.0-r20 openssl=3.5.7-r0 socat=1.8.1.3-r0 ca-certificates=20260611-r0 && \
 rm -f /sbin/apk /usr/sbin/apk && rm -rf /var/cache/apk
COPY --from=busybox-builder /out/busybox /tmp/restricted-busybox
COPY --from=timeout-builder /out/timeout /tmp/restricted-timeout
# Keep Alpine's non-BusyBox runtime programs, but replace every stock BusyBox
# applet link with a link to the restricted binary. The final image has no
# binary named busybox, so neither `busybox nc` nor a forged argv[0] can revive
# an undeclared applet.
RUN set -eu; \
 for path in /bin/* /sbin/* /usr/bin/* /usr/sbin/*; do \
   if test -L "$path" && test "$(/bin/busybox readlink "$path")" = /bin/busybox; then /bin/busybox rm -f "$path"; fi; \
 done; \
 for tool in sh chmod dd dirname id od sed tr wc wget; do /bin/busybox ln /tmp/restricted-busybox "/bin/$tool"; done; \
 /bin/busybox mv /tmp/restricted-timeout /bin/timeout; \
 /bin/busybox rm -f /bin/busybox /tmp/restricted-busybox; \
 for name in busybox apk apt apt-get apt-cache dpkg gcc cc make node npm npx python python3 pip pip3 curl nc telnet ftp ftpget ftpput httpd tftp; do \
   for directory in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do \
     test ! -x "$directory/$name" || { echo "forbidden command present: $directory/$name" >&2; exit 1; }; \
   done; \
 done; \
 ! /bin/sh -c 'exec -a nc /bin/sh' >/dev/null 2>&1; \
 ! /bin/sh -c 'exec -a timeout /bin/sh' >/dev/null 2>&1; \
 ! /bin/sh -c 'exec -a busybox /bin/sh nc' >/dev/null 2>&1

FROM runtime-os AS example-runtime
WORKDIR /opt/convex
COPY client/convex.sh client/live.sh ./client/
COPY examples/basics/main.sh ./examples/basics/main.sh
RUN printf '%s\n' '#!/bin/sh' 'exec bash /opt/convex/examples/basics/main.sh "$@"' > /usr/local/bin/convex-example && chmod 0555 /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-os AS runtime
WORKDIR /opt/convex
COPY client/convex.sh client/live.sh ./client/
COPY client/tests/conformance/adapter.sh ./adapter.sh
RUN printf '%s\n' '#!/bin/sh' 'if test -n "$ADAPTER_LISTEN"; then listen_host=${ADAPTER_LISTEN%:*}; listen_port=${ADAPTER_LISTEN##*:}; exec socat "TCP-LISTEN:$listen_port,bind=$listen_host,reuseaddr" EXEC:"bash /opt/convex/adapter.sh"; fi' 'exec bash /opt/convex/adapter.sh "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
