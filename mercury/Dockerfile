# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BUILD_IMAGE=ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
WORKDIR /src

# Mercury has no Ubuntu-archive package; it ships from the language's own
# Debian/Ubuntu repository (dl.mercurylang.org), maintained by the Mercury
# release manager. That repository's signing key is a personal GPG key that
# has since expired, which apt treats as "unsigned" regardless of the key's
# actual origin -- there is no proprietary license or cost involved, only a
# stale signature. The package's own sha512 is not published per-build, so
# the mitigation here is to pin the exact package version below rather than
# floating on whatever "mercury-recommended" resolves to on the day of a
# rebuild; an unexpected version bump fails the build instead of silently
# changing the toolchain underneath this image.
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      ca-certificates wget gnupg software-properties-common build-essential libssl-dev \
      >/tmp/apt-base.log 2>&1 || (cat /tmp/apt-base.log; exit 1)
RUN echo "deb [trusted=yes] http://dl.mercurylang.org/deb/ noble main" \
      > /etc/apt/sources.list.d/mercury.list && \
    apt-get update -qq >/tmp/apt-mercury.log 2>&1 || (cat /tmp/apt-mercury.log; exit 1)
RUN apt-get install -y -qq --no-install-recommends \
      mercury-recommended=22.01.8-1~noble \
      >/tmp/apt-mercury-install.log 2>&1 || (cat /tmp/apt-mercury-install.log; exit 1)
RUN test "$(uname -m)" = x86_64
RUN mmc --version

COPY client ./client
COPY examples ./examples

# Mercury's `mmc --make` resolves each build target's own .m file only in
# its search directories, and a make target may not itself contain a
# directory component -- there is no ecosystem convention here for a
# multi-directory source tree the way Cargo or Cabal have one. Rather than
# reshape the educational repository layout AGENTS.md requires (client/,
# client/tests/, client/tests/conformance/, examples/basics/) around that
# constraint, flatten the sources into the toolchain's expected single
# directory here, inside the build stage only.
RUN mkdir -p build && \
    cp client/*.m build/ && \
    cp client/tests/*.m build/ && \
    cp client/tests/conformance/*.m build/ && \
    cp examples/basics/*.m build/
WORKDIR /src/build

# Every compiled artefact -- unit tests, the conformance adapter, and the
# canonical example -- is built from the exact same checked-in sources the
# README and website display. `-D_GNU_SOURCE` is required for the C shim in
# convex_transport.m to see POSIX socket declarations (glibc hides them
# under Mercury's own default compile flags); it affects only that one
# translation unit's C, not the Mercury source.
RUN mmc --cflag -D_GNU_SOURCE --make --ld-flags "-lssl -lcrypto" \
      convex_json_test client_test adapter_test adapter main

RUN mkdir -p /out && cp adapter /out/convex-adapter && cp main /out/convex-example

# Resolve the full runtime shared-library closure from the two final
# binaries (ldd already flattens transitive dependencies, so one pass is
# enough) and stage it for the minimal runtime images below. This is the
# same "carry exactly what was built, not what the base image happens to
# ship" approach the other C-backed clients in this project use, and it
# keeps the runtime images working regardless of Debian/Ubuntu glibc drift.
RUN set -eu; root=/rootfs; mkdir -p "$root"; \
    { ldd /out/convex-adapter; ldd /out/convex-example; } | \
      awk '$3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' | sort -u | \
      xargs -r -I{} sh -c 'cd / && cp -L --parents "$1" "$2"' sh {} "$root"; \
    if test -d "$root/lib"; then mkdir -p "$root/usr/lib"; cp -a "$root/lib/." "$root/usr/lib/"; rm -rf "$root/lib"; fi; \
    if test -d "$root/lib64"; then mkdir -p "$root/usr/lib64"; cp -a "$root/lib64/." "$root/usr/lib64/"; rm -rf "$root/lib64"; fi; \
    mkdir -p "$root/etc/ssl/certs"; cp -L /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"

FROM build AS test
# The `test` target is deliberately the toolchain image: it proves
# compilation and language-local behaviour before the separate minimal
# runtime is made. Mercury's own build already checked determinism and mode
# declarations for every predicate; this stage runs what those declarations
# promised.
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
    for forbidden in mmc mercury_compile apt apt-get apt-cache dpkg dpkg-query perl cpan wget curl gcc cc make ld as node npm python python3 ruby php java git ssh nc socat convex; do ! command -v "$forbidden" >/dev/null 2>&1; done; \
    test ! -e /usr/bin/mmc; \
    test ! -d /var/lib/dpkg
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
