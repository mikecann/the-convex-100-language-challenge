# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG NODE_IMAGE=node:22.16.0-bookworm-slim@sha256:048ed02c5fd52e86fda6fbd2f6a76cf0d4492fd6c6fee9e2c463ed5108da0e34

FROM --platform=linux/amd64 ${NODE_IMAGE} AS build
WORKDIR /opt/convex
COPY client/package.json client/package-lock.json ./client/
RUN cd client && npm ci --ignore-scripts
COPY client ./client
COPY examples ./examples
# CoffeeScript is intentionally confined to this build stage. The final images
# receive JavaScript emitted from these teaching sources, never the compiler.
# client/ stays --bare because it is `require()`d as a plain CommonJS module.
# examples/ is not: main.coffee awaits at the top level, which is only legal
# CommonJS syntax inside a wrapping function, so it needs the async IIFE
# coffee adds automatically once it is not told to omit it.
#
# npm installed into client/node_modules beside the .coffee sources, but the
# compiled output — and the tests run below — live under the sibling /build
# tree, which has no node_modules of its own; the symlink below is what lets
# a compiled test's `require('ws')` resolve as Node walks up looking for it.
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(node -p 'process.arch')" = x64 \
 && ./client/node_modules/.bin/coffee --compile --bare --output /build/client client \
 && ./client/node_modules/.bin/coffee --compile --output /build/examples examples \
 && node --check /build/client/convex.js \
 && node --check /build/client/tests/conformance/adapter.js \
 && node --check /build/examples/basics/main.js \
 && ln -s /opt/convex/client/node_modules /build/node_modules \
 && node --test /build/client/tests/*.test.js /build/client/tests/conformance/*.test.js /build/examples/basics/*.test.js

# `./run test` targets a stage literally named `test`. The compile, the
# node --check syntax gate and the node --test suites all already ran as
# RUN steps while building `build`, above, so this is a pure alias.
FROM build AS test
CMD ["/bin/sh", "-ec", "echo 'coffeescript compile, syntax checks and node --test already passed while building this image'"]

FROM --platform=linux/amd64 ${NODE_IMAGE} AS runtime-base
# Node is the declared target runtime. ws is an ordinary WebSocket transport
# library, copied without npm, npx, corepack, or the CoffeeScript compiler.
# The base node image is Debian underneath and its rootfs carries perl-base
# (Priority: important, pulled in independently of anything this Dockerfile
# does) even though nothing here ever invokes perl -- `apt-get remove
# --simulate perl-base` inside this exact image reports zero reverse
# dependencies. Strip it alongside apt/dpkg rather than leaving it unclaimed.
RUN rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
 /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* /usr/bin/debconf* \
 /usr/bin/update-alternatives /usr/sbin/dpkg-* /usr/sbin/invoke-rc.d /usr/sbin/update-rc.d \
 /usr/bin/perl /usr/bin/perl5.36.0 \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
 /etc/apt /var/lib/apt /var/cache/apt /var/lib/dpkg /var/cache/debconf /usr/lib/apt /usr/lib/dpkg /usr/share/dpkg \
 /usr/lib/x86_64-linux-gnu/perl-base
WORKDIR /opt/convex
COPY --from=build /opt/convex/client/node_modules/ws ./node_modules/ws
COPY --from=build /build/client/convex.js ./client/convex.js
RUN test "$(node -p 'process.arch')" = x64 \
 && for command_name in apt apt-get dpkg npm npx corepack coffee perl; do ! command -v "$command_name" >/dev/null 2>&1 || exit 1; done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /build/examples/basics/main.js /opt/convex/examples/basics/main.js
USER root
RUN printf '%s\n' '#!/bin/sh' 'exec node /opt/convex/examples/basics/main.js "$@"' > /usr/local/bin/convex-example && chmod 0555 /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /build/client/tests/conformance/adapter.js /opt/convex/client/tests/conformance/adapter.js
USER root
RUN printf '%s\n' '#!/bin/sh' 'exec node /opt/convex/client/tests/conformance/adapter.js "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
