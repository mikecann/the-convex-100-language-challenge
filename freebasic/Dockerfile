# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:38a76d01668772e381ad2826d876627c89e7133e2f8a0f5d567306798b0f2a16

# ---------------------------------------------------------------------------
# Toolchain: Debian does not package FreeBASIC, so fbc is built from the
# official bootstrap source release. The bootstrap archive carries
# pre-generated C sources, so gcc alone can produce the first compiler.
#
# UNVERIFIED: this checkpoint was written with no Docker daemon and no host
# compiler, so this stage has never been executed. The official archive is
# digest-pinned, but compilation and installation remain first-Docker risks.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS toolchain
# ca-certificates, gcc, libc6-dev, and file are pinned to the versions already
# proved on this base image by another client in this repository. The remaining
# packages are unpinned only because no build has yet resolved their trixie
# versions; pin them from the first successful build before claiming evidence.
RUN apt-get update && apt-get install --no-install-recommends --yes \
      ca-certificates=20250419 \
      gcc=4:14.2.0-1 \
      libc6-dev=2.41-12+deb13u3 \
      file=1:5.46-5 \
      binutils \
      curl \
      libncurses-dev \
      libssl-dev \
      make \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY client/toolchain.lock /tmp/toolchain.lock
RUN set -eu; \
    url=$(sed -n 's/^url=//p' /tmp/toolchain.lock); \
    digest=$(sed -n 's/^sha256=//p' /tmp/toolchain.lock); \
    test -n "$url"; \
    if test "$(printf '%s' "$digest" | wc -c)" -ne 64; then \
      echo "client/toolchain.lock needs a verified 64 character sha256" >&2; \
      exit 1; \
    fi; \
    case "$digest" in *[!0-9a-f]*) echo "toolchain digest is not hex" >&2; exit 1 ;; esac; \
    curl --fail --silent --show-error --location "$url" --output /tmp/fbc-source.tar.xz; \
    printf '%s  %s\n' "$digest" /tmp/fbc-source.tar.xz | sha256sum -c -; \
    mkdir -p /tmp/fbc; \
    tar --extract --xz --file /tmp/fbc-source.tar.xz --directory /tmp/fbc --strip-components=1; \
    cd /tmp/fbc; \
    # bootstrap-minimal first compiles a bootstrap fbc from the archive's
    # pre-generated C sources into ./bin/fbc, then immediately uses that
    # same fbc -- found only by PATH lookup, not by any path the makefile
    # is told directly -- to compile the real compiler and runtime library
    # from FreeBASIC source. Without ./bin on PATH before this target
    # starts, that second half fails the moment it exists: "fbc: not
    # found", because ./bin/fbc exists by then but was never on PATH.
    export PATH="/tmp/fbc/bin:$PATH"; \
    # The client is console-only. bootstrap-minimal deliberately omits the \
    # optional X11/GPM/libffi surface, then installs only the compiler, headers, \
    # and thread-safe runtime instead of building the unused graphics library. \
    make -j1 bootstrap-minimal; \
    make install-compiler install-includes install-rtlib prefix=/usr/local; \
    fbc --version

# ---------------------------------------------------------------------------
# Build: style gate, language-local tests, then the adapter and the canonical
# example. Compilation alone is never treated as evidence, so every test binary
# is executed here.
# ---------------------------------------------------------------------------
FROM toolchain AS build
WORKDIR /project
COPY client ./client
COPY examples ./examples

# FreeBASIC has no standard formatter, so a deterministic style gate stands in
# for one and fails the build rather than rewriting reviewed source.
RUN set -eu; \
    fbc -w all -i client -x /out-style-check \
      client/tests/style_check.bas client/core.bas; \
    /out-style-check $(find client examples -type f \( -name '*.bas' -o -name '*.bi' \) | sort)

# The client library. -mt links the thread-safe runtime the Live owner needs.
ENV CONVEX_FB_LIB="client/core.bas client/json.bas client/net.bas client/http.bas client/ws.bas client/convex.bas"

RUN set -eu; \
    fbc -mt -w all -i client -i client/tests -x /out-core-test \
      client/tests/core_test.bas $CONVEX_FB_LIB; \
    /out-core-test
RUN set -eu; \
    fbc -mt -w all -i client -i client/tests -x /out-json-test \
      client/tests/json_test.bas $CONVEX_FB_LIB; \
    /out-json-test
RUN set -eu; \
    fbc -mt -w all -i client -i client/tests -x /out-http-test \
      client/tests/http_test.bas $CONVEX_FB_LIB; \
    /out-http-test
