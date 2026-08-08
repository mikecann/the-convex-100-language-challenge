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
# prove a real TLS handshake from inside the container, and run every
# language-local test suite. CMD reruns the same suite from the built
# image (see the bottom of this stage), so `./run test setl` re-verifies
# rather than only proving the build-time RUN steps once.
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
       busybox-static \
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

# RFC 6455 WebSocket framing (client/websocket.setl): the HTTP Upgrade
# handshake with a verified Sec-WebSocket-Accept token (SHA-1 computed
# via the new callout() service 5, see client/callskel.c), one masked
# text frame per outbound send, and inbound fragmented-message
# reassembly with transparent ping/pong and close handling. Tested for
# real against a public WebSocket echo service -- not the Convex
# backend, which is only reachable once the built image runs with real
# network access (verify-example / verify), not during this isolated
# build -- covering a short frame, a frame that forces the 126
# extended-length header, and a clean close handshake.
COPY client/websocket.setl /stage/websocket.setl
COPY client/tests/websocket_test.setl /stage/websocket_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp websocket_test.setl | tee /tmp/websocket_test.out; \
    grep -Fq 'WEBSOCKET CLIENT: ALL CHECKS PASSED' /tmp/websocket_test.out

# client/sync.setl is a single-connection primitive for the pinned
# convex-rs-0.10.4-unversioned-sync /api/sync protocol: Connect,
# ModifyQuerySet (Add/Remove), and Transition handling (QueryUpdated,
# QueryFailed, QueryRemoved) with the little-endian version/timestamp
# tracking the reference Go client documents in protocol.go.
# client/tests/sync_test.setl proves the decode/version-tracking logic
# with hand-built Transition messages injected directly into a
# connection's read buffer -- the same synthetic style
# client/tests/convex_test.setl uses for the HTTP envelope -- covering an
# initial QueryUpdated, a chained external update, QueryFailed followed
# by a recovering QueryUpdated on the same subscription, and rejection of
# a Transition whose startVersion does not match.
COPY client/sync.setl /stage/sync.setl
COPY client/tests/sync_test.setl /stage/sync_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp sync_test.setl | tee /tmp/sync_test.out; \
    grep -Fq 'SYNC CLIENT: ALL CHECKS PASSED' /tmp/sync_test.out

# client/live.setl threads a sequence of client/sync.setl connections
# together across drops: exponential backoff, replaying the active query
# set on every reconnect, and unchanged-rehydration suppression --
# AGENTS.md's Live acceptance requirements. client/tests/live_test.setl
# proves the bookkeeping a live deployment is not needed for, in the same
# synthetic style client/tests/sync_test.setl uses one layer down:
# delivery, QueryFailed then recovery, an unchanged rehydration being
# suppressed versus a changed one being delivered normally, live_remove/
# live_add clearing every bit of state under a reused subscription ID, and
# exponential backoff growing then capping against a real (if instantly
# refused) local connection. A full end-to-end reconnect against a real
# backend -- five real reconnects, backoff actually resetting after a good
# handshake -- is proven instead by `./run verify`'s shared conformance
# run: AGENTS.md is explicit that only that shared evidence earns the
# Live badge.
COPY client/live.setl /stage/live.setl
COPY client/tests/live_test.setl /stage/live_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp live_test.setl | tee /tmp/live_test.out; \
    grep -Fq 'LIVE CLIENT: ALL CHECKS PASSED' /tmp/live_test.out

