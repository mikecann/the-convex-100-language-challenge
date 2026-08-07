# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS test
WORKDIR /project
RUN apk add --no-cache \
    hare=0.24.2-r3 harec=0.24.2-r1 qbe=1.2-r3 \
    openssl=3.5.7-r0 openssl-dev=3.5.7-r0 openssl-libs-static=3.5.7-r0 \
    musl-dev=1.2.5-r12 file=5.46-r2 binutils=2.44-r3
# Hare's build driver always shells out to the platform toolchain's `cc` to
# link, but exposes no flag of its own to request static linking. A thin `cc`
# wrapper earlier on PATH appends `-static` to every link this image performs,
# so both binaries built below (and `hare test`'s own transient test binary)
# come out statically linked against musl with no further flags anywhere else
# in this file.
RUN mkdir -p /wrap && printf '#!/bin/sh\nexec /usr/bin/cc -static "$@"\n' >/wrap/cc && chmod +x /wrap/cc
ENV PATH=/wrap:/usr/bin:/bin:/sbin:/usr/sbin
RUN hare version | grep -Fx 'hare 0.24.2-alpine'
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md
# Hare 0.24 (current when this client was written) ships no `hare fmt` or
# other blessed formatter; a community `hare-fmt` project exists but is not
# part of the toolchain this image installs. Source in this directory is
# therefore hand-formatted against the tabs-for-indentation, brace-on-same-
# line style Hare's own standard library uses throughout
# /usr/src/hare/stdlib, rather than machine-checked here.
#
# Hare resolves `use convex;` against a directory named `convex` on HAREPATH;
# this project's layout keeps the public client tree at `client/` instead, so
# the build stages below copy it into a `convex/`-named module root rather
# than reshaping the checked-in source tree around Hare's own naming
# convention.
RUN mkdir -p /build/convex && cp client/*.ha /build/convex/
# `hare test` covers the client's local, network-independent unit behaviour
# (JSON encode/decode, and every fixture-free regression in the suite). The
# three real-backend regressions in this suite (one real TLS handshake, one
# HTTP query/mutation, and one Live subscribe/reconnect) each check for an
# opt-in environment variable and no-op when it is absent, so this step
# proves everything it can without a network dependency, matching this
# project's layered split between `test` and `./run verify`/`verify-hosted`.
RUN HAREPATH=/build:/usr/src/hare/stdlib:/usr/src/hare/third-party hare test -lssl -lcrypto /build/convex
RUN mkdir -p /build/example && cp examples/basics/main.ha /build/example/
RUN mkdir -p /build/conformance && cp client/tests/conformance/main.ha /build/conformance/
RUN mkdir -p /out \
    && HAREPATH=/build:/usr/src/hare/stdlib:/usr/src/hare/third-party hare build -lssl -lcrypto -o /out/convex-example /build/example \
    && HAREPATH=/build:/usr/src/hare/stdlib:/usr/src/hare/third-party hare build -lssl -lcrypto -o /out/convex-adapter /build/conformance
RUN test "$(uname -m)" = x86_64 \
    && file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64.*statically linked' \
    && file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64.*statically linked' \
    && readelf -h /out/convex-example | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
# Prove the real adapter binary's hello/close NDJSON lifecycle at build time,
# against the exact binary shipped in /out. CONVEX_URL is a dummy value
# scoped to this one RUN: hello and close never open a network connection, so
# the adapter only needs the variable to be present.
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:9 /out/convex-adapter >/tmp/convex-adapter-hello.ndjson \
    && grep -Fq '"language":"hare"' /tmp/convex-adapter-hello.ndjson \
    && grep -Fq '"type":"closed"' /tmp/convex-adapter-hello.ndjson
# The default command only has to be an honest, CONVEX_URL-free sanity check
# rather than repeat a probe that would fail before reading a single command:
# running the adapter here with no deployment URL would abort in
# client_init before it ever sees "hello".
CMD ["/bin/sh", "-ec", "test \"$(uname -m)\" = x86_64 && echo 'hare test and the adapter hello/close probe already passed while building this image'"]

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260611-r0

# BusyBox supplies the verifier's required /bin/sh and POSIX text tools. The
# final rootfs receives only BusyBox, the CA bundle, and one statically
# linked Hare binary; Alpine's apk database and package manager, and Hare's
# own compiler and linker, never cross this stage boundary. Both static
# binaries above proved they load and verify a real TLS peer certificate
# using OpenSSL's compiled-in default provider (client/tls.ha's
# real_tls_handshake_against_a_public_host regression), so the CA bundle is
# the only runtime dependency this image needs to add for TLS to keep
# working here.
FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN test "$(uname -m)" = x86_64 \
    && ! test -e /sbin/apk \
    && ! command -v apk \
    && for command in hare harec qbe gcc cc make node python python3 npm pip curl convex; do \
         ! command -v "$command" >/dev/null 2>&1; \
       done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because the root build command selects the
# default Docker target when it builds a language.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
