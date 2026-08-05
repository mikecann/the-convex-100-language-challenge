# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG CRYSTAL_IMAGE=crystallang/crystal:1.14.1-alpine@sha256:e99593ba1bb7cec5bc686d46523217c09617e3b935588841b7f7961fc710a3ce
FROM ${CRYSTAL_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN crystal tool format --check client examples
RUN crystal build --release --static --no-debug examples/basics/main.cr -o /tmp/convex-example
RUN crystal build --release --static --no-debug client/tests/conformance/adapter.cr -o /tmp/convex-adapter
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | CONVEX_URL=http://127.0.0.1 /tmp/convex-adapter | grep -F '"language":"crystal"'

FROM ${CRYSTAL_IMAGE} AS build
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN mkdir -p /out && crystal build --release --static --no-debug examples/basics/main.cr -o /out/convex-example && crystal build --release --static --no-debug client/tests/conformance/adapter.cr -o /out/convex-adapter

FROM alpine:3.20.3@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a AS runtime
RUN addgroup -S -g 65532 app && adduser -S -D -H -u 65532 -G app app && apk add --no-cache ca-certificates
COPY --from=build /out/convex-example /usr/local/bin/convex-example
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
RUN chmod 0555 /usr/local/bin/convex-example /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]

FROM runtime AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]
