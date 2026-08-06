# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG RACKET_COMMIT=b10ecfb8311fca2d42636eea2ca12aff0b76b208
ARG RACKET_RELEASE=8.10

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS toolchain
ARG RACKET_COMMIT
ARG RACKET_RELEASE

# Packaged Racket CS and precise-GC BC abort under Docker Desktop's amd64
# translation on this host. Racket's own BC conservative-GC target, built with
# its JIT and futures disabled, is a genuine x86_64 runtime and runs reliably.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      ca-certificates build-essential git liblz4-dev libssl-dev m4 uuid-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git init /build/racket \
    && git -C /build/racket remote add origin https://github.com/racket/racket.git \
    && git -C /build/racket fetch --depth 1 origin "${RACKET_COMMIT}" \
    && git -C /build/racket checkout --detach FETCH_HEAD \
    && test "$(git -C /build/racket rev-parse HEAD)" = "${RACKET_COMMIT}"

# Nested libffi make loses GNU make's parallel jobserver descriptor under this
# amd64 translation path. The serial target is the proven deterministic build.
RUN mkdir -p /build/racket/racket/src/build/bc \
    && cd /build/racket/racket/src/build/bc \
    && ../../bc/configure \
      --disable-jit --disable-futures --disable-gracket \
      --enable-bcdefault --disable-useprefix --enable-origtree \
    && make cgc \
    && make install-cgc \
    && /build/racket/racket/bin/racketcgc -v \
    && /build/racket/racket/bin/racketcgc -e '(displayln (+ 40 2))'

# The release-specific catalog makes the compiler and RackUnit dependency set
# reproducible to the Racket 8.10 release, instead of following the live catalog.
RUN /build/racket/racket/bin/racocgc pkg install --auto --scope installation \
      --catalog "https://download.racket-lang.org/releases/${RACKET_RELEASE}/catalog/" \
      compiler-lib rackunit-lib

FROM toolchain AS build-artifacts
WORKDIR /project
COPY client ./client
COPY examples ./examples

RUN test "$(uname -m)" = x86_64 \
    && /build/racket/racket/bin/racketcgc -v 2>&1 | grep -Fq 'Racket v8.10 [cgc]' \
    && /build/racket/racket/bin/racocgc make \
      client/client.rkt client/tests/backpressure-fixture.rkt \
      client/tests/conformance/adapter.rkt examples/basics/main.rkt \
    && /build/racket/racket/bin/racocgc test client/tests examples/basics/main.rkt

RUN mkdir -p /out \
    && /build/racket/racket/bin/racocgc exe --cgc --orig-exe \
      -o /out/convex-adapter client/tests/conformance/adapter.rkt \
    && /build/racket/racket/bin/racocgc exe --cgc --orig-exe \
      -o /out/convex-example examples/basics/main.rkt \
    && /build/racket/racket/bin/racocgc exe --cgc --orig-exe \
      -o /out/backpressure-fixture client/tests/backpressure-fixture.rkt \
    && readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && readelf -h /out/convex-example | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && readelf -h /out/backpressure-fixture | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && ldd /out/convex-adapter | grep -Fq 'libc.so.6' \
    && printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | /out/convex-adapter > /tmp/adapter.ndjson \
    && grep -Fq '"language":"racket"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base

