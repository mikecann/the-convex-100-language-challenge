# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The Agda compiler is built from Hackage inside this stage only. Dependency
# resolution is pinned by index state; the exact resolved versions must be
# frozen into client/cabal.project.freeze once a build has succeeded.
ARG BUILD_IMAGE=haskell:9.10.1@sha256:87b1db498a795e08ac4861dfe1bbd2b2a8d4d7fbcf1b97933085db2d822ec3e9
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG HACKAGE_INDEX_STATE=2025-08-01T00:00:00Z
ARG AGDA_VERSION=2.7.0.1

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG HACKAGE_INDEX_STATE
ARG AGDA_VERSION
WORKDIR /project
RUN test "$(uname -m)" = x86_64 \
    && ghc --print-target-platform | grep -Fq x86_64-unknown-linux
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       busybox-static \
       file \
       libtinfo-dev \
       zlib1g-dev \
       openssl \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# `cabal install --install-method=copy` only copies the executable; the Agda
# package's data files (the primitive modules under `share/lib/prim` that
# every module implicitly needs, even with `--no-libraries`) stay in the
# cabal store, which lives entirely inside the two cache mounts below. A
# cache mount's contents are never committed to an image layer, so the
# datadir baked into the compiled binary would point at a path that no
# longer exists in any later step or stage. Copy the package's `share`
# tree out to a normal image path while the cache is still mounted, and
# point every later invocation at it with `Agda_datadir` (the env var the
# Cabal-generated `Paths_Agda` module consults before falling back to the
# baked-in, now-dangling store path).
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    cabal update \
    && cabal install "Agda-${AGDA_VERSION}" \
       --index-state="${HACKAGE_INDEX_STATE}" \
       --installdir=/usr/local/bin \
       --install-method=copy \
       --overwrite-policy=always \
    && agda_pkgdir=$(find /root/.cabal/store -maxdepth 2 -type d \
         -iname "Agda-${AGDA_VERSION}-*" | head -n 1) \
    && test -n "$agda_pkgdir" \
    && mkdir -p /usr/local/share/agda \
    && cp -r "$agda_pkgdir/share/." /usr/local/share/agda/ \
    && test -d /usr/local/share/agda/lib/prim \
    && agda --version | grep -Fq "${AGDA_VERSION}"
ENV Agda_datadir=/usr/local/share/agda

# The only Haskell packages the foreign boundary needs. `tls` is a pure Haskell
# implementation, so the final runtime carries a certificate bundle rather than
# an OpenSSL provider tree.
#
# `--package-env` records absolute `package-db` paths into the cabal store
# (see /opt/convex-ffi below), and every later `agda --compile` step -- each
# its own RUN instruction, later stages included -- calls GHC, which reads
# that file and needs those paths to resolve. The store lives under the same
# cache mount as the Agda datadir above, so without intervention those paths
# go dangling the moment this RUN completes. Copying the store out is not
# enough on its own: cabal's package `.conf` files and ghc-pkg's binary
# index also embed the original `/root/.cabal/store/...` paths internally,
# so rewriting just the package-env file would still leave GHC unable to
# find the actual interface and library files those entries point at.
# Committing a symlink at that exact path (below, after this cache-mounted
# RUN completes) lets every already-recorded absolute path keep resolving
# with no metadata rewriting required.
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.local/state/cabal \
    cabal install --lib \
      base bytestring text network tls crypton-x509-system \
      --index-state="${HACKAGE_INDEX_STATE}" \
      --package-env=/opt/convex-ffi \
    && test -s /opt/convex-ffi \
    && mkdir -p /usr/local/lib/cabal-store \
    && cp -r /root/.cabal/store/. /usr/local/lib/cabal-store/
ENV GHC_ENVIRONMENT=/opt/convex-ffi
RUN mkdir -p /root/.cabal \
    && ln -s /usr/local/lib/cabal-store /root/.cabal/store

FROM toolchain AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples

