# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea

# ---------------------------------------------------------------------------
# test: build jsource from pinned source, then run every language-local
# test suite against the built interpreter.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project

# xz-utils/nasm are deliberately unpinned build-time-only tools; nothing they
# produce ships in the runtime images below, and jsource's own build scripts
# are what actually need nasm for its x86-64 assembly routines.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       build-essential=12.10ubuntu1 \
       git=1:2.43.0-1ubuntu7.3 \
       ca-certificates=20240203 \
       libssl-dev=3.0.13-0ubuntu3.12 \
       pkg-config=1.8.1-2build1 \
       nasm=2.16.01-1build1 \
       busybox-static=1:1.36.1-6ubuntu3.1 \
       file=1:5.45-3build1 \
    && rm -rf /var/lib/apt/lists/*

# jsource has no tagged release; this commit is what the feasibility spike
# proved a full TCP -> TLS 1.3 -> HTTP round trip against, including this
# project's own hosted deployment, entirely through 15!:0 foreign calls with
# no C shim. Building it is one `sh` script, not a multi-tool toolchain, so
# the whole test image never installs a package manager on top of apt.
WORKDIR /src
RUN git clone -q https://github.com/jsoftware/jsource.git . \
    && git checkout -q e505e149130b5039e711d243228f559a565f95a6 \
    && cp jsrc/jversion-x.h jsrc/jversion.h
WORKDIR /src/make2
RUN set -eu; \
    chmod +x *.sh; \
    test "$(uname -m)" = x86_64; \
    jplatform=linux j64x=j64 ./build_all.sh; \
    test -x /src/jlibrary/bin/jconsole; \
    file /src/jlibrary/bin/jconsole | grep -Eq 'ELF 64-bit.*x86-64'; \
    printf 'echo 3+4\n' | /src/jlibrary/bin/jconsole /dev/stdin >/tmp/smoke.out; \
    grep -Fqx 7 /tmp/smoke.out

WORKDIR /project
COPY client ./client
COPY examples ./examples

ENV LC_ALL=C

# Every local suite against the pinned interpreter. Each is a hand-built
# fixture over plain function calls -- none of them open a socket, so they
# do not depend on network reachability inside the build.
RUN /src/jlibrary/bin/jconsole client/tests/json_test.ijs
RUN /src/jlibrary/bin/jconsole client/tests/transport_test.ijs
RUN /src/jlibrary/bin/jconsole client/tests/convex_test.ijs
RUN /src/jlibrary/bin/jconsole client/tests/websocket_test.ijs

# adapter_id_valid/adapter_error/adapter_result direct coverage: the
# ADAPTER_LISTEN crash a live conformance run found (a stale numeric-to-
# character reconversion of already-character id data) was reachable only
# once any adapter_error response carried a request id, which the hello/close
# smoke test below never exercises. ADAPTER_AUTOEXEC=: 0 inside the test file
# itself loads adapter.ijs as a library instead of running adapter_main.
RUN /src/jlibrary/bin/jconsole client/tests/conformance/adapter_test.ijs

# The adapter answers a hello/close session over stdin and stdout before any
# runtime image is built from it.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid /src/jlibrary/bin/jconsole client/tests/conformance/adapter.ijs \
    | tee /tmp/adapter-probe.out \
    && grep -Fq '"language":"j"' /tmp/adapter-probe.out \
    && grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# ---------------------------------------------------------------------------
# Stage exactly the runtime closure: jsource's interpreter (jconsole,
# libj.so, libtsdll.so) and its own .ijs system library (never a compiler --
# jlibrary is interpreted source plus the three build artifacts above), the
# TLS libraries the client dlopens by name at runtime through 15!:0 (never
# linked at jconsole build time, so ldd on jconsole alone would miss them),
# and the trust store / OpenSSL config / provider module TLS actually loads.
#
# jlibrary is staged whole, addons and user included: profile.ijs (run by
# every jconsole start-up, script mode or not) unconditionally tries to load
# a handful of addon scripts and prints "not found: <path>" to stdout, ahead
# of any real output, for each one that is missing. That first attempt at
# this image pruned addons/ and user/ out to save the (7.6 MiB of 18 MiB
# total) space; the diagnostic line it produced looked identical in shape to
# the libgmp one above -- a prune removing something later called, just from
# this Dockerfile's own staging step rather than a missed ldd edge. jlibrary
# is small enough whole that trimming it buys nothing but a new way to leak
# noise onto the adapter's stdout.
#
# libgmp.so.10 is staged for the same reason: libj.so dlopen()s it by name
# during interpreter start-up to back J's extended-precision integers, a
# feature this client's own code never invokes (JSON numbers are kept as
# their verbatim source literal, never parsed into any numeric type). ldd
# never reports it as a dependency because the load is dynamic, not linked,
# so leaving it unstaged does not fail the build -- it silently reappears as
# a "cannot open shared object file" diagnostic on the first line of every
# process's stdout, ahead of the real NDJSON. Shipping the exact library the
# build already resolved this against is what keeps that diagnostic from
# firing at all, rather than papering over its output downstream.
#
# Every shared object copied here is discovered by running ldd on exactly
# one binary per invocation (interleaved multi-argument ldd output is not
# parsed anywhere in this file) and dereferenced with `cp -aL`, so a SONAME
# symlink never gets staged without the real file behind it.
# ---------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p /staging/project/client /staging/opt/convex/lib \
             /staging/usr/local/bin /staging/usr/bin /staging/bin \
             /staging/etc/ssl/certs /staging/usr/lib/x86_64-linux-gnu/ossl-modules; \
    cp -a /src/jlibrary /staging/opt/convex/jlibrary; \
    cp -aL /usr/lib/x86_64-linux-gnu/libssl.so.3 /staging/opt/convex/lib/libssl.so.3; \
    cp -aL /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /staging/opt/convex/lib/libcrypto.so.3; \
    cp -aL /usr/lib/x86_64-linux-gnu/libgmp.so.10 /staging/opt/convex/lib/libgmp.so.10; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
       /staging/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    cp -aL /etc/ssl/openssl.cnf /staging/etc/ssl/openssl.cnf; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /staging/etc/ssl/certs/ca-certificates.crt; \
    cp -a /bin/dash /staging/bin/sh; \
    for tool in id cat cut head tail tr sort uniq wc uname grep sed tee; do \
      cp -a "/usr/bin/$tool" "/staging/usr/bin/$tool"; \
    done; \
    for object in /staging/opt/convex/jlibrary/bin/jconsole \
                  /staging/opt/convex/jlibrary/bin/libj.so \
                  /staging/opt/convex/jlibrary/bin/libtsdll.so \
                  /staging/opt/convex/lib/libssl.so.3 \
                  /staging/opt/convex/lib/libcrypto.so.3 \
                  /staging/opt/convex/lib/libgmp.so.10 \
                  /staging/bin/sh /staging/usr/bin/*; do \
      test -f "$object" || continue; \
      ldd "$object" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }' \
        | while read -r library; do \
            mkdir -p "/staging$(dirname "$library")"; \
            cp -aL "$library" "/staging$library"; \
          done; \
    done; \
    cp -a client/json.ijs client/transport.ijs client/convex.ijs client/websocket.ijs client/live.ijs \
       /staging/project/client/; \
    for object in /staging/opt/convex/jlibrary/bin/jconsole \
                  /staging/opt/convex/jlibrary/bin/libj.so \
                  /staging/opt/convex/jlibrary/bin/libtsdll.so \
                  /staging/opt/convex/lib/libssl.so.3 \
                  /staging/opt/convex/lib/libcrypto.so.3 \
                  /staging/opt/convex/lib/libgmp.so.10; do \
      test -f "$object" || { echo "missing staged object: $object" >&2; exit 1; }; \
    done

# Entry points. Each one is a two line launcher for the exact checked-in J
# program. AWKPATH/LUA_PATH-style search-path resolution does not exist in
# J -- `load` takes a literal string, so every client file's own load of a
# sibling module is the same hardcoded /project/client/whatever.ijs that
# already has to be true in the test stage (WORKDIR /project, client copied
# beneath it). Staging the runtime closure at that identical absolute path,
# rather than the more conventional /opt/convex/client, is what lets every
# client .ijs file work unmodified in both places; the one file that named
# /opt/convex/client directly (examples/basics/main.ijs, which is not
# itself loaded by anything and so had no reason to match) is the one file
# that was fixed instead.
#
# These go into per-image trees rather than into the shared /staging
# closure. runtime-base is the common ancestor of both leaf images, so
# anything staged there arrives in both of them, and each leaf image proves
# that the other image's entry point is absent. The final images ship no
# `rm` and run as 65532, so a leaf cannot undo an over-broad base: the split
# has to happen here, where the launchers are written.
RUN mkdir -p /staging-example/usr/local/bin /staging-adapter/usr/local/bin \
    && printf '%s\n' \
      '#!/bin/sh' \
      'exec /opt/convex/jlibrary/bin/jconsole /opt/convex/examples/basics/main.ijs "$@"' \
      > /staging-example/usr/local/bin/convex-example \
    && printf '%s\n' \
      '#!/bin/sh' \
      'exec /opt/convex/jlibrary/bin/jconsole /project/client/tests/conformance/adapter.ijs "$@"' \
      > /staging-adapter/usr/local/bin/convex-adapter \
    && chmod 0555 /staging-example/usr/local/bin/convex-example \
       /staging-adapter/usr/local/bin/convex-adapter

# `./run test j` runs the same suites again from the built image, so the
# evidence is not limited to what happened during the build.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'cd /project' \
      'export LC_ALL=C' \
      'J=/src/jlibrary/bin/jconsole' \
      '$J client/tests/json_test.ijs' \
      '$J client/tests/transport_test.ijs' \
      '$J client/tests/convex_test.ijs' \
      '$J client/tests/websocket_test.ijs' \
      '$J client/tests/conformance/adapter_test.ijs' \
      > /usr/local/bin/run-language-tests \
    && chmod 0555 /usr/local/bin/run-language-tests
CMD ["/usr/local/bin/run-language-tests"]

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its broad filesystem removed, then
# only the staged closure copied back.
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
    exec "$pruner" rm -rf /etc/.pwd.lock
# /tmp is deliberately left alone: jconsole's own start-up probes for a
# writable scratch directory there (see the read-only/non-root check below),
# and it needs the directory itself to exist to do so gracefully. Deleting
# it here -- as opposed to leaving the base image's stock empty 1777 /tmp in
# place -- turned a tolerated "read-only" failure into a hard "Directory
# nonexistent" one from the shell itself, on every process start-up.
COPY --from=test /staging /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LC_ALL=C \
    LD_LIBRARY_PATH=/opt/convex/lib \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(uname -m)" = x86_64 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after

# jconsole itself, run --read-only as 65532 with no tmpfs: profile.ijs's own
# directory-creation helper catches and ignores a failed mkdir (proven here,
# not assumed), so a read-only filesystem with no writable HOME is fine.
RUN test "$(printf 'echo 3+4\n' | /opt/convex/jlibrary/bin/jconsole /dev/stdin)" = 7

# TLS has to be provable inside the final image rather than at hosted
# verification time. This exercises the exact 15!:0 bindings transport.ijs
# declares, straight through to a real handshake and certificate
# verification against a live host, using the shipped trust store.
# if./do./end. only parses inside an explicit definition -- J's control
# words are rejected at top-level immediate execution ("spelling error: fn
# (invalid inflection)"), which is why every test file's checks live inside
# a 3 : 0 main, never bare at script scope. This probe needs the same shape.
RUN printf '%s\n' \
      "load '/project/client/transport.ijs'" \
      'tls_probe=: 3 : 0' \
      "result=. ('example.com';443;1) tx_connect 15000" \
      "status=. > 0 { result" \
      "conn=. > 1 { result" \
      "if. status ~: TX_IO_OK do. echo 'TLS probe failed, status ', (\": status) [ exit 1 end." \
      'tx_close conn' \
      "echo 'TLS probe ok'" \
      ')' \
      "tls_probe ''" \
      'exit 0' \
    | /opt/convex/jlibrary/bin/jconsole /dev/stdin \
    | tee /tmp/tls-probe.out \
    && grep -Fq 'TLS probe ok' /tmp/tls-probe.out

RUN test ! -e /etc/dpkg \
    && test ! -e /etc/apt \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /busybox \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && for command_name in cc gcc g++ clang make ld as ar cmake apt apt-get dpkg \
         apk rpm curl wget nc netcat socat openssl busybox node npm npx python \
         python3 pip pip3 perl ruby php java go rustc cargo convex jq git; do \
         ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
       done

# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /staging-example /
COPY --from=test /project/examples/basics/main.ijs /opt/convex/examples/basics/main.ijs
RUN set -eux; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /project/client/tests
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# Keep the adapter last: `./run build j` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /staging-adapter /
COPY --from=test /project/client/tests/conformance/adapter.ijs /project/client/tests/conformance/adapter.ijs
RUN set -eux; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /opt/convex/examples; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid /usr/local/bin/convex-adapter \
    | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
