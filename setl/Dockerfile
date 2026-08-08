# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base other clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# GNU SETL is not packaged for Debian, so its source is pinned by URL and
# checksum and built from scratch, matching this repository's policy for
# anything not packaged by the distribution. 8.13.22 is the current release
# published at https://setl.org/setl/.
ARG SETL_URL=https://setl.org/setl/setl-8.13.22.tgz
ARG SETL_SHA256=ee0475fd7e8f5c728a25db626286a8c8f62ad1751169ffb892170cdde271f207

# ---------------------------------------------------------------------------
# test: build GNU SETL from source with the Convex TLS boundary linked in,
# and prove a real TLS handshake from inside the container.
#
# STATUS: this is the first, proven deliverable for the SETL client -- a
# from-source interpreter build with the callout() TLS boundary wired up and
# a real handshake against a live TLS host. No Convex client source exists
# yet (see setl/README.md), so this Dockerfile intentionally has no
# `example-runtime` or `runtime` stage: this repository's honesty rules
# forbid shipping a runtime image that does not actually run a Convex
# client. Do not add those stages until client/ has real code to put in
# them.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG SETL_URL
ARG SETL_SHA256
WORKDIR /opt
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       m4 \
       bison \
       make \
       file \
       binutils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; test "$(uname -m)" = x86_64

# Fetch and verify GNU SETL by URL and checksum, matching the project's own
# pin-by-digest policy for anything not packaged by the distribution.
ADD --checksum=sha256:${SETL_SHA256} ${SETL_URL} /opt/setl.tgz
RUN set -eu; \
    mkdir -p /opt/setl-src; \
    tar xzf /opt/setl.tgz -C /opt/setl-src --strip-components=1; \
    rm -f /opt/setl.tgz

# Replace GNU SETL's stub SETL2-compatibility callout dispatcher
# (src/run/callskel.c, upstream-documented as deliberately overridable --
# see the block comment in client/callskel.c) with the Convex TLS boundary.
# This is the ONLY native code in this client: it is compiled straight into
# the `setl` interpreter binary itself (callskel.c has always been one of
# its translation units), not built as a separate loadable library, because
# GNU SETL exposes no dlopen-style FFI -- callout() is the sole native
# extension point.
COPY client/callskel.c /opt/setl-src/src/run/callskel.c

WORKDIR /opt/setl-src
# GNU SETL's own top-level `make` interactively prompts for a build
# directory and configure options on every fresh checkout (see INSTALL and
# mkbuild in the source tree). The supported non-interactive path is to
# pre-seed config.parms (the file that prompt would otherwise write) with
# the desired `configure` arguments and touch its witness timestamp file so
# `make` treats configuration as already done; main.mk's own GNUmakefile
# then builds directly in this source tree without ever shelling out to the
# interactive mkbuild script. LIBS is deliberately set to the toolchain's
# own default (`-lm`, confirmed from a stock configure run) plus the OpenSSL
# libraries the TLS boundary needs: passing LIBS on the make command line
# replaces the Makefile's own assignment rather than extending it, so
# dropping `-lm` here would silently break every math intrinsic.
RUN set -eu; \
    printf '%s\n' "--prefix=/usr/local" > config.parms; \
    touch stamp-parms; \
    make LIBS="-lm -lssl -lcrypto" >/tmp/make.log 2>&1; status=$?; \
    tail -400 /tmp/make.log; \
    exit $status

# GNU SETL's `setl` driver invokes two sibling tools it does not search
# PATH for: `setltran` (the compiler) and `setlcpp` (the preprocessor),
# both resolved relative to the interpreter's own install location. `make
# install` would place all three together; this build stays in the source
# tree instead (see the closure-building RUN below, which copies only the
# reviewed set of files a minimal runtime actually needs), so the same
# sibling relationship is reproduced here with symlinks next to the built
# `setl` binary.
RUN set -eu; \
    cd src/run; \
    ln -sf ../tran/setltran setltran; \
    ln -sf ../cpp/setlcpp setlcpp; \
    printf 'print(1+1);\n' > /tmp/boot.setl; \
    ./setl /tmp/boot.setl | grep -Fq 2

