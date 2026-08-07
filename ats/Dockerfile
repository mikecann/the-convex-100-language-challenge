# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BUILD_IMAGE=ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
WORKDIR /src

# ats2-lang and libcjson-dev are both in Ubuntu's own universe archive --
# unlike Mercury's toolchain, no third-party repository or signing wrinkle
# at all. Pinned package versions so an archive update fails this build
# instead of silently changing the toolchain underneath it.
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      ca-certificates ats2-lang=0.4.2-1.1 libssl-dev libcjson-dev=1.7.17-1 build-essential \
      >/tmp/apt.log 2>&1 || (cat /tmp/apt.log; exit 1)
RUN test "$(uname -m)" = x86_64
RUN patscc -version

COPY client ./client
COPY examples ./examples

# ATS2's `patscc`/`patsopt` resolve a `staload` file path relative to the
# invoking working directory, not the .dats file's own directory, and a
# `--dynamics` build target may not itself contain a directory component.
# Rather than reshape the educational repository layout AGENTS.md requires
# (client/, client/tests/, client/tests/conformance/, examples/basics/)
# around that constraint, flatten the sources into one directory here,
# inside the build stage only.
RUN mkdir -p build && \
    cp client/*.sats client/*.dats build/ && \
    cp client/tests/*.dats build/ && \
    cp client/tests/conformance/*.sats client/tests/conformance/*.dats build/ && \
    cp examples/basics/*.dats build/
WORKDIR /src/build

# `patsopt --dynamics` combines every listed .dats file into one C
# translation unit (necessary: a plain per-file `--dynamic` compile leaves
# each file's own module-init storage undefined at link time), which gcc
# then compiles. `-DATS_MEMALLOC_LIBC` selects the plain-malloc allocator
# ATS's runtime needs when cJSON's tree-walk allocates through it;
# `-D_GNU_SOURCE` is required for convex_transport.dats's C shim to see
# POSIX socket declarations that glibc hides under ATS's own default
# compile flags.
RUN set -eu; \
    CFLAGS="-D_GNU_SOURCE -DATS_MEMALLOC_LIBC -std=c99 -D_XOPEN_SOURCE -I/usr/lib/ats2-postiats-0.4.2 -I/usr/lib/ats2-postiats-0.4.2/ccomp/runtime -L/usr/lib/ats2-postiats-0.4.2/ccomp/atslib/lib"; \
    LIBS="-lssl -lcrypto -lcjson"; \
    patsopt --dynamics convex_transport.dats convex_json.dats convex.dats convex_json_test.dats > convex_json_test_dats.c && \
    patsopt --dynamics convex_transport.dats convex_json.dats convex.dats client_test.dats > client_test_dats.c && \
    patsopt --dynamics convex_transport.dats convex_json.dats convex.dats adapter_logic.dats adapter_test.dats > adapter_test_dats.c && \
    patsopt --dynamics convex_transport.dats convex_json.dats convex.dats adapter_logic.dats adapter.dats > adapter_dats.c && \
    patsopt --dynamics convex_transport.dats convex_json.dats convex.dats main.dats > main_dats.c && \
    gcc $CFLAGS -o convex_json_test convex_json_test_dats.c $LIBS && \
    gcc $CFLAGS -o client_test client_test_dats.c $LIBS && \
    gcc $CFLAGS -o adapter_test adapter_test_dats.c $LIBS && \
    gcc $CFLAGS -o adapter adapter_dats.c $LIBS && \
    gcc $CFLAGS -o main main_dats.c $LIBS

RUN mkdir -p /out && cp adapter /out/convex-adapter && cp main /out/convex-example

# Resolve the full runtime shared-library closure from the two final
# binaries (ldd already flattens transitive dependencies) and stage it for
# the minimal runtime images below. ldd only reports shared-library
# dependencies, not OpenSSL 3's own runtime-loaded configuration and
# provider modules that SSL_CTX_set_default_verify_paths and the
# certificate store subsystem read at connect time -- both are staged
# explicitly, the same lesson the Mercury client in this project recorded
# after discovering it against the hosted target instead of here.
RUN set -eu; root=/rootfs; mkdir -p "$root"; \
    { ldd /out/convex-adapter; ldd /out/convex-example; } | \
      awk '$3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' | sort -u | \
      xargs -r -I{} sh -c 'cd / && cp -L --parents "$1" "$2"' sh {} "$root"; \
    if test -d "$root/lib"; then mkdir -p "$root/usr/lib"; cp -a "$root/lib/." "$root/usr/lib/"; rm -rf "$root/lib"; fi; \
    if test -d "$root/lib64"; then mkdir -p "$root/usr/lib64"; cp -a "$root/lib64/." "$root/usr/lib64/"; rm -rf "$root/lib64"; fi; \
    mkdir -p "$root/etc/ssl/certs"; cp -L /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"; \
    mkdir -p "$root/usr/lib/ssl"; cp -a /usr/lib/ssl/. "$root/usr/lib/ssl/"; \
    mkdir -p "$root/etc/ssl"; cp -L /etc/ssl/openssl.cnf "$root/etc/ssl/openssl.cnf"; \
    mkdir -p "$root/usr/lib/x86_64-linux-gnu/ossl-modules"; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules/. "$root/usr/lib/x86_64-linux-gnu/ossl-modules/"

FROM build AS test
# The `test` target is deliberately the toolchain image: it proves
# compilation and language-local behaviour before the separate minimal
# runtime is made.
CMD ["/bin/sh", "-ec", "\
    test \"$(uname -m)\" = x86_64 && \
    ./convex_json_test && \
    ./client_test && \
    ./adapter_test \
  "]

FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-base
# Debian supplies separate POSIX executables rather than a BusyBox-style
# multicall binary, so there is no applet surface hiding behind a single
# file: removing a command from PATH removes it.
RUN set -eu; \
    keep=/runtime-command-whitelist; \
    mkdir -p "$keep/usr/bin"; \
    for command_name in dash id grep sed mawk cat head tail wc cut tr sort uname find basename dirname env cp rm ln; do \
      command_path=$(command -v "$command_name"); \
      cp -L "$command_path" "$keep/usr/bin/$command_name"; \
    done; \
    "$keep/usr/bin/find" /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -exec "$keep/usr/bin/rm" -rf {} +; \
    "$keep/usr/bin/cp" -a "$keep/usr/bin/." /usr/bin/; \
    "$keep/usr/bin/ln" -s dash /usr/bin/sh; \
    "$keep/usr/bin/ln" -s mawk /usr/bin/awk; \
    /usr/bin/rm -rf "$keep" /etc/apt /var/lib/apt /var/lib/dpkg /usr/lib/apt /usr/lib/dpkg \
      /usr/lib/*perl* /usr/share/perl /usr/share/perl5 /usr/share/debconf \
      /usr/share/doc/perl* /usr/share/man/man1/perl* /usr/share/lintian; \
    find /usr/local/bin /usr/local/sbin -mindepth 1 -maxdepth 1 -exec rm -rf {} +; \
    /usr/bin/rm -f /usr/bin/cp /usr/bin/ln /usr/bin/rm /usr/bin/env
COPY --from=build /rootfs /
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    for required in sh id grep sed awk cat head tail wc cut tr sort uname find basename dirname; do command -v "$required" >/dev/null; done; \
    for forbidden in patscc patsopt atscc apt apt-get apt-cache dpkg dpkg-query perl cpan wget curl gcc cc make ld as node npm python python3 ruby php java git ssh nc socat convex; do ! command -v "$forbidden" >/dev/null 2>&1; done; \
    test ! -e /usr/bin/patscc; \
    test ! -d /var/lib/dpkg
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
