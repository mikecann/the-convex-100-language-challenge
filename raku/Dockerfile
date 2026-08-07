# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
#
# Raku client image.
#
# Layout:
#   test            Rakudo toolchain, dependency install, compile checks, unit
#                   tests, and the stdio adapter smoke probe.
#   runtime-base    Pinned Debian carrier holding only the runtime closure:
#                   MoarVM, Rakudo, the core setting, the installed
#                   distributions, the TLS closure, and the POSIX tools the
#                   shared verifier needs.
#   example-runtime The canonical example at /usr/local/bin/convex-example.
#   runtime         The conformance adapter at /usr/local/bin/convex-adapter.

ARG RAKUDO_IMAGE=rakudo-star:2024.12
ARG RUNTIME_BASE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# The rakudo-star image installs Raku system-wide under /usr rather than into
# a dedicated prefix directory: /usr/bin/raku (a symlink to rakudo),
# /usr/bin/rakudo (the interpreter, dynamically linked against libmoar.so),
# /lib/libmoar.so, /usr/share/perl6/{core,lib,runtime,site,vendor}, and
# /usr/share/nqp. There is no single directory that can be copied wholesale
# into the runtime image without also dragging in apt, dpkg, the system perl,
# and roughly 150 unrelated modules the image bundles under
# /usr/share/perl6/site; the runtime-base stage below copies exactly the
# pieces confirmed necessary instead.
ARG JSON_FAST_VERSION=0.19.1
ARG CRO_VERSION=0.8.9

FROM --platform=linux/amd64 ${RAKUDO_IMAGE} AS test
ARG JSON_FAST_VERSION
ARG CRO_VERSION
WORKDIR /project

# Fail early and loudly if the toolchain is not what the manifest claims.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    test -x /usr/bin/rakudo; \
    test "$(readlink -f /usr/bin/raku)" = /usr/bin/rakudo; \
    command -v raku; \
    command -v zef; \
    raku --version; \
    raku -e 'exit($*KERNEL.hardware eq "x86_64" ?? 0 !! 1)'

