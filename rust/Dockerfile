# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG RUST_IMAGE=rust:1.89.0-bookworm@sha256:948f9b08a66e7fe01b03a98ef1c7568292e07ec2e4fe90d88c07bb14563c84ff
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${RUST_IMAGE} AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN apt-get update \
    && apt-get install --no-install-recommends --yes binutils file musl-tools \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add rustfmt \
    && rustup target add x86_64-unknown-linux-musl
RUN cargo fmt --manifest-path client/Cargo.toml --check
RUN cargo test --locked --manifest-path client/Cargo.toml
RUN cargo build --locked --release --target x86_64-unknown-linux-musl \
    --manifest-path client/Cargo.toml --bin convex-adapter --bin convex-example
RUN test "$(uname -m)" = x86_64 \
    && rustc --print cfg --target x86_64-unknown-linux-musl | grep -qx 'target_arch="x86_64"' \
    && file client/target/x86_64-unknown-linux-musl/release/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && file client/target/x86_64-unknown-linux-musl/release/convex-example | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && readelf -h client/target/x86_64-unknown-linux-musl/release/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
CMD ["/bin/sh", "-ec", "test \"$(uname -m)\" = x86_64 && /project/client/target/x86_64-unknown-linux-musl/release/convex-adapter <<'EOF'\n{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\nEOF"]

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260611-r0

# BusyBox supplies the verifier's required /bin/sh and POSIX text tools. The
# final rootfs receives only BusyBox, the CA bundle, and one static Rust binary;
# Alpine's apk database and package manager never cross this stage boundary.
FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN test "$(uname -m)" = x86_64 \
    && ! test -e /sbin/apk \
    && ! command -v apk \
    && for command in cargo rustc rustfmt rustup gcc cc make node python python3 npm pip curl convex; do ! command -v "$command"; done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /project/client/target/x86_64-unknown-linux-musl/release/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because `./run build rust` builds the default target.
FROM runtime-base AS runtime
COPY --from=test /project/client/target/x86_64-unknown-linux-musl/release/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