# Type checking is the formatting and lint gate for this language: Agda has no
# separate formatter, and `--safe`-adjacent flags plus the totality checker
# reject the classes of defect a linter would.
RUN mkdir -p /build /out \
    && agda -i client --no-libraries client/Convex.agda \
    && agda -i client --no-libraries client/Convex/Live.agda

RUN agda -i client -i client/tests --no-libraries \
      --compile --compile-dir=/build/protocol \
      --ghc-flag=-threaded --ghc-flag=-O1 \
      client/tests/ProtocolTest.agda \
    && /build/protocol/ProtocolTest

RUN agda -i client -i client/tests -i client/tests/conformance --no-libraries \
      --compile --compile-dir=/build/adapterunit \
      --ghc-flag=-threaded --ghc-flag=-O1 \
      client/tests/AdapterTest.agda \
    && /build/adapterunit/AdapterTest

RUN agda -i client -i client/tests --no-libraries \
      --compile --compile-dir=/build/live \
      --ghc-flag=-threaded --ghc-flag=-O1 \
      client/tests/LiveFixtureTest.agda \
    && /build/live/LiveFixtureTest

# A real TLS exchange from this stage, against a locally issued certificate.
# The client must accept the requested DNS name and reject a certificate that
# does not cover the address it was asked to connect to.
# `-copy_extensions copy` (the usual way to carry a CSR's SAN into the
# signed cert) is an OpenSSL 3.x flag. `haskell:9.10.1` is Debian 11
# bullseye with OpenSSL 1.1.1, which rejects it outright ("Unrecognized
# flag copy_extensions") and this RUN step's stderr was being discarded, so
# the failure surfaced only as a bare non-zero exit. `-extfile` naming the
# SAN directly is the 1.1.1-compatible way to get the same signed
# extension.
RUN mkdir -p /tmp/agda-tls \
    && openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
       -subj '/CN=agda-test-ca' \
       -keyout /tmp/agda-tls/ca.key -out /tmp/agda-tls/ca.crt >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -sha256 -nodes \
       -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
       -keyout /tmp/agda-tls/server.key -out /tmp/agda-tls/server.csr >/dev/null 2>&1 \
    && printf 'subjectAltName=DNS:localhost\n' > /tmp/agda-tls/server.ext \
    && openssl x509 -req -sha256 -days 1 -in /tmp/agda-tls/server.csr \
       -CA /tmp/agda-tls/ca.crt -CAkey /tmp/agda-tls/ca.key -CAcreateserial \
       -extfile /tmp/agda-tls/server.ext -out /tmp/agda-tls/server.crt >/dev/null 2>&1

# `crypton-x509-system`'s Unix loader (used by Convex.Prim's TLS boundary)
# reads `SYSTEM_CERTIFICATE_PATH`, not `SSL_CERT_FILE` (the OpenSSL
# convention). The latter is silently ignored, so the client would fall
# back to the real `/etc/ssl/certs` bundle, which never trusts this run's
# freshly minted CA.
RUN agda -i client -i client/tests --no-libraries \
      --compile --compile-dir=/build/tls \
      --ghc-flag=-threaded --ghc-flag=-O1 \
      client/tests/TlsTest.agda \
    && ( openssl s_server -quiet -naccept 2 -accept 8443 \
           -cert /tmp/agda-tls/server.crt -key /tmp/agda-tls/server.key \
           -www >/dev/null 2>&1 & ) \
    && sleep 2 \
    && SYSTEM_CERTIFICATE_PATH=/tmp/agda-tls/ca.crt TLS_FIXTURE_PORT=8443 /build/tls/TlsTest

RUN agda -i client -i examples/basics --no-libraries \
      --compile --compile-dir=/build/example \
      --ghc-flag=-threaded --ghc-flag=-O1 \
      examples/basics/Main.agda \
    && cp /build/example/Main /out/convex-example \
    && chmod 0555 /out/convex-example \
    && file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64'

