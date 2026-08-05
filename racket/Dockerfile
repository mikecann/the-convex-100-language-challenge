# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG RACKET_COMMIT=b10ecfb8311fca2d42636eea2ca12aff0b76b208
ARG RACKET_RELEASE=8.10

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS toolchain
ARG RACKET_COMMIT
ARG RACKET_RELEASE

# Packaged Racket CS and precise-GC BC abort under Docker Desktop's amd64
# translation on this host. Racket's own BC conservative-GC target, built with
# its JIT and futures disabled, is a genuine x86_64 runtime and runs reliably.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      ca-certificates build-essential git liblz4-dev libssl-dev m4 uuid-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git init /build/racket \
    && git -C /build/racket remote add origin https://github.com/racket/racket.git \
    && git -C /build/racket fetch --depth 1 origin "${RACKET_COMMIT}" \
    && git -C /build/racket checkout --detach FETCH_HEAD \
    && test "$(git -C /build/racket rev-parse HEAD)" = "${RACKET_COMMIT}"

# Nested libffi make loses GNU make's parallel jobserver descriptor under this
# amd64 translation path. The serial target is the proven deterministic build.
RUN mkdir -p /build/racket/racket/src/build/bc \
    && cd /build/racket/racket/src/build/bc \
    && ../../bc/configure \
      --disable-jit --disable-futures --disable-gracket \
      --enable-bcdefault --disable-useprefix --enable-origtree \
    && make cgc \
    && make install-cgc \
    && /build/racket/racket/bin/racketcgc -v \
    && /build/racket/racket/bin/racketcgc -e '(displayln (+ 40 2))'

# The release-specific catalog makes the compiler and RackUnit dependency set
# reproducible to the Racket 8.10 release, instead of following the live catalog.
RUN /build/racket/racket/bin/racocgc pkg install --auto --scope installation \
      --catalog "https://download.racket-lang.org/releases/${RACKET_RELEASE}/catalog/" \
      compiler-lib rackunit-lib

FROM toolchain AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples

RUN test "$(uname -m)" = x86_64 \
    && /build/racket/racket/bin/racketcgc -v 2>&1 | grep -Fq 'Racket v8.10 [cgc]' \
    && /build/racket/racket/bin/racocgc make \
      client/client.rkt client/tests/backpressure-fixture.rkt \
      client/tests/conformance/adapter.rkt examples/basics/main.rkt \
    && /build/racket/racket/bin/racocgc test client/tests

RUN mkdir -p /out \
    && /build/racket/racket/bin/racocgc exe --cgc --orig-exe \
      -o /out/convex-adapter client/tests/conformance/adapter.rkt \
    && /build/racket/racket/bin/racocgc exe --cgc --orig-exe \
      -o /out/convex-example examples/basics/main.rkt \
    && readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && readelf -h /out/convex-example | grep -Eq 'Machine:.*Advanced Micro Devices X86-64' \
    && ldd /out/convex-adapter | grep -Fq 'libc.so.6' \
    && printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | /out/convex-adapter > /tmp/adapter.ndjson \
    && grep -Fq '"language":"racket"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson

CMD ["/bin/sh", "-ec", "test \"$(uname -m)\" = x86_64 && /out/convex-adapter <<'EOF'\n{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\nEOF"]

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base

# Copy the TLS pieces used by Racket's OpenSSL FFI and then remove Debian's
# administration surface. The final image keeps separate sh/id/grep/sed/awk
# binaries, not a broad multicall executable.
COPY --from=toolchain /etc/ssl /etc/ssl
COPY --from=toolchain /usr/lib/ssl /usr/lib/ssl
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/engines-3 /usr/lib/x86_64-linux-gnu/engines-3
COPY --from=toolchain /usr/lib/x86_64-linux-gnu/ossl-modules /usr/lib/x86_64-linux-gnu/ossl-modules
RUN rm -rf \
      /etc/apt /etc/dpkg /usr/lib/apt /usr/lib/dpkg /usr/share/doc \
      /usr/share/man /usr/share/perl /usr/share/perl5 \
      /usr/lib/x86_64-linux-gnu/perl* /var/cache/* /var/lib/apt /var/lib/dpkg /var/log/* \
    && rm -f \
      /usr/bin/apt* /usr/bin/dpkg* /usr/bin/gpgv /usr/bin/perl* \
      /usr/bin/update-alternatives /usr/sbin/dpkg* \
      /usr/sbin/dpkg-reconfigure /usr/sbin/update-ca-certificates \
      /usr/bin/debconf* /usr/sbin/invoke-rc.d /usr/sbin/service /usr/sbin/update-rc.d \
    && test "$(uname -m)" = x86_64 \
    && for command in \
      racket racketcgc raco racocgc node npm python python3 pip curl wget nc telnet \
      ftp convex git gcc g++ cc c++ cpp make ld as ar strip apt apt-get apt-cache \
      dpkg dpkg-deb apk yum dnf rpm gem bundle cargo rustc go javac \
      perl ruby php lua java dotnet; do \
        ! command -v "$command" >/dev/null 2>&1 || exit 1; \
      done \
    && test -x /bin/sh \
    && test -x /usr/bin/id \
    && test -x /usr/bin/grep \
    && test -x /usr/bin/sed \
    && test -x /usr/bin/awk

USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test --chmod=0555 /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build racket` builds the default target.
FROM runtime-base AS runtime
COPY --from=test --chmod=0555 /out/convex-adapter /usr/local/bin/convex-adapter
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | /usr/local/bin/convex-adapter > /tmp/adapter.ndjson \
    && grep -Fq '"language":"racket"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson \
    && rm /tmp/adapter.ndjson
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
