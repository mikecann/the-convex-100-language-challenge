# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base other clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Portable CLU (pclu), Valery Ushakov's 2021+ fix-up of Liskov's original
# MIT CLU compiler, pinned by commit. Not packaged for Debian, so it is
# built from source. pclu's README names Boehm GC 7.2f, but that 2014 release
# faults during GC_init under Docker Desktop's amd64 Rosetta emulation before
# pclu reads any source. GC 8.2.8 is a source-compatible conservative-GC
# replacement that fixes that bootstrap failure; it is still built statically,
# so no libgc.so needs to ship in the runtime image.
ARG PCLU_REPO=https://github.com/nbuwe/pclu.git
ARG PCLU_COMMIT=1a8ad7603ea20b9744942182a52810441182f6a6
ARG GC_URL=https://github.com/ivmai/bdwgc/releases/download/v8.2.8/gc-8.2.8.tar.gz
ARG GC_SHA256=7649020621cb26325e1fb5c8742590d92fb48ce5c259b502faf7d9fb5dabb160

# ---------------------------------------------------------------------------
# test: build pclu from source, apply this client's runtime fix and new
# builtin, build the client library, lint every source file, and run every
# language-local test suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG PCLU_REPO
ARG PCLU_COMMIT
ARG GC_URL
ARG GC_SHA256
WORKDIR /project
ENV HOME=/root
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       git \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       make \
       binutils \
       patch \
       m4 \
       libatomic-ops-dev \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; test "$(uname -m)" = x86_64

# Fetch and verify Boehm GC by URL and checksum, matching the project's own
# pin-by-digest policy for anything not packaged by the distribution.
ADD --checksum=sha256:${GC_SHA256} ${GC_URL} /tmp/gc-8.2.8.tar.gz
RUN set -eu; \
    mkdir -p /opt/gc-8.2.8; \
    tar xzf /tmp/gc-8.2.8.tar.gz -C /opt/gc-8.2.8 --strip-components=1; \
    rm -f /tmp/gc-8.2.8.tar.gz

