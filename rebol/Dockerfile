# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base several other native clients in this
# repository use for their build stages.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG RUNTIME_IMAGE=gcr.io/distroless/base-debian12@sha256:63f52bd27b6aa6555f5d56500b70d7bb0afe51c654905be88a2c1cf967a77b1a

# ---------------------------------------------------------------------------
# toolchain: fetch, sha256-verify, and unpack the pinned Rebol/Bulk 3.22.1
# (the Oldes/Rebol3 fork) release binary -- no OpenSSL, no FFI, no delegated
# runtime, and (below) no compiler or package manager ships in either
# runtime image; this stage exists purely to produce one verified,
# executable, genuinely linux/amd64 ELF binary.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG REBOL_VERSION=3.22.1
ARG REBOL_ASSET=rebol3-bulk-linux-x64.gz
ARG REBOL_SHA256=1932a7048b09cad5fc7bd9c6e4649f9fcfb45245d55876871d6a89e1d5dbad32
# busybox-static supplies `nc` for the adapter's own ADAPTER_LISTEN
# build-time probe below, and (its `rm`) the runtime-base pruning stage
# further down -- never shipped in either runtime image, only used here
# in the toolchain/test stages that produce them.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl busybox-static \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /toolchain
RUN curl --fail --location --output "${REBOL_ASSET}" \
      "https://github.com/Oldes/Rebol3/releases/download/${REBOL_VERSION}/${REBOL_ASSET}" \
    && echo "${REBOL_SHA256}  ${REBOL_ASSET}" | sha256sum --check --strict \
    && gunzip -c "${REBOL_ASSET}" > /usr/local/bin/rebol3 \
    && chmod +x /usr/local/bin/rebol3 \
    && rm "${REBOL_ASSET}"

# Assert both this stage's own container architecture and the just-
# unpacked interpreter binary's target architecture: not an amd64 label
# over a host-platform (for example arm64) binary produced by silently
# skipping --platform, and not the wrong release asset for this pinned
# version. Checks the ELF header directly (magic bytes, then e_machine at
# offset 18 = 0x003e little-endian for x86-64) rather than trusting a
# file(1) guess.
RUN test "$(uname -m)" = "x86_64" \
    && test "$(head -c4 /usr/local/bin/rebol3 | od -An -tx1 | tr -d ' ')" = "7f454c46" \
    && test "$(od -An -tx1 -j18 -N2 /usr/local/bin/rebol3 | tr -d ' ')" = "3e00"
RUN /usr/local/bin/rebol3 --quiet --do "print [system/product system/version] quit" \
      | grep -q "Bulk 3.22.1"

# A pre-created, empty, correctly-owned Rebol data folder, baked in at
# build time: REBOL always tries to create ~/.rebol/ once at startup, and
# both runtime images below run as 65532:65532 against a read-only
# filesystem with no writable HOME (the shared verifier's own client
# container gets no --tmpfs). Observed directly: when that directory does
# not already exist and cannot be created, REBOL prints one
# uncontrollable warning line to stdout, even under --quiet, before
# continuing -- which would break examples/basics' exact-match stdout
# contract. Pre-creating it (present, so REBOL never tries to create it;
# empty, so its read-only ownership afterwards never matters) removes the
# warning without weakening either runtime's read-only posture.
RUN mkdir -p /home-scaffold/home/nonroot/.rebol