# Copy the TLS pieces used by Racket's OpenSSL FFI and then remove Debian's
# administration surface. The final image keeps separate sh/id/grep/sed/awk
# binaries, not a broad multicall executable.
COPY --from=toolchain /etc/ssl /etc/ssl
COPY --from=toolchain /usr/lib/ssl /usr/lib/ssl
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/engines-3 /usr/lib/x86_64-linux-gnu/engines-3
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/ossl-modules /usr/lib/x86_64-linux-gnu/ossl-modules
RUN set -eu; \
    rm -f /usr/bin/awk; \
    ln -s mawk /usr/bin/awk; \
    rm -rf \
      /boot /home /media /mnt /opt /root /run /srv \
      /etc/.pwd.lock /etc/adduser.conf /etc/bash.bashrc \
      /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily \
      /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly /etc/crontab \
      /etc/debconf.conf /etc/default /etc/deluser.conf /etc/dpkg \
      /etc/e2scrub.conf /etc/environment /etc/fstab /etc/gshadow \
      /etc/init.d /etc/issue /etc/issue.net /etc/kernel /etc/libaudit.conf \
      /etc/login.defs /etc/logrotate.conf \
      /etc/logrotate.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d \
      /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d /etc/systemd \
      /etc/mke2fs.conf /etc/motd /etc/opt /etc/pam.conf /etc/pam.d \
      /etc/passwd- /etc/group- /etc/profile /etc/profile.d /etc/rmt \
      /etc/security /etc/selinux /etc/shadow /etc/shells /etc/skel \
      /etc/subgid /etc/subuid /etc/terminfo /etc/update-motd.d \
      /usr/games /usr/include /usr/lib/apt /usr/lib/dpkg /usr/lib/init \
      /usr/lib/locale /usr/lib/lsb /usr/lib/mime /usr/lib/ssl/misc \
      /usr/lib/systemd /usr/lib/terminfo /usr/lib/tmpfiles.d /usr/lib/udev \
      /usr/lib/x86_64-linux-gnu/e2fsprogs \
      /usr/lib/x86_64-linux-gnu/perl-base \
      /usr/lib/x86_64-linux-gnu/security \
      /usr/libexec /usr/share /usr/src /var; \
    printf '%s\n' 'nonroot:x:65532:65532:nonroot:/nonexistent:/bin/sh' \
      > /etc/passwd; \
    printf '%s\n' 'nonroot:x:65532:' > /etc/group; \
    find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print \
      > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cat|/usr/bin/cmp|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/ls|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh|/usr/bin/sleep|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/wc) ;; \
        *) rm -f "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    rm -f /tmp/runtime-commands; \
    test "$(uname -m)" = x86_64; \
    test ! -e /bin/busybox; \
    test ! -e /usr/bin/busybox; \
    for path in \
      /boot /home /media /mnt /opt /root /run /srv \
      /etc/apt /etc/default /etc/dpkg /etc/init.d /etc/kernel /etc/pam.d \
      /etc/rc0.d /etc/security /etc/selinux /etc/skel /etc/systemd \
      /etc/update-motd.d /usr/lib/apt /usr/lib/dpkg /usr/lib/init \
      /usr/lib/lsb /usr/lib/systemd /usr/lib/tmpfiles.d /usr/lib/udev \
      /usr/libexec /usr/share /var; do \
      test ! -e "$path" || exit 1; \
    done; \
    for required in sh dash id grep sed awk mawk cat find; do \
      command -v "$required" >/dev/null 2>&1; \
    done; \
    for forbidden in \
      busybox racket racketcgc raco racocgc node npm npx python python3 pip \
      pip3 curl wget nc netcat telnet ftp openssl convex git gcc g++ cc c++ \
      cpp make ld as ar strip apt apt-get apt-cache dpkg dpkg-deb debconf \
      deb-systemd-helper deb-systemd-invoke update-alternatives invoke-rc.d \
      policy-rc.d service start-stop-daemon update-rc.d mount umount unshare \
      chroot adduser addgroup useradd usermod perl ruby php lua java dotnet \
      apk yum dnf rpm gem bundle cargo rustc go javac; do \
      ! command -v "$forbidden" >/dev/null 2>&1 || exit 1; \
    done

USER 65532:65532

FROM runtime-base AS test
COPY --from=build-artifacts --chmod=0555 /out/convex-adapter /usr/local/bin/convex-adapter
COPY --from=build-artifacts --chmod=0555 /out/backpressure-fixture /usr/local/bin/backpressure-fixture
COPY --from=build-artifacts --chmod=0555 /project/client/tests/run-runtime-tests.sh /usr/local/bin/run-runtime-tests
CMD ["/usr/local/bin/run-runtime-tests"]

FROM runtime-base AS example-runtime
COPY --from=build-artifacts --chmod=0555 /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build racket` builds the default target.
FROM runtime-base AS runtime
COPY --from=build-artifacts --chmod=0555 /out/convex-adapter /usr/local/bin/convex-adapter
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | /usr/local/bin/convex-adapter > /tmp/adapter.ndjson \
    && grep -Fq '"language":"racket"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson \
    && rm /tmp/adapter.ndjson
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
