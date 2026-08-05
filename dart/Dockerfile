# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DART_IMAGE=dart:3.7.2-sdk@sha256:ede9f598a82f87ba0d6cd9fe327c02a1c7aac69ac64528b8d1ac192b3bc4c1b2
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${DART_IMAGE} AS test
WORKDIR /work
ENV PATH=/usr/lib/dart/bin:${PATH}
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md

# The test stage contains the SDK, formatter and compiler. No Dart tooling is
# copied into either final image.
RUN dart format --set-exit-if-changed client examples && \
    dart analyze client examples && \
    dart run client/tests/client_test.dart && \
    mkdir -p /out && \
    dart compile exe examples/basics/main.dart -o /out/convex-dart-example && \
    dart compile exe client/tests/conformance/adapter.dart -o /out/convex-dart-adapter && \
    uname -m | grep -qx x86_64 && \
    test "$(od -An -t x1 -j 18 -N 2 /out/convex-dart-example | tr -d ' ')" = 3e00

FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-rootfs
RUN apt-get update && apt-get install --yes --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
    rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config /usr/bin/apt-get /usr/bin/apt-mark /usr/bin/dpkg* && \
    test -x /bin/sh && command -v id && command -v grep

FROM runtime-rootfs AS runtime-base
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-dart-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /out/convex-dart-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
