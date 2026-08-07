# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

# ---------------------------------------------------------------------------
# test: install YottaDB from the pinned installer script, compile the
# client, and run every language-local test suite.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV LC_ALL=C

# YottaDB needs glibc >= 2.38 for its r2.06 x86-64 binaries; bookworm ships
# 2.36. trixie (glibc 2.41) is the oldest Debian release the pinned tarball
# actually runs on.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ca-certificates=20250419 \
       wget=1.25.0-2 \
       file=1:5.46-5 \
       binutils=2.44-3 \
       libelf-dev=0.192-4 \
       git=1:2.47.3-0+deb13u1 \
       gcc=4:14.2.0-1 \
       make=4.4.1-2 \
       libssl-dev=3.5.6-1~deb13u2 \
       openssl=3.5.6-1~deb13u2 \
       pkg-config=1.8.1-4 \
       libgcrypt20-dev=1.11.0-7+deb13u1 \
       libgpg-error-dev=1.51-4 \
       libgpgme-dev=1.24.2-3 \
       libconfig-dev=1.7.3-2 \
       tcsh=6.24.13-2 \
       busybox-static=1:1.37.0-6+b8 \
    && rm -rf /var/lib/apt/lists/*

# ydbinstall.sh is YottaDB's own installer wrapper; it resolves and fetches
# the actual release tarball from YottaDB's GitLab releases at install time,
# so only the wrapper script itself has a fixed checksum to pin here. The
# release it fetches is pinned by the explicit "r2.06" version argument
# below (a bare positional argument -- ydbinstall.sh's own argument parser
# treats the first non-flag word as the requested version).
# --encplugin builds YottaDB's OpenSSL-backed TLS plugin from source as part
# of the same install; this answers the brief's one open question -- the
# plugin does ship, and does build unattended. --utf8 is deliberately never
# passed: it installs a second, ICU-linked engine variant purely to support a
# UTF-8 chset this client never selects (ydb_chset=M below is set for every
# stage, including this one), so omitting it also drops the ICU dependency
# from the whole image.
ADD --checksum=sha256:ca1def5ae28a136dbaec58bb72630420f9e7c9f43633a2b9aeb4a036be441f47 \
    https://download.yottadb.com/ydbinstall.sh /tmp/ydbinstall.sh
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    chmod +x /tmp/ydbinstall.sh; \
    /tmp/ydbinstall.sh r2.06 --installdir /opt/yottadb \
      --encplugin --overwrite-existing --verbose; \
    rm -f /tmp/ydbinstall.sh; \
    /opt/yottadb/yottadb --version 2>&1 | head -n 1 | grep -Fq 'YottaDB release:         r2.06'; \
    test -f /opt/yottadb/plugin/libgtmcrypt.so; \
    test -f /opt/yottadb/plugin/libgtmtls.so

ENV ydb_dist=/opt/yottadb
ENV PATH=/opt/yottadb:${PATH}
# The client is byte-oriented (M mode, not UTF-8 mode): every string
# operation is a raw byte operation, which is what lets UTF-8 JSON payloads
# pass through untouched without depending on ICU or a UTF-8 locale.
ENV ydb_chset=M

# A YottaDB process always attaches a database region at startup even when
# the M program never references a `^global` (confirmed empirically: a
# fresh, never-referenced region's .dat file is untouched after a run). The
# client here never uses globals, so this region is created once, baked
# into the runtime images read-only, and never written again.
RUN set -eu; \
    mkdir -p /opt/convex/db; \
    export ydb_gbldir=/opt/convex/db/mumps.gld; \
    printf 'change -segment DEFAULT -file=/opt/convex/db/mumps.dat\nexit\n' \
      | /opt/yottadb/mumps -run GDE; \
    /opt/yottadb/mupip create -region DEFAULT; \
    test -s /opt/convex/db/mumps.dat; \
    test -s /opt/convex/db/mumps.gld
ENV ydb_gbldir=/opt/convex/db/mumps.gld

COPY client ./client
COPY examples ./examples

# Compile every checked-in M source ahead of time. `mumps -object=dir file.m`
# compiles to a .o without running anything; the runtime images ship only
# these objects, never the checked-in .m source.
RUN set -eu; \
    mkdir -p /build/o; \
    for source in client/convex.m client/tests/conformance/adapter.m \
                  examples/basics/main.m client/tests/jsontest.m \
                  client/tests/cryptotest.m client/tests/fixture.m \
                  client/tests/httptest.m client/tests/livetest.m; do \
      /opt/yottadb/mumps -object=/build/o/ "$source"; \
    done; \
    file /build/o/convex.o | grep -Eq 'ELF 64-bit.*x86-64'
ENV ydb_routines=/build/o(/build/o)

# Parse-only checks already happened at compile time above (a syntax error
# fails the `mumps -object` step); this is the smoke check that the compiled
# adapter actually answers hello/close over its own NDJSON protocol.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid mumps -run main^adapter \
    | tee /tmp/adapter-probe.out \
    && grep -Fq '"language":"mumps"' /tmp/adapter-probe.out \
    && grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Unit suites that need no network: JSON codec and the SHA-1/base64 digest
# primitives the WebSocket handshake depends on.
RUN mumps -run jsontest
RUN mumps -run cryptotest

# HTTP and Live tests talk to client/tests/fixture.m over real 127.0.0.1
# sockets rather than replaying canned strings in-process, so a bug in the
# client's own request framing or WebSocket codec cannot pass by construction.
# Each fixture process is single-shot (it accepts exactly one connection),
# so httptest gets one fixture per case rather than one fixture handling three
# sequential accepts.
RUN set -eu; \
    mumps -run main^fixture http 18101 query & p1=$!; \
    mumps -run main^fixture http 18102 mutation & p2=$!; \
    mumps -run main^fixture http 18103 error & p3=$!; \
    sleep 0.3; \
    mumps -run main^httptest 18101 18102 18103; status=$?; \
    wait "$p1"; s1=$?; wait "$p2"; s2=$?; wait "$p3"; s3=$?; \
    test "$status" -eq 0; test "$s1" -eq 0; test "$s2" -eq 0; test "$s3" -eq 0
RUN set -eu; \
    mumps -run main^fixture sync 18201 & p1=$!; \
    sleep 0.3; \
    mumps -run main^livetest 18201; status=$?; \
    wait "$p1"; s1=$?; \
    test "$status" -eq 0; test "$s1" -eq 0

# Stage exactly the runtime closure while the test stage's full toolset (cp,
# ldd, awk, mkdir) is still available. runtime-base below deletes everything
# in a *fresh* debian:trixie-slim FIRST, including /bin/sh itself, so any
# staging work has to happen here, in a stage that never gets pruned, and
# arrive as one COPY --from=test /staging / afterwards -- not as RUN commands
# that execute after the deletion (the first attempt at this got that order
# backwards: pruning ran in runtime-base and then a later RUN in that same
# stage needed /bin/sh, which the prune had just deleted, and the build
# failed to even start that step).
#
# yottadb is the real engine launcher binary; mumps is only ever a symlink to
# it (confirmed on the build host: `mumps -> ./yottadb`). Copying the mumps
# symlink with cp -a and never copying its target -- the classic "cp -a
# stages a SONAME symlink without what it points at" failure -- would ship a
# dangling link, so the real file is staged under its own name (dereferenced
# with -L) and mumps is recreated as a symlink to it, matching upstream.
#
# libyottadb.so is the actual engine; the yottadb binary itself only links
# libc and dlopen()s libyottadb.so at startup, so a naive ldd closure over
# just the launcher binary silently misses it and everything it needs (this
# was caught by actually running the built runtime image, not by reasoning
# about it). libgtmtls.so -- the OpenSSL-backed plugin WRITE /TLS dlopen()s --
# is the same story: it is not a link-time dependency of anything above it,
# so it and its own closure are staged and ldd'd explicitly too, even though
# nothing here calls dlopen() directly.
RUN set -eu; \
    mkdir -p /staging/bin /staging/usr/bin /staging/opt/yottadb/plugin \
             /staging/opt/convex/db /staging/opt/convex/o /staging/etc/ssl/certs; \
    cp -a /bin/dash /staging/bin/sh; \
    for tool in id cat; do cp -a "/usr/bin/$tool" "/staging/usr/bin/$tool"; done; \
    cp -aL /opt/yottadb/yottadb /staging/opt/yottadb/yottadb; \
    ln -s ./yottadb /staging/opt/yottadb/mumps; \
    cp -aL /opt/yottadb/libyottadb.so /staging/opt/yottadb/libyottadb.so; \
    cp -aL /opt/yottadb/plugin/libgtmtls.so /staging/opt/yottadb/plugin/libgtmtls.so; \
    for object in /opt/yottadb/yottadb /opt/yottadb/libyottadb.so /opt/yottadb/plugin/libgtmtls.so; do \
      ldd "$object" 2>/dev/null \
        | awk '{ for (f = 1; f <= NF; f++) if ($f ~ /^\//) print $f }' \
        | while read -r library; do \
            mkdir -p "/staging$(dirname "$library")"; \
            cp -aL "$library" "/staging$library"; \
          done; \
    done; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /staging/etc/ssl/certs/ca-certificates.crt; \
    cp -aL /etc/ssl/openssl.cnf /staging/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /staging/etc/nsswitch.conf; \
    for resolver in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL "/lib/x86_64-linux-gnu/$resolver" "/staging/lib/x86_64-linux-gnu/$resolver"; \
    done; \
    cp -a /opt/convex/db/mumps.dat /staging/opt/convex/db/mumps.dat; \
    cp -a /opt/convex/db/mumps.gld /staging/opt/convex/db/mumps.gld; \
    cp -a /build/o/convex.o /staging/opt/convex/o/convex.o; \
    printf '%s\n' \
      'tls: {' \
      '  client: {' \
      '    CAfile: "/etc/ssl/certs/ca-certificates.crt";' \
      '    verify-level: "CHECK";' \
      '    verify-depth: 9;' \
      '  };' \
      '}' \
      > /staging/opt/convex/tls.conf

# `./run test mumps` reruns this exact suite from the built image, so the
# evidence is not limited to what happened during the build.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'export ydb_dist=/opt/yottadb PATH=/opt/yottadb:$PATH ydb_chset=M' \
      'export ydb_gbldir=/opt/convex/db/mumps.gld' \
      'export ydb_routines="/build/o(/build/o)"' \
      'mumps -run jsontest' \
      'mumps -run cryptotest' \
      'mumps -run main^fixture http 18101 query & p1=$!' \
      'mumps -run main^fixture http 18102 mutation & p2=$!' \
      'mumps -run main^fixture http 18103 error & p3=$!' \
      'sleep 0.3' \
      'mumps -run main^httptest 18101 18102 18103; status=$?' \
      'wait "$p1"; s1=$?; wait "$p2"; s2=$?; wait "$p3"; s3=$?' \
      'test "$status" -eq 0; test "$s1" -eq 0; test "$s2" -eq 0; test "$s3" -eq 0' \
      'mumps -run main^fixture sync 18201 & p4=$!' \
      'sleep 0.3' \
      'mumps -run main^livetest 18201; status=$?' \
      'wait "$p4"; s4=$?' \
      'test "$status" -eq 0; test "$s4" -eq 0' \
      'printf "%s\n" "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}" "{\"id\":\"close\",\"op\":\"close\"}" | CONVEX_URL=http://example.invalid mumps -run main^adapter | grep -Fq "\"type\":\"closed\""' \
      > /usr/local/bin/run-language-tests \
    && chmod 0555 /usr/local/bin/run-language-tests
CMD ["/usr/local/bin/run-language-tests"]

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its broad filesystem removed, then
# only YottaDB's own runtime closure (found via ldd) and the staged
# database/object files copied back.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    exec "$pruner" rm -rf /tmp
# The whole runtime closure was built as /staging in the test stage, while
# that stage's own filesystem (cp, ldd, awk, mumps itself) was still intact;
# here it lands in one shot, after this stage's own broad filesystem is
# already gone. Only convex.o -- the routine both leaf images call into -- is
# included; each leaf below copies in just its own entry-point object, so
# neither final image ships the other's entry point or any test-only object
# (fixture.o, jsontest.o, httptest.o, livetest.o, cryptotest.o).
COPY --from=test /staging /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LC_ALL=C \
    ydb_dist=/opt/yottadb \
    ydb_chset=M \
    ydb_gbldir=/opt/convex/db/mumps.gld \
    ydb_routines=/opt/convex/o(/opt/convex/o) \
    gtmcrypt_config=/opt/convex/tls.conf \
    PATH=/usr/local/bin:/opt/yottadb:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(uname -m)" = x86_64

RUN test ! -e /etc/dpkg \
    && test ! -e /etc/apt \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /busybox \
    && for command_name in cc gcc g++ clang make ld as ar cmake apt apt-get dpkg \
         apk rpm curl wget nc netcat socat busybox node npm npx python \
         python3 pip pip3 perl ruby php java go rustc cargo convex jq; do \
         ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
       done

# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /build/o/main.o /opt/convex/o/main.o
RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec /opt/yottadb/mumps -run main^main "$@"' \
    > /usr/local/bin/convex-example \
    && chmod 0555 /usr/local/bin/convex-example
RUN set -eux; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /opt/convex/o/adapter.o
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# Keep the adapter last: `./run build mumps` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /build/o/adapter.o /opt/convex/o/adapter.o
RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec /opt/yottadb/mumps -run main^adapter' \
    > /usr/local/bin/convex-adapter \
    && chmod 0555 /usr/local/bin/convex-adapter
RUN set -eux; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /opt/convex/o/main.o; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid /usr/local/bin/convex-adapter \
    | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