# ---------------------------------------------------------------------------
# test: language-local unit tests, plus live smoke/regression tests
# against a real Convex deployment for the hardest layers this client
# owns -- x509 chain/hostname verification, the full HTTP + RFC 6455
# WebSocket + /api/sync Live round trip, five real forced reconnects with
# backoff-reset and rehydration-suppression proofs, and the adapter's own
# bounded output queue -- plus two build-time probes proving the
# conformance adapter actually answers protocol v1 over both its
# transports. Compilation alone would not catch a defect in any of these.
# ---------------------------------------------------------------------------
FROM toolchain AS test
# REBOL's own file-security default is scoped to the process's current
# working directory (observed directly: an identical `read` against an
# absolute path is allowed from WORKDIR /work and denied from anywhere
# else, with no other variable changed) -- so client/ is copied under
# WORKDIR /work, matching the layout the README's own manual `docker run`
# command already relies on, rather than every test file needing its own
# `secure [file allow]` escape hatch the way examples/basics/main.r3
# does (that program also has to open %/dev/stderr, which is outside any
# WORKDIR and so needs the explicit override regardless).
WORKDIR /work
COPY client /work/client
COPY examples /work/examples
ARG CONVEX_TEST_URL=https://usable-reindeer-44.convex.cloud
ENV CONVEX_URL=${CONVEX_TEST_URL}
RUN /usr/local/bin/rebol3 --quiet /work/client/tests/json-test.r3
RUN /usr/local/bin/rebol3 --quiet /work/client/tests/x509-verify-test.r3
RUN /usr/local/bin/rebol3 --quiet /work/client/tests/smoke-live.r3
# Five real reconnects via debugDisconnect, each one proving the
# connection count advanced, backoff reset to its base delay after the
# successful handshake, an unchanged rehydration was suppressed, and the
# subscription is still genuinely alive afterward. smoke-live.r3 above
# only ever proves one forced reconnect; this is the fuller proof
# AGENTS.md's Live acceptance section asks for.
RUN /usr/local/bin/rebol3 --quiet /work/client/tests/live-reconnect-test.r3
# The adapter's bounded output queue (byte budget, oldest-first eviction,
# undroppable responses failing loudly instead of being dropped) tested
# directly under a simulated stopped reader -- no network needed here,
# ADAPTER_NO_AUTORUN keeps client/tests/conformance/main.r3's own
# connect-and-loop driver from running at all.
RUN ADAPTER_NO_AUTORUN=1 /usr/local/bin/rebol3 --quiet /work/client/tests/conformance/queue-test.r3
# Parse-only proof already happened at every unit-test step above (a
# syntax error fails those); this is the smoke check that the adapter
# actually answers hello/close over its own NDJSON protocol, in BOTH
# transport modes -- stdin/stdout, and one accepted ADAPTER_LISTEN TCP
# connection (busybox's `nc`, installed above, is test-only tooling that
# never ships in either runtime image; see the runtime-base pruning
# stage further down).
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://example.invalid /usr/local/bin/rebol3 --quiet /work/client/tests/conformance/main.r3 \
    | tee /tmp/adapter-stdio-probe.out; \
    grep -Fq '"language":"rebol"' /tmp/adapter-stdio-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-stdio-probe.out
RUN set -eu; \
    CONVEX_URL=http://example.invalid ADAPTER_LISTEN=127.0.0.1:18080 \
      /usr/local/bin/rebol3 --quiet /work/client/tests/conformance/main.r3 >/tmp/adapter-tcp-probe.out 2>/tmp/adapter-tcp-probe.err & \
    pid=$!; \
    sleep 1; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | busybox nc 127.0.0.1 18080 | tee /tmp/adapter-tcp-probe.reply; \
    wait "$pid"; \
    grep -Fq '"language":"rebol"' /tmp/adapter-tcp-probe.reply; \
    grep -Fq '"type":"closed"' /tmp/adapter-tcp-probe.reply
# REBOL has no separate compile step; running the canonical example for
# real against a fresh room is this stage's equivalent proof that it
# still loads and executes cleanly end to end, not merely that its
# syntax parses.
RUN /usr/local/bin/rebol3 --quiet /work/examples/basics/main.r3 "rebol-dockerfile-test-$(date +%s%N)"