# gcc, make, and libc6-dev exist only in this stage: Cro's dependency chain
# pulls in Digest::SHA1::Native, which zef compiles from C source
# (Digest-SHA1-Native's Build.rakumod shells out to `make`). Neither the
# compiler nor zef itself reaches the runtime images; both are removed and
# then probed for below.
RUN set -eu; \
    apt-get update; \
    apt-get install --no-install-recommends --yes \
        gcc=4:12.2.0-3 \
        make=4.3-4.1 \
        libc6-dev=2.36-9+deb12u14 \
        libssl3=3.0.20-1~deb12u2; \
    rm -rf /var/lib/apt/lists/*

# Raku's OpenSSL binding asks NativeCall to dlopen the unversioned
# `libssl.so` / `libcrypto.so`, but Debian's runtime libssl3 package only
# installs the SONAME-versioned `libssl.so.3` / `libcrypto.so.3` (the
# unversioned symlink normally ships in libssl-dev, which pulls in headers
# and static libraries this image does not need). These symlinks must exist
# before the zef install below: Cro::TLS itself is precompiled as part of
# installing Cro::HTTP, and precompilation loads the native library too.
RUN set -eu; \
    ln -sf /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so; \
    ln -sf /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so

# Dependencies are installed into the default site repository, alongside the
# ~150 modules rakudo-star already bundles there (App::Prove6, DBIish, and
# the like). Cro::HTTP transitively depends on a few of those bundled
# modules (for example OO::Monitors) at versions zef considers already
# satisfied, so installing into an isolated `--to` repository silently drops
# them; the runtime-base stage copies the whole merged site tree instead and
# removes its `bin/` directory, which is where zef and prove6 live.
RUN set -eu; \
    zef install --/test \
        "JSON::Fast:ver<${JSON_FAST_VERSION}>" \
        "Cro::HTTP:ver<${CRO_VERSION}>" \
        "Cro::WebSocket:ver<${CRO_VERSION}>"; \
    zef list --installed | sort > /tmp/installed-distributions.txt; \
    cat /tmp/installed-distributions.txt

COPY client ./client
COPY examples ./examples

# client/META6.json's provides map points directly at the checked-in flat
# layout (client/Convex.rakumod, client/Convex/*.rakumod), so no reshaping
# into an ecosystem-style lib/ tree is needed: zef installs straight from
# client/, and -Iclient is exactly what a curious user gets from the example's
# own `use lib` against the checked-in tree. An earlier version of this
# Dockerfile reshaped the source into /build/dist/lib/ to match a META6.json
# that declared lib/-prefixed paths; that mismatch is exactly what broke
# `raku -c examples/basics/main.raku`, because `use lib` auto-detects a
# META6.json in the directory it is given and applies its provides mapping,
# and the raw checked-in client/ directory has never had a lib/ subdirectory.

# Compile checks come before the tests so a syntax error is reported as one.
RUN set -eu; \
    for module in client/Convex.rakumod client/Convex/*.rakumod; do \
        raku -Iclient -c "$module"; \
    done

RUN set -eu; \
    cd client; \
    zef install --/test .; \
    raku -e 'use Convex; use Convex::Live; use Convex::Adapter; say "installed distribution loads"'

# Language-local tests run against the checked-in tree directly. They are
# executed with `raku` directly rather than through prove6, so the build does
# not depend on a test harness distribution being present in the base image.
RUN set -eu; \
    for suite in client/tests/http.t client/tests/network-http.t \
        client/tests/values.t client/tests/live.t client/tests/network-live.t \
        client/tests/buffering.t \
        client/tests/output.t client/tests/conformance/adapter.t; do \
        echo "# $suite"; \
        sed '/^use lib /d' "$suite" > /tmp/raku-suite.t; \
        raku -Iclient /tmp/raku-suite.t; \
    done

RUN set -eu; \
    raku -Iclient -c examples/basics/main.raku; \
    raku -Iclient -c client/tests/conformance/adapter.raku

# The example must fail, print nothing on stdout, and explain itself on stderr
# when it has no deployment. Compilation alone is not example evidence.
RUN set -eu; \
    code=0; \
    raku -Iclient examples/basics/main.raku demo-room \
        >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# A stdio smoke probe of the real adapter engine: hello then close must produce
# a ready event and exactly one closed event, with nothing else on stdout.
RUN set -eu; \
    printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 \
        raku -Iclient client/tests/conformance/adapter.raku \
      > /tmp/adapter-probe.out 2>/tmp/adapter-probe.err; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out; \
    test "$(wc -l < /tmp/adapter-probe.out)" -eq 2

# --------------------------------------------------------------------------
# Runtime carrier
# --------------------------------------------------------------------------
FROM --platform=linux/amd64 ${RUNTIME_BASE} AS runtime-base

# Only TLS material and the POSIX text tools the shared verifier requires stay
# behind. Every package manager, compiler frontend, and other language runtime
# is removed and then probed for.
RUN set -eu; \
    apt-get update; \
    apt-get install --no-install-recommends --yes \
        ca-certificates=20230311+deb12u1 \
        libssl3=3.0.20-1~deb12u2; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf \
        /usr/bin/apt /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-config \
        /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/apt-cdrom \
        /usr/lib/apt /etc/apt /var/lib/apt /var/cache/apt \
        /usr/bin/dpkg /usr/bin/dpkg-deb /usr/bin/dpkg-divert \
        /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query \
        /usr/bin/dpkg-split /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger \
        /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure \
        /var/lib/dpkg /etc/dpkg \
        /usr/bin/perl /usr/bin/perl5* /usr/share/perl /usr/share/perl5 \
        /usr/lib/x86_64-linux-gnu/perl /usr/lib/x86_64-linux-gnu/perl-base \
        /usr/bin/gpgv /usr/share/doc /usr/share/man /usr/share/locale \
        /var/log/* ; \
    ln -sf /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so; \
    ln -sf /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so

# The Raku runtime closure: MoarVM, the raku/rakudo binaries, the core
# setting, NQP's precompiled bootstrap layer (Rakudo looks this up relative to
# its own binary at startup and refuses to run without it), and the site
# repository holding both the client's dependencies and the modules
# rakudo-star bundles by default. zef and prove6 live under site/bin and are
# the one part of that tree this image does not want.
COPY --from=test /usr/bin/rakudo /usr/bin/rakudo
COPY --from=test /usr/bin/raku /usr/bin/raku
COPY --from=test /lib/libmoar.so /lib/libmoar.so
COPY --from=test /usr/share/perl6/core /usr/share/perl6/core
COPY --from=test /usr/share/perl6/lib /usr/share/perl6/lib
COPY --from=test /usr/share/perl6/runtime /usr/share/perl6/runtime
COPY --from=test /usr/share/perl6/site /usr/share/perl6/site
COPY --from=test /usr/share/nqp /usr/share/nqp
RUN rm -rf /usr/share/perl6/site/bin

# HOME points at a path that does not exist on purpose: the shared conformance
# container runs read-only, so nothing may depend on a writable home
# repository. Every module the client loads is already installed and
# precompiled inside /usr/share/perl6.
# RAKUDO_MAX_THREADS keeps the MoarVM thread pool well inside the shared
# container's process limit.
ENV PATH=/usr/local/bin:/usr/bin:/bin \
    HOME=/nonexistent \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    RAKUDO_MAX_THREADS=8

USER 65532:65532

# Prove the policy inside the image rather than asserting it in prose. The
# Raku runtime itself is the target language interpreter -- the equivalent of
# `ruby` for Ruby -- and is the only language runtime present.
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test "$(uname -m)" = x86_64; \
    test -s "$SSL_CERT_FILE"; \
    test "$(printf 'ok\n' | cat)" = ok; \
    test "$(printf 'a:b\n' | cut -d: -f2)" = b; \
    test "$(printf 'first\nsecond\n' | head -n 1)" = first; \
    test "$(printf 'first\nsecond\n' | tail -n 1)" = second; \
    test "$(printf 'a\n' | tr a A)" = A; \
    test "$(printf 'b\na\n' | sort | head -n 1)" = a; \
    test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1; \
    printf 'needle\n' | grep -Fqx needle; \
    test "$(printf 'before\n' | sed 's/before/after/')" = after; \
    test "$(printf 'value\n' | awk '{print $1}')" = value; \
    raku -e 'exit($*KERNEL.hardware eq "x86_64" ?? 0 !! 1)'; \
    raku -e 'use Convex; use Convex::CroTransport; use Convex::CroLive; say "runtime closure loads"'; \
    for command_name in zef gcc cc clang make cmake apt apt-get dpkg curl wget \
        nc netcat node python python3 ruby perl php go rustc cargo npm pip \
        composer convex; do \
        ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
    done

# --------------------------------------------------------------------------
# Final images
# --------------------------------------------------------------------------
FROM runtime-base AS example-runtime
USER root
COPY --from=test /project/examples/basics/main.raku /usr/local/lib/convex/example.raku
# A tiny shell wrapper keeps the required entrypoint path exact while still
# letting the Raku runtime execute the canonical example source verbatim.
RUN set -eu; \
    printf '%s\n' \
        '#!/bin/sh' \
        'exec /usr/bin/raku /usr/local/lib/convex/example.raku "$@"' \
        > /usr/local/bin/convex-example; \
    chmod 555 /usr/local/bin/convex-example; \
    chmod 444 /usr/local/lib/convex/example.raku
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    code=0; \
    /usr/local/bin/convex-example demo-room >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err
ENTRYPOINT ["/usr/local/bin/convex-example"]

# The adapter is last because `./run build raku` uses the default target.
FROM runtime-base AS runtime
USER root
COPY --from=test /project/client/tests/conformance/adapter.raku /usr/local/lib/convex/adapter.raku
RUN set -eu; \
    printf '%s\n' \
        '#!/bin/sh' \
        'exec /usr/bin/raku /usr/local/lib/convex/adapter.raku "$@"' \
        > /usr/local/bin/convex-adapter; \
    chmod 555 /usr/local/bin/convex-adapter; \
    chmod 444 /usr/local/lib/convex/adapter.raku
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
      > /tmp/final-probe.out; \
    grep -Fq '"type":"ready"' /tmp/final-probe.out; \
    grep -Fq '"type":"closed"' /tmp/final-probe.out; \
    test "$(wc -l < /tmp/final-probe.out)" -eq 2
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
