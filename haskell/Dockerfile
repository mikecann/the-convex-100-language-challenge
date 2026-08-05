# syntax=docker/dockerfile:1.7
ARG HASKELL_IMAGE=haskell:9.10.1@sha256:87b1db498a795e08ac4861dfe1bbd2b2a8d4d7fbcf1b97933085db2d822ec3e9
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM ${HASKELL_IMAGE} AS formatter
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    cabal update && \
    cabal install fourmolu-0.16.2.0 \
      --with-compiler=/opt/ghc/9.10.1/bin/ghc-9.10.1 \
      --index-state=2025-08-01T00:00:00Z \
      --installdir=/usr/local/bin \
      --install-method=copy \
      --overwrite-policy=always

FROM formatter AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples

# Cabal and GHC exist only in this build stage. The pinned index state in the
# project file makes dependency selection repeatable even though Hackage is
# used solely inside Docker. Fourmolu checks the exact checked-in teaching and
# client sources, rather than silently formatting a temporary build copy.
RUN test "$(uname -m)" = x86_64 && \
    test "$(/opt/ghc/9.10.1/bin/ghc-9.10.1 --print-target-platform)" = x86_64-unknown-linux && \
    fourmolu --mode check \
      client/Convex.hs \
      client/tests/conformance/AdapterTest.hs \
      client/tests/conformance/Main.hs \
      client/tests/example/CountTest.hs \
      client/tests/http/Main.hs \
      client/tests/live/Main.hs \
      examples/basics/Main.hs
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    cabal update && cabal build --project-file=client/cabal.project all
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    CONVEX_ADAPTER_BIN="$(find /work/dist-newstyle -type f -path '*/convex-adapter/build/convex-adapter/convex-adapter' -print -quit)" \
      cabal test --project-file=client/cabal.project all --test-show-details=direct
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
    CONVEX_URL=http://127.0.0.1 cabal run --project-file=client/cabal.project haskell-convex:exe:convex-adapter -- 2>/dev/null | grep -Fq '"language":"haskell"'
CMD ["/bin/sh", "-c", "true"]

FROM test AS build-artifacts
RUN mkdir -p /out && \
    cp "$(find /work/dist-newstyle -type f -path '*/convex-example/build/convex-example/convex-example' -print -quit)" /out/convex-example && \
    cp "$(find /work/dist-newstyle -type f -path '*/convex-adapter/build/convex-adapter/convex-adapter' -print -quit)" /out/convex-adapter && \
    chmod 0555 /out/convex-example /out/convex-adapter

# The linked executables contain the Haskell RTS and package code. A pinned
# Debian runtime contributes glibc, DNS, /bin/sh and the POSIX text utilities
# required by the shared verifier, without retaining GHC or Cabal.
FROM ${RUNTIME_IMAGE} AS runtime-base
COPY --from=test /etc/ssl /etc/ssl
RUN set -eu; \
    find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cmp|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/ls|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/wc) ;; \
        *) /usr/bin/rm -f "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    /usr/bin/rm -rf \
      /etc/apt \
      /etc/cron.daily/apt-compat \
      /etc/cron.daily/dpkg \
      /etc/debconf.conf \
      /etc/dpkg \
      /etc/logrotate.d/apt \
      /etc/logrotate.d/dpkg \
      /etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer \
      /etc/systemd/system/timers.target.wants/apt-daily.timer \
      /etc/systemd/system/timers.target.wants/dpkg-db-backup.timer \
      /usr/lib/apt \
      /usr/lib/dpkg \
      /usr/lib/systemd/system/apt-daily-upgrade.service \
      /usr/lib/systemd/system/apt-daily-upgrade.timer \
      /usr/lib/systemd/system/apt-daily.service \
      /usr/lib/systemd/system/apt-daily.timer \
      /usr/lib/systemd/system/dpkg-db-backup.service \
      /usr/lib/systemd/system/dpkg-db-backup.timer \
      /usr/libexec/dpkg \
      /usr/share/bash-completion/completions/apt \
      /usr/share/bash-completion/completions/debconf \
      /usr/share/bash-completion/completions/debconf-show \
      /usr/share/bug/apt \
      /usr/share/bug/dpkg \
      /usr/share/debconf \
      /usr/share/doc/apt \
      /usr/share/doc/debconf \
      /usr/share/doc/dpkg \
      /usr/share/dpkg \
      /usr/share/lintian/profiles/dpkg \
      /usr/share/polkit-1/actions/org.dpkg.pkexec.update-alternatives.policy \
      /var/cache/apt \
      /var/cache/debconf \
      /var/lib/apt \
      /var/lib/dpkg \
      /var/lib/systemd/deb-systemd-helper-enabled/apt-daily-upgrade.timer.dsh-also \
      /var/lib/systemd/deb-systemd-helper-enabled/apt-daily.timer.dsh-also \
      /var/lib/systemd/deb-systemd-helper-enabled/dpkg-db-backup.timer.dsh-also \
      /var/lib/systemd/deb-systemd-helper-enabled/timers.target.wants/apt-daily-upgrade.timer \
      /var/lib/systemd/deb-systemd-helper-enabled/timers.target.wants/apt-daily.timer \
      /var/lib/systemd/deb-systemd-helper-enabled/timers.target.wants/dpkg-db-backup.timer \
      /var/log/* \
      /tmp/runtime-commands; \
    if /usr/bin/find /etc /usr/lib /usr/libexec /usr/share /var -xdev -print 2>/dev/null | \
      /usr/bin/grep -Eq '(^|/)(apt|dpkg|debconf)([^/]*|/)|update-alternatives'; then \
      echo "forbidden runtime package-management residue:" >&2; \
      /usr/bin/find /etc /usr/lib /usr/libexec /usr/share /var -xdev -print 2>/dev/null | \
        /usr/bin/grep -E '(^|/)(apt|dpkg|debconf)([^/]*|/)|update-alternatives' >&2; \
      exit 1; \
    fi; \
    /usr/bin/rm -f /usr/bin/rm; \
    for command in apt apt-get apt-cache dpkg dpkg-query getent hostname ping nc openssl curl wget ghc ghci ghc-pkg runghc runhaskell cabal stack gcc cc clang make ld as perl ruby go rustc cargo node npm npx python python3 pip pip3 convex; do \
      if command -v "$command" >/dev/null 2>&1; then echo "forbidden runtime command: $command" >&2; exit 1; fi; \
    done; \
    for path in /etc/apt /etc/dpkg /var/lib/dpkg /usr/lib/apt /usr/lib/dpkg /usr/share/dpkg; do \
      if test -e "$path"; then echo "forbidden runtime helper tree: $path" >&2; exit 1; fi; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build-artifacts /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build-artifacts /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