RUN set -eu; \
    fbc -mt -w all -i client -i client/tests -x /out-ws-test \
      client/tests/ws_test.bas $CONVEX_FB_LIB; \
    /out-ws-test
# The Live tests reach the adapter-only inspection hooks, which is why this one
# binary is built with CONVEX_ADAPTER defined.
RUN set -eu; \
    fbc -mt -w all -d CONVEX_ADAPTER -i client -i client/tests -x /out-live-test \
      client/tests/live_test.bas $CONVEX_FB_LIB; \
    /out-live-test
RUN set -eu; \
    fbc -mt -w all -d CONVEX_ADAPTER -i client -i client/tests -x /out-adapter-test \
      client/tests/conformance/adapter_test.bas \
      client/tests/conformance/adapter_core.bas $CONVEX_FB_LIB; \
    /out-adapter-test

# The conformance executable is test infrastructure. debugDisconnect exists
# only in this build, never in the client the example links.
RUN set -eu; \
    fbc -mt -w all -d CONVEX_ADAPTER -i client -i client/tests -x /out-adapter \
      client/tests/conformance/adapter.bas \
      client/tests/conformance/adapter_core.bas $CONVEX_FB_LIB; \
    fbc -mt -w all -i client -x /out-example \
      examples/basics/main.bas $CONVEX_FB_LIB; \
    test "$(uname -m)" = x86_64; \
    file /out-adapter | grep -F 'x86-64'; \
    file /out-example | grep -F 'x86-64'
# The educational client must not contain the fault-injection hook. Proving it
# by symbol is stronger than trusting the compile flags.
RUN set -eu; \
    ! nm -a /out-example 2>/dev/null | grep -qi 'CONVEXDEBUGDISCONNECT'