# Prove the callout() boundary itself: PING exercises the dispatcher with no
# socket involved, isolating "the boundary works" from "TLS works".
RUN set -eu; \
    printf 'print(callout(0, om, []));\n' > /tmp/ping.setl; \
    src/run/setl /tmp/ping.setl | grep -Fq PONG

# Prove a real TLS handshake, a real HTTP/1.1 request written across the
# boundary, and a real response read back -- against a stable, well-known
# TLS host reachable from any Docker build environment. This is deliberately
# not the Convex backend: it isolates "the TLS boundary itself works" from
# "the Convex host is reachable", which the client's own tests prove later
# against the approved test deployment. GNU SETL's built-in `hex`/`unhex`
# operators (not hand-rolled string math) do the boundary encoding, matching
# what client/callskel.c documents and what the eventual client will use.
COPY client/tests/tls_smoke.setl /tmp/tls_smoke.setl
RUN set -eu; \
    src/run/setl /tmp/tls_smoke.setl | tee /tmp/tls_smoke.out; \
    grep -Fq 'TLS HANDSHAKE AND HTTP ROUND TRIP: OK' /tmp/tls_smoke.out

# The JSON codec (client/json.setl) is a proc-only module, meant to be
# #include'd near the end of a file, after that file's own mainline
# statements -- GNU SETL requires every source unit's executable statements
# to precede its procedure definitions (confirmed directly against this
# interpreter: a bare `proc` before any statement, or a statement after one,
# is a syntax error). setlcpp resolves a quoted #include relative to the
# current working directory, so the module and its test are staged side by
# side rather than left in their separate repository directories.
RUN mkdir -p /stage
COPY client/json.setl /stage/json.setl
COPY client/tests/json_test.setl /stage/json_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp json_test.setl | tee /tmp/json_test.out; \
    grep -Eq '^([0-9]+)/\1 json checks passed$' /tmp/json_test.out

# The transport layer: client/tcp.setl (native open(f,"tcp-client")) for
# the local plain-HTTP profile, client/tls.setl (the callout() boundary)
# for the hosted profile, client/stream.setl unifying the two behind one
# [status,payload] shape, and client/http.setl framing HTTP/1.1 requests
# and responses (status line, headers, Content-Length and chunked bodies)
# over either. client/tests/http_test.setl proves both transports for
# real against a stable public host -- not the Convex backend, which the
# client's own conformance tests exercise once they exist -- covering a
# plain HTTP round trip on port 80 and a TLS round trip (with a chunked
# response body, exercising that decoder) on port 443.
COPY client/tcp.setl /stage/tcp.setl
COPY client/tls.setl /stage/tls.setl
COPY client/stream.setl /stage/stream.setl
COPY client/http.setl /stage/http.setl
COPY client/tests/http_test.setl /stage/http_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp http_test.setl | tee /tmp/http_test.out; \
    grep -Fq 'HTTP CLIENT: ALL CHECKS PASSED' /tmp/http_test.out

# client/convex.setl implements query/mutation/action over the documented
# POST /api/{query,mutation,action} "format":"json" envelope, classifying
# every response into a result or one of FunctionError/ProtocolError/
# TransportError. client/tests/convex_test.setl unit-tests the envelope
# classification and deployment-URL parsing directly with synthetic
# inputs -- no live deployment or fixture server needed for this layer,
# since client/tests/http_test.setl already proves the transport and
# framing underneath it against real servers.
COPY client/convex.setl /stage/convex.setl
COPY client/tests/convex_test.setl /stage/convex_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp convex_test.setl | tee /tmp/convex_test.out; \
    grep -Fq 'CONVEX CLASSIFY: ALL CHECKS PASSED' /tmp/convex_test.out