# Stages the runtime closure the conformance adapter's image needs below,
# while this stage's own full toolset (cp, ldd, awk) is still available.
# runtime-base further down deletes everything in a *fresh*
# debian:bookworm-slim FIRST, including /bin/sh itself, so any staging
# work has to happen here, in THIS stage (which is never pruned), and
# arrive as one COPY --from=test /staging-runtime / afterwards -- matching
# the pattern setl/Dockerfile and mumps/Dockerfile both use for exactly
# the same reason (a RUN in runtime-base after its own prune has no
# /bin/sh left to run it with).
#
# The shared image_policy check execs `--entrypoint /bin/sh` against the
# runtime image directly (see AGENTS.md and ./run's own image_policy),
# so unlike example-runtime below -- which never needs a shell at all,
# since its ENTRYPOINT array invokes the interpreter directly -- the
# `runtime` stage needs a real /bin/sh to exist without also shipping a
# full distribution's worth of other tools. /bin/dash (renamed to
# /bin/sh) and three plain utilities (id, cat, uname) are staged the same
# way setl/Dockerfile's own runtime-base does it, and are exactly what
# that policy probe and the toolchain_policy's own `command -v` checks
# need.
#
# convex.r3 needs no OpenSSL, no system CA store, and no OpenSSL config:
# client/x509.r3's own trust bundle (client/ca-bundle/*.pem, copied in by
# the `runtime` stage below alongside the rest of client/) is entirely
# separate from the system trust store this base image would otherwise
# need staged in -- so, unlike setl/Dockerfile and mumps/Dockerfile
# (both OpenSSL-backed), nothing under /etc/ssl is staged here at all.
RUN set -eu; \
    mkdir -p /staging-runtime/bin /staging-runtime/usr/bin /staging-runtime/usr/local/bin; \
    cp -a /bin/dash /staging-runtime/bin/sh; \
    for tool in id cat uname; do cp -a "/usr/bin/$tool" "/staging-runtime/usr/bin/$tool"; done; \
    cp -aL /usr/local/bin/rebol3 /staging-runtime/usr/local/bin/convex-adapter; \
    for object in /staging-runtime/usr/local/bin/convex-adapter /staging-runtime/usr/bin/*; do \
      ldd "$object" 2>/dev/null \
        | awk '{ for (f = 1; f <= NF; f++) if ($f ~ /^\//) print $f }' \
        | while read -r library; do \
            mkdir -p "/staging-runtime$(dirname "$library")"; \
            cp -aL "$library" "/staging-runtime$library"; \
          done; \
    done

# ---------------------------------------------------------------------------
# example-runtime: the canonical examples/basics/main.r3 program, and
# nothing else. The interpreter binary itself is installed as
# /usr/local/bin/convex-example with the example script wired in via
# ENTRYPOINT's own argument vector, so this image needs no shell to glue
# them together (this distroless base has none) -- `docker run <image>
# <room>` appends straight onto that vector as the verifier's own unique
# room argument.
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS example-runtime
COPY --from=toolchain /usr/local/bin/rebol3 /usr/local/bin/convex-example
COPY --from=toolchain --chown=65532:65532 /home-scaffold/home/nonroot/.rebol /home/nonroot/.rebol
COPY --chown=65532:65532 client /app/client
COPY --chown=65532:65532 examples /app/examples
USER 65532:65532
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/convex-example", "--quiet", "/app/examples/basics/main.r3"]

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its broad filesystem removed, then
# only the staged closure above (built in the `test` stage) copied back.
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
COPY --from=test /staging-runtime /
COPY --from=toolchain --chown=65532:65532 /home-scaffold/home/nonroot/.rebol /home/nonroot/.rebol
ENV HOME=/home/nonroot LC_ALL=C
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
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
         python3 pip pip3 perl ruby php java go rustc cargo convex jq; do \
         ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
       done

# ---------------------------------------------------------------------------
# runtime: the test-only conformance adapter, and nothing else. client/
# (convex.r3, json.r3, x509.r3, ca-bundle/) and client/tests/conformance/
# main.r3 are copied in -- no other test file, no examples/ -- since
# main.r3's own `do %../../convex.r3` needs that exact relative layout
# preserved. Keep this stage last: `./run build rebol` (and image_policy/
# toolchain_policy, which inspect the untagged default build) use the
# Dockerfile's final stage with no --target.
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --chown=65532:65532 client/convex.r3 client/json.r3 client/x509.r3 /app/client/
COPY --chown=65532:65532 client/ca-bundle /app/client/ca-bundle
COPY --chown=65532:65532 client/tests/conformance/main.r3 /app/client/tests/conformance/main.r3
WORKDIR /app
# Proves the adapter answers hello/close from the FINAL pruned image
# itself, not merely from the toolchain/test stage's much larger
# filesystem -- AGENTS.md: "Exercise TLS from the final image so hosted
# verification is not the first place a missing provider or certificate
# path is discovered" applies just as much to a plain transport smoke
# check as it does to TLS specifically.
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /app/examples; \
    reply="$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://example.invalid /usr/local/bin/convex-adapter --quiet /app/client/tests/conformance/main.r3)"; \
    case "$reply" in \
      *'"language":"rebol"'*) ;; \
      *) printf '%s\n' "$reply" >&2; exit 1 ;; \
    esac; \
    case "$reply" in \
      *'"type":"closed"'*) ;; \
      *) printf '%s\n' "$reply" >&2; exit 1 ;; \
    esac
ENTRYPOINT ["/usr/local/bin/convex-adapter", "--quiet", "/app/client/tests/conformance/main.r3"]
