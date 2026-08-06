# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS test
WORKDIR /project
RUN apk add --no-cache zig=0.14.1-r0 file=5.46-r2 binutils=2.44-r3
COPY client ./client
COPY examples ./examples
RUN zig version | grep -Fx '0.14.1'
RUN zig fmt --check client examples
RUN zig test client/convex.zig
RUN mkdir -p /out
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl --dep convex -Mroot=client/tests/conformance/main.zig -Mconvex=client/convex.zig -femit-bin=/out/convex-adapter
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl --dep convex -Mroot=examples/basics/main.zig -Mconvex=client/convex.zig -femit-bin=/out/convex-example
RUN test "$(uname -m)" = x86_64 \
    && file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
CMD ["/bin/sh", "-ec", "/out/convex-adapter <<'EOF'\n{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\nEOF"]

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260611-r0

# Debian slim supplies separate dash/coreutils binaries rather than a
# multicall binary whose hidden applets would expand the final command surface.
FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN rm -rf /var/lib/apt /var/lib/dpkg /usr/lib/apt /usr/share/doc/apt \
        /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config \
        /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/dpkg \
        /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper \
        /usr/bin/dpkg-query /usr/bin/dpkg-reconfigure /usr/bin/dpkg-split \
        /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger /usr/sbin/dpkg-reconfigure \
    && test "$(uname -m)" = x86_64 \
    && for command in apk apt apt-get dpkg dpkg-query busybox wget nc telnet zig zigfmt gcc cc make node python python3 npm pip curl convex; do ! command -v "$command"; done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because the root build command selects the
# default Docker target when it builds a language.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
