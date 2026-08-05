# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG SWIFT_IMAGE=swift:6.1.2-noble@sha256:9096456b6dd5f3dcb1f64152601de3d96f40e48ac98354fefa9ffa9abf2dd6bf

FROM --platform=linux/amd64 ${SWIFT_IMAGE} AS dependencies
WORKDIR /work
COPY client/Package.swift client/Package.resolved ./
RUN swift package resolve

FROM dependencies AS test
COPY client ./
COPY examples ./examples
RUN --mount=type=cache,id=swift-amd64-build-v2,target=/work/.build \
    find . -path './.build' -prune -o -name '*.swift' -print0 | xargs -0 swift-format lint --strict && \
    swift test --configuration release && \
    test "$(uname -m)" = x86_64 && \
    swift -print-target-info | grep -q 'x86_64-unknown-linux-gnu' && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
      .build/release/convex-adapter | grep -q '"language":"swift"' && \
    mkdir -p /out && \
    cp .build/release/convex-adapter /out/convex-adapter && \
    cp .build/release/convex-example /out/convex-example

FROM test AS runtime-files
RUN set -eu; \
    mkdir -p /rootfs/bin /rootfs/usr/bin /rootfs/usr/local/bin /rootfs/etc/ssl/certs; \
    cp -L /bin/dash /rootfs/bin/sh; \
    cp -L /usr/bin/id /rootfs/usr/bin/id; \
    cp /out/convex-adapter /rootfs/usr/local/bin/convex-adapter; \
    cp /out/convex-example /rootfs/usr/local/bin/convex-example; \
    cp /etc/ssl/certs/ca-certificates.crt /rootfs/etc/ssl/certs/ca-certificates.crt; \
    for executable in /bin/dash /usr/bin/id /out/convex-adapter /out/convex-example; do ldd "$executable"; done | \
      sed -n -e 's/.*=> \(\/[^ ]*\).*/\1/p' -e 's/^[[:space:]]*\(\/[^ ]*\).*/\1/p' | \
      sort -u | xargs -r -I '{}' cp -L --parents '{}' /rootfs; \
    chmod 0555 /rootfs/bin/sh /rootfs/usr/bin/id /rootfs/usr/local/bin/convex-*; \
    test ! -e /rootfs/usr/bin/apt; \
    test ! -e /rootfs/usr/bin/dpkg; \
    test ! -e /rootfs/usr/bin/perl

FROM scratch AS runtime-base
COPY --from=runtime-files /rootfs /
ENV PATH=/usr/local/bin:/usr/bin:/bin \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
