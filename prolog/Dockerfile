# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG SWIPL_IMAGE=swipl:9.2.8@sha256:58a263f0ff5d13d54518e7b05e11eb68d2022825112eb2c472a6c8e124e7872c
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:362e64223cc0da95422b3b13c045186fc0a81250e765d31c025fbddf257f6143

FROM --platform=linux/amd64 ${SWIPL_IMAGE} AS build
WORKDIR /src
COPY client ./client
COPY examples ./examples

# SWI's saved executables are native launchers.  The checked-in source remains
# readable Prolog while the runtime receives neither swipl nor its compiler.
RUN test "$(uname -m)" = x86_64 && \
    swipl -q -g "[client/tests/client_test],run_tests,halt" && \
    swipl -q -g "[client/tests/conformance/adapter_test],run_tests,halt" && \
    mkdir -p /out && \
    swipl -q -g "consult('examples/basics/main.pl'),qsave_program('/out/convex-example',[stand_alone(true),goal(main),toplevel(halt)]),halt" && \
    swipl -q -g "consult('client/tests/conformance/adapter.pl'),qsave_program('/out/convex-adapter',[stand_alone(true),goal(convex_adapter:main),toplevel(halt)]),halt"

# Copy the SWI engine and only the shared-object closure that the two saved
# programs load.  There is intentionally no swipl executable in this rootfs.
RUN set -eu; root=/rootfs; mkdir -p "$root"; \
    mkdir -p "$root/usr/lib"; cp -a /usr/lib/swipl "$root/usr/lib/"; \
    rm -rf "$root/usr/lib/swipl/bin" "$root/usr/lib/swipl/include" "$root/usr/lib/swipl/cmake" "$root/usr/lib/swipl/demo" "$root/usr/lib/swipl/customize"; \
    { ldd /out/convex-example /out/convex-adapter; find /usr/lib/swipl -type f -name '*.so' -exec ldd {} \; ; } | \
      awk '$3 ~ /^\// {print $3} $1 ~ /^\// {path=$1; sub(/:$/, "", path); print path}' | sort -u | sed 's#^/##' | \
      xargs -r -I{} sh -c 'cd / && cp -L --parents "$1" "$2"' sh {} "$root"; \
    # bookworm-slim uses /lib and /lib64 symlinks into /usr.  Merge the
    # copied dynamic loader closure into those destinations before COPY.
    if test -d "$root/lib"; then mkdir -p "$root/usr/lib"; cp -a "$root/lib/." "$root/usr/lib/"; rm -rf "$root/lib"; fi; \
    if test -d "$root/lib64"; then mkdir -p "$root/usr/lib64"; cp -a "$root/lib64/." "$root/usr/lib64/"; rm -rf "$root/lib64"; fi; \
    mkdir -p "$root/etc/ssl/certs"; cp -L /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"

FROM build AS test
# The `test` target is deliberately the toolchain image: it proves formatting
# and language-local behaviour before the separate minimal runtime is made.
CMD ["/bin/sh", "-ec", "swipl -q -g \"[client/tests/client_test],run_tests,halt\" && swipl -q -g \"[client/tests/conformance/adapter_test],run_tests,halt\""]

FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-base
# Debian supplies /bin/sh and the POSIX text tools required by the shared
# verifier.  Remove its installer/database before copying the closed runtime.
RUN rm -f /usr/bin/apt /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-config /usr/bin/apt-mark /usr/bin/dpkg /usr/bin/dpkg-query /usr/bin/dpkg-deb && \
    rm -rf /etc/apt /var/lib/apt /var/lib/dpkg
COPY --from=build /rootfs /
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    for required in sh id grep; do command -v "$required" >/dev/null; done; \
    for forbidden in swipl plld qsave_program apt apt-get dpkg gcc cc make node npm python python3 curl convex; do ! command -v "$forbidden" >/dev/null 2>&1; done; \
    test ! -e /usr/lib/swipl/bin/x86_64-linux/swipl
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
