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

FROM ${RUBY_IMAGE} AS runtime-rootfs

# Construct the runtime filesystem explicitly. It contains Ruby's interpreter
# and core libraries, their shared-library closure, CA/DNS data, and only the
# sh/id/grep commands required by the shared image and example verifiers.
RUN set -eu; \
    root=/runtime-root; \
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib" "$root/usr/share" "$root/usr/local/bin" "$root/usr/local/lib/ruby" "$root/etc"; \
    cp /usr/local/bin/ruby "$root/usr/local/bin/ruby"; \
    cp /bin/dash "$root/bin/dash"; \
    ln -s dash "$root/bin/sh"; \
    cp /usr/bin/id "$root/usr/bin/id"; \
    cp /usr/bin/grep "$root/usr/bin/grep"; \
    cp -a /usr/local/lib/ruby/3.4.0 "$root/usr/local/lib/ruby/3.4.0"; \
    rm -rf \
      "$root/usr/local/lib/ruby/3.4.0/bundler" \
      "$root/usr/local/lib/ruby/3.4.0/bundler.rb" \
      "$root/usr/local/lib/ruby/3.4.0/rubygems" \
      "$root/usr/local/lib/ruby/3.4.0/rubygems.rb"; \
    { \
      ldd /usr/local/bin/ruby /bin/dash /usr/bin/id /usr/bin/grep; \
      find /usr/local/lib/ruby/3.4.0 -type f -name '*.so' -exec ldd '{}' ';'; \
    } | awk '/=> \// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | \
      while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do \
      test ! -e "$library" || cp --parents "$library" "$root"; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/share/ca-certificates "$root/usr/share/ca-certificates"; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      test ! -e "$config" || cp --parents "$config" "$root"; \
    done

FROM scratch AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV RUBYOPT=--disable-gems
COPY --from=runtime-rootfs /runtime-root /
COPY client/convex.rb /opt/convex/client/convex.rb
COPY client/convex /opt/convex/client/convex

# Prove the deliberately tiny command surface and the absence of RubyGems,
# then load the actual client with gems disabled before publishing the layer.
RUN ["/bin/sh", "-ec", "set -- /bin/*; test \"$#\" = 2; set -- /usr/bin/*; test \"$#\" = 2; set -- /usr/local/bin/*; test \"$#\" = 1; for name in node npm python python3 curl convex gem bundle bundler irb rake rdoc ri rdbg rbs typeprof erb racc syntax_suggest apt apt-get apt-cache dpkg debconf gcc cc make; do ! command -v \"$name\" >/dev/null 2>&1 || exit 1; done; if ruby -e 'require \"rubygems\"' >/dev/null 2>&1; then echo 'RubyGems remained loadable' >&2; exit 1; fi; ruby -I/opt/convex/client -e 'require \"convex\"; abort \"RubyGems loaded\" if defined?(Gem)' "]
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.rb /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.rb /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
