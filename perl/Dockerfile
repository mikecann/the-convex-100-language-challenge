# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG PERL_IMAGE=perl:5.42.0-threaded-bookworm@sha256:cd02f6430d6a579ece5e10498823448125200c5c50bae9eeb26a4403330d87a8

FROM ${PERL_IMAGE} AS tooling
# These are build-only quality tools. Runtime HTTP, JSON, TLS, and base64
# modules come from the digest-pinned Perl image at the exact versions asserted
# below; no unpinned CPAN install contributes to either runtime image.
RUN cpanm --notest -L /opt/tooling \
      Perl::Tidy@20260705 \
      Perl::Critic@1.156

FROM ${PERL_IMAGE} AS test
WORKDIR /opt/convex
COPY --from=tooling /opt/tooling /opt/tooling
ENV PERL5LIB=/opt/tooling/lib/perl5
COPY client ./client
COPY examples ./examples

RUN test "$(dpkg --print-architecture)" = amd64 && \
    test "$(perl -MConfig -e 'print $Config::Config{archname}')" = \
      x86_64-linux-gnu-thread-multi && \
    perl -MHTTP::Tiny -MJSON::PP -MIO::Socket::SSL -MMIME::Base64 \
      -e 'exit !( \
        $HTTP::Tiny::VERSION eq "0.090" && \
        $JSON::PP::VERSION eq "4.16" && \
        $IO::Socket::SSL::VERSION eq "2.091" && \
        $MIME::Base64::VERSION eq "3.16_01" \
      )'

# Compare each checked-in source against Perl::Tidy output without modifying
# the build context, then apply the ecosystem linter at its strictest severity.
RUN set -eu; \
    find client examples -type f \( -name '*.pm' -o -name '*.pl' \) | \
      sort | while IFS= read -r source; do \
        /opt/tooling/bin/perltidy -q -o /tmp/formatted "$source"; \
        cmp -s "$source" /tmp/formatted || { \
          printf '%s\n' "$source is not formatted by Perl::Tidy 20260705" >&2; \
          exit 1; \
        }; \
      done
RUN /opt/tooling/bin/perlcritic --severity 5 client examples
RUN find client examples -type f \( -name '*.pm' -o -name '*.pl' \) \
      -exec perl -Iclient -c '{}' \;
RUN timeout --signal=TERM --kill-after=5s 30s \
      perl -Iclient client/client_test.pl && \
    timeout --signal=TERM --kill-after=5s 30s \
      perl -Iclient client/web_socket_test.pl && \
    timeout --signal=TERM --kill-after=5s 30s \
      perl -Iclient client/live_test.pl && \
    timeout --signal=TERM --kill-after=5s 30s \
      perl -Iclient client/tests/conformance/adapter_test.pl
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | \
    perl -Iclient client/tests/conformance/adapter.pl >/tmp/adapter.ndjson && \
    grep -Fq '"language":"perl"' /tmp/adapter.ndjson && \
    grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["perl", "-e", "exit 0"]

FROM ${PERL_IMAGE} AS runtime-rootfs
# Assemble a runtime-only root explicitly. The official Perl build image is a
# toolchain image, so using it directly would leak gcc, make, ld, and ar.
RUN set -eu; \
    root=/runtime-root; \
    mkdir -p \
      "$root/bin" \
      "$root/usr/bin" \
      "$root/usr/local/bin" \
      "$root/usr/local/lib/perl5" \
      "$root/usr/lib" \
      "$root/usr/share" \
      "$root/etc"; \
    cp /usr/local/bin/perl "$root/usr/local/bin/perl"; \
    cp /bin/dash "$root/bin/dash"; \
    ln -s dash "$root/bin/sh"; \
    cp /usr/bin/id "$root/usr/bin/id"; \
    cp /usr/bin/grep "$root/usr/bin/grep"; \
    cp -a /usr/local/lib/perl5/5.42.0 "$root/usr/local/lib/perl5/5.42.0"; \
    cp -a /usr/local/lib/perl5/site_perl "$root/usr/local/lib/perl5/site_perl"; \
    { \
      ldd /usr/local/bin/perl /bin/dash /usr/bin/id /usr/bin/grep; \
      find /usr/local/lib/perl5 -type f -name '*.so' -exec ldd '{}' ';'; \
    } | awk '/=> \// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | \
      sort -u | while IFS= read -r library; do \
        cp --parents "$library" "$root"; \
      done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do \
      test ! -e "$library" || cp --parents "$library" "$root"; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/share/ca-certificates "$root/usr/share/ca-certificates"; \
    test ! -d /usr/lib/x86_64-linux-gnu/ossl-modules || \
      cp -a --parents /usr/lib/x86_64-linux-gnu/ossl-modules "$root"; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      test ! -e "$config" || cp --parents "$config" "$root"; \
    done

FROM scratch AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV PATH=/usr/local/bin:/usr/bin:/bin
COPY --from=runtime-rootfs /runtime-root /
COPY client/Convex.pm /opt/convex/client/Convex.pm
COPY client/Convex/ /opt/convex/client/Convex/
COPY client/tests/conformance/RelayGuard.pm \
  /opt/convex/client/tests/conformance/RelayGuard.pm

USER 65532:65532
RUN ["/bin/sh", "-ec", "for name in gcc cc g++ c++ make ld ar as nm strip objcopy cpan cpanm perldoc prove perlcritic perltidy node npm python python3 curl convex apt apt-get dpkg; do if command -v \"$name\" >/dev/null 2>&1; then echo \"unexpected runtime command: $name\" >&2; exit 1; fi; done; perl -I/opt/convex/client -MConvex -MIO::Socket::SSL -e 'exit 0'"]

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.pl /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.pl \
  /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
