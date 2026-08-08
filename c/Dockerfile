# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
FROM ${ALPINE_IMAGE} AS build
RUN apk add --no-cache build-base=0.5-r3 clang19-extra-tools=19.1.7-r6 curl-dev=8.14.1-r3 json-c-dev=0.18-r1
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN /usr/lib/llvm19/bin/clang-format --style=LLVM --dry-run --Werror client/convex.c client/convex.h client/tests/conformance/main.c client/tests/live_test.c examples/basics/main.c && \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/convex.c client/tests/conformance/main.c -lcurl -ljson-c -o /out-adapter && \
    gcc -DCONVEX_ADAPTER_TESTING -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/convex.c client/tests/conformance/main.c -lcurl -ljson-c -o /out-adapter-test && \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/convex.c examples/basics/main.c -lcurl -ljson-c -o /out-example && \
    gcc -DCONVEX_CLIENT_TESTING -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/convex.c client/tests/live_test.c -lcurl -ljson-c -lcrypto -o /out-live-test && \
    file /out-adapter | grep 'x86-64'
FROM build AS test
RUN <<'EOF'
set -eu
test "$(uname -m)" = x86_64
actual=$(/out-adapter <<'COMMANDS'
{malformed
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"unknown","op":"notAnOperation"}
{"id":"close","op":"close"}
COMMANDS
)
printf '%s\n' "$actual" | grep -Fx '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'
printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready"'
printf '%s\n' "$actual" | grep -Fx '{"type":"error","id":"unknown","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'
printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
EOF
RUN /out-live-test
RUN <<'EOF'
set -eu
ADAPTER_LISTEN=127.0.0.1:18080 /out-adapter &
adapter_pid=$!
sleep 0.1
container_address=$(ip -4 addr show eth0 | awk '/inet / {sub("/.*", "", $2); print $2; exit}')
non_loopback=$(printf '%s\n' \
  '{"id":"wrong-host","protocolVersion":1,"op":"hello"}' \
  '{"id":"wrong-close","op":"close"}' | nc -w 1 "$container_address" 18080 2>/dev/null || true)
if test -n "$non_loopback"; then
  printf '%s\n' 'loopback adapter unexpectedly accepted a non-loopback connection' >&2
  exit 1
fi
actual=$(printf '%s\n' \
  '{"id":"tcp-hello","protocolVersion":1,"op":"hello"}' \
  '{"id":"tcp-close","op":"close"}' | nc 127.0.0.1 18080)
wait "$adapter_pid"
printf '%s\n' "$actual" | grep -F '"id":"tcp-hello","type":"ready"'
printf '%s\n' "$actual" | grep -F '"id":"tcp-close","type":"closed"'
EOF
# Alpine's own /bin/sh, and everything else in /bin, /sbin, /usr/bin and
# /usr/sbin, is BusyBox: one multicall binary that `busybox --install` turns
# into ~300 symlinks (including wget and nc, both compiled into Alpine's
# default BusyBox build) at image-build time. apk's package database owns
# only the busybox binary's own package entry, not those symlinks, so
# removing only /sbin/apk (as this image previously did) leaves every one of
# those applets fully reachable, /bin/sh included. This stage compiles a
# from-source BusyBox with only the applets the shared verifier's
# image_policy and this Dockerfile's own checks need.
FROM ${ALPINE_IMAGE} AS busybox-builder
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

# The apk-installed libcurl and json-c shared libraries under /usr/lib are
# immutable runtime inputs for the two compiled binaries and stay untouched.
# Everything BusyBox owns in /bin, /sbin, /usr/bin and /usr/sbin — apk
# included, since it is one more BusyBox applet symlink on this image rather
# than a separate package — is deleted and replaced by the restricted
# BusyBox above, hard-linked under the applet names it serves and never
# written to a path literally named busybox: a from-source rebuild that
# still ends up at /bin/busybox only proves the applet table changed, not
# that the image stopped being "Alpine with apk removed".
FROM ${ALPINE_IMAGE} AS runtime-base
RUN apk add --no-cache libcurl=8.14.1-r3 json-c=0.18-r1 ca-certificates=20260611-r0
COPY --from=busybox-builder /out/busybox /restricted-busybox
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox mkdir /policy /verify; \
    /bin/busybox cp /bin/busybox /policy/busybox; \
    /bin/busybox cp /restricted-busybox /verify/busybox; \
    test "$(/verify/busybox --list)" = "$(printf "%s\n" "[" "[[" ash grep id sh test)"; \
    for tool in apk apt apt-get curl dpkg nc rpm wget; do \
      test "$(/verify/busybox "$tool" 2>/dev/null; printf "%s" "$?")" = 127; \
    done; \
    /policy/busybox rm -rf /verify; \
    /policy/busybox rm -rf /etc/apk /lib/apk /var/cache/apk /var/lib/apk /usr/share/apk /etc/busybox-paths.d; \
    /policy/busybox find /bin /sbin /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -delete; \
    /policy/busybox mkdir -p /bin /usr/bin /usr/local/bin; \
    /policy/busybox mv /restricted-busybox /bin/sh; \
    /policy/busybox ln /bin/sh /usr/bin/id; \
    /policy/busybox ln /bin/sh /usr/bin/grep; \
    test -x /bin/sh; \
    test -x /usr/bin/id; \
    test -x /usr/bin/grep; \
    for name in apk apt apt-get curl dpkg nc rpm wget; do \
      implicit="$(/bin/sh -c "exec -a $name /bin/sh" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$implicit" = 127; \
      explicit="$(/bin/sh -c "exec -a busybox /bin/sh $name" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$explicit" = 127; \
    done; \
    forbidden="$(/policy/busybox find / -xdev -path /policy -prune -o \( -type f -o -type l \) \( -name apk -o -name apt -o -name apt-get -o -name busybox -o -name curl -o -name dpkg -o -name nc -o -name rpm -o -name wget \) -print)"; \
    test -z "$forbidden"; \
    /policy/busybox rm -rf /policy; \
    test ! -e /policy'
RUN set -eu; \
    for command_name in apk apt apt-get busybox curl dpkg gcc cc clang make netcat nc node npm python python3 pip convex; do \
      ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
    done
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
