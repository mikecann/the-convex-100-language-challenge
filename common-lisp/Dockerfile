# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG RUNTIME_IMAGE=gcr.io/distroless/base-nossl-debian12:nonroot@sha256:aab92be2973c7fa996ab6496138e8e01e8613fdf0e5084c9d9daad6e9cef68aa

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       sbcl=2:2.2.9-1 \
       file=1:5.44-3 \
       libssl3=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
    && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 \
    && sbcl --version | grep -Fqx 'SBCL 2.2.9.debian'
RUN sbcl --noinform --disable-debugger --script client/tests/json-test.lisp
RUN sbcl --noinform --disable-debugger --script client/tests/http-test.lisp
RUN sbcl --noinform --disable-debugger --script client/tests/live-test.lisp
RUN sbcl --noinform --disable-debugger --script examples/basics/main-test.lisp
RUN mkdir -p /out \
    && sbcl --dynamic-space-size 96 --control-stack-size 8 \
       --noinform --disable-debugger \
       --script client/build-adapter.lisp \
    && sbcl --dynamic-space-size 96 --control-stack-size 8 \
       --noinform --disable-debugger \
       --script client/build-example.lisp
RUN sbcl --noinform --disable-debugger --script client/tests/adapter-test.lisp
RUN file /out/convex-adapter /out/convex-example \
    | grep -Eq 'ELF 64-bit.*x86-64' \
    && /out/convex-adapter <<'EOF'
{"protocolVersion":1,"id":"hello","op":"hello"}
{"id":"close","op":"close"}
EOF

# Distroless is a real non-scratch Debian runtime base. Add only the dynamic
# libraries loaded by the saved SBCL executables and TLS, plus individual POSIX
# tools required by the shared verifier. There is no multicall binary, package
# manager, network utility, compiler frontend, or delegated runtime.
FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-base
COPY --from=test /lib/x86_64-linux-gnu/libzstd.so.1 /lib/x86_64-linux-gnu/libzstd.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build common-lisp` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