# Static-only: the runtime image ships no libgc.so, only the CLU binaries it
# is linked into. -fcommon remains set for pclu's own older C sources.
RUN set -eu; \
    cd /opt/gc-8.2.8; \
    ./configure --enable-static=yes --enable-shared=no --enable-threads=no \
        --prefix=/opt/gc-install CFLAGS="-fcommon -O2"; \
    make -j"$(nproc)"; \
    make install; \
    mkdir -p /opt/gc-install/include/gc/private; \
    cp include/private/*.h /opt/gc-install/include/gc/private/

RUN set -eu; \
    git clone "${PCLU_REPO}" /opt/pclu; \
    cd /opt/pclu; \
    git checkout "${PCLU_COMMIT}"

# Verbatim upstream permission grant (Copyright 1995 MIT, permissive
# MIT/X11-style, no separate license file added by the nbuwe/pclu fork).
# Checked here so a silently re-licensed upstream fails the build loudly
# rather than shipping unnoticed.
RUN set -eu; \
    grep -Fq 'Permission to use, copy, modify, and distribute this program' \
        /opt/pclu/COPYRIGHT

COPY client/wordvec-64bit-word-size.patch /tmp/wordvec-64bit-word-size.patch
RUN set -eu; cd /opt/pclu; patch -p1 < /tmp/wordvec-64bit-word-size.patch

# Wire up the symlink layout pclu's README.md documents (adjusted: the
# private GC headers belong under gc/include/gc/private to match the
# #include <gc/private/gc_priv.h> paths baked into pclu's C sources --
# README.md's own instructions symlink `private` to the wrong location).
RUN set -eu; \
    cd /opt/pclu; \
    mkdir -p code/gc include; \
    ln -s /opt/gc-install/include code/gc/include; \
    ln -s /opt/gc-install/lib code/gc/lib; \
    (cd exe && ln -sf ../code/cmp/pclu); \
    (cd include && ln -sf ../code/include/pclu_err.h); \
    (cd include && ln -sf ../code/include/pclu_sys.h); \
    (cd code && ln -sf gc/lib/libgc.a); \
    (cd code/include && ln -sf ../gc/include/gc)

ENV CLUHOME=/opt/pclu

# Bootstrap sequence from pclu's own README.md ("Bootstrapping the
# compiler"), with -fcommon carried through every stage that links against
# libgc.a.
RUN set -eu; \
    cd "$CLUHOME/code"; \
    make -w OPT_FLAGS='-fcommon -g -O0 -Wall -Wextra'
RUN set -eu; \
    cd "$CLUHOME/code/cmp"; \
    make -w OPT_FLAGS='-fcommon -g -O0 -Wall -Wextra'
RUN set -eu; \
    cd "$CLUHOME/lib"; \
    make libs

# This client's only new C: a brand-new builtin cluster, _tls, giving CLU
# a TLS-capable transport for the hosted profile (pclu has no TLS at all
# otherwise). Added the same way pclu's own hand-written primitives are:
# a .spc interface file plus a hand-authored .c file the linker resolves
# by the <type>OP<opname> naming convention -- no dlopen, no FFI
# declarations, no glue-code generator.
COPY client/convexrt-tls.c "$CLUHOME/code/libasm/Opt/_tls.c"
RUN set -eu; \
    cd "$CLUHOME/code/libasm/Opt"; \
    gcc -I../../include -DLINUX -fcommon -g -O0 -Wall -Wextra \
        -c -o _tls.o _tls.c; \
    ar r "$CLUHOME/code/libpclu_opt.a" _tls.o; \
    ranlib "$CLUHOME/code/libpclu_opt.a"

RUN set -eu; \
    mkdir -p /tmp/boot-test; \
    cd /tmp/boot-test; \
    printf '%s\n' \
      'start_up = proc ()' \
      '    po: stream := stream$primary_output()' \
      '    stream$putl(po, "boot ok")' \
      '    end start_up' \
      > boot.clu; \
    "$CLUHOME/exe/pclu" -ext false -spec boot -opt -compile boot; \
    "$CLUHOME/exe/plink" -opt -o boot boot.o; \
    ./boot | grep -Fq 'boot ok'

COPY client ./client
COPY examples ./examples

# pclu has no standard formatter, so the style gate is explicit: tabs for
# indentation only (CLU source in this repository, and pclu's own
# distribution, indents with tabs; a stray space run at the start of a
# line usually means a copy-paste misalignment), no trailing blanks, a
# final newline, and a line-width bound.
RUN set -eu; \
    files=$(find client examples -name '*.clu'); \
    test -n "$files"; \
    for f in $files; do \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      case "$f" in examples/*) width=100 ;; *) width=100 ;; esac; \
      if awk -v width="$width" \
             'length > width { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over $width columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS clu source style"

# The client library is spec'd once here (per-module .spc-equivalent
# interface knowledge lives in the .clu source itself -- ordinary CLU
# clusters, not hand-written C, from this point on) and compiled together
# with its unit tests. Everything lands in one flat /stage directory
# because pclu's -spec/-compile take bare module names resolved by the
# current working directory, not paths.
COPY client/_tls.spc "$CLUHOME/lib/_tls.spc"
RUN set -eu; \
    mkdir -p /stage; \
    cp client/*.clu /stage/ 2>/dev/null || true; \
    cp client/tests/*.clu /stage/ 2>/dev/null || true; \
    cp client/tests/fixtures/*.clu /stage/ 2>/dev/null || true; \
    cp examples/basics/main.clu /stage/main.clu; \
    cp client/tests/conformance/adapter.clu /stage/adapter.clu; \
    ls /stage

# language-local unit tests, real loopback-TCP/WebSocket/sync coverage,
# and a compiled-and-linked build of the canonical example. Proven here:
# the JSON codec (incl. array_items, for walking a Transition's own
# modifications array); the arithmetic bitwise helpers WebSocket masking
# and its handshake SHA-1 need (CLU's own int cluster has no bitwise
# operators at all); base64; the conn transport (dial/send/recv/close
# unifying the plain _chan profile and the new _tls builtin, plus this
# client's own DNS resolver -- see convex-dns.clu's header comment for
# why pclu's bundled one silently fails against Docker's resolv.conf);
# full HTTP/1.1 request/response framing against Convex's documented
# "format":"json" envelope; RFC 6455 WebSocket framing (masking,
# fragmentation, interleaved control frames, UTF-8 validated once after
# reassembly); and the convex-rs-0.10.4-unversioned-sync /api/sync state
# machine (Connect, ModifyQuerySet, Transition, backoff, rehydration
# suppression). The transport/HTTP/WebSocket/sync tests are real
# loopback TCP coverage against client/tests/fixtures/*.clu -- genuine
# peer processes, not mocks -- started here by the shell rather than by
# the test binaries themselves, since pclu has no async-subprocess-spawn
# primitive a CLU program could use to start its own fixture the way
# some of this repository's other language tests do. example_main.clu
# (examples/basics/main.clu) is compiled and linked here to prove it
# builds; running it against a real deployment is verify-example's job,
# not this image's.
RUN set -eu; \
    cd /stage; \
    test -f convex-json.clu; \
    "$CLUHOME/exe/pclu" -merge "$CLUHOME/lib/lowlev.lib" -ext false \
        -spec "$CLUHOME/lib/etc.spc", "$CLUHOME/lib/_tls.spc", \
              "$CLUHOME/lib/maybe.spc", \
              convex-dns, convex-json, convex-bitops, convex-sha1, \
              convex-base64, \
              convex-transport, convex-http, convex-websocket, \
              convex-sync, \
              json_test, bitops_test, sha1_test, base64_test, dns_test, \
              transport_test, http_test, websocket_test, sync_test, \
              echo_fixture, http_fixture, websocket_fixture, sync_fixture, \
              main, adapter \
        -opt -cfiles \
        -compile convex-dns, convex-json, convex-bitops, convex-sha1, \
                 convex-base64, \
                 convex-transport, convex-http, convex-websocket, \
                 convex-sync, \
                 json_test, bitops_test, sha1_test, base64_test, dns_test, \
                 transport_test, http_test, websocket_test, sync_test, \
                 echo_fixture, http_fixture, websocket_fixture, \
                 sync_fixture, main, adapter; \
    "$CLUHOME/exe/plink" -opt -o json_test convex-json.o json_test.o; \
    "$CLUHOME/exe/plink" -opt -o bitops_test convex-bitops.o bitops_test.o; \
    "$CLUHOME/exe/plink" -opt -o sha1_test convex-sha1.o convex-bitops.o \
        sha1_test.o convex-base64.o; \
    "$CLUHOME/exe/plink" -opt -o base64_test convex-base64.o base64_test.o; \
    "$CLUHOME/exe/plink" -opt -o dns_test convex-dns.o dns_test.o; \
    "$CLUHOME/exe/plink" -opt -o echo_fixture echo_fixture.o; \
    "$CLUHOME/exe/plink" -opt -o http_fixture http_fixture.o; \
    "$CLUHOME/exe/plink" -opt -o websocket_fixture websocket_fixture.o \
        convex-bitops.o convex-sha1.o convex-base64.o; \
    "$CLUHOME/exe/plink" -opt -o sync_fixture sync_fixture.o \
        convex-bitops.o convex-sha1.o convex-base64.o convex-json.o; \
    ./json_test | tee /tmp/json_test.out; \
    grep -Fq 'ALL PASS' /tmp/json_test.out; \
    ./bitops_test | tee /tmp/bitops_test.out; \
    grep -Fq 'ALL PASS' /tmp/bitops_test.out; \
    ./sha1_test | tee /tmp/sha1_test.out; \
    grep -Fq 'ALL PASS' /tmp/sha1_test.out; \
    ./base64_test | tee /tmp/base64_test.out; \
    grep -Fq 'ALL PASS' /tmp/base64_test.out; \
    ./dns_test | tee /tmp/dns_test.out; \
    grep -Fq 'ALL PASS' /tmp/dns_test.out; \
    # conn's oneof rep always references both _chan and _tls, so any
    # binary linking convex-transport.o needs libssl/libcrypto even when
    # (as here) only its plain _chan path is ever exercised; plink's own
    # trailing "-lpclu_opt -lm -lgc" places those too late in the link
    # line for a static archive to resolve against, so gcc is invoked
    # directly, matching the ordering this client's feasibility spike
    # already proved for _tls itself (see manifest.yaml/README.md). \
    gcc transport_test.o convex-transport.o convex-dns.o \
        -L"$CLUHOME/code" -lpclu_opt -lssl -lcrypto -lm -lgc \
        -o transport_test; \
    gcc http_test.o convex-http.o convex-transport.o convex-dns.o \
        convex-json.o \
        -L"$CLUHOME/code" -lpclu_opt -lssl -lcrypto -lm -lgc \
        -o http_test; \
    gcc websocket_test.o convex-websocket.o convex-transport.o \
        convex-dns.o convex-sha1.o convex-base64.o convex-bitops.o \
        -L"$CLUHOME/code" -lpclu_opt -lssl -lcrypto -lm -lgc \
        -o websocket_test; \
    gcc sync_test.o convex-sync.o convex-websocket.o convex-transport.o \
        convex-dns.o convex-sha1.o convex-base64.o convex-bitops.o \
        convex-json.o \
        -L"$CLUHOME/code" -lpclu_opt -lssl -lcrypto -lm -lgc \
        -o sync_test; \
    gcc main.o convex-sync.o convex-websocket.o convex-transport.o \
        convex-http.o convex-dns.o convex-sha1.o convex-base64.o \
        convex-bitops.o convex-json.o \
        -L"$CLUHOME/code" -lpclu_opt -lssl -lcrypto -lm -lgc \
        -o convex-example; \
    gcc adapter.o convex-sync.o convex-websocket.o convex-transport.o \
        convex-http.o convex-dns.o convex-sha1.o convex-base64.o \
        convex-bitops.o convex-json.o \
        -L"$CLUHOME/code" -lpclu_opt -lssl -lcrypto -lm -lgc \
        -o convex-adapter; \
    ./echo_fixture 19001 >/tmp/echo_fixture.log 2>&1 & \
    ECHO_PID=$!; \
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 40\r\nConnection: close\r\n\r\n{"status":"success","value":{"count":0}}' \
        > /tmp/http_resp_cl.bin; \
    printf 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n28\r\n{"status":"success","value":{"count":0}}\r\n0\r\n\r\n' \
        > /tmp/http_resp_chunked.bin; \
    printf 'HTTP/1.1 560 OK\r\nContent-Type: application/json\r\nContent-Length: 49\r\nConnection: close\r\n\r\n{"status":"error","errorMessage":"boom","code":1}' \
        > /tmp/http_resp_error.bin; \
    ./http_fixture 19002 /tmp/http_resp_cl.bin >/tmp/http_fixture_cl.log 2>&1 & \
    HF1_PID=$!; \
    ./http_fixture 19003 /tmp/http_resp_chunked.bin >/tmp/http_fixture_chunked.log 2>&1 & \
    HF2_PID=$!; \
    ./http_fixture 19004 /tmp/http_resp_error.bin >/tmp/http_fixture_error.log 2>&1 & \
    HF3_PID=$!; \
    ./websocket_fixture 19005 >/tmp/websocket_fixture.log 2>&1 & \
    WSF_PID=$!; \
    ./sync_fixture 19006 >/tmp/sync_fixture.log 2>&1 & \
    SYNCF_PID=$!; \
    sleep 1; \
    ./transport_test 19001 19099 | tee /tmp/transport_test.out; \
    ./http_test 19002 19003 19004 | tee /tmp/http_test.out; \
    ./websocket_test 19005 | tee /tmp/websocket_test.out; \
    ./sync_test 19006 | tee /tmp/sync_test.out; \
    wait $ECHO_PID $HF1_PID $HF2_PID $HF3_PID $WSF_PID $SYNCF_PID \
        2>/dev/null || true; \
    grep -Fq 'ALL PASS' /tmp/sync_test.out; \
    grep -Fq 'ALL PASS' /tmp/transport_test.out; \
    grep -Fq 'ALL PASS' /tmp/http_test.out; \
    grep -Fq 'ALL PASS' /tmp/websocket_test.out

# Prove the real adapter binary's hello/close NDJSON lifecycle at build
# time. CONVEX_URL is a dummy value scoped to this one RUN: hello and
# close never open a network connection, so the adapter only needs the
# variable to be present.
RUN set -eu; \
    cd /stage; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 ./convex-adapter \
      > /tmp/convex-adapter-hello.ndjson; \
    grep -Fq '"language":"clu"' /tmp/convex-adapter-hello.ndjson; \
    grep -Fq '"type":"closed"' /tmp/convex-adapter-hello.ndjson

RUN mkdir -p /out; \
    cp /stage/convex-example /stage/convex-adapter /out/

# ---------------------------------------------------------------------------
# runtime images: the two compiled, self-contained native ELF binaries
# above (~1.1MB each, no CLUHOME needed at runtime) plus exactly the
# shared libraries and CA bundle they load -- nothing else. runtime-tools
# keeps an unmodified copy of the same pinned base image purely as a COPY
# source; runtime-base starts fresh from that same pinned image and is
# wiped down to nothing before copying back only the named files below,
# an allow-list rather than a deny-list, so nothing the pinned image
# happened to ship (a package manager, a second shell, a compiler) can
# survive by omission from a deletion list. libssl.so.3/libcrypto.so.3
# and the OpenSSL CA bundle/config come from the test stage's own
# ca-certificates/libssl-dev install (bookworm-slim itself ships
# neither); every other library and the coreutils/dash the shared
# policy's own verifier requires come from runtime-tools, unmodified.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-tools

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# bookworm-slim has no findutils, and /bin is a symlink into /usr, so
# rm itself becomes unreachable via PATH the moment a *separate* rm
# invocation deletes /usr out from under the running shell -- caught
# the first time this ran, on the second (per-/etc/entry) rm call, with
# a bare "rm: not found". Fixed by making this exactly one rm process:
# the /etc allow-list exclusion is computed with echo (a shell builtin,
# no PATH lookup) inside a command substitution that runs to completion
# before rm itself is ever invoked, so rm is resolved via PATH exactly
# once, while everything it needs (including itself) still exists.
RUN set -eu; \
    rm -rf /bin /sbin /usr /lib /lib64 /var /root /home /opt /media \
           /mnt /srv \
        $(for f in /etc/*; do \
              case "$f" in \
                  /etc/resolv.conf|/etc/hosts) ;; \
                  *) echo "$f" ;; \
              esac; \
          done)
# No mkdir here: mkdir itself lived under the /usr this RUN step just
# deleted, so (like rm above) it would already be unreachable via PATH
# by the time this same shell tried to call it. Every directory below
# is created implicitly by COPY, which -- unlike a shell command run
# inside the image -- is a build-time Docker operation, not a process
# that has to resolve anything through this image's own now-empty PATH.
COPY --from=runtime-tools /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
COPY --from=runtime-tools /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=runtime-tools /bin/dash /bin/sh
COPY --from=runtime-tools /usr/bin/id /usr/bin/id
COPY --from=runtime-tools /usr/bin/cat /usr/bin/cat
COPY --from=runtime-tools /usr/bin/cut /usr/bin/cut
COPY --from=runtime-tools /usr/bin/head /usr/bin/head
COPY --from=runtime-tools /usr/bin/tail /usr/bin/tail
COPY --from=runtime-tools /usr/bin/tr /usr/bin/tr
COPY --from=runtime-tools /usr/bin/sort /usr/bin/sort
COPY --from=runtime-tools /usr/bin/uniq /usr/bin/uniq
COPY --from=runtime-tools /usr/bin/wc /usr/bin/wc
COPY --from=runtime-tools /usr/bin/uname /usr/bin/uname
COPY --from=runtime-tools /usr/bin/grep /usr/bin/grep
COPY --from=runtime-tools /usr/bin/sed /usr/bin/sed
COPY --from=runtime-tools /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libssl.so.3 /lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /lib/x86_64-linux-gnu/libcrypto.so.3 /lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /usr/lib/ssl/openssl.cnf /usr/lib/ssl/openssl.cnf
# convexrt-tls.c calls SSL_CTX_set_default_verify_paths(), which trusts
# OpenSSL's own compiled-in OPENSSLDIR ("/usr/lib/ssl", confirmed with
# `openssl version -d` in the test image) to hold cert.pem -- on Debian
# that path is actually a symlink to /etc/ssl/certs/ca-certificates.crt,
# which this stage never copied, so the hosted (wss://) profile's first
# real handshake failed verification outright ("certificate verify
# failed") until the CA bundle was placed at this exact default location
# too, not only its own /etc/ssl/certs/ path.
COPY --from=test /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem
ENV PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /var && test ! -e /usr/share && test ! -e /usr/include \
    && test ! -e /usr/src && test ! -e /etc/dpkg \
    && test ! -e /bin/bash && test ! -e /usr/bin/bash \
    && test ! -e /usr/bin/perl && test ! -e /usr/bin/debconf \
    && test ! -e /usr/bin/ldd && test ! -e /usr/sbin/chroot \
    && test ! -e /usr/sbin/debugfs && test ! -e /usr/sbin/mke2fs \
    && set -- /bin/* && test "$#" -eq 1 && test "$1" = /bin/sh \
    && for command in bash busybox perl debconf ldd chroot debugfs \
         mke2fs mkfs fdisk mount umount su passwd groupadd useradd \
         apk apt apt-get dpkg dpkg-query wget nc telnet openssl \
         gcc cc make cmake node python python3 npm pip curl convex \
         pclu plink; do \
         ! command -v "$command" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last: the root build command selects the
# default Docker target when it builds a language, and that default
# must be the conformance adapter, not the example.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