# ---------------------------------------------------------------------------
# Test target: the adapter's real stdin/stdout and TCP behaviour, exercised
# against the built binary rather than a mock.
# ---------------------------------------------------------------------------
FROM build AS test
RUN set -eu; \
    long_id=$(printf '%129s' '' | tr ' ' x); \
    actual=$({ \
      printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"protocolVersion":2,"id":"oldversion","op":"hello"}' \
        '{"protocolVersion":1,"op":"hello"}' \
        '{"id":"","op":"query","path":"demo:state","args":{}}' \
        'not json at all' \
        '{"id":"unknown","op":"nope"}'; \
      printf '{"id":"%s","op":"close"}\n' "$long_id"; \
      printf '%s\n' '{"id":"close","op":"close"}'; \
    } | /out-adapter); \
    printf '%s\n' "$actual" | grep -F '"id":"hello"' | grep -F '"type":"ready"'; \
    printf '%s\n' "$actual" | grep -F '"language":"freebasic"'; \
    printf '%s\n' "$actual" | grep -F '"id":"oldversion"' | grep -F '"type":"error"'; \
    test "$(printf '%s\n' "$actual" | grep -cF 'adapter command id must be 1 to 128 Unicode code points')" -eq 3; \
    ! printf '%s\n' "$actual" | grep -F '"id":""'; \
    printf '%s\n' "$actual" | grep -F '"id":"unknown"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"close","type":"closed"'
# A command that arrives split across reads must still frame correctly.
RUN set -eu; \
    actual=$( { printf '{"protocolVersion":1,"id":"spl'; sleep 1; \
      printf 'it","op":"hello"}\n{"id":"close","op":"close"}\n'; } | /out-adapter); \
    printf '%s\n' "$actual" | grep -F '"id":"split"' | grep -F '"type":"ready"'
# TCP mode carries the identical NDJSON stream for one controller connection.
RUN set -eu; \
    ADAPTER_LISTEN=127.0.0.1:18080 /out-adapter & adapter_pid=$!; \
    sleep 1; \
    actual=$(printf '%s\n' '{"protocolVersion":1,"id":"tcp","op":"hello"}' \
      '{"id":"close","op":"close"}' | \
      curl --silent --max-time 10 telnet://127.0.0.1:18080 || true); \
    wait "$adapter_pid"; \
    printf '%s\n' "$actual" | grep -F '"id":"tcp"' | grep -F '"type":"ready"'
# An input line past the 2 MiB bound is refused rather than buffered, so a
# hostile stream cannot grow the adapter without limit.
RUN set -eu; \
    { head -c 3000000 /dev/zero | tr '\0' 'x'; printf '\n'; } > /tmp/oversized-input; \
    /out-adapter < /tmp/oversized-input > /tmp/oversized-output & adapter_pid=$!; \
    peak_kib=0; checks=0; \
    while kill -0 "$adapter_pid" 2>/dev/null && test "$checks" -lt 600; do \
      rss_kib=$(awk '/VmRSS:/ { print $2 }' "/proc/$adapter_pid/status" 2>/dev/null || true); \
      rss_kib=${rss_kib:-0}; \
      test "$rss_kib" -le "$peak_kib" || peak_kib=$rss_kib; \
      checks=$((checks + 1)); \
      sleep 0.02; \
    done; \
    status=0; wait "$adapter_pid" || status=$?; \
    test "$status" -ne 0; \
    test "$peak_kib" -gt 0; \
    test "$peak_kib" -lt 65536; \
    printf 'oversized-input peak RSS: %s KiB\n' "$peak_kib"
# A reader that never drains must make the adapter fail on its own deadline,
# without an external kill, while staying far below the 128 MiB process limit.
RUN set -eu; \
    mkfifo /tmp/stalled-output; \
    i=1; \
    while test "$i" -le 5000; do \
      printf '{"protocolVersion":1,"id":"h%s","op":"hello"}\n' "$i"; \
      i=$((i + 1)); \
    done > /tmp/stalled-input; \
    exec 5<>/tmp/stalled-output; \
    /out-adapter < /tmp/stalled-input > /tmp/stalled-output & adapter_pid=$!; \
    peak_kib=0; checks=0; \
    while kill -0 "$adapter_pid" 2>/dev/null && test "$checks" -lt 150; do \
      rss_kib=$(awk '/VmRSS:/ { print $2 }' "/proc/$adapter_pid/status" 2>/dev/null || true); \
      rss_kib=${rss_kib:-0}; \
      test "$rss_kib" -le "$peak_kib" || peak_kib=$rss_kib; \
      checks=$((checks + 1)); \
      sleep 0.02; \
    done; \
    ! kill -0 "$adapter_pid" 2>/dev/null; \
    exec 5>&-; \
    status=0; wait "$adapter_pid" || status=$?; \
    rm -f /tmp/stalled-output; \
    test "$status" -ne 0; \
    test "$checks" -lt 150; \
    test "$peak_kib" -gt 0; \
    test "$peak_kib" -lt 65536; \
    printf 'stalled-reader peak RSS: %s KiB\n' "$peak_kib"
CMD ["sh", "-c", "echo 'freebasic test image: all gates ran during build' && /out-style-check /project/client/convex.bi"]

# ---------------------------------------------------------------------------
# Runtime closure: the compiled binaries plus exactly the shared libraries,
# OpenSSL provider modules, and CA bundle they load. TLS is exercised from the
# final image so a missing provider is not first discovered during hosted
# verification.
# ---------------------------------------------------------------------------
FROM build AS runtime-libs
RUN set -eu; \
    mkdir -p /runtime-root; \
    copy_library() { \
      library=$(readlink -f "$1"); \
      cp --parents "$library" /runtime-root; \
      soname=$(objdump -p "$library" | awk '/SONAME/ { print $2; exit }'); \
      if test -n "$soname" && test "$soname" != "$(basename "$library")"; then \
        ln -sf "$(basename "$library")" "/runtime-root$(dirname "$library")/$soname"; \
      fi; \
    }; \
    { ldd /out-adapter; ldd /out-example; } | \
      awk '/=> \/[^ ]+/ { print $3 } /^\/[^ ]+ \(0x/ { print $1 }' | sort -u | \
      while read -r library; do copy_library "$library"; done; \
    cp --parents /etc/ssl/certs/ca-certificates.crt /etc/ssl/openssl.cnf /runtime-root; \
    cp -a --parents /usr/lib/x86_64-linux-gnu/ossl-modules /runtime-root; \
    if test -d /usr/lib/x86_64-linux-gnu/engines-3; then \
      cp -a --parents /usr/lib/x86_64-linux-gnu/engines-3 /runtime-root; \
    fi

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
# The shared policy verifier still needs /bin/sh and basic POSIX text tools, so
# this is a stripped Debian rather than scratch. Everything that could compile,
# fetch, or delegate is removed and then proved absent.
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
    && for forbidden in apt apt-get dpkg curl wget gcc cc make ld as fbc perl bash \
         node python python3 npm pip pip3 convex service update-alternatives ldconfig \
         ldd localedef login su passwd; do \
         if command -v "$forbidden" >/dev/null 2>&1; then \
           echo "unexpected command in runtime base: $forbidden" >&2; exit 1; \
         fi; \
       done \
    && test ! -e /usr/share/doc && test ! -e /usr/share/man && test ! -e /etc/pam.d
COPY --from=runtime-libs /runtime-root/usr/lib/x86_64-linux-gnu/ /usr/lib/x86_64-linux-gnu/
COPY --from=runtime-libs /runtime-root/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=runtime-libs /runtime-root/etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
