# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG SWIFT_IMAGE=swift:6.1.2-noble@sha256:9096456b6dd5f3dcb1f64152601de3d96f40e48ac98354fefa9ffa9abf2dd6bf

FROM --platform=linux/amd64 ${SWIFT_IMAGE} AS dependencies
WORKDIR /work
COPY client/Package.swift client/Package.resolved ./
RUN swift package resolve

FROM dependencies AS test
COPY client ./
COPY examples ./examples
RUN --mount=type=cache,id=swift-amd64-build-v2,target=/work/.build \
    find . -path './.build' -prune -o -name '*.swift' -print0 | xargs -0 swift-format lint --strict && \
    swift test --configuration release && \
    test "$(uname -m)" = x86_64 && \
    swift -print-target-info | grep -q 'x86_64-unknown-linux-gnu' && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
      .build/release/convex-adapter | grep -q '"language":"swift"' && \
    mkdir -p /out && \
    cp .build/release/convex-adapter /out/convex-adapter && \
    cp .build/release/convex-example /out/convex-example

FROM --platform=linux/amd64 swift:6.1.2-noble-slim@sha256:bf926ea857fa4e28a549bdc8ab2554d97e31bf323dce1d80594b6bce7acac19e AS runtime-common
# Keep the pinned glibc and Swift runtime distribution, but remove its package
# environment and Perl interpreter completely. The final image remains a real
# non-scratch OS image with the shell and text tools required by shared policy.
RUN set -eu; \
    rm -f \
      /usr/bin/apt /usr/bin/apt-* \
      /usr/bin/dpkg /usr/bin/dpkg-* \
      /usr/bin/debconf /usr/bin/debconf-* \
      /usr/bin/perl /usr/bin/perl[0-9]* \
      /usr/bin/cpan /usr/bin/cpan[0-9]* /usr/bin/corelist /usr/bin/enc2xs \
      /usr/bin/h2ph /usr/bin/h2xs /usr/bin/instmodsh /usr/bin/json_pp \
      /usr/bin/libnetcfg /usr/bin/pl2pm /usr/bin/pod2html /usr/bin/pod2man \
      /usr/bin/pod2text /usr/bin/pod2usage /usr/bin/podchecker /usr/bin/prove \
      /usr/bin/ptar /usr/bin/ptardiff /usr/bin/ptargrep /usr/bin/shasum \
      /usr/bin/splain /usr/bin/xsubpp /usr/bin/zipdetails; \
    rm -rf \
      /etc/apt /etc/dpkg /etc/cron.daily/apt-compat /etc/cron.daily/dpkg \
      /etc/logrotate.d/apt /etc/logrotate.d/dpkg \
      /etc/systemd/system/timers.target.wants/apt-* \
      /etc/systemd/system/timers.target.wants/dpkg-* \
      /var/lib/apt /var/cache/apt /var/log/apt \
      /var/lib/dpkg /var/cache/debconf /usr/lib/dpkg /usr/share/dpkg /usr/share/debconf \
      /usr/lib/apt /usr/libexec/dpkg /usr/sbin/dpkg-* \
      /usr/lib/systemd/system/apt-* /usr/lib/systemd/system/dpkg-* \
      /usr/share/bash-completion/completions/apt \
      /usr/share/bug/apt /usr/share/bug/dpkg \
      /usr/share/doc/apt /usr/share/doc/dpkg /usr/share/doc/libapt-* \
      /usr/share/doc/perl /usr/share/doc/perl-* \
      /usr/share/lintian/overrides/apt /usr/share/lintian/overrides/dpkg \
      /usr/share/lintian/overrides/libapt-* /usr/share/lintian/overrides/perl-* \
      /usr/share/lintian/profiles/dpkg \
      /usr/lib/perl /usr/lib/perl5 /usr/share/perl /usr/share/perl5 \
      /usr/lib/*/perl /usr/lib/*/perl-base \
      /var/lib/systemd/deb-systemd-helper-enabled/apt-* \
      /var/lib/systemd/deb-systemd-helper-enabled/dpkg-* \
      /var/lib/systemd/deb-systemd-helper-enabled/timers.target.wants/apt-* \
      /var/lib/systemd/deb-systemd-helper-enabled/timers.target.wants/dpkg-*; \
    rm -f /var/log/dpkg.log /usr/lib/*/libapt-pkg.so* /usr/lib/*/libapt-private.so*; \
    for required in sh id grep sed awk; do command -v "$required" >/dev/null; done; \
    for forbidden in apt apt-get apt-cache dpkg dpkg-query perl perl5.38.2 swift swiftc swift-format swift-package clang gcc git npm npx node python python3 pip pip3 curl convex; do \
      if command -v "$forbidden" >/dev/null 2>&1; then exit 1; fi; \
    done; \
    test ! -e /etc/apt; \
    test ! -e /var/lib/apt; \
    test ! -e /var/lib/dpkg; \
    test ! -e /usr/share/perl5; \
    test ! -e /usr/lib/x86_64-linux-gnu/perl-base; \
    test -z "$(find /etc /usr /var \( -iname 'apt' -o -iname 'apt-*' -o -iname 'dpkg' -o -iname 'dpkg-*' -o -iname 'perl' -o -iname 'perl-*' -o -iname 'libapt-*' \) 2>/dev/null)"
USER 65532:65532

FROM runtime-common AS example-runtime
COPY --from=test --chown=65532:65532 --chmod=0555 /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-common AS runtime
COPY --from=test --chown=65532:65532 --chmod=0555 /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
