# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG NODE_IMAGE=node:22.16.0-bookworm-slim@sha256:048ed02c5fd52e86fda6fbd2f6a76cf0d4492fd6c6fee9e2c463ed5108da0e34

FROM ${NODE_IMAGE} AS test
WORKDIR /opt/convex
COPY client/package.json client/package-lock.json ./client/
RUN cd client && npm ci --ignore-scripts
RUN ln -s client/node_modules node_modules
COPY client ./client
COPY examples ./examples
# Assert that this is a real amd64 runtime, then parse and test both the client
# and canonical example in the Docker-only toolchain.
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(node -p 'process.arch')" = x64
RUN cd client && npm run check && npm test
RUN node --test examples/basics/main.test.js
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | node client/tests/conformance/adapter.js >/tmp/adapter.ndjson && grep -Fq '"language":"javascript"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["node", "-e", "process.exit(0)"]

FROM ${NODE_IMAGE} AS production-dependencies
WORKDIR /opt/convex/client
COPY client/package.json client/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

FROM ${NODE_IMAGE} AS runtime-base
# Node is the declared target runtime. Remove package managers and development
# frontends before publishing either minimal runtime image.
# The base node image is Debian underneath and its rootfs carries perl-base
# (Priority: important, pulled in independently of anything this Dockerfile
# does) even though nothing here ever invokes perl -- `apt-get remove
# --simulate perl-base` inside this exact image reports zero reverse
# dependencies. Strip it alongside apt/dpkg rather than leaving it unclaimed.
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
COPY --from=production-dependencies /opt/convex/client/node_modules ./client/node_modules
COPY client/convex.js ./client/convex.js
RUN test "$(node -p 'process.arch')" = x64 && \
    for command_name in apt apt-get dpkg npm npx corepack perl; do \
      ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY examples/basics/main.js /opt/convex/examples/basics/main.js
USER root
RUN printf '%s\n' '#!/bin/sh' 'exec node /opt/convex/examples/basics/main.js "$@"' > /usr/local/bin/convex-example && chmod 0555 /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY client/tests/conformance/adapter.js /opt/convex/client/tests/conformance/adapter.js
USER root
RUN printf '%s\n' '#!/bin/sh' 'exec node /opt/convex/client/tests/conformance/adapter.js "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
