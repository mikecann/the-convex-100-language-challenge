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
COPY --from=test /etc/ssl/certs /etc/ssl/certs
COPY --from=build-artifacts /out/convex-example /tmp/closure-targets/convex-example
COPY --from=build-artifacts /out/convex-adapter /tmp/closure-targets/convex-adapter
RUN set -eu; \
    /usr/bin/rm -f /usr/bin/awk; \
    /usr/bin/ln -s mawk /usr/bin/awk; \
    for target in /tmp/closure-targets/convex-example /tmp/closure-targets/convex-adapter /usr/bin/awk /usr/bin/mawk /usr/bin/basename /usr/bin/cmp /usr/bin/cut /usr/bin/dash /usr/bin/dirname /usr/bin/env /usr/bin/find /usr/bin/grep /usr/bin/head /usr/bin/id /usr/bin/ls /usr/bin/printf /usr/bin/readlink /usr/bin/rm /usr/bin/sed /usr/bin/sh /usr/bin/sort /usr/bin/tail /usr/bin/tr /usr/bin/true /usr/bin/uname /usr/bin/wc; do /usr/bin/ldd "$target" 2>/dev/null || true; done | /usr/bin/awk '$3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }' | /usr/bin/sort -u > /tmp/runtime-libraries; \
    while IFS= read -r library; do /usr/bin/readlink -f "$library"; done < /tmp/runtime-libraries | /usr/bin/sort -u > /tmp/runtime-library-realpaths; \
    /usr/bin/find /usr/lib/x86_64-linux-gnu -xdev \( -type f -o -type l \) -print > /tmp/runtime-library-candidates; \
    while IFS= read -r path; do real_path=$(/usr/bin/readlink -f "$path" 2>/dev/null || true); if test -n "$real_path" && /usr/bin/grep -Fxq "$real_path" /tmp/runtime-library-realpaths; then continue; fi; /usr/bin/rm -f "$path"; done < /tmp/runtime-library-candidates; \
    /usr/bin/find /usr/lib/x86_64-linux-gnu -xdev -depth -type d -empty -delete; \
    /usr/bin/find /usr/lib -mindepth 1 -maxdepth 1 ! -name x86_64-linux-gnu -exec /usr/bin/rm -rf {} +; \
    /usr/bin/find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do case "$path" in /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cmp|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/ls|/usr/bin/printf|/usr/bin/readlink|/usr/bin/rm|/usr/bin/sed|/usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/wc) ;; *) /usr/bin/rm -f "$path" ;; esac; done < /tmp/runtime-commands; \
    /usr/bin/rm -rf /etc/apt /etc/alternatives /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly /etc/crontab /etc/debconf.conf /etc/dpkg /etc/init.d /etc/logrotate.conf /etc/logrotate.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d /etc/systemd /usr/libexec /usr/games /usr/include /usr/share /usr/src /usr/local /var /tmp/runtime-commands; \
    /usr/bin/rm -rf /tmp/runtime-libraries /tmp/runtime-library-realpaths /tmp/runtime-library-candidates /tmp/closure-targets; \
    /usr/bin/find /etc -mindepth 1 -maxdepth 1 -print > /tmp/runtime-etc; \
    while IFS= read -r path; do case "$path" in /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl) ;; *) /usr/bin/rm -rf "$path" ;; esac; done < /tmp/runtime-etc; \
    /usr/bin/rm -f /tmp/runtime-etc; \
    if /usr/bin/find /etc /usr/lib /var -xdev -print 2>/dev/null | /usr/bin/grep -Eq '(^|/)(apt|dpkg|debconf)([^/]*|/)|update-alternatives'; then echo "forbidden runtime package-management residue" >&2; exit 1; fi; \
    for path in /usr/local /usr/share /usr/libexec /var; do test ! -e "$path" || { echo "forbidden runtime artifact tree: $path" >&2; exit 1; }; done; \
    for path in /etc/*; do if test ! -e "$path" && test ! -L "$path"; then continue; fi; case "$path" in /etc/gai.conf|/etc/host.conf|/etc/hostname|/etc/hosts|/etc/ld.so.cache|/etc/ld.so.conf|/etc/ld.so.conf.d|/etc/nsswitch.conf|/etc/resolv.conf|/etc/ssl) ;; *) echo "unexpected runtime config: $path" >&2; exit 1 ;; esac; done; \
    for path in /usr/lib/*; do if test ! -e "$path" && test ! -L "$path"; then continue; fi; case "$path" in /usr/lib/x86_64-linux-gnu) ;; *) echo "unexpected runtime library tree: $path" >&2; exit 1 ;; esac; done; \
    if unrelated=$(/usr/bin/find /usr/lib/x86_64-linux-gnu -xdev \( -name 'libsystemd.so*' -o -name 'libpam.so*' -o -name 'libaudit.so*' -o -name 'libmount.so*' -o -name 'libext2fs.so*' -o -name 'libapt*' -o -name 'libdebconf*' -o -name 'perl*' \) -print) && test -n "$unrelated"; then echo "unrelated runtime library remains: $unrelated" >&2; exit 1; fi; \
    /usr/bin/rm -f /usr/bin/rm; \
    for command in apt apt-get apt-cache dpkg dpkg-query getent hostname ping nc openssl curl wget ghc ghci ghc-pkg runghc runhaskell cabal stack gcc cc clang make ld as perl ruby go rustc cargo node npm npx python python3 pip pip3 convex; do if command -v "$command" >/dev/null 2>&1; then echo "forbidden runtime command: $command" >&2; exit 1; fi; done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build-artifacts /out/convex-example /usr/local/bin/convex-example
RUN set -eu; test -x /usr/local/bin/convex-example; test "$(/usr/bin/find /usr/local -xdev -type f | /usr/bin/wc -l)" = 1; test ! -e /var; test ! -e /usr/share
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build-artifacts /out/convex-adapter /usr/local/bin/convex-adapter
RUN set -eu; test -x /usr/local/bin/convex-adapter; test "$(/usr/bin/find /usr/local -xdev -type f | /usr/bin/wc -l)" = 1; test ! -e /var; test ! -e /usr/share
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
