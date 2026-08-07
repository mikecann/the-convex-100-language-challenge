# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Ring has no official container image and no distribution package, so the
# language is built from its own source tree at a pinned commit using the
# upstream build scripts. Ring 1.27 is tag v1.27, commit
# f88d95236319460327b05efcfdab7c342caa7d22.
ARG BUILD_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258
ARG RING_COMMIT=f88d95236319460327b05efcfdab7c342caa7d22

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
ARG RING_COMMIT
ENV DEBIAN_FRONTEND=noninteractive \
    LD_LIBRARY_PATH=/opt/ring/lib

# Build dependencies are deliberately unpinned here. The reproducible pin for
# this image is the base image digest above plus the exact Ring commit; exact
# apt version strings will be recorded from the first successful build rather
# than guessed.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       build-essential \
       ca-certificates \
       git \
       libcurl4-openssl-dev \
       libssl-dev \
       libuv1-dev \
       pkgconf \
    && rm -rf /var/lib/apt/lists/*

# The Convex sync socket rides on libcurl's WebSocket API, which is only
# compiled in from curl 8.11 onwards. Fail here rather than at the first Live
# subscription if this base image ever ships a libcurl without it.
RUN curl-config --protocols | grep -qx WSS \
    && curl-config --version

# Ring's own build scripts install through bin/install.sh, which calls sudo.
# This shim keeps the upstream scripts unmodified inside the build stage; it
# never reaches a runtime image.
RUN printf '%s\n' '#!/bin/sh' 'exec "$@"' > /usr/local/bin/sudo \
    && chmod 0755 /usr/local/bin/sudo

RUN git clone --no-checkout https://github.com/ring-lang/ring.git /opt/ring \
    && git -C /opt/ring checkout --detach "${RING_COMMIT}" \
    && test "$(git -C /opt/ring rev-parse HEAD)" = "${RING_COMMIT}" \
    && rm -rf /opt/ring/.git

# The compiler and virtual machine, then only the three official extensions
# this client uses: RingLibCurl for HTTP, TLS and RFC 6455 transport, RingLibuv
# for the monotonic clock and the adapter's controller stream, and RingOpenSSL
# for the SHA-1 the loopback WebSocket fixture needs to answer a handshake.
RUN cd /opt/ring/language/build && sh buildgcc.sh
RUN cd /opt/ring/extensions/ringcurl && sh buildgcc.sh
RUN cd /opt/ring/extensions/ringlibuv && sh buildgcc.sh
RUN cd /opt/ring/extensions/ringopenssl && sh buildgcc.sh

RUN test "$(uname -m)" = x86_64 \
    && printf '%s\n' \
       'load "libcurl.ring"' \
       'load "libuv.ring"' \
       'load "openssllib.ring"' \
       '? "ring extensions ready " + sha1("ring") + " " + string(floor(uv_hrtime() > 0))' \
       > /tmp/probe.ring \
    && /opt/ring/bin/ring /tmp/probe.ring | grep -q "ring extensions ready" \
    && rm -f /tmp/probe.ring

# Stage the exact runtime closure. ldd resolves what the interpreter and its
# extensions actually link, and the extra entries cover what OpenSSL and glibc
# load at run time rather than link time.
#
# BUILD_IMAGE ships merged-usr: /lib, /lib64, /bin and /sbin are symlinks
# into /usr/*. ldd and the raw /etc and /usr ls entries below report library
# paths through those symlinks (e.g. /lib/x86_64-linux-gnu/libc.so.6), so a
# naive `tar ... -T closure.txt` extraction into an empty /rootfs recreates
# /rootfs/lib as a real directory rather than a symlink. Later, copying that
# real directory onto the runtime-base image's /lib symlink makes buildkit's
# containerd-snapshotter backend fail with "cannot copy to non-directory";
# it refuses to write a directory over a symlink even though the symlink's
# target (/usr/lib) is itself a directory. Resolving only the directory
# component of each path with `readlink -f` (never the basename, which is
# often itself a SONAME symlink such as libcurl.so.4 -> libcurl.so.4.8.0
# that must keep its name) rewrites every entry to its canonical /usr/*
# location before the tar step, so /rootfs only ever gains real directories
# - usr/, etc/, opt/ - that already exist as real directories in
# runtime-base too, and the final COPY never touches /lib, /lib64, /bin or
# /sbin at all.
RUN set -eu; \
    mkdir -p /rootfs; \
    { ldd /opt/ring/bin/ring; \
      ldd /opt/ring/lib/libring.so; \
      ldd /opt/ring/lib/libring_libcurl.so; \
      ldd /opt/ring/lib/libring_uv.so; \
      ldd /opt/ring/lib/libring_openssl.so; } \
      | awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }' \
      | grep -v '^/opt/ring/' | sort -u > /tmp/closure.txt; \
    for extra in /etc/ssl/certs/ca-certificates.crt /etc/ssl/openssl.cnf /etc/nsswitch.conf; do \
      test -e "$extra" && echo "$extra" >> /tmp/closure.txt; \
    done; \
    ls /usr/lib/x86_64-linux-gnu/ossl-modules/*.so >> /tmp/closure.txt 2>/dev/null || true; \
    ls /lib/x86_64-linux-gnu/libnss_*.so.2 /lib/x86_64-linux-gnu/libresolv.so.2 \
      >> /tmp/closure.txt 2>/dev/null || true; \
    sort -u /tmp/closure.txt -o /tmp/closure.txt; \
    while IFS= read -r closure_path; do \
      printf '%s/%s\n' "$(readlink -f "$(dirname "$closure_path")")" "$(basename "$closure_path")"; \
    done < /tmp/closure.txt | sort -u > /tmp/closure.resolved.txt; \
    mv /tmp/closure.resolved.txt /tmp/closure.txt; \
    tar -chf /tmp/closure.tar -T /tmp/closure.txt; \
    tar -xpf /tmp/closure.tar -C /rootfs; \
    mkdir -p /rootfs/opt/ring/bin/load /rootfs/opt/ring/lib \
             /rootfs/opt/ring/extensions/ringcurl \
             /rootfs/opt/ring/extensions/ringlibuv \
             /rootfs/opt/ring/extensions/ringopenssl; \
    cp -a /opt/ring/bin/ring /rootfs/opt/ring/bin/ring; \
    cp -a /opt/ring/bin/load/. /rootfs/opt/ring/bin/load/; \
    cp -a /opt/ring/lib/*.so /rootfs/opt/ring/lib/; \
    cp -a /opt/ring/extensions/ringcurl/libcurl.ring \
          /opt/ring/extensions/ringcurl/ring_libcurl.rh \
          /rootfs/opt/ring/extensions/ringcurl/; \
    cp -a /opt/ring/extensions/ringlibuv/libuv.ring \
          /opt/ring/extensions/ringlibuv/ring_libuv.rh \
          /rootfs/opt/ring/extensions/ringlibuv/; \
    cp -a /opt/ring/extensions/ringopenssl/openssllib.ring \
          /rootfs/opt/ring/extensions/ringopenssl/

# ---------------------------------------------------------------------------
# Language-local tests
# ---------------------------------------------------------------------------

FROM build AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples

# Ring resolves load "name.ring" against the interpreter's own load folder, so
# the client and the adapter are installed there once. The tests then exercise
# the exact files this repository ships rather than a second copy.
RUN cp client/convex.ring /opt/ring/bin/load/convex.ring \
    && cp client/tests/conformance/adapter.ring /opt/ring/bin/load/convexadapter.ring

RUN test "$(uname -m)" = x86_64

RUN /opt/ring/bin/ring client/tests/run.ring | tee /tmp/unit.txt \
    && grep -q "Ring client unit tests passed" /tmp/unit.txt

RUN /opt/ring/bin/ring client/tests/live_socket.test.ring | tee /tmp/socket.txt \
    && grep -q "Ring real transport and adapter envelope tests passed" /tmp/socket.txt

RUN /opt/ring/bin/ring client/tests/stopped_reader.test.ring | tee /tmp/pressure.txt \
    && grep -q "Ring real stopped-reader test passed" /tmp/pressure.txt

# The conformance executable's stdin/stdout mode, with its exact ready and
# closed envelopes.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | /opt/ring/bin/ring client/tests/conformance/adapter.ring > /tmp/adapter.ndjson \
    && grep -Fqx '{"protocolVersion":1,"id":"hello","type":"ready","language":"ring","implementation":"native-ring-1.27","runtime":"ring-1.27"}' /tmp/adapter.ndjson \
    && grep -Fqx '{"id":"close","type":"closed"}' /tmp/adapter.ndjson

# Ring compiles a whole file before running it, so reaching the configuration
# check proves the canonical example parses and links against the client.
RUN /opt/ring/bin/ring examples/basics/main.ring > /tmp/example.txt 2>&1 || true; \
    grep -q "CONVEX_URL is required" /tmp/example.txt

CMD ["/opt/ring/bin/ring", "/project/client/tests/run.ring"]

# ---------------------------------------------------------------------------
# Minimal runtime
# ---------------------------------------------------------------------------

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base

# Only the staged closure is installed, so no compiler, no build frontend and
# no development headers exist here. /rootfs holds only real directories
# that also exist as real directories here (usr/, etc/, opt/); it has no
# entries at /lib, /lib64, /bin or /sbin, so this never copies a directory
# onto this merged-usr image's symlinks at those paths. The base image's
# package manager is then removed outright rather than merely hidden from
# PATH.
COPY --from=build /rootfs/ /
RUN set -eu; \
    rm -rf /etc/apt /usr/lib/apt /var/lib/apt /var/cache/apt /var/lib/dpkg /usr/share/dpkg; \
    rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config \
          /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/dpkg \
          /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper \
          /usr/bin/dpkg-query /usr/bin/dpkg-split /usr/bin/dpkg-statoverride \
          /usr/bin/dpkg-trigger /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure; \
    for forbidden in apt apt-get dpkg curl node php python python3 npm npx pip pip3 convex \
                     gcc cc g++ ld as make; do \
      if command -v "$forbidden" >/dev/null 2>&1; then \
        printf '%s\n' "unexpected command in the runtime image: $forbidden" >&2; \
        exit 1; \
      fi; \
    done

ENV LD_LIBRARY_PATH=/opt/ring/lib \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    PATH=/usr/local/bin:/usr/bin:/bin

COPY client/convex.ring /opt/ring/bin/load/convex.ring

USER 65532:65532

# Prove the unprivileged runtime can boot Ring, load every extension it needs
# and complete a real TLS handshake. libcurl codes 35, 60 and 77 are the ones
# that mean a certificate store or a TLS provider is missing from this image;
# a network-less build is allowed to fail with anything else.
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test "$(uname -m)" = x86_64; \
    printf '%s\n' \
      'load "convex.ring"' \
      'oCurl = curl_easy_init()' \
      'curl_easy_setopt(oCurl, CURLOPT_URL, "https://usable-reindeer-44.convex.cloud/version")' \
      'curl_easy_setopt(oCurl, CURLOPT_WRITEFUNCTION, :cvxSinkWrite)' \
      'curl_easy_setopt(oCurl, CURLOPT_CAINFO, CONVEX_CA_BUNDLE)' \
      'curl_easy_setopt(oCurl, CURLOPT_SSL_VERIFYPEER, 1)' \
      'curl_easy_setopt(oCurl, CURLOPT_SSL_VERIFYHOST, 2)' \
      'curl_easy_setopt(oCurl, CURLOPT_TIMEOUT_MS, 10000)' \
      'nResult = curl_easy_perform(oCurl)' \
      'curl_easy_cleanup(oCurl)' \
      'if nResult = 35 or nResult = 60 or nResult = 77' \
      '    ? "tls probe failed " + cvxIntText(nResult)' \
      'else' \
      '    ? "tls probe usable " + cvxIntText(nResult)' \
      'ok' \
      > /tmp/tls-probe.ring; \
    /opt/ring/bin/ring /tmp/tls-probe.ring > /tmp/tls-probe.txt 2>&1; \
    cat /tmp/tls-probe.txt; \
    grep -q "tls probe usable" /tmp/tls-probe.txt; \
    rm -f /tmp/tls-probe.ring /tmp/tls-probe.txt

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.ring /usr/local/bin/convex-example
RUN /usr/local/bin/convex-example > /tmp/example.txt 2>&1 || true; \
    grep -q "CONVEX_URL is required" /tmp/example.txt; \
    rm -f /tmp/example.txt
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.ring /usr/local/bin/convex-adapter
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | /usr/local/bin/convex-adapter > /tmp/adapter.ndjson; \
    grep -Fqx '{"protocolVersion":1,"id":"hello","type":"ready","language":"ring","implementation":"native-ring-1.27","runtime":"ring-1.27"}' /tmp/adapter.ndjson; \
    grep -Fqx '{"id":"close","type":"closed"}' /tmp/adapter.ndjson; \
    rm -f /tmp/adapter.ndjson
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
