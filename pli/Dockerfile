# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:38a76d01668772e381ad2826d876627c89e7133e2f8a0f5d567306798b0f2a16

# ---------------------------------------------------------------------------
# Toolchain.
#
# Iron Spring PL/I 1.4.1 ships one statically linked 32-bit ELF compiler
# (plic) and one 32-bit runtime archive (libprf.a). Everything it produces is
# therefore 32-bit, so this stage enables Debian's i386 multiarch and installs
# the i386 C library and OpenSSL the client links against. The image itself is
# a genuine linux/amd64 image; only the client binaries are i386, executed
# through the kernel's ia32 compatibility layer.
#
# plic is run under qemu-i386-static, and only at build time. The reason is
# specific and worth stating: the PL/I runtime's start-up routine installs trap
# handlers with the legacy i386 `sigaction` syscall (number 67), which Docker's
# default seccomp profile does not allow, so plic dies with
# "SIGACTION 1 returned -1" and return code 16 before it reads any source.
# qemu-user emulates guest signal syscalls in user space, so plic runs. The
# binaries plic produces do NOT need qemu: client/plisig.pli replaces that same
# runtime routine with one that uses rt_sigaction, which the seccomp profile
# does allow, so the shipped client runs natively.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS toolchain
RUN dpkg --add-architecture i386 \
    && apt-get update && apt-get install --no-install-recommends --yes \
      ca-certificates=20250419 \
      curl=8.14.1-2+deb13u4 \
      binutils=2.44-3 \
      file=1:5.46-5 \
      qemu-user-static=1:10.0.11+ds-0+deb13u1 \
      libc6:i386=2.41-12+deb13u3 \
      libc6-dev:i386=2.41-12+deb13u3 \
      libssl3t64:i386=3.5.6-1~deb13u2 \
      libssl-dev:i386=3.5.6-1~deb13u2 \
    && rm -rf /var/lib/apt/lists/*

# The vendor's certificate is expired, so the archive arrives over plain HTTP
# and this digest is what authenticates it.
COPY client/toolchain.lock /tmp/toolchain.lock
RUN set -eu; \
    url=$(sed -n 's/^url=//p' /tmp/toolchain.lock); \
    digest=$(sed -n 's/^sha256=//p' /tmp/toolchain.lock); \
    test -n "$url"; \
    test "$(printf '%s' "$digest" | wc -c)" -eq 64; \
    case "$digest" in *[!0-9a-f]*) echo "toolchain digest is not hex" >&2; exit 1 ;; esac; \
    curl --fail --silent --show-error --location "$url" --output /tmp/pli.tgz; \
    printf '%s  %s\n' "$digest" /tmp/pli.tgz | sha256sum -c -; \
    mkdir -p /opt; \
    tar --extract --gzip --file /tmp/pli.tgz --directory /opt; \
    mv /opt/pli-1.4.1 /opt/pli; \
    rm -f /tmp/pli.tgz /opt/pli/plic.exe; \
    file /opt/pli/plic | grep -F 'ELF 32-bit LSB executable, Intel i386'

# One wrapper so every compile in this file reads the same. plic wants its
# alternate-NOT-character option as a single argument; without -cn(^) the
# compiler silently reads `^=` as `=`, which is a very quiet way to invert
# every comparison in the client.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec qemu-i386-static /opt/pli/plic -C -dELF -ew "-cn(^)" "$@"' \
      > /usr/local/bin/plic && chmod 0755 /usr/local/bin/plic
# The link recipe from the distribution's own samples/Makefile.Linux, extended
# with a dynamic linker and the shared libraries the FFI needs. plisig.o is
# listed before libprf.a on purpose: ld only pulls an archive member in to
# resolve something still undefined, so naming our _pli_SigInit first is what
# keeps the vendor's seccomp-hostile one out of the binary.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'out=$1; shift' \
      'ld -z muldefs -o "$out" --oformat=elf32-i386 -melf_i386 -e main \' \
      '   --dynamic-linker /lib/ld-linux.so.2 -L/usr/lib/i386-linux-gnu \' \
      '   "$@" /build/plisig.o \' \
      '   --start-group /opt/pli/lib/libprf.a -lssl -lcrypto -lc --end-group' \
      > /usr/local/bin/plild && chmod 0755 /usr/local/bin/plild

# ---------------------------------------------------------------------------
# Build: style gate, the client's own tests, then the adapter and the
# canonical example. Every test binary is executed here; compiling is never
# treated as evidence.
# ---------------------------------------------------------------------------
FROM toolchain AS build
WORKDIR /build
COPY client ./client
COPY examples ./examples

# The runtime signal-routine replacement is compiled first because every link
# in this file names it ahead of the vendor archive.
RUN set -eu; plic client/plisig.pli -o plisig.o

# PL/I has no standard formatter. A deterministic style gate stands in for one
# and fails the build rather than rewriting reviewed source.
RUN set -eu; \
    plic -i/build/client client/tests/style_check.pli -o style_check.o; \
    plild /out-style-check style_check.o; \
    /out-style-check $(find client examples -name '*.pli' -o -name '*.inc' | sort)

RUN set -eu; \
    plic -i/build/client client/tests/unit_test.pli -o unit_test.o; \
    plild /out-unit-test unit_test.o; \
    /out-unit-test

RUN set -eu; \
    plic -i/build/client client/tests/live_test.pli -o live_test.o; \
    plild /out-live-test live_test.o; \
    /out-live-test

# The conformance executable is test infrastructure. debugDisconnect exists in
# this binary and nowhere else.
RUN set -eu; \
    plic -i/build/client client/tests/conformance/adapter.pli -o adapter.o; \
    plild /usr/local/bin/convex-adapter adapter.o; \
    plic -i/build/client examples/basics/main.pli -o example.o; \
    plild /usr/local/bin/convex-example example.o; \
    test "$(uname -m)" = x86_64; \
    file /usr/local/bin/convex-adapter | grep -F 'ELF 32-bit LSB executable, Intel i386'; \
    file /usr/local/bin/convex-example | grep -F 'ELF 32-bit LSB executable, Intel i386'; \
    file /usr/local/bin/convex-adapter | grep -F 'dynamically linked'
# The educational client must not carry the fault-injection hook.
RUN set -eu; ! nm /usr/local/bin/convex-example 2>/dev/null | grep -qi 'DEBUGDISCONNECT'
# Prove the vendor's seccomp-hostile signal routine is gone and ours is in.
RUN set -eu; \
    nm /usr/local/bin/convex-adapter | grep -F '_pli_SigInit'; \
    ! strings /usr/local/bin/convex-adapter | grep -q 'SIGACTION'; \
    ! strings /usr/local/bin/convex-example | grep -q 'SIGACTION'

# ---------------------------------------------------------------------------
# Test target.
# ---------------------------------------------------------------------------
FROM build AS test
RUN set -eu; \
    actual=$({ \
      printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"protocolVersion":2,"id":"oldversion","op":"hello"}' \
        'not json at all' \
        '{"id":"unknown","op":"nope"}' \
        '{"id":"close","op":"close"}'; \
    } | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter); \
    printf '%s\n' "$actual"; \
    printf '%s\n' "$actual" | grep -F '"id":"hello"' | grep -F '"type":"ready"'; \
    printf '%s\n' "$actual" | grep -F '"language":"pli"'; \
    printf '%s\n' "$actual" | grep -F '"id":"oldversion"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"unknown"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
CMD ["sh", "-c", "echo 'pli test image: all gates ran during build'"]

# ---------------------------------------------------------------------------
# Runtime closure: the two binaries plus exactly the i386 shared libraries,
# the i386 program interpreter, and the CA material OpenSSL loads. TLS is
# exercised from the final image so a missing certificate path is not first
# discovered during hosted verification.
# ---------------------------------------------------------------------------
FROM build AS runtime-libs
RUN set -eu; \
    mkdir -p /runtime-root; \
    stage() { \
      target=$(readlink -f "$1"); \
      cp -a --parents "$target" /runtime-root; \
      if test "$target" != "$1"; then \
        mkdir -p "/runtime-root$(dirname "$1")"; \
        cp -aL "$1" "/runtime-root$1"; \
      fi; \
    }; \
    for binary in /usr/local/bin/convex-adapter /usr/local/bin/convex-example; do \
      ldd "$binary" | awk '/=> \/[^ ]+/ { print $3 } /^\t\/[^ ]+ \(0x/ { print $1 }'; \
    done | sort -u | while read -r library; do stage "$library"; done; \
    stage /lib/ld-linux.so.2; \
    cp -a --parents /etc/ssl/certs/ca-certificates.crt /etc/ssl/openssl.cnf /runtime-root; \
    if test -d /usr/lib/i386-linux-gnu/engines-3; then \
      cp -a --parents /usr/lib/i386-linux-gnu/engines-3 /runtime-root; \
    fi; \
    if test -d /usr/lib/i386-linux-gnu/ossl-modules; then \
      cp -a --parents /usr/lib/i386-linux-gnu/ossl-modules /runtime-root; \
    fi; \
    if find /runtime-root -xtype l | grep .; then \
      echo 'runtime closure contains a broken symlink' >&2; exit 1; \
    fi

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
# The shared policy verifier still needs /bin/sh and basic POSIX text tools,
# so this is a stripped Debian rather than scratch. Everything that could
# compile, fetch, or delegate is removed and then proved absent.
RUN rm -rf /var/lib/apt /var/lib/dpkg /var/cache/apt /var/cache/debconf /var/log/* \
      /etc/apt /etc/dpkg /etc/systemd /usr/lib/apt /usr/lib/dpkg /usr/lib/systemd \
      /usr/share/systemd /etc/tmpfiles.d /etc/sysusers.d /usr/lib/tmpfiles.d \
      /usr/lib/sysusers.d /usr/lib/init /usr/lib/lsb /etc/update-motd.d /etc/profile.d \
      /var/lib/systemd /etc/init.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d \
      /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d /etc/cron.d /etc/cron.daily \
      /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly /etc/logrotate.d \
      /etc/alternatives /etc/debconf.conf /usr/libexec/dpkg /usr/share/apt \
      /usr/share/bash-completion /usr/share/bug /usr/share/debconf /usr/share/dpkg \
      /usr/share/gcc /usr/share/base-files /usr/share/doc /usr/share/doc-base \
      /usr/share/man /usr/share/info /usr/share/keyrings /var/cache/ldconfig \
      /etc/perl /usr/lib/perl* /usr/lib/x86_64-linux-gnu/perl-base /usr/share/perl* \
      /etc/kernel /etc/pam.conf /etc/pam.d /etc/security \
      /usr/lib/x86_64-linux-gnu/security /usr/share/pam* /var/lib/pam \
      /etc/bash.bashrc /etc/skel /usr/share/debianutils /usr/share/menu \
      /etc/issue /etc/issue.net /usr/sbin/* \
    && rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config \
      /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/dpkg /usr/bin/dpkg-deb \
      /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query \
      /usr/bin/dpkg-realpath /usr/bin/dpkg-split /usr/bin/dpkg-statoverride \
      /usr/bin/dpkg-trigger /usr/bin/dpkg-preconfigure /usr/bin/perl /usr/bin/perl5.* \
      /usr/bin/bash /usr/bin/bashbug /usr/bin/rbash /usr/bin/login /usr/bin/su \
      /usr/bin/passwd /usr/bin/chfn /usr/bin/chsh /usr/bin/chage /usr/bin/gpasswd \
      /usr/bin/newgrp /usr/bin/sg /usr/bin/expiry /etc/motd \
      /usr/bin/debconf /usr/bin/debconf-* /usr/bin/update-alternatives /usr/bin/run-parts \
      /usr/bin/ischroot /usr/bin/savelog /usr/bin/tempfile /usr/bin/localedef \
      /usr/bin/ldd /usr/bin/sqv \
    && rm -f /usr/lib/x86_64-linux-gnu/libapt-pkg.so* /usr/lib/x86_64-linux-gnu/libapt-private.so* \
      /usr/lib/x86_64-linux-gnu/libdebconfclient.so* /usr/lib/x86_64-linux-gnu/libsystemd.so* \
      /usr/lib/x86_64-linux-gnu/libpam.so* /usr/lib/x86_64-linux-gnu/libpam_misc.so* \
      /usr/lib/x86_64-linux-gnu/libpamc.so* \
    && ln -sf mawk /usr/bin/awk \
    && for required in sh awk sed grep cut tr head tail sort uniq wc find xargs; do \
         command -v "$required" >/dev/null; done \
    && for forbidden in apt apt-get dpkg curl wget gcc cc make ld as plic perl bash \
         node python python3 npm pip pip3 convex qemu-i386-static service \
         update-alternatives ldconfig ldd localedef login su passwd; do \
         if command -v "$forbidden" >/dev/null 2>&1; then \
           echo "unexpected command in runtime base: $forbidden" >&2; exit 1; \
         fi; \
       done \
    && test ! -e /usr/share/doc && test ! -e /usr/share/man && test ! -e /etc/pam.d
# cp -a preserves the original mode. That matters most for the i386 program
# interpreter: the kernel loads ld-linux.so.2 through the same MAY_EXEC check
# as any other binary, so a fixed mode that stripped its execute bit would
# make every client binary fail to start with ENOENT.
COPY --from=runtime-libs /runtime-root/lib/ /lib/
COPY --from=runtime-libs /runtime-root/usr/lib/ /usr/lib/
COPY --from=runtime-libs /runtime-root/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=runtime-libs /runtime-root/etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
# This image's i386 OpenSSL was built with OPENSSLDIR=/usr/lib/ssl (confirmed
# by reading the compiled-in path out of the i386 libcrypto, not the host's
# amd64 one), and that directory's certs symlink does not survive the strip
# above. SSL_CERT_FILE and SSL_CERT_DIR are consulted ahead of the compiled-in
# default, so setting them here is what actually makes hosted TLS verification
# succeed rather than fail closed.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    OPENSSL_CONF=/etc/ssl/openssl.cnf
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /usr/local/bin/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /usr/local/bin/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
