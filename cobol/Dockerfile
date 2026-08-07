# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------
# test: lint, unit tests, and the two executables.
# ---------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
# The pinned version (`4.0~early_dev-3.0`) does not exist in the Debian
# bookworm archive; `apt-cache madison gnucobol4` there shows only
# `4.0~early~20200606-6+b1`. GnuCOBOL 4 itself (the early-dev branch) is
# genuinely present in bookworm/main -- gnucobol3 was never needed -- the
# original pin just named a version string that was never published.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gnucobol4=4.0~early~20200606-6+b1 \
       gcc=4:12.2.0-3 \
       libssl-dev=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
       binutils=2.40-2 \
    && rm -rf /var/lib/apt/lists/*
RUN test "$(uname -m)" = x86_64 \
    && cobc --version | head -n 1

COPY client ./client
COPY examples ./examples

# COBOL has no canonical formatter. The repository standard for this
# client is free-format, four space indentation, no tabs, and no line
# beyond 79 columns; that is enforced here, and cobc -Wall carries the
# actual language diagnostics.
RUN set -eu; \
    for f in $(find client examples -name '*.cbl' -o -name '*.cpy'); do \
      if grep -q "$(printf '\t')" "$f"; then \
        echo "tab character in $f" >&2; exit 1; \
      fi; \
      if grep -qE ' +$' "$f"; then \
        echo "trailing whitespace in $f" >&2; exit 1; \
      fi; \
      if awk 'length($0)>79 {found=1} END {exit !found}' "$f"; then \
        echo "line over 79 columns in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS cobol source layout"

# One place defines the module list so the three link steps cannot
# drift apart.
ENV CVX_MODULES="client/convex.cbl client/convex-json.cbl \
client/convex-http.cbl client/convex-ws.cbl client/convex-util.cbl"
ENV CVX_CFLAGS="-free -fstatic-call -Wall -I client"

RUN mkdir -p /build /out

# Syntax-only pass first, so a language diagnostic is reported without
# being tangled up in link errors.
RUN set -eu; \
    for f in ${CVX_MODULES} client/tests/test-units.cbl \
             client/tests/test-http-fixtures.cbl \
             client/tests/test-ws-fixtures.cbl \
             client/tests/test-live-fixtures.cbl \
             client/tests/conformance/adapter.cbl \
             client/tests/conformance/test-adapter-memory.cbl \
             examples/basics/main.cbl; do \
      cobc -free -fsyntax-only -Wall -I client "$f"; \
    done; \
    echo "PASS cobc syntax and warnings"

# Deterministic unit tests: JSON, base64, timestamps, UTF-8.
RUN cobc -x ${CVX_CFLAGS} -o /build/test-units \
       client/tests/test-units.cbl ${CVX_MODULES} \
       client/convex-native.c -lssl -lcrypto \
    && /build/test-units

# Socket-level tests against hostile peers. The fixture translation
# unit is linked only into these binaries, never into the two shipped
# executables; that is asserted below.
ENV CVX_FIXTURE="client/tests/fixtures/convex-fixture.c"

# HTTP: status classification through the public client entry, plus
# chunked, oversized, conflicting, truncated, dribbled, and stalled
# responses driven byte by byte.
RUN cobc -x ${CVX_CFLAGS} -o /build/test-http-fixtures \
       client/tests/test-http-fixtures.cbl ${CVX_MODULES} \
       client/convex-native.c ${CVX_FIXTURE} -lssl -lcrypto \
    && /build/test-http-fixtures

# WebSocket framing: fragmentation, control frames, malformed frames,
# oversized declared lengths, and parser resumability across a timeout.
RUN cobc -x ${CVX_CFLAGS} -o /build/test-ws-fixtures \
       client/tests/test-ws-fixtures.cbl ${CVX_MODULES} \
       client/convex-native.c ${CVX_FIXTURE} -lssl -lcrypto \
    && /build/test-ws-fixtures

# Live: five real reconnect cycles with generation and query-set
# barriers, QueryFailed recovery, and stale-relay rejection, against a
# scripted sync peer that speaks the real handshake.
RUN cobc -x ${CVX_CFLAGS} -o /build/test-live-fixtures \
       client/tests/test-live-fixtures.cbl ${CVX_MODULES} \
       client/convex-native.c ${CVX_FIXTURE} -lssl -lcrypto \
    && /build/test-live-fixtures

# The canonical example and the conformance adapter, from the same
# client sources the tests just exercised.
RUN cobc -x ${CVX_CFLAGS} -o /out/convex-example \
       examples/basics/main.cbl ${CVX_MODULES} \
       client/convex-native.c -lssl -lcrypto \
    && cobc -x ${CVX_CFLAGS} -o /out/convex-adapter \
       client/tests/conformance/adapter.cbl ${CVX_MODULES} \
       client/convex-native.c -lssl -lcrypto \
    && file /out/convex-example /out/convex-adapter \
       | grep -Eq 'ELF 64-bit.*x86-64'

# The example must refuse to run without a deployment and must print
# nothing at all on stdout when it fails.
RUN set -eu; \
    code=0; \
    /out/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err; \
    echo "PASS example refuses an unconfigured deployment"

# The adapter must complete a hello/close exchange with no network.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"bye","op":"close"}' \
    | /out/convex-adapter > /tmp/adapter.out \
    && grep -Fq '"type":"ready"' /tmp/adapter.out \
    && grep -Fq '"language":"cobol"' /tmp/adapter.out \
    && grep -Fq '"type":"closed"' /tmp/adapter.out \
    && echo "PASS adapter hello and clean close"

# Static footprint check. Every buffer in this client lives in
# WORKING-STORAGE, so the ceiling is visible in the binary rather than
# depending on what a peer sends.
RUN size -A /out/convex-adapter | awk '/\.bss/ {print "bss bytes:", $2}' \
    && size -A /out/convex-adapter \
       | awk '/\.bss/ {if ($2 > 134217728) exit 1}' \
    && echo "PASS static footprint below the shared 128 MiB limit"

# The shipped executables must not carry the fixture harness. If any
# fixture symbol survived into them, the link lines above are wrong.
RUN set -eu; \
    for binary in /out/convex-adapter /out/convex-example; do \
      if nm -C "$binary" 2>/dev/null | grep -q 'cvx_fixture_'; then \
        echo "fixture harness leaked into $binary" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS no fixture harness in the shipped executables"

# Run the real adapter under a controller that never reads its stdout,
# feeding near-maximum command lines, and measure resident memory. The
# adapter owns no output queue, so a stopped reader must block it in
# the kernel rather than accumulate anything in the process.
RUN cobc -x ${CVX_CFLAGS} -o /build/test-adapter-memory \
       client/tests/conformance/test-adapter-memory.cbl ${CVX_MODULES} \
       client/convex-native.c ${CVX_FIXTURE} -lssl -lcrypto \
    && ADAPTER_BINARY=/out/convex-adapter /build/test-adapter-memory

# ---------------------------------------------------------------------
# runtime-base: start from the pinned image, remove its filesystem with
# a temporary static helper, then copy back only the declared closure.
# ---------------------------------------------------------------------
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
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /etc/gnucobol /lib/x86_64-linux-gnu /lib64 \
      /usr/bin /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin; \
    exec "$pruner" rm -rf /tmp

COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/libdl.so.2
# GnuCOBOL runtime library. The client is compiled, not interpreted;
# libcob is the language runtime it links against, and it exposes no
# compiler or build frontend of its own. libcob.so.5 is a symlink to
# the real libcob.so.5.0.0 (the pinned gnucobol4/libcob5 packages ship
# soname 5, not 4), so both are copied: the loader opens the SONAME,
# which then resolves through the symlink to the real file.
COPY --from=test /usr/lib/x86_64-linux-gnu/libcob.so.5 /usr/lib/x86_64-linux-gnu/libcob.so.5
COPY --from=test /usr/lib/x86_64-linux-gnu/libcob.so.5.0.0 /usr/lib/x86_64-linux-gnu/libcob.so.5.0.0
# libcob itself links against GMP (COBOL's arbitrary-precision decimal
# arithmetic) and ncurses/tinfo (its optional screen-handling support,
# linked in regardless of whether this client's programs ever use
# ACCEPT/DISPLAY screen sections). Confirmed with ldd against the
# compiled convex-adapter and convex-example binaries, not assumed.
COPY --from=test /usr/lib/x86_64-linux-gnu/libgmp.so.10 /usr/lib/x86_64-linux-gnu/libgmp.so.10
COPY --from=test /usr/lib/x86_64-linux-gnu/libncursesw.so.6 /usr/lib/x86_64-linux-gnu/libncursesw.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
# libcob resolves its runtime configuration (default.conf and the
# dialect files it can select) from COB_CONFIG_DIR. The pinned
# gnucobol4 package installs these directly under /etc/gnucobol rather
# than under /usr/share/gnucobol, so that whole small directory of
# text files is copied as-is; the pruned filesystem still keeps only
# what is actually loaded.
COPY --from=test /etc/gnucobol /etc/gnucobol
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
# The shared policy and example verifier still require /bin/sh and a
# few POSIX text tools in runtime images.
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
# sed links against libacl for its extended-attribute-aware file mode;
# nothing else copied here needs it.
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1

ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    COB_CONFIG_DIR=/etc/gnucobol \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532

# Prove the runtime is what it claims: the right user and architecture,
# a working POSIX surface, a real CA bundle, and no compiler, package
# manager, downloader, or delegated language runtime anywhere on PATH.
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
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /etc/dpkg \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /busybox \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && for command_name in cobc cobcrun cob-config gcc cc clang make cmake \
         ld as apt apt-get dpkg curl wget nc netcat openssl node python \
         python3 ruby perl java php go rustc cargo npm pip convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done \
    && echo "PASS runtime policy"

# ---------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
# Exercise the real entrypoint from the final image. Without a
# deployment it must exit 1 and print nothing on stdout; a missing
# binary or a broken runtime closure fails here rather than during
# hosted verification.
# /tmp was pruned and this stage runs as 65532, so the probe keeps
# everything in shell variables rather than touching the filesystem.
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    code=0; \
    out=$(/usr/local/bin/convex-example 2>/dev/null) || code=$?; \
    test "$code" -eq 1; \
    test -z "$out"; \
    err=$(/usr/local/bin/convex-example 2>&1 >/dev/null || true); \
    printf '%s\n' "$err" | grep -Fq 'CONVEX_URL is required'; \
    echo "PASS example entrypoint runs from the minimal image"
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last: `./run build cobol` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"bye","op":"close"}' \
       | /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
