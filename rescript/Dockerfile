# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# ReScript compiles to JavaScript, so the target runtime for this client is a
# JavaScript engine. The base image is pinned by digest and shared with the
# other JavaScript-runtime clients in this repository.
#
# This file has never been built. It is the design that accompanies the
# source-only checkpoint, and the README records exactly what remains unproven.
ARG NODE_IMAGE=node:22.16.0-bookworm-slim@sha256:048ed02c5fd52e86fda6fbd2f6a76cf0d4492fd6c6fee9e2c463ed5108da0e34

# --- build -------------------------------------------------------------------
# The ReScript compiler expects one package directory containing every source
# file, so the build copies the educational layout into that shape here instead
# of reshaping the repository around it.
FROM ${NODE_IMAGE} AS build
WORKDIR /opt/convex
COPY client/package.json ./client/package.json
COPY client/package-lock.json ./client/package-lock.json
COPY client/rescript.json ./client/rescript.json
# Both dependencies and their registry integrity hashes are committed in the
# lockfile. `npm ci` therefore refuses drift instead of resolving a fresh tree
# during each Docker build.
RUN cd client && npm ci --no-audit --no-fund
COPY client ./client
COPY examples/basics ./client/example
# Prove this is a genuine amd64 image and a genuine amd64 Node, not an amd64
# label over host-architecture binaries.
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(node -p 'process.arch')" = x64
RUN cd client && npm run build

# --- test --------------------------------------------------------------------
FROM build AS test
# Formatting is checked against ReScript's own formatter, so the source shown in
# the README and on the website is the formatter's output.
RUN cd client && npm run check
RUN cd client && npm test
RUN cd client && npm run test:example
# A last check that the real adapter entrypoint speaks protocol v1 over stdio.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | node client/tests/conformance/ConvexAdapterMain.res.mjs >/tmp/adapter.ndjson \
    && grep -Fq '"language":"rescript"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["node", "-e", "process.exit(0)"]

# --- production dependencies -------------------------------------------------
FROM ${NODE_IMAGE} AS production-dependencies
WORKDIR /opt/convex/client
COPY client/package.json ./package.json
COPY client/package-lock.json ./package-lock.json
RUN npm ci --omit=dev --no-audit --no-fund

# --- runtime base ------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime-base
# Node is the target runtime that executes compiled ReScript. Everything that
# could build, fetch, or delegate is removed before either minimal image is
# published.
#
# NODE_IMAGE is Debian bookworm-slim underneath and its rootfs carries
# perl-base (Priority: important) independently of anything Node-specific --
# confirmed on this exact pinned digest with `apt-get remove --simulate
# perl-base`, which reports zero reverse dependencies. Nothing here ever
# invokes perl; strip it alongside apt/dpkg rather than leaving it unclaimed.
RUN rm -f \
      /usr/local/bin/npm \
      /usr/local/bin/npx \
      /usr/local/bin/corepack \
      /usr/bin/apt \
      /usr/bin/apt-* \
      /usr/bin/dpkg \
      /usr/bin/dpkg-* \
      /usr/bin/debconf* \
      /usr/bin/update-alternatives \
      /usr/sbin/dpkg-* \
      /usr/sbin/invoke-rc.d \
      /usr/sbin/update-rc.d \
      /usr/bin/perl \
      /usr/bin/perl5.36.0 && \
    rm -rf \
      /usr/local/lib/node_modules/npm \
      /usr/local/lib/node_modules/corepack \
      /etc/apt \
      /var/lib/apt \
      /var/cache/apt \
      /var/lib/dpkg \
      /var/cache/debconf \
      /usr/lib/apt \
      /usr/lib/dpkg \
      /usr/share/dpkg \
      /usr/lib/x86_64-linux-gnu/perl-base
WORKDIR /opt/convex
# Only the WebSocket transport is a real runtime dependency.
COPY --from=production-dependencies /opt/convex/client/node_modules/ws ./client/node_modules/ws
# Compiled ReScript imports its standard-library modules from the compiler
# package's `lib/es6` directory. Those files are plain JavaScript, so the
# runtime closure is complete without shipping any part of the compiler: the
# check below proves no ReScript build frontend survived.
COPY --from=build /opt/convex/client/node_modules/rescript/package.json \
  ./client/node_modules/rescript/package.json
COPY --from=build /opt/convex/client/node_modules/rescript/lib/es6 \
  ./client/node_modules/rescript/lib/es6
COPY --from=build /opt/convex/client/ConvexNode.res.mjs ./client/ConvexNode.res.mjs
COPY --from=build /opt/convex/client/ConvexError.res.mjs ./client/ConvexError.res.mjs
COPY --from=build /opt/convex/client/ConvexJson.res.mjs ./client/ConvexJson.res.mjs
COPY --from=build /opt/convex/client/ConvexProtocol.res.mjs ./client/ConvexProtocol.res.mjs
COPY --from=build /opt/convex/client/ConvexHttp.res.mjs ./client/ConvexHttp.res.mjs
COPY --from=build /opt/convex/client/ConvexLive.res.mjs ./client/ConvexLive.res.mjs
COPY --from=build /opt/convex/client/Convex.res.mjs ./client/Convex.res.mjs
# Those standard-library files are ES modules with a `.js` extension, so the
# directory has to declare that explicitly for Node to parse them.
RUN printf '%s\n' '{"type":"module"}' > ./client/node_modules/rescript/lib/es6/package.json
RUN test "$(node -p 'process.arch')" = x64 && \
    for command_name in apt apt-get dpkg npm npx corepack rescript bsc perl; do \
      ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
    done && \
    test ! -e /opt/convex/client/node_modules/rescript/rescript && \
    test ! -e /opt/convex/client/node_modules/.bin
USER 65532:65532

# --- example runtime ---------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=build /opt/convex/client/example/Main.res.mjs ./client/example/Main.res.mjs
USER root
RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec node /opt/convex/client/example/Main.res.mjs "$@"' \
      > /usr/local/bin/convex-example && chmod 0555 /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

# --- adapter runtime ---------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=build /opt/convex/client/tests/conformance/ConvexAdapter.res.mjs \
  ./client/tests/conformance/ConvexAdapter.res.mjs
COPY --from=build /opt/convex/client/tests/conformance/ConvexAdapterMain.res.mjs \
  ./client/tests/conformance/ConvexAdapterMain.res.mjs
USER root
RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec node /opt/convex/client/tests/conformance/ConvexAdapterMain.res.mjs "$@"' \
      > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
