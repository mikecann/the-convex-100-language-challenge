# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The build and runtime bases are the same digest-pinned Debian image, so the
# compiled client runs against exactly the glibc and OpenSSL it was built with.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# V is not packaged by Debian, so the toolchain is built from a pinned tag and
# the tag's exact commit is verified before the compiler is built.
ARG V_REF=0.4.9
ARG V_COMMIT=39534459885e916e2765b5b0c0ed66ce15f0ab86
# V bootstraps by compiling a checked-in C translation of an earlier V
# compiler (`vc/v.c`), then uses that to compile this checkout's actual
# source. `vlang/v`'s own Makefile fetches that translation from the
# separate `vlang/vc` repository at that repository's own current HEAD by
# default, which is not the commit V_REF was tagged against - vc moves on
# every push to v's master branch, so left to itself it drifts out of sync
# with any older pinned V_REF and can fail to compile that older source
# outright. This is the `vlang/vc` commit `vlang-bot` generated from
# V_COMMIT above (its message is `[v:master] <short V_COMMIT> - V_REF`),
# found by searching that repository's history for V_COMMIT's short hash.
ARG VC_COMMIT=27942c7ab5a12b9253eb69eaf3a58699bcdd5189
ARG GIT_VERSION=1:2.39.5-0+deb12u2

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG V_REF
ARG V_COMMIT
ARG VC_COMMIT
ARG GIT_VERSION
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       make=4.3-4.1 \
       libssl-dev=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       file=1:5.44-3 \
       git=${GIT_VERSION} \
    && rm -rf /var/lib/apt/lists/*
RUN test "$(uname -m)" = x86_64
RUN set -eu; \
    if test -z "${V_COMMIT}"; then \
      echo "V_COMMIT build-arg must pin the exact vlang/v commit for ${V_REF}" >&2; \
      exit 1; \
    fi; \
    git clone --depth 1 --branch "${V_REF}" https://github.com/vlang/v /opt/v; \
    cd /opt/v; \
    test "$(git rev-parse HEAD)" = "${V_COMMIT}"; \
    mkdir -p vc; \
    cd vc; \
    git init --quiet; \
    git remote add origin https://github.com/vlang/vc; \
    git fetch --quiet --depth 1 origin "${VC_COMMIT}"; \
    test "$(git rev-parse FETCH_HEAD)" = "${VC_COMMIT}"; \
    git checkout --quiet FETCH_HEAD; \
    cd /opt/v; \
    git clone --filter=blob:none --quiet --branch thirdparty-linux-amd64 \
      https://github.com/vlang/tccbin ./thirdparty/tcc; \
    make local=1; \
    ./v symlink; \
    v version

# The educational tree stays flat under client/ and examples/. V resolves an
# `import convex` through VMODULES, so the toolchain's expected layout is built
# here inside the container instead of reshaping the repository around it.
ENV VMODULES=/build/vmodules
COPY client ./client
COPY examples ./examples
RUN set -eu; \
    mkdir -p /build/vmodules/convex /build/vmodules/conformance /build/cmd /out; \
    cp client/*.v /build/vmodules/convex/; \
    cp client/tests/*_test.v /build/vmodules/convex/; \
    cp client/tests/conformance/*.v /build/vmodules/conformance/; \
    cp client/tests/conformance/main/main.v /build/cmd/main.v; \
    cp examples/basics/main.v /build/example.v

# Formatting is a gate, not a rewrite: the README and the website show this
# exact source, so a checked-in file vfmt would change is a failure.
RUN v fmt -verify client examples
RUN v -d use_openssl vet client examples

RUN v -d use_openssl test /build/vmodules/convex
RUN v -d use_openssl test /build/vmodules/conformance

RUN v -d use_openssl -prod -o /out/convex-adapter /build/cmd/main.v \
    && v -d use_openssl -prod -o /out/convex-example /build/example.v \
    && file /out/convex-adapter /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64' \
    && ldd /out/convex-adapter \
    && ldd /out/convex-example

# The example must refuse to run without a deployment and must keep stdout
# clean while doing it, because stdout is the shared happy-path transcript.
RUN set -eu; \
    code=0; \
    /out/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# A locally issued certificate lets the shipped binary prove its own TLS path
# in the tls-closure stage below. Neither the key nor the CA is ever shipped.
RUN mkdir -p /tls \
    && openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
       -subj '/CN=convex-v-test-ca' \
       -keyout /tls/ca.key -out /tls/ca.crt >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -sha256 -nodes \
       -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
       -keyout /tls/server.key -out /tls/server.csr >/dev/null 2>&1 \
    && openssl x509 -req -sha256 -days 1 -in /tls/server.csr \
       -CA /tls/ca.crt -CAkey /tls/ca.key -CAcreateserial -copy_extensions copy \
       -out /tls/server.crt >/dev/null 2>&1
CMD ["/bin/sh", "-c", "v version && echo 'v client test stage: fmt, vet, unit tests, and both executables built'"]

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# Start from the pinned image and remove everything the client does not need.
# The shared policy and example verifier still require /bin/sh and basic POSIX
# text tools, so this is deliberately not `scratch`.
RUN set -eu; \
    # Debian points /usr/bin/awk at mawk through /etc/alternatives, and the
    # sweeps below delete that directory. Resolve every tool this stage keeps
    # to a real file first, or the survivors are left as dangling symlinks and
    # fail with "not found" despite the target binary still being present.
    for tool in sh dash id cat cut head tail tr sort uniq wc uname grep sed awk mawk; do \
      path="/usr/bin/$tool"; \
      test -L "$path" || continue; \
      target="$(readlink -f "$path")"; \
      test -f "$target" || continue; \
      cp "$target" "$path.real"; \
      mv "$path.real" "$path"; \
    done; \
    for path in /boot /home /media /mnt /opt /root /srv /var /usr/share \
                /usr/include /usr/src /usr/games /usr/sbin /sbin /usr/libexec; do \
      rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf|/etc/nsswitch.conf|/etc/ld.so.conf.d|/etc/ld.so.cache) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done; \
    rm -f /etc/.pwd.lock; \
    rm -rf /tmp; \
    mkdir -p /usr/local/bin /usr/local/share /etc/ssl/certs \
      /usr/lib/x86_64-linux-gnu/ossl-modules; \
    # This sweep deletes rm, find and mkdir themselves, so nothing but COPY may\
    # follow it. mkdir in particular is /usr/bin/mkdir and not a shell builtin,\
    # so the directories above have to exist before this runs.\
    find /usr/bin -mindepth 1 -maxdepth 1 \
      ! -name sh ! -name dash ! -name id ! -name cat ! -name cut ! -name head \
      ! -name tail ! -name tr ! -name sort ! -name uniq ! -name wc \
      ! -name uname ! -name grep ! -name sed ! -name awk ! -name mawk \
      -exec rm -rf {} +
# Only the TLS closure is added back: the base image ships glibc and the DNS
# resolver modules, but not OpenSSL, its provider modules, or a CA bundle.
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
# CONVEX_RUNTIME_VERSION is the adapter's `runtime` field, taken from the same
# pin the toolchain was built from so evidence and image cannot disagree.
ARG V_REF
ENV CONVEX_RUNTIME_VERSION="V ${V_REF}"
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test -s "$OPENSSL_CONF" \
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
    && test ! -e /etc/apt \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /sbin \
    && test ! -e /usr/sbin \
    && set -- /usr/lib/x86_64-linux-gnu/ossl-modules/* \
    && test "$#" -eq 1 \
    && for command_name in v vc cc gcc clang make cmake ld as ar apt apt-get \
         dpkg dpkg-query curl wget nc netcat ssh openssl git node python \
         python3 ruby perl java php go rustc cargo npm npx pip pip3 convex \
         busybox tar gzip; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

# The TLS closure is proven with the shipped binary and the shipped OpenSSL
# files rather than with the build stage's toolchain. `openssl` is copied in
# only for this verification stage and never reaches a published image.
FROM runtime-base AS tls-closure
USER root:root
COPY --from=test /usr/bin/openssl /usr/bin/openssl
COPY --from=test /usr/bin/timeout /usr/bin/timeout
COPY --from=test /usr/bin/sleep /usr/bin/sleep
COPY --from=test /tls /tls
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN set -eu; \
    openssl s_server -quiet -www -accept 8443 \
      -cert /tls/server.crt -key /tls/server.key >/dev/null 2>&1 & \
    server=$!; \
    ready=0; \
    for _ in 1 2 3 4 5 6 7 8 9 10; do \
      if openssl s_client -connect localhost:8443 -CAfile /tls/ca.crt \
           </dev/null >/dev/null 2>&1; then ready=1; break; fi; \
      sleep 1; \
    done; \
    test "$ready" = 1; \
    code=0; \
    CONVEX_URL=https://localhost:8443 SSL_CERT_FILE=/tls/ca.crt \
      timeout 30 /usr/local/bin/convex-example tls-closure \
      >/probe.out 2>/probe.err || code=$?; \
    kill "$server" 2>/dev/null || true; \
    cat /probe.err; \
    test "$code" -eq 1; \
    test ! -s /probe.out; \
    grep -Fq 'payload is not valid JSON' /probe.err; \
    printf '%s\n' \
      'convex-example completed a TLS handshake against a locally issued' \
      'certificate using only the shipped OpenSSL closure, then failed at' \
      'Convex envelope decoding as expected for a non-Convex TLS peer.' \
      > /usr/local/share/convex-tls-closure
# The probe files are deliberately left in place: this stage inherits the
# pruned runtime-base, which has no rm, and nothing here reaches a shipped
# image anyway — the leaf stages copy only the marker file out of this stage.

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
# Copying the marker makes the TLS closure proof a dependency of this image
# rather than an optional extra target somebody has to remember to build.
COPY --from=tls-closure /usr/local/share/convex-tls-closure /usr/local/share/convex-tls-closure
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    code=0; \
    /usr/local/bin/convex-example >/dev/null 2>&1 || code=$?; \
    test "$code" -eq 1
ENTRYPOINT ["/usr/local/bin/convex-example"]

# The adapter is last because `./run build v` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
COPY --from=tls-closure /usr/local/share/convex-tls-closure /usr/local/share/convex-tls-closure
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/bin/convex-example; \
    events=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | /usr/local/bin/convex-adapter); \
    echo "$events"; \
    echo "$events" | grep -Fq '"type":"ready"'; \
    echo "$events" | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
