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
    /usr/bin/rm -f /usr/bin/awk; \
    /usr/bin/ln -s mawk /usr/bin/awk; \
    find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cmp|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/ls|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/wc) ;; \
        *) /usr/bin/rm -f "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    /usr/bin/rm -rf \
      /etc/apt \
      /etc/alternatives \
      /etc/cron.d \
      /etc/cron.daily \
      /etc/cron.hourly \
      /etc/cron.monthly \
      /etc/cron.weekly \
      /etc/crontab \
      /etc/debconf.conf \
      /etc/dpkg \
      /etc/init.d \
      /etc/logrotate.conf \
      /etc/logrotate.d \
      /etc/rc0.d \
      /etc/rc1.d \
      /etc/rc2.d \
      /etc/rc3.d \
      /etc/rc4.d \
      /etc/rc5.d \
      /etc/rc6.d \
      /etc/rcS.d \
      /etc/systemd \
      /usr/lib/apt \
      /usr/lib/dpkg \
      /usr/lib/systemd \
      /usr/libexec \
      /usr/games \
      /usr/include \
      /usr/share \
      /usr/src \
      /var/cache \
      /var/backups \
      /var/lib \
      /var/local \
      /var/mail \
      /var/opt \
      /var/spool \
      /var/tmp \
      /var/log/* \
      /tmp/runtime-commands; \
    /usr/bin/rm -f \
      /usr/lib/*/libapt-pkg.so* \
      /usr/lib/*/libapt-private.so* \
      /usr/lib/*/libdebconfclient.so*; \
    /usr/bin/find /etc -mindepth 1 -maxdepth 1 -print > /tmp/runtime-etc; \
    while IFS= read -r path; do \
      case "$path" in \
        /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/localtime|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl|/etc/timezone) ;; \
        *) /usr/bin/rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-etc; \
    /usr/bin/rm -f /tmp/runtime-etc; \
    /usr/bin/find /usr/lib -mindepth 1 -maxdepth 1 -print > /tmp/runtime-usr-lib; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/lib/locale|/usr/lib/x86_64-linux-gnu) ;; \
        *) /usr/bin/rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-usr-lib; \
    /usr/bin/rm -f /tmp/runtime-usr-lib; \
    /usr/bin/rm -rf /usr/local/man; \
    if /usr/bin/find /etc /usr/lib /usr/libexec /usr/share /var -xdev -print 2>/dev/null | \
      /usr/bin/grep -Eq '(^|/)(apt|dpkg|debconf)([^/]*|/)|update-alternatives'; then \
      echo "forbidden runtime package-management residue:" >&2; \
      /usr/bin/find /etc /usr/lib /usr/libexec /usr/share /var -xdev -print 2>/dev/null | \
        /usr/bin/grep -E '(^|/)(apt|dpkg|debconf)([^/]*|/)|update-alternatives' >&2; \
      exit 1; \
    fi; \
    for path in \
      /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily /etc/cron.hourly \
      /etc/cron.monthly /etc/cron.weekly /etc/crontab /etc/debconf.conf \
      /etc/dpkg /etc/init.d /etc/logrotate.conf /etc/logrotate.d \
      /etc/systemd /usr/lib/apt /usr/lib/dpkg /usr/lib/systemd \
      /usr/libexec /usr/games /usr/include /usr/share /usr/src \
      /var/backups /var/cache /var/lib /var/local /var/mail /var/opt \
      /var/spool /var/tmp; do \
      if test -e "$path"; then echo "forbidden runtime artifact tree: $path" >&2; exit 1; fi; \
    done; \
    for path in /etc/*; do \
      if test ! -e "$path" && test ! -L "$path"; then continue; fi; \
      case "$path" in \
        /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/localtime|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl|/etc/timezone) ;; \
        *) echo "unexpected runtime config: $path" >&2; exit 1 ;; \
      esac; \
    done; \
    for path in /usr/lib/*; do \
      if test ! -e "$path" && test ! -L "$path"; then continue; fi; \
      case "$path" in \
        /usr/lib/locale|/usr/lib/x86_64-linux-gnu) ;; \
        *) echo "unexpected runtime library tree: $path" >&2; exit 1 ;; \
      esac; \
    done; \
    if test -e /usr/local/man; then echo "forbidden runtime manual tree" >&2; exit 1; fi; \
    if /usr/bin/find /usr/lib -xdev \
      \( -name 'libapt-pkg.so*' -o -name 'libapt-private.so*' -o -name 'libdebconfclient.so*' \) \
      -print -quit | /usr/bin/grep -q .; then \
      echo "forbidden runtime package library remains" >&2; \
      exit 1; \
    fi; \
    /usr/bin/rm -f /usr/bin/rm; \
    for command in apt apt-get apt-cache dpkg dpkg-query getent hostname ping nc openssl curl wget ghc ghci ghc-pkg runghc runhaskell cabal stack gcc cc clang make ld as perl ruby go rustc cargo node npm npx python python3 pip pip3 convex; do \
      if command -v "$command" >/dev/null 2>&1; then echo "forbidden runtime command: $command" >&2; exit 1; fi; \
    done; \
    true
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build-artifacts /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build-artifacts /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
