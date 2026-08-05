# syntax=docker/dockerfile:1.7
ARG HASKELL_IMAGE=haskell:9.10.1@sha256:87b1db498a795e08ac4861dfe1bbd2b2a8d4d7fbcf1b97933085db2d822ec3e9
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM ${HASKELL_IMAGE} AS formatter
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    cabal update && \
    cabal install fourmolu-0.16.2.0 \
      --with-compiler=/opt/ghc/9.10.1/bin/ghc-9.10.1 \
      --index-state=2025-08-01T00:00:00Z \
      --installdir=/usr/local/bin \
      --install-method=copy \
      --overwrite-policy=always

FROM formatter AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples

# Cabal and GHC exist only in this build stage. The pinned index state in the
# project file makes dependency selection repeatable even though Hackage is
# used solely inside Docker. Fourmolu checks the exact checked-in teaching and
# client sources, rather than silently formatting a temporary build copy.
RUN test "$(uname -m)" = x86_64 && \
    test "$(/opt/ghc/9.10.1/bin/ghc-9.10.1 --print-target-platform)" = x86_64-unknown-linux && \
    fourmolu --mode check \
      client/Convex.hs \
      client/tests/conformance/AdapterTest.hs \
      client/tests/conformance/Main.hs \
      client/tests/http/Main.hs \
      client/tests/live/Main.hs \
      examples/basics/Main.hs
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    cabal update && cabal build --project-file=client/cabal.project all
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    CONVEX_ADAPTER_BIN="$(find /work/dist-newstyle -type f -path '*/convex-adapter/build/convex-adapter/convex-adapter' -print -quit)" \
      cabal test --project-file=client/cabal.project all --test-show-details=direct
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
    CONVEX_URL=http://127.0.0.1 cabal run --project-file=client/cabal.project haskell-convex:exe:convex-adapter -- 2>/dev/null | grep -Fq '"language":"haskell"'
CMD ["/bin/sh", "-c", "true"]

FROM test AS build-artifacts
RUN mkdir -p /out && \
    cp "$(find /work/dist-newstyle -type f -path '*/convex-example/build/convex-example/convex-example' -print -quit)" /out/convex-example && \
    cp "$(find /work/dist-newstyle -type f -path '*/convex-adapter/build/convex-adapter/convex-adapter' -print -quit)" /out/convex-adapter && \
    chmod 0555 /out/convex-example /out/convex-adapter

# The linked executables contain the Haskell RTS and package code. A pinned
# Debian runtime contributes glibc, DNS, /bin/sh and the POSIX text utilities
# required by the shared verifier, without retaining GHC or Cabal.
FROM ${RUNTIME_IMAGE} AS runtime-base
COPY --from=test /etc/ssl /etc/ssl
RUN rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/* && \
    rm -f /usr/bin/apt /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-config /usr/bin/apt-mark \
      /usr/bin/dpkg /usr/bin/dpkg-query /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper \
      /usr/bin/dpkg-realpath /usr/bin/dpkg-split /usr/bin/start-stop-daemon /usr/bin/deb-systemd-helper \
      /usr/bin/deb-systemd-invoke /usr/bin/perl /usr/bin/perl5.36.0 && \
    for command in ghc ghci ghc-pkg runghc runhaskell cabal stack gcc cc clang make ld as apt apt-get apt-cache dpkg perl ruby go rustc cargo curl wget node npm npx python python3 pip pip3 convex; do \
      if command -v "$command" >/dev/null 2>&1; then echo "forbidden runtime command: $command -> $(command -v $command)" >&2; exit 1; fi; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build-artifacts /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build-artifacts /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
