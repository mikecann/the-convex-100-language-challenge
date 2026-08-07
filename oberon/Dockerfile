# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

# OBNC (the Oberon-07 compiler this client uses) has no Debian package: it
# translates Oberon to C and is itself built from source, then drives an
# ordinary system C compiler and linker for every module it compiles.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /src
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
       curl=8.14.1-2+deb13u4 \
       ca-certificates=20250419 \
       gcc=4:14.2.0-1 \
       make=4.4.1-2 \
       libc6-dev=2.41-12+deb13u3 \
       libgc-dev=1:8.2.8-1 \
       libssl-dev=3.5.6-1~deb13u2 \
       file=1:5.46-5 \
       binutils=2.44-3 \
       busybox-static=1:1.37.0-6+b8 \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:f672663e295df6daba53ac59a0280011732b0e7f95078d7944aa8c328b5f47ec \
    https://miasap.se/obnc/downloads/obnc_0.17.2.tar.gz /tmp/obnc.tar.gz
RUN cd /tmp && tar xzf obnc.tar.gz && cd obnc-0.17.2 && ./build && ./install \
    && cd / && rm -rf /tmp/obnc.tar.gz /tmp/obnc-0.17.2 \
    && obnc -v 2>&1 | grep -Fq '0.17.2'
ENV OBNC_IMPORT_PATH=/src/client
COPY client ./client
COPY examples ./examples
RUN echo "LDLIBS=-lssl -lcrypto" > client/ConvexShim.env

# obnc has no separate "compile only" mode and no package manager: obnc
# MODULE.obn -o OUTFILE compiles that module, transitively compiles every
# module it imports that is not already cached, and links a complete
# executable in one step. ConvexShim is the only module "implemented in C"
# (see ConvexShim.obn); obnc generates its C interface header and compiles
# the hand written ConvexShim.c beside it, matching the standard library's
# own C-implemented modules. Building the five programs below in one RUN,
# in dependency order, means every later build reuses the earlier ones'
# already-compiled shared modules (ConvexJSON, ConvexSync, and so on)
# instead of recompiling them.
#
# client/tests/ConvexFixture is a test-only loopback WebSocket *server*
# fixture (not part of the public client) used by TestLive to prove the
# Live acceptance failure modes AGENTS.md calls out.
RUN set -eu; \
    cd client/tests; \
    obnc TestJSON.obn -o /out-test-json; \
    obnc FixtureServer.obn -o /out-fixture-server; \
    obnc TestLive.obn -o /out-test-live; \
    cd conformance; \
    obnc ConvexAdapter.obn -o /out-adapter; \
    cd /src/examples/basics; \
    obnc main.obn -o /out-example; \
    file /out-adapter | grep -Fq 'ELF 64-bit LSB pie executable, x86-64'; \
    file /out-example | grep -Fq 'ELF 64-bit LSB pie executable, x86-64'; \
    strip /out-adapter /out-example

# TestJSON is a deterministic offline unit test of the JSON module,
# including the integral-decimal-number regression ("0.0" must decode,
# "1.5" must not). TestLive runs against FixtureServer, a second test-only
# process, because proving a real reconnect needs two independently
# scheduled peers; see client/tests/TestLive.obn for the full scripted
# scenario. The adapter smoke test proves the NDJSON protocol's
# hello/close lifecycle end to end.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    /out-test-json; \
    /out-fixture-server > /tmp/fixture.log 2>&1 & \
    fixture_pid=$!; \
    sleep 0.3; \
    live_status=0; \
    /out-test-live || live_status=$?; \
    wait "$fixture_pid" || true; \
    cat /tmp/fixture.log; \
    test "$live_status" -eq 0; \
    printf '%s\n' \
      '{"id":"h1","protocolVersion":1,"op":"hello"}' \
      '{"id":"c1","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:9 /out-adapter > /tmp/adapter-smoke.ndjson; \
    grep -Fq '"id":"h1"' /tmp/adapter-smoke.ndjson; \
    grep -Fq '"type":"ready"' /tmp/adapter-smoke.ndjson; \
    grep -Fq '"language":"oberon"' /tmp/adapter-smoke.ndjson; \
    grep -Fqx '{"id":"c1","type":"closed"}' /tmp/adapter-smoke.ndjson

