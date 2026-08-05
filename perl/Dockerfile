# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG PERL_IMAGE=perl:5.42.0-threaded-bookworm@sha256:cd02f6430d6a579ece5e10498823448125200c5c50bae9eeb26a4403330d87a8
FROM ${PERL_IMAGE} AS test
WORKDIR /opt/convex
COPY client ./client
COPY examples ./examples
# Only ordinary HTTP/TLS, JSON, and WebSocket support is installed. Convex
# behaviour stays in the checked-in Perl modules above.
RUN cpanm --notest IO::Socket::SSL MIME::Base64 URI HTTP::Tiny JSON::PP
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(perl -e 'print $Config::Config{archname}' -MConfig)" = x86_64-linux-gnu-thread-multi
RUN find client examples -type f \( -name '*.pm' -o -name '*.pl' \) -exec perl -Iclient -c '{}' \;
RUN perl -Iclient client/client_test.pl && perl -Iclient client/live_test.pl
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | perl -Iclient client/tests/conformance/adapter.pl >/tmp/adapter.ndjson && grep -Fq '"language":"perl"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["perl", "-e", "exit 0"]

FROM ${PERL_IMAGE} AS runtime-base
WORKDIR /opt/convex
ENV CONVEX_CLIENT_PATH=/opt/convex/client
COPY --from=test /usr/local/lib/perl5 /usr/local/lib/perl5
COPY client /opt/convex/client
# Perl is the declared target runtime, but CPAN and build frontends must not
# remain in either final image.
RUN rm -f /usr/local/bin/cpan /usr/local/bin/cpanm /usr/local/bin/perldoc /usr/local/bin/prove /usr/local/bin/perlbug /usr/local/bin/perlthanks /usr/bin/cpan /usr/bin/curl /usr/bin/python /usr/bin/python3 /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* && rm -rf /root/.cpanm /var/lib/apt /var/lib/dpkg /etc/apt
RUN for command_name in cpan cpanm curl node npm python python3 convex; do if command -v "$command_name" >/dev/null 2>&1; then exit 1; fi; done && perl -I/opt/convex/client -MConvex -e 'print $Config::Config{archname}' -MConfig | grep -qx x86_64-linux-gnu-thread-multi
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.pl /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.pl /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
