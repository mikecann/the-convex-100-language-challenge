# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG RUST_IMAGE=rust:1.89.0-bookworm@sha256:948f9b08a66e7fe01b03a98ef1c7568292e07ec2e4fe90d88c07bb14563c84ff
FROM ${RUST_IMAGE} AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN apt-get update \
    && apt-get install --no-install-recommends --yes musl-tools \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add rustfmt \
    && rustup target add x86_64-unknown-linux-musl
RUN cargo fmt --manifest-path client/Cargo.toml
RUN cargo test --manifest-path client/Cargo.toml
RUN cargo build --release --target x86_64-unknown-linux-musl --manifest-path client/Cargo.toml --bin convex-adapter --bin convex-example
RUN test "$(uname -m)" = x86_64
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS runtime-base
RUN apk add --no-cache ca-certificates=20260611-r0
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=test /project/client/target/x86_64-unknown-linux-musl/release/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=test /project/client/target/x86_64-unknown-linux-musl/release/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
