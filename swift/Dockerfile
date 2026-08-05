# syntax=docker/dockerfile:1.7
ARG SWIFT_IMAGE=swift:6.1.2-noble@sha256:9096456b6dd5f3dcb1f64152601de3d96f40e48ac98354fefa9ffa9abf2dd6bf
FROM --platform=linux/amd64 ${SWIFT_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN mkdir -p /out && \
    swiftc client/Convex.swift client/tests/conformance/main.swift -o /out/convex-adapter && \
    swiftc -parse-as-library client/Convex.swift examples/basics/main.swift -o /out/convex-example && \
    test "$(uname -m)" = x86_64
FROM --platform=linux/amd64 swift:6.1.2-noble-slim@sha256:bf926ea857fa4e28a549bdc8ab2554d97e31bf323dce1d80594b6bce7acac19e AS runtime-base
RUN for command in swift swiftc swift-package npm npx node python python3 pip pip3 curl convex; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
