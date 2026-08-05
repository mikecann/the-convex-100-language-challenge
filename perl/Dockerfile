# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG PERL_IMAGE=perl:5.42.0-threaded-bookworm@sha256:cd02f6430d6a579ece5e10498823448125200c5c50bae9eeb26a4403330d87a8
ARG RUNTIME_BASE=gcr.io/distroless/base-debian12:nonroot@sha256:63ed1103bb7803ce757fda443d559270181e2a119ba55dce79c033bcf09645b2

FROM ${PERL_IMAGE} AS tooling
# Fetch exactly the 37 locked build-only distributions, verify every archive,
# and install without dependency resolution. CPAN cannot silently select a new
# transitive version for the formatter or linter.
COPY client/tooling-cpan.lock /tmp/tooling-cpan.lock
RUN set -eu; \
    mkdir -p /tmp/cpan-dists; \
    count=0; \
    while read -r module version path expected_hash; do \
      case "$module" in ''|'#'*) continue ;; esac; \
      author=${path%%/*}; \
      first=$(printf '%.1s' "$author"); \
      first_two=$(printf '%.2s' "$author"); \
      archive=/tmp/cpan-dists/${path##*/}; \
      wget -q -O "$archive" \
        "https://cpan.metacpan.org/authors/id/$first/$first_two/$path"; \
      printf '%s  %s\n' "$expected_hash" "$archive" | sha256sum -c -; \
      count=$((count + 1)); \
    done </tmp/tooling-cpan.lock; \
    test "$count" -eq 37; \
    mkdir -p /tmp/cpan-mirror/modules; \
    printf 'File: 02packages.details.txt\nLine-Count: 0\n\n' | \
      gzip -c >/tmp/cpan-mirror/modules/02packages.details.txt.gz; \
    while read -r module version path expected_hash; do \
      case "$module" in ''|'#'*) continue ;; esac; \
      cpanm --notest --mirror-only --mirror file:///tmp/cpan-mirror \
        -L /opt/tooling \
        "/tmp/cpan-dists/${path##*/}"; \
    done </tmp/tooling-cpan.lock; \
    test "$(find /opt/tooling -type f -name .packlist | wc -l)" -eq 37; \
    while read -r module version path expected_hash; do \
      case "$module" in ''|'#'*) continue ;; esac; \
      perl -I/opt/tooling/lib/perl5 -e ' \
        my ($module, $expected) = @ARGV; \
        (my $file = $module) =~ s{::}{/}g; \
        require "$file.pm"; \
        no strict "refs"; \
        my $actual = ${"${module}::VERSION"}; \
        die "$module version $actual, expected $expected\n" \
          unless defined $actual && "$actual" eq $expected; \
      ' "$module" "$version"; \
    done </tmp/tooling-cpan.lock

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
RUN set -eu; \
    find client examples -type f \( -name '*.pm' -o -name '*.pl' \) | \
      sort | while IFS= read -r source; do \
        perl -Iclient -Iclient/tests/conformance -c "$source"; \
      done
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
COPY client /tmp/client
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
    perl -I/tmp/client \
      -MConvex -MConfig -MDigest::SHA -MFindBin -MHTTP::Tiny -MIO::Handle \
      -MIO::Socket::SSL -MJSON::PP -Mlib -MMIME::Base64 -MNet::SSLeay \
      -MSocket \
      -e ' \
        my $arch = $Config::Config{archname}; \
        print "$_\n" for grep { m{^/usr/local/lib/perl5/} } values %INC; \
        open my $maps, "<", "/proc/self/maps" or die $!; \
        while (<$maps>) { \
          print "$1\n" if m{(/usr/local/lib/perl5/\S+\.so)(?:\s|$)}; \
        } \
      ' | sort -u >/tmp/perl-runtime-files; \
    find /usr/local/lib/perl5 -type f \( \
      -path '*/auto/Net/SSLeay/*.al' -o \
      -path '*/auto/Net/SSLeay/autosplit.ix' \
    \) >>/tmp/perl-runtime-files; \
    sort -u -o /tmp/perl-runtime-files /tmp/perl-runtime-files; \
    while IFS= read -r source; do \
      cp --parents "$source" "$root"; \
    done </tmp/perl-runtime-files; \
    { \
      ldd /usr/local/bin/perl /bin/dash /usr/bin/id /usr/bin/grep; \
      while IFS= read -r source; do \
        case "$source" in *.so) ldd "$source" ;; esac; \
      done </tmp/perl-runtime-files; \
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

FROM ${RUNTIME_BASE} AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV PATH=/usr/local/bin:/usr/bin:/bin
COPY --from=runtime-rootfs /runtime-root /
COPY client/Convex.pm /opt/convex/client/Convex.pm
COPY client/Convex/ /opt/convex/client/Convex/
COPY client/tests/conformance/Adapter.pm \
  /opt/convex/client/tests/conformance/Adapter.pm
COPY client/tests/conformance/RelayGuard.pm \
  /opt/convex/client/tests/conformance/RelayGuard.pm

USER 65532:65532
RUN ["/bin/sh", "-ec", "test \"$(id -u):$(id -g)\" = 65532:65532; test ! -e /busybox/busybox; for name in gcc cc g++ c++ make ld ar as nm strip objcopy cpan cpanm perldoc prove perlcritic perltidy node npm python python3 curl wget convex apt apt-get dpkg apk rpm busybox; do if command -v \"$name\" >/dev/null 2>&1; then echo \"unexpected runtime command: $name\" >&2; exit 1; fi; done; perl -I/opt/convex/client -MConfig -MConvex -MIO::Socket::SSL -e 'exit !($Config::Config{archname} eq \"x86_64-linux-gnu-thread-multi\")'; if perl -MCPAN -e 1 2>/dev/null; then echo 'unexpected runtime module: CPAN' >&2; exit 1; fi; if perl -MExtUtils::MakeMaker -e 1 2>/dev/null; then echo 'unexpected runtime module: ExtUtils::MakeMaker' >&2; exit 1; fi"]

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.pl /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.pl \
  /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
