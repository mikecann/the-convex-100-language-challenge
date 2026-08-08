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
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl \
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
# test: language-local unit tests, plus a live smoke test against a real
# Convex deployment for the two hardest layers this client owns -- x509
# chain/hostname verification, and the full HTTP + RFC 6455 WebSocket +
# /api/sync Live round trip (subscribe, initial value, a forced
# debugDisconnect reconnect, a mutation, and the resulting Live update).
# Compilation alone would not catch a defect in either.
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
# REBOL has no separate compile step; running the canonical example for
# real against a fresh room is this stage's equivalent proof that it
# still loads and executes cleanly end to end, not merely that its
# syntax parses.
RUN /usr/local/bin/rebol3 --quiet /work/examples/basics/main.r3 "rebol-dockerfile-test-$(date +%s%N)"

# ---------------------------------------------------------------------------
# example-runtime: the canonical examples/basics/main.r3 program, and
# nothing else. The interpreter binary itself is installed as
# /usr/local/bin/convex-example with the example script wired in via
# ENTRYPOINT's own argument vector, so this image needs no shell to glue
# them together (this distroless base has none) -- `docker run <image>
# <room>` appends straight onto that vector as the verifier's own unique
# room argument.
#
# CHECKPOINT NOTE: rebol/client/tests/conformance/ does not exist yet, so
# no `runtime` stage (the test-only conformance adapter, entrypoint
# /usr/local/bin/convex-adapter) exists below this one yet. No capability
# is claimed; see rebol/README.md and manifest.yaml's capabilities: [].
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS example-runtime
COPY --from=toolchain /usr/local/bin/rebol3 /usr/local/bin/convex-example
COPY --from=toolchain --chown=65532:65532 /home-scaffold/home/nonroot/.rebol /home/nonroot/.rebol
COPY --chown=65532:65532 client /app/client
COPY --chown=65532:65532 examples /app/examples
USER 65532:65532
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/convex-example", "--quiet", "/app/examples/basics/main.r3"]