# The canonical example must refuse to run without a deployment, and must not
# write anything to stdout when it fails.
RUN code=0 \
    && /out/convex-example >/tmp/example.out 2>/tmp/example.err || code=$? \
    && test "$code" -eq 1 \
    && test ! -s /tmp/example.out \
    && grep -Fq 'CONVEX_URL is required' /tmp/example.err

RUN agda -i client -i client/tests/conformance --no-libraries \
      --compile --compile-dir=/build/adapter \
      --ghc-flag=-threaded --ghc-flag=-O1 \
      client/tests/conformance/Adapter.agda \
    && cp /build/adapter/Adapter /out/convex-adapter \
    && chmod 0555 /out/convex-adapter \
    && file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64'

# Exercise the exact adapter binary over stdin/stdout before it is copied into
# a minimal image.
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 /out/convex-adapter >/tmp/adapter.out \
    && grep -Fq '"language":"agda"' /tmp/adapter.out \
    && grep -Fq '"type":"closed"' /tmp/adapter.out
CMD ["/bin/sh", "-c", "true"]

# Start from the pinned runtime image, remove its broad filesystem with a
# static helper mounted from the build stage, then copy back only the declared
# runtime closure.
FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /usr/lib/x86_64-linux-gnu /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
# The `test` stage builds on the `haskell` image, which is Debian 11
# (bullseye): a pre-usrmerge layout where /lib and /usr/lib, and /bin and
# /usr/bin, are genuinely distinct directories -- unlike this bookworm-based
# runtime image, and unlike every other language here, whose build and
# runtime stages share one bookworm base. A file Debian packages under
# /usr/lib on bullseye is not reachable at the matching /lib path (and vice
# versa for /bin vs /usr/bin), so COPY fails outright instead of silently
# grabbing the wrong file. Every source path below was confirmed by running
# `ldd` on the compiled convex-adapter/convex-example and on each coreutils
# binary inside the test stage, rather than assumed from the bookworm layout
# the other languages share; destinations keep the /lib vs /usr/lib split
# those languages use, since the runtime image's dynamic linker searches
# both by default.
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libz.so.1
COPY --from=test /lib/x86_64-linux-gnu/librt.so.1 /lib/x86_64-linux-gnu/librt.so.1
COPY --from=test /lib/x86_64-linux-gnu/libutil.so.1 /lib/x86_64-linux-gnu/libutil.so.1
COPY --from=test /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/libdl.so.2
COPY --from=test /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/libpthread.so.0
COPY --from=test /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/libgcc_s.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/x86_64-linux-gnu/libstdc++.so.6
# `libgmp.so.10` is packaged under /usr/lib on bullseye, not /lib. GHC's RTS
# does not need libffi at runtime for an ahead-of-time compiled, non-GHCi
# binary on x86_64 (confirmed absent from `ldd` on both convex-adapter and
# convex-example) -- it is only the interpreter/ARM adjustor-thunk fallback
# -- so the previous libffi.so.8 line, besides pointing at a bullseye path
# that does not exist at all (apt installs only libffi7; GHC's own private
# libffi.so.8 lives under /opt/ghc, unused by these binaries), was dead
# weight rather than a genuine runtime dependency.
COPY --from=test /usr/lib/x86_64-linux-gnu/libgmp.so.10 /lib/x86_64-linux-gnu/libgmp.so.10
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /bin/uname /usr/bin/uname
COPY --from=test /bin/grep /usr/bin/grep
COPY --from=test /bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /usr/lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
# bullseye's /bin/grep links the legacy libpcre.so.3 (PCRE1); bookworm's grep
# -- what every other language's copy list assumes -- links libpcre2 instead.
COPY --from=test /lib/x86_64-linux-gnu/libpcre.so.3 /lib/x86_64-linux-gnu/libpcre.so.3
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && set -- /lib64/* \
    && test "$#" -eq 1 \
    && for command_name in agda ghc ghci ghc-pkg runghc runhaskell cabal stack \
         gcc cc clang make cmake apt apt-get dpkg curl wget nc netcat openssl \
         node python python3 ruby perl java php go rustc cargo npm pip convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build agda` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