# examples/basics/count.setl decodes and validates the "count" field the
# canonical example reads from demo:state/demo:increment, accepting a
# Convex JSON integral value encoded as either a bare integer (0) or a
# real with a whole value (0.0) while rejecting anything fractional,
# quoted, negative, or out of range (AGENTS.md's integral-decoding rule).
# examples/basics/tests/count_test.setl is the focused regression that
# rule calls for -- synthetic values only, no live deployment needed,
# the same style client/tests/convex_test.setl uses for the HTTP
# envelope.
COPY examples/basics/count.setl /stage/count.setl
COPY examples/basics/tests/count_test.setl /stage/count_test.setl
RUN set -eu; \
    cd /stage; \
    /opt/setl-src/src/run/setl --cpp count_test.setl | tee /tmp/count_test.out; \
    grep -Fq 'COUNT DECODING: ALL CHECKS PASSED' /tmp/count_test.out

# ---------------------------------------------------------------------------
# Two flat source trees for the runtime images below: every shared client
# module plus each runtime's own entrypoint. Kept separate from the
# incremental /stage above, rather than merged into it, because
# examples/basics/main.setl and client/tests/conformance/main.setl share a
# filename -- setlcpp resolves a quoted #include relative to the current
# working directory (see client/json.setl's module comment), so each
# entrypoint needs its own directory of siblings, and each runtime image
# below proves explicitly that it ships only its own entrypoint.
# ---------------------------------------------------------------------------
RUN mkdir -p /stage-example /stage-adapter
COPY client/*.setl /stage-example/
COPY examples/basics/main.setl examples/basics/count.setl /stage-example/
COPY client/*.setl /stage-adapter/
COPY client/tests/conformance/main.setl /stage-adapter/

# examples/basics/main.setl is executed for real against the approved
# local backend by ./run verify-example; this build stage has no network
# path to that backend, so it is only proven here to parse correctly and
# reach its own CONVEX_URL guard -- the same distinction
# client/tests/tls_smoke.setl's own module comment draws between "the
# transport works" and "the Convex host is reachable".
RUN set -eu; \
    cd /stage-example; \
    if /opt/setl-src/src/run/setl --cpp main.setl >/tmp/example-guard.out 2>&1; then \
      echo "expected the example to fail without CONVEX_URL" >&2; \
      cat /tmp/example-guard.out >&2; \
      exit 1; \
    fi; \
    grep -Fq 'CONVEX_URL is required' /tmp/example-guard.out

# Parse-only proof already happened at every unit-test step above (a
# syntax error fails those); this is the smoke check that the compiled
# adapter actually answers hello/close over its own NDJSON protocol,
# matching every other language's own build-time adapter probe (see
# mumps/Dockerfile).
RUN set -eu; \
    cd /stage-adapter; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid /opt/setl-src/src/run/setl --cpp main.setl \
    | tee /tmp/adapter-probe.out; \
    grep -Fq '"language":"setl"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Stage exactly the runtime closure while this stage's own full toolset
# (cp, ldd, awk, mkdir) is still available. runtime-base below deletes
# everything in a *fresh* debian:bookworm-slim FIRST, including /bin/sh
# itself, so any staging work has to happen here, in a stage that never
# gets pruned, and arrive as one COPY --from=test /staging / afterwards --
# not as RUN commands that execute after that deletion (see
# mumps/Dockerfile's own comment on why the order cannot run the other
# way; that Dockerfile is this one's template for the whole pattern).
#
# setltran (the compiler) and setlcpp (the preprocessor) are GNU SETL's
# own required boot dependencies, not an optional toolchain: `setl` always
# shells out to setlcpp once a '#' appears anywhere in a source file
# (confirmed directly against this interpreter, not just when --cpp is
# passed on the command line), and to setltran to translate every program
# before running it -- every client module here uses #include, so both
# run on every single invocation. This is the same "a runtime may retain a
# language-runtime library named compiler only when the runtime itself
# requires it to boot" exception AGENTS.md documents for exactly this
# situation. Neither is placed on PATH: the launcher scripts below invoke
# /opt/convex/bin/setl by its absolute path, so setltran and setlcpp are
# reachable only as its required siblings next to it, never as a general
# command anything else in the image could invoke.
RUN set -eu; \
    mkdir -p /staging/bin /staging/usr/bin /staging/opt/convex/bin \
             /staging/etc/ssl/certs; \
    cp -a /bin/dash /staging/bin/sh; \
    for tool in id cat uname; do cp -a "/usr/bin/$tool" "/staging/usr/bin/$tool"; done; \
    cp -aL /opt/setl-src/src/run/setl /staging/opt/convex/bin/setl; \
    cp -aL /opt/setl-src/src/tran/setltran /staging/opt/convex/bin/setltran; \
    cp -aL /opt/setl-src/src/cpp/setlcpp /staging/opt/convex/bin/setlcpp; \
    for object in /staging/opt/convex/bin/* /staging/usr/bin/*; do \
      ldd "$object" 2>/dev/null \
        | awk '{ for (f = 1; f <= NF; f++) if ($f ~ /^\//) print $f }' \
        | while read -r library; do \
            mkdir -p "/staging$(dirname "$library")"; \
            cp -aL "$library" "/staging$library"; \
          done; \
    done; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /staging/etc/ssl/certs/ca-certificates.crt; \
    cp -aL /etc/ssl/openssl.cnf /staging/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /staging/etc/nsswitch.conf; \
    for resolver in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL "/lib/x86_64-linux-gnu/$resolver" "/staging/lib/x86_64-linux-gnu/$resolver"; \
    done

# The two entry-point launchers, and each runtime's own flat source tree,
# also have to be written here, as root, rather than in the leaf stages
# below: runtime-base switches to USER 65532:65532 before those leaf
# stages run, and that user cannot write into /usr/local/bin (owned by
# root, from the shared /staging COPY above). Each goes into its own tree
# rather than the shared /staging closure above -- deliberately not
# staged there -- so runtime-base, the common ancestor of both leaf
# images, never contains either one; each leaf image ends up proving the
# OTHER launcher's entrypoint and source directory are both genuinely
# absent, not just that its own is present. Each launcher cd's into its
# own flat source directory before invoking setl, since GNU SETL's
# #include resolves relative to the current working directory rather
# than the entrypoint file's own location.
RUN mkdir -p /staging-example/usr/local/bin /staging-example/opt/convex/example-src \
             /staging-adapter/usr/local/bin /staging-adapter/opt/convex/adapter-src \
    && cp -a /stage-example/*.setl /staging-example/opt/convex/example-src/ \
    && cp -a /stage-adapter/*.setl /staging-adapter/opt/convex/adapter-src/ \
    && printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'cd /opt/convex/example-src' \
      'exec /opt/convex/bin/setl --cpp main.setl "$@"' \
      > /staging-example/usr/local/bin/convex-example \
    && printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'cd /opt/convex/adapter-src' \
      'exec /opt/convex/bin/setl --cpp main.setl' \
      > /staging-adapter/usr/local/bin/convex-adapter \
    && chmod 0555 /staging-example/usr/local/bin/convex-example \
       /staging-adapter/usr/local/bin/convex-adapter

# `./run test setl` reruns this exact suite from the built image (a plain
# `docker run` on the `test` target otherwise only inherits the base
# image's own default CMD, which proves nothing), so the evidence is not
# limited to what happened during the build.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'SETL=/opt/setl-src/src/run/setl' \
      'cd /stage' \
      '"$SETL" --cpp json_test.setl | grep -Eq "^([0-9]+)/\1 json checks passed$"' \
      '"$SETL" --cpp http_test.setl | grep -Fq "HTTP CLIENT: ALL CHECKS PASSED"' \
      '"$SETL" --cpp convex_test.setl | grep -Fq "CONVEX CLASSIFY: ALL CHECKS PASSED"' \
      '"$SETL" --cpp websocket_test.setl | grep -Fq "WEBSOCKET CLIENT: ALL CHECKS PASSED"' \
      '"$SETL" --cpp sync_test.setl | grep -Fq "SYNC CLIENT: ALL CHECKS PASSED"' \
      '"$SETL" --cpp live_test.setl | grep -Fq "LIVE CLIENT: ALL CHECKS PASSED"' \
      '"$SETL" --cpp count_test.setl | grep -Fq "COUNT DECODING: ALL CHECKS PASSED"' \
      'cd /stage-example' \
      'if "$SETL" --cpp main.setl >/tmp/example-guard.out 2>&1; then' \
      '  echo "expected the example to fail without CONVEX_URL" >&2' \
      '  cat /tmp/example-guard.out >&2' \
      '  exit 1' \
      'fi' \
      'grep -Fq "CONVEX_URL is required" /tmp/example-guard.out' \
      'cd /stage-adapter' \
      'probe=$(printf "%s\n" "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}" "{\"id\":\"close\",\"op\":\"close\"}" | CONVEX_URL=http://example.invalid "$SETL" --cpp main.setl)' \
      'case "$probe" in' \
      '  *"\"language\":\"setl\""*) ;;' \
      '  *) printf "%s\n" "$probe" >&2; exit 1 ;;' \
      'esac' \
      'case "$probe" in' \
      '  *"\"type\":\"closed\""*) ;;' \
      '  *) printf "%s\n" "$probe" >&2; exit 1 ;;' \
      'esac' \
      > /usr/local/bin/run-language-tests \
    && chmod 0555 /usr/local/bin/run-language-tests
CMD ["/usr/local/bin/run-language-tests"]

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its broad filesystem removed, then
# only GNU SETL's own runtime closure (found via ldd) copied back --
# deliberately not either runtime's own client source tree, which each
# leaf stage below stages and proves the other lacks. Both leaf images add
# a real TLS
# handshake proof from the pruned filesystem itself (AGENTS.md: "Exercise
# TLS from the final image so hosted verification is not the first place
# a missing provider or certificate path is discovered") -- OpenSSL's
# default provider needs no engine or ossl-modules provider .so beyond
# what is already linked into libcrypto for standard TLS 1.2/1.3
# (confirmed against this base image: /etc/ssl/openssl.cnf ships its
# [provider_sect] commented out by default, and client/callskel.c never
# calls OSSL_PROVIDER_load), so none is staged.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /staging /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LC_ALL=C
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(uname -m)" = x86_64

RUN test ! -e /etc/dpkg \
    && test ! -e /etc/apt \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /busybox \
    && for command_name in cc gcc g++ clang make ld as ar cmake apt apt-get dpkg \
         apk rpm curl wget nc netcat socat busybox node npm npx python \
         python3 pip pip3 perl ruby php java go rustc cargo convex jq \
         setltran setlcpp; do \
         ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
       done

# A real TLS handshake and HTTP round trip from the pruned filesystem
# itself, against the same stable well-known host client/tests/tls_smoke.setl
# proves the boundary against during the test stage -- isolating "this
# minimal image's own OpenSSL/cert/library closure works" from "the
# client's own protocol code works", which the two leaf stages' own probes
# below prove separately.
COPY client/tests/tls_smoke.setl /opt/convex/tls-smoke-src/tls_smoke.setl
RUN set -eu; \
    cd /opt/convex/tls-smoke-src; \
    output=$(/opt/convex/bin/setl tls_smoke.setl); \
    printf '%s\n' "$output"; \
    case "$output" in \
      *'TLS HANDSHAKE AND HTTP ROUND TRIP: OK'*) ;; \
      *) exit 1 ;; \
    esac

# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /staging-example /
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter \
    && test ! -e /opt/convex/adapter-src
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# Keep the adapter last: `./run build setl` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /staging-adapter /
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /opt/convex/example-src; \
    probe=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://example.invalid /usr/local/bin/convex-adapter); \
    case "$probe" in \
      *'"type":"closed"'*) ;; \
      *) printf '%s\n' "$probe" >&2; exit 1 ;; \
    esac
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
