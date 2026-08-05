# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DART_IMAGE=dart:3.7.2-sdk@sha256:ede9f598a82f87ba0d6cd9fe327c02a1c7aac69ac64528b8d1ac192b3bc4c1b2
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS busybox

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
    dart run client/tests/live_matrix_test.dart && \
    dart run client/tests/adapter_test.dart && \
    dart run client/tests/websocket_frame_test.dart && \
    mkdir -p /out && \
    dart compile exe examples/basics/main.dart -o /out/convex-dart-example && \
    dart compile exe client/tests/conformance/adapter.dart -o /out/convex-dart-adapter && \
    uname -m | grep -qx x86_64 && \
    test "$(od -An -t x1 -j 18 -N 2 /out/convex-dart-example | tr -d ' ')" = 3e00

FROM test AS runtime-rootfs
COPY --from=busybox /bin/busybox /busybox-static
RUN set -eu; \
    rm -rf /runtime; \
    mkdir -p /runtime/bin /runtime/usr/bin /runtime/etc/ssl/certs /runtime/usr/local/bin; \
    cp /busybox-static /runtime/bin/busybox; \
    ln -s busybox /runtime/bin/sh; \
    ln -s ../../bin/busybox /runtime/usr/bin/id; \
    ln -s ../../bin/busybox /runtime/usr/bin/grep; \
    { \
      ldd /out/convex-dart-example; \
      ldd /out/convex-dart-adapter; \
    } | awk '/=> \/.* \(/ { print $3 } $1 ~ /^\// { print $1 }' | sort -u | \
      while IFS= read -r library; do cp --parents "$library" /runtime; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do \
      test ! -e "$library" || cp --parents "$library" /runtime; \
    done; \
    cp /etc/ssl/certs/ca-certificates.crt /runtime/etc/ssl/certs/; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      test ! -e "$config" || cp --parents "$config" /runtime; \
    done

FROM scratch AS runtime-base
COPY --from=runtime-rootfs /runtime /
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-dart-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /out/convex-dart-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
