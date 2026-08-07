# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DART_IMAGE=dart:3.7.2-sdk@sha256:ede9f598a82f87ba0d6cd9fe327c02a1c7aac69ac64528b8d1ac192b3bc4c1b2
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS busybox

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
    ./busybox --list && \
    file ./busybox | grep -q 'statically linked' && \
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" && \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

FROM --platform=linux/amd64 ${DART_IMAGE} AS test
WORKDIR /work
ENV PATH=/usr/lib/dart/bin:${PATH}
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md

# The test stage contains the SDK, formatter and compiler. No Dart tooling is
# copied into either final image.
RUN dart format --set-exit-if-changed client examples && \
    dart analyze client examples && \
    dart run client/tests/client_test.dart && \
    dart run client/tests/live_matrix_test.dart && \
    dart run client/tests/lifecycle_test.dart && \
    dart run client/tests/adapter_test.dart && \
    dart run client/tests/websocket_frame_test.dart && \
    mkdir -p /out && \
    dart compile exe examples/basics/main.dart -o /out/convex-dart-example && \
    dart compile exe client/tests/conformance/adapter.dart -o /out/convex-dart-adapter && \
    uname -m | grep -qx x86_64 && \
    test "$(od -An -t x1 -j 18 -N 2 /out/convex-dart-example | tr -d ' ')" = 3e00

FROM test AS runtime-rootfs
RUN set -eu; \
    rm -rf /runtime; \
    mkdir -p /runtime/etc/ssl/certs /runtime/usr/local/bin; \
    { \
      ldd /out/convex-dart-example; \
      ldd /out/convex-dart-adapter; \
    } | awk '/=> \/.* \(/ { print $3 } $1 ~ /^\// { print $1 }' | sort -u | \
      while IFS= read -r library; do cp --parents "$library" /runtime; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do \
      test ! -e "$library" || cp --parents "$library" /runtime; \
    done; \
    cp /etc/ssl/certs/ca-certificates.crt /runtime/etc/ssl/certs/; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      test ! -e "$config" || cp --parents "$config" /runtime; \
    done

FROM busybox AS runtime-base
USER 0:0
# Build a shell/text-tool surface containing only the applets the shared
# verifier needs. The stock image is still the pinned non-scratch ancestry, but
# its general-purpose multicall binary is replaced rather than hidden off PATH.
#
# BusyBox's multicall dispatcher only enters "top-level" mode (--list,
# explicit `busybox <applet>`) when argv[0]'s basename is literally
# "busybox"; invoked under any other name it looks that name up directly in
# the compiled applet table. The restricted binary is therefore verified
# through a copy at a path still named "busybox" that is deleted before this
# layer ends, then installed under the applet names it actually serves — sh,
# id, grep — and never again written to a path literally named busybox: a
# from-source rebuild that still ends up at /bin/busybox only proves the
# applet table changed, not that the image stopped being "a copy of BusyBox
# with a longer denylist" the way this stage's own FROM busybox starts out.
COPY --from=busybox-builder /out/busybox /restricted-busybox
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox mkdir /policy /verify; \
    cp /bin/busybox /policy/busybox; \
    cp /restricted-busybox /verify/busybox; \
    test "$(/verify/busybox --list)" = "$(printf "%s\n" "[" "[[" ash grep id sh test)"; \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      if /verify/busybox "$tool" >/dev/null 2>&1; then exit 1; \
      else status=$?; test "$status" = 127; fi; \
    done; \
    /policy/busybox rm -rf /verify; \
    /policy/busybox rm -rf \
      /etc/group /etc/localtime /etc/mtab /etc/network /etc/passwd /etc/shadow \
      /.cache /home /root /sbin /tmp /usr /var /lib; \
    /policy/busybox find /bin -mindepth 1 -maxdepth 1 -delete; \
    /policy/busybox mkdir -p /usr/bin /usr/local/bin; \
    /policy/busybox mv /restricted-busybox /bin/sh; \
    /policy/busybox ln /bin/sh /usr/bin/id; \
    /policy/busybox ln /bin/sh /usr/bin/grep; \
    test -x /bin/sh; \
    test -x /usr/bin/id; \
    test -x /usr/bin/grep; \
    for name in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      implicit="$(/bin/sh -c "exec -a $name /bin/sh" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$implicit" = 127; \
      explicit="$(/bin/sh -c "exec -a busybox /bin/sh $name" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$explicit" = 127; \
    done; \
    forbidden="$(/policy/busybox find / -xdev -path /policy -prune -o \( -type f -o -type l \) \
      \( -name apk -o -name apt -o -name apt-get -o -name apt-key -o -name busybox \
      -o -name curl -o -name dpkg -o -name nc -o -name rpm -o -name wget \) \
      -print)"; \
    test -z "$forbidden"; \
    /policy/busybox rm -rf /policy; \
    test ! -e /policy'
COPY --from=runtime-rootfs /runtime /
RUN set -eu; \
    test -x /bin/sh && test -x /usr/bin/id && test -x /usr/bin/grep; \
    test ! -e /bin/busybox; \
    test -r /etc/ssl/certs/ca-certificates.crt; \
    for tool in dart dartaotruntime node python python3 npm npx apt apt-get apt-key dpkg rpm debconf perl openssl curl wget nc convex gcc cc make; do \
      ! command -v "$tool" >/dev/null 2>&1 || exit 1; \
    done; \
    scan_tree() { \
      for path in "$1"/* "$1"/.[!.]* "$1"/..?*; do \
        test -e "$path" || test -L "$path" || continue; \
        case "$path" in /dev|/proc|/sys) continue;; esac; \
        name="${path##*/}"; \
        case "$name" in \
          apk|apt|apt-get|apt-key|busybox|cc|convex|curl|dart|dartaotruntime|debconf|dpkg|gcc|make|nc|node|npm|npx|openssl|perl|python|python3|rpm|wget) \
            exit 1;; \
        esac; \
        if test -d "$path" && test ! -L "$path"; then scan_tree "$path"; fi; \
      done; \
    }; \
    scan_tree ""
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-dart-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /out/convex-dart-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter && test ! -e /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
