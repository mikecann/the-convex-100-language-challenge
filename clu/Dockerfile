# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base other clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Portable CLU (pclu), Valery Ushakov's 2021+ fix-up of Liskov's original
# MIT CLU compiler, pinned by commit. Not packaged for Debian, so it is
# built from source. Boehm GC 7.2f is the exact version pclu's own
# README.md calls for; also built from source, statically, so no libgc.so
# needs to ship in the runtime image.
ARG PCLU_REPO=https://github.com/nbuwe/pclu.git
ARG PCLU_COMMIT=1a8ad7603ea20b9744942182a52810441182f6a6
ARG GC_URL=https://www.hboehm.info/gc/gc_source/gc-7.2f.tar.gz
ARG GC_SHA256=265ce3167273cff1d77081ad7dd86ca1269a0ec2ae0324f9ad8070ccc23d3d85

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
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; test "$(uname -m)" = x86_64

# Fetch and verify Boehm GC by URL and checksum, matching the project's own
# pin-by-digest policy for anything not packaged by the distribution.
ADD --checksum=sha256:${GC_SHA256} ${GC_URL} /tmp/gc-7.2f.tar.gz
RUN set -eu; \
    mkdir -p /opt/gc-7.2f; \
    tar xzf /tmp/gc-7.2f.tar.gz -C /opt/gc-7.2f --strip-components=1; \
    rm -f /tmp/gc-7.2f.tar.gz

# gc-7.2 (released 2014) relies on tentative definitions (a jmp_buf global
# repeated, unqualified, in a header every gc .c file includes) that GCC's
# -fno-common default (the default since GCC 10) rejects at final-link
# time with "multiple definition of GC_jmp_buf". -fcommon restores the
# old, and here required, behaviour. Static-only: the runtime image ships
# no libgc.so, only the CLU binaries it is linked into.
RUN set -eu; \
    cd /opt/gc-7.2f; \
    ./configure --enable-static=yes --enable-shared=no --enable-threads=no \
        --with-libatomic-ops=no --prefix=/opt/gc-install CFLAGS="-fcommon -O2"; \
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
# with its unit tests.
COPY client/_tls.spc "$CLUHOME/lib/_tls.spc"
RUN set -eu; \
    mkdir -p /stage; \
    cp client/*.clu /stage/ 2>/dev/null || true; \
    cp client/tests/*.clu /stage/ 2>/dev/null || true; \
    ls /stage

# language-local unit tests: currently just the JSON codec module. HTTP
# framing, WebSocket framing, the /api/sync state machine, the
# conformance adapter and the canonical example are not implemented yet
# -- see manifest.yaml limitations. This stage intentionally has nothing
# further to run until those land; it exists so the pclu-plus-patches
# build itself is proven inside this repository's own Docker gate rather
# than only in a throwaway spike container.
RUN set -eu; \
    cd /stage; \
    test -f convex-json.clu; \
    "$CLUHOME/exe/pclu" -merge "$CLUHOME/lib/lowlev.lib" -ext false \
        -spec "$CLUHOME/lib/etc.spc", convex-json, json_test \
        -opt -cfiles -compile convex-json, json_test; \
    "$CLUHOME/exe/plink" -opt -o json_test convex-json.o json_test.o; \
    ./json_test | tee /tmp/json_test.out; \
    grep -Fq 'ALL PASS' /tmp/json_test.out

# ---------------------------------------------------------------------------
# runtime images are not built yet: no example, no HTTP/WS/sync client, no
# conformance adapter exist to ship. Adding runtime-base/example-runtime/
# runtime stages ahead of real behaviour would let a minimal image exist
# without anything working behind it, which is exactly what this
# repository's evidence rules forbid. They land once client/*.clu and
# client/tests/conformance/adapter.clu are real. See manifest.yaml.
# ---------------------------------------------------------------------------
