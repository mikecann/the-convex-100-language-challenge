# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Io has no distribution package on any mainstream base image, so the VM is
# built from a pinned upstream commit. Upstream's `master` branch now targets
# WebAssembly and has removed the addon system entirely, so this client needs
# the maintained `native` branch, pinned by commit rather than by branch name.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG IO_COMMIT=3d4bc9cc6f6b45bcc334437a5fdd2359dcb767b7
ARG PARSON_COMMIT=4f3eaa6849ba62404fc5756650168bb2056d0b46

# Every stage installs from the same digest-pinned snapshot, so the constraint
# that actually matters is that the OpenSSL the transport is compiled against
# and the one it dlopens at runtime are the same series. Both stages assert
# this value rather than one of them pinning an exact apt version and the
# others trusting the archive to agree.
ARG GCC_MAJOR=12
ARG CMAKE_SERIES=3.25
ARG CLANG_FORMAT_MAJOR=14
ARG OPENSSL_SERIES=3.0

# ------------------------------------------------------------------
# Build the Io VM and the native transport boundary
# ------------------------------------------------------------------

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS builder
ARG IO_COMMIT
ARG PARSON_COMMIT
ARG GCC_MAJOR
ARG CMAKE_SERIES
ARG CLANG_FORMAT_MAJOR
ARG OPENSSL_SERIES
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       build-essential \
       cmake \
       git \
       libssl-dev \
       ca-certificates \
       clang-format-14 \
    && rm -rf /var/lib/apt/lists/*

# Assert the toolchain this client was written against. Io's CMake files
# declare cmake_minimum_required(VERSION 3.5), which CMake 4 no longer accepts,
# so the major version is a correctness constraint and not just a record. The
# OpenSSL series is asserted here and again in the runtime image, because the
# transport is compiled here and dlopened there.
RUN cc --version | head -n 1 \
    && test "$(cc -dumpversion | cut -d. -f1)" = "${GCC_MAJOR}" \
    && test "$(cmake --version | head -n 1 | cut -d' ' -f3 | cut -d. -f1,2)" = "${CMAKE_SERIES}" \
    && test "$(clang-format-14 --version | tr ' ' '\n' | grep -E '^[0-9]+\.' | cut -d. -f1)" \
       = "${CLANG_FORMAT_MAJOR}" \
    && openssl version \
    && test "$(openssl version | cut -d' ' -f2 | cut -d. -f1,2)" = "${OPENSSL_SERIES}"

# Fetch the VM at an exact commit. `deps/parson` is a submodule, so it is
# pinned separately rather than left to float with upstream.
WORKDIR /src
RUN git init io \
    && cd io \
    && git remote add origin https://github.com/IoLanguage/io.git \
    && git fetch --depth 1 origin ${IO_COMMIT} \
    && git checkout --detach FETCH_HEAD \
    && rm -rf deps/parson \
    && git init deps/parson \
    && cd deps/parson \
    && git remote add origin https://github.com/kgabis/parson.git \
    && git fetch --depth 1 origin ${PARSON_COMMIT} \
    && git checkout --detach FETCH_HEAD

WORKDIR /src/io/build
RUN cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/io .. \
    && make -j"$(nproc)" \
    && make install \
    && rm -f /opt/io/bin/io_static

# The transport boundary is one C file. `--no-undefined` turns a wrong VM
# symbol into a build failure here rather than a dlopen failure inside a
# container that has already been declared healthy.
WORKDIR /project
COPY client/convex_transport.c ./client/convex_transport.c
COPY client/.clang-format ./client/.clang-format
RUN clang-format-14 --dry-run --Werror client/convex_transport.c
RUN mkdir -p /opt/convex/lib \
    && gcc -O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter \
       -o /opt/convex/lib/libIoConvexIO.so \
       client/convex_transport.c \
       -I/src/io/libs/basekit/source \
       -I/src/io/libs/garbagecollector/source \
       -I/src/io/libs/iovm/source \
       -I/src/io/deps/parson \
       -L/opt/io/lib -Wl,-rpath,/opt/io/lib -Wl,--no-undefined \
       -liovmall -lbasekit -lgarbagecollector -lssl -lcrypto \
    && ldd /opt/convex/lib/libIoConvexIO.so \
    && ldd /opt/io/bin/io

# ------------------------------------------------------------------
# Language-local tests
# ------------------------------------------------------------------

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
RUN apt-get update \
    && apt-get install --no-install-recommends --yes libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/io /opt/io
COPY --from=builder /opt/convex /opt/convex
RUN ln -s /opt/io/bin/io /usr/local/bin/io
ENV LD_LIBRARY_PATH=/opt/io/lib \
    CONVEX_IO_TRANSPORT=/opt/convex/lib/libIoConvexIO.so
WORKDIR /project
COPY client ./client
COPY examples ./examples

# The interpreter is compiled here rather than downloaded, so assert both the
# container architecture and the ELF machine type of the artifact that will run
# the client. 62 is EM_X86_64 in the ELF header.
RUN test "$(uname -m)" = x86_64 \
    && test "$(od -An -tu1 -j18 -N1 /opt/io/bin/io | tr -d ' ')" = 62 \
    && test "$(od -An -tu1 -j18 -N1 /opt/convex/lib/libIoConvexIO.so | tr -d ' ')" = 62 \
    && test "$(io -e 'System version println')" = 20260302 \
    && io -e 'DynLib clone setPath(System getEnvironmentVariable("CONVEX_IO_TRANSPORT")) open voidCall("IoConvexIOInit", Lobby); ConvexIO version println; ConvexIO tlsVersion println'

# Formatting and parse checks stand in for a compiler front end, then the
# client, framing, hostile-peer, adapter and example suites run. Every socket
# test uses the in-process loopback peer, so no deployment is involved.
RUN io client/tests/style.io
RUN io client/tests/run.io

# The conformance executable must answer a real hello and a real close over
# NDJSON, using the exact source that ships in the runtime image.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid io client/tests/conformance/adapter.io > /tmp/adapter.ndjson \
    && grep -Fqx '{"protocolVersion":1,"id":"hello","type":"ready","language":"io","implementation":"native-io-20260302","runtime":"io-20260302"}' /tmp/adapter.ndjson \
    && grep -Fqx '{"id":"close","type":"closed"}' /tmp/adapter.ndjson

# The same NDJSON lifecycle has to work over the TCP mode the shared harness
# uses, driven here by the adapter's own transport so no extra tool is needed.
RUN io client/tests/conformance/tcp_smoke.io

# ------------------------------------------------------------------
# Minimal runtime
# ------------------------------------------------------------------
#
# The shared policy and example verifier still require /bin/sh and basic POSIX
# text tools, so this is a pruned Debian rather than scratch. Everything that
# could act as a build front end, a package manager or a second language
# runtime is removed, and the assertions below probe for them directly instead
# of trusting that they were never installed.

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
ARG OPENSSL_SERIES
RUN apt-get update \
    && apt-get install --no-install-recommends --yes libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf \
       /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config \
       /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/dpkg \
       /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper \
       /usr/bin/dpkg-query /usr/bin/dpkg-split /usr/bin/dpkg-statoverride \
       /usr/bin/dpkg-trigger /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure \
       /usr/bin/gpgv /usr/lib/apt /etc/apt /var/lib/apt /var/lib/dpkg /var/cache/apt \
       /usr/bin/perl /usr/bin/perl5.36.0 /usr/lib/x86_64-linux-gnu/perl-base \
       /usr/share/perl /usr/share/perl5 /usr/share/doc /usr/share/man
# The runtime closure is stated rather than inherited: the interpreter, the Io
# VM shared libraries it links against, the transport boundary, and the client
# source. Headers and the rest of the install prefix stay in the builder.
COPY --from=builder /opt/io/bin/io /opt/io/bin/io
COPY --from=builder /opt/io/lib /opt/io/lib
COPY --from=builder /opt/convex/lib /opt/convex/lib
COPY client/convex.io /opt/convex/client/convex.io
RUN ln -s /opt/io/bin/io /usr/local/bin/io
ENV LD_LIBRARY_PATH=/opt/io/lib \
    CONVEX_IO_TRANSPORT=/opt/convex/lib/libIoConvexIO.so \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin

# Prove that closure is complete and that the OpenSSL this image supplies is
# the same series the transport was compiled against. A missing library or a
# different provider must fail here rather than during hosted verification.
RUN for artifact in /opt/io/bin/io /opt/convex/lib/libIoConvexIO.so; do \
      if ldd "$artifact" | grep -q 'not found'; then \
        echo "incomplete runtime closure for $artifact" >&2; ldd "$artifact" >&2; exit 1; \
      fi; \
    done \
    && io -e 'Lobby doFile("/opt/convex/client/convex.io"); Convex loadTransport tlsVersion println' \
       | grep -Eq "^OpenSSL ${OPENSSL_SERIES}\\." \
    && test "$(ls /opt/convex/lib)" = libIoConvexIO.so

USER 65532:65532
# Prove the exported image really is a non-root amd64 runtime whose VM boots and
# can load the transport, and that nothing able to compile or delegate survived
# the prune. The forbidden commands are probed directly rather than assumed to
# be absent because they were never deliberately installed.
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(uname -m)" = x86_64 \
    && test "$(io -e 'System version println')" = 20260302 \
    && for forbidden in cc gcc g++ clang make cmake ld as apt apt-get dpkg perl python python3 node npm npx curl wget convex; do \
         if command -v "$forbidden" >/dev/null 2>&1; then \
           echo "unexpected command in runtime image: $forbidden" >&2; exit 1; \
         fi; \
       done \
    && io -e 'Lobby doFile("/opt/convex/client/convex.io"); Convex loadTransport tlsVersion println'

# Complete one real TLS handshake against a Convex host from the exported
# image. This is deliberately a transport probe rather than an HTTP request:
# it proves DNS, TLS 1.2+, the CA bundle, chain validation, hostname
# verification and the OpenSSL provider modules without depending on what any
# particular endpoint chooses to answer. A missing provider or certificate path
# therefore fails here rather than during hosted verification.
RUN io -e 'Lobby doFile("/opt/convex/client/convex.io"); \
      wire := Convex loadTransport; \
      handle := wire connect("api.convex.dev", 443, 1); \
      if(handle < 0, Exception raise("TLS probe could not connect: " .. wire errorText)); \
      deadline := wire monotonicMs + 30000; \
      step := wire handshake(handle); \
      while(step > 0, if(wire monotonicMs > deadline, Exception raise("TLS probe timed out")); \
        wire wait(2 ** handle, 2 ** handle, 500); step = wire handshake(handle)); \
      if(step < 0, Exception raise("TLS is broken in this image: " .. wire errorText)); \
      wire close(handle); "tls ok" println'

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.io /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.io /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
