# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG RUBY_IMAGE=ruby:3.4.5-slim-bookworm@sha256:117c5f0aa049978501584b5393fc14de8d5c1b35f164d8d57323b39121899648

FROM ${RUBY_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples

# Ruby parses every checked-in source file before the unit tests run. This
# catches the adapter and educational example too, not only the public client.
RUN find client examples -type f -name '*.rb' -exec ruby -w -c '{}' ';'
RUN ruby -Iclient client/client_test.rb
RUN ruby -Iclient client/web_socket_test.rb
RUN ruby -Iclient client/live_test.rb
RUN ruby -Iclient examples/basics/main_test.rb

# Exercise the real conformance entrypoint without needing a deployment. The
# hello and close commands prove its NDJSON lifecycle independently of HTTP.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | \
    ruby client/tests/conformance/adapter.rb >/tmp/adapter.ndjson && \
    grep -Fq '"language":"ruby"' /tmp/adapter.ndjson && \
    grep -Fq '"type":"closed"' /tmp/adapter.ndjson

# `./run test ruby` executes the built test target after the build-time checks.
CMD ["ruby", "-e", "exit 0"]

FROM ${RUBY_IMAGE} AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client

# The standard library is enough for this demonstration. Remove the Ruby and
# Debian package-manager frontends from the final educational runtime image.
RUN rm -f \
      /usr/local/bin/bundle \
      /usr/local/bin/bundler \
      /usr/local/bin/gem \
      /usr/local/bin/irb \
      /usr/local/bin/rake \
      /usr/local/bin/rdoc \
      /usr/local/bin/ri \
      /usr/bin/apt \
      /usr/bin/apt-get \
      /usr/bin/apt-cache \
      /usr/bin/dpkg \
      /usr/bin/dpkg-deb \
      /usr/bin/dpkg-query
COPY client/convex.rb /opt/convex/client/convex.rb
COPY client/convex /opt/convex/client/convex
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.rb /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.rb /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
