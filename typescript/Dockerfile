# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG NODE_IMAGE=node:22.16.0-bookworm-slim@sha256:048ed02c5fd52e86fda6fbd2f6a76cf0d4492fd6c6fee9e2c463ed5108da0e34
FROM ${NODE_IMAGE} AS test
WORKDIR /opt/convex
COPY client/package.json client/package-lock.json ./client/
RUN cd client && npm ci --ignore-scripts
RUN ln -s client/node_modules node_modules
COPY client ./client
COPY examples ./examples
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(node -p 'process.arch')" = x64
RUN cd client && npm run check && npm test
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | node client/dist/client/tests/conformance/adapter.js >/tmp/adapter.ndjson && grep -Fq '"language":"typescript"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["node", "-e", "process.exit(0)"]

FROM ${NODE_IMAGE} AS production-dependencies
WORKDIR /opt/convex/client
COPY client/package.json client/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
FROM test AS compile
RUN cd client && npm run build
FROM ${NODE_IMAGE} AS runtime-base
RUN rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* /usr/bin/debconf* /usr/bin/update-alternatives /usr/sbin/dpkg-* /usr/sbin/invoke-rc.d /usr/sbin/update-rc.d && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /etc/apt /var/lib/apt /var/cache/apt /var/lib/dpkg /var/cache/debconf /usr/lib/apt /usr/lib/dpkg /usr/share/dpkg
WORKDIR /opt/convex
COPY --from=production-dependencies /opt/convex/client/node_modules ./client/node_modules
COPY --from=compile /opt/convex/client/dist ./client/dist
RUN test "$(node -p 'process.arch')" = x64 && for command_name in apt apt-get dpkg npm npx corepack; do ! command -v "$command_name"; done
USER 65532:65532
FROM runtime-base AS example-runtime
USER root
RUN printf '%s\n' '#!/bin/sh' 'exec node /opt/convex/client/dist/examples/basics/main.js "$@"' > /usr/local/bin/convex-example && chmod 0555 /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
USER root
RUN printf '%s\n' '#!/bin/sh' 'exec node /opt/convex/client/dist/client/tests/conformance/adapter.js "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