# Stage the exact runtime library closure the two final binaries need,
# computed from ldd rather than guessed, plus the handful of coreutils the
# shared policy verifier requires and their own transitive libraries.
# libnss_dns/libnss_files/libresolv are loaded by glibc's NSS at connect
# time (cshim.c calls getaddrinfo to resolve the deployment host) and do
# not appear in an ELF's own dependency list, so they are added explicitly.
RUN set -eu; \
    mkdir -p /out/lib /out/ossl-modules; \
    cp /out-adapter /out/convex-adapter; \
    cp /out-example /out/convex-example; \
    cp /bin/dash /out/sh; \
    for tool in id cat cut head tail tr sort uniq wc uname grep sed mawk; do \
      cp "/usr/bin/$tool" "/out/$tool"; \
    done; \
    for binary in /out/convex-adapter /out/convex-example /out/sh \
                  /out/id /out/cat /out/cut /out/head /out/tail /out/tr \
                  /out/sort /out/uniq /out/wc /out/uname /out/grep /out/sed /out/mawk; do \
      ldd "$binary" | awk '{ for (field = 1; field <= NF; field++) if ($field ~ /^\//) print $field }'; \
    done | sort -u > /tmp/runtime-library-paths; \
    while IFS= read -r library; do \
      cp -L "$library" "/out/lib/$(basename "$library")"; \
    done < /tmp/runtime-library-paths; \
    for library in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -L "/usr/lib/x86_64-linux-gnu/$library" "/out/lib/$library"; \
    done; \
    cp -L /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /out/ld-linux-x86-64.so.2; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /out/ossl-modules/legacy.so; \
    cp /etc/ssl/certs/ca-certificates.crt /out/ca-certificates.crt; \
    cp /etc/ssl/openssl.cnf /out/openssl.cnf; \
    cp /etc/nsswitch.conf /out/nsswitch.conf; \
    chmod 0555 /out/convex-adapter /out/convex-example
CMD ["/bin/sh", "-c", "true"]

# Begin from a pinned, non-scratch Debian image, remove everything with a
# temporary static helper, then reconstruct only the reviewed runtime
# closure. This proves nothing survives from the build image by omission
# rather than by remembering to delete each unwanted thing.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) "$pruner" rm -rf "$path" ;; esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /out/lib/ /lib/x86_64-linux-gnu/
COPY --from=test /out/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /out/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /out/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /out/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /out/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /out/sh /bin/sh
COPY --from=test /out/id /usr/bin/id
COPY --from=test /out/cat /usr/bin/cat
COPY --from=test /out/cut /usr/bin/cut
COPY --from=test /out/head /usr/bin/head
COPY --from=test /out/tail /usr/bin/tail
COPY --from=test /out/tr /usr/bin/tr
COPY --from=test /out/sort /usr/bin/sort
COPY --from=test /out/uniq /usr/bin/uniq
COPY --from=test /out/wc /usr/bin/wc
COPY --from=test /out/uname /usr/bin/uname
COPY --from=test /out/grep /usr/bin/grep
COPY --from=test /out/sed /usr/bin/sed
COPY --from=test /out/mawk /usr/bin/awk
# OpenSSL's compiled-in OPENSSLDIR on Debian is /usr/lib/ssl, which the full
# OS image reaches only via a symlink to /etc/ssl that this pruned image
# does not recreate. SSL_CTX_set_default_verify_paths() honours these two
# environment variables ahead of that compiled-in default, so they point it
# straight at the CA bundle actually installed above instead.
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    PATH=/usr/local/bin:/usr/bin:/bin
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
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && for command_name in obnc obnc-compile obnc-path gcc cc clang make ld as apt apt-get dpkg \
         curl wget nc netcat openssl node python python3 ruby perl java php go \
         rustc cargo npm pip convex busybox; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build oberon` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"id":"h1","protocolVersion":1,"op":"hello"}' \
         '{"id":"c1","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
       | grep -Fqx '{"id":"c1","type":"closed"}'
# The plaintext check above never asks OpenSSL to do anything: it proves the
# binary runs, not that this pruned image's CA bundle, OpenSSL
# configuration, and provider modules actually work. This client only wraps
# a connection in TLS after a plain TCP connect succeeds (see TlsWrap in
# client/ConvexShim.c), so a refused local port would never reach OpenSSL at
# all; a real external host is required to force the handshake, certificate
# verification, and hostname check to actually run in this exact pruned
# image. example.com is not a Convex deployment, so a POST to it completes
# as an ordinary non-Convex HTTP response rather than a Convex value -
# either an intact response this client does not recognise as a Convex
# envelope, or (observed in practice: example.com answers a POST with a 405
# error page using Transfer-Encoding: chunked) a framing this client
# deliberately declines to guess at rather than parse speculatively. Either
# message can only be produced after a real TLS handshake and real response
# bytes were both read, so either is proof the CA bundle, OPENSSL_CONF, and
# legacy provider are all correctly wired in this image, not just present in
# the build stage.
RUN set -eu; \
    output="$(printf '%s\n' \
         '{"id":"h1","protocolVersion":1,"op":"hello"}' \
         '{"id":"q","op":"query","path":"messages:count","args":{}}' \
         '{"id":"c1","op":"close"}' \
       | CONVEX_URL=https://example.com /usr/local/bin/convex-adapter)"; \
    printf '%s\n' "$output" | grep -Fqx '{"id":"c1","type":"closed"}'; \
    printf '%s\n' "$output" | grep -Fq '"id":"q"'; \
    printf '%s\n' "$output" | grep -Eq 'HTTP response was not valid Convex JSON|chunked transfer encoding is not supported'; \
    ! printf '%s\n' "$output" | grep -Eiq \
      'ca-certificat|openssl_conf|provider|no such file|unable to load|legacy\.so|x509 lookup|certificate verify|SSL_CTX|handshake|connect:'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
