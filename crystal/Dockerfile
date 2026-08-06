# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG CRYSTAL_IMAGE=crystallang/crystal:1.14.1-alpine@sha256:e99593ba1bb7cec5bc686d46523217c09617e3b935588841b7f7961fc710a3ce
ARG ALPINE_IMAGE=alpine:3.20.3@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23
FROM ${CRYSTAL_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN crystal tool format --check client examples
RUN test "$(uname -m)" = x86_64
RUN crystal build --release --static --no-debug examples/basics/main.cr -o /tmp/convex-example
RUN crystal build --release --static --no-debug client/tests/conformance/adapter.cr -o /tmp/convex-adapter
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | CONVEX_URL=http://127.0.0.1 /tmp/convex-adapter | grep -F '"language":"crystal"'

FROM ${CRYSTAL_IMAGE} AS build
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 && mkdir -p /out && crystal build --release --static --no-debug examples/basics/main.cr -o /out/convex-example && crystal build --release --static --no-debug client/tests/conformance/adapter.cr -o /out/convex-adapter

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260413-r0

# BusyBox supplies only the shell and POSIX tools the shared verifier needs.
# Alpine's package database and apk executable stop at the certificates stage.
FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN test "$(uname -m)" = x86_64 \
    && ! test -e /sbin/apk \
    && ! command -v apk \
    && for command in crystal shards npm npx node python python3 pip pip3 curl convex gcc cc clang make; do ! command -v "$command"; done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build --chmod=0555 /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep runtime last because ./run build crystal builds the default target.
FROM runtime-base AS runtime
COPY --from=build --chmod=0555 /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
