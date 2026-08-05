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

FROM --platform=linux/amd64 swift:6.1.2-noble-slim@sha256:bf926ea857fa4e28a549bdc8ab2554d97e31bf323dce1d80594b6bce7acac19e AS runtime-base
RUN for command in swift swiftc swift-format swift-package clang gcc git npm npx node python python3 pip pip3 curl convex; do \
      ! command -v "$command" >/dev/null 2>&1 || exit 1; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
