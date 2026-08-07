# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Mojo ships as a PyPI wheel, so the build stage necessarily has Python and
# pip in it. None of that reaches the runtime image: Mojo compiles to a native
# ELF executable, and the runtime below is `FROM scratch` holding only that
# executable, the shared libraries it actually loads, a TLS trust store, and
# the shell plus POSIX tools the shared image policy needs.
ARG BUILD_IMAGE=python:3.12-slim-bookworm@sha256:229a2c5bfa27522db7815ea81f9bed70af17ccb9de9fc7ad142b1877b5830d36
ARG MOJO_VERSION=0.26.2.0

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
ARG MOJO_VERSION
WORKDIR /work

# clang is here only because the Mojo driver shells out to a C compiler to
# link the object file it produces. libssl-dev supplies the OpenSSL symbols
# the client calls through `external_call`.
RUN apt-get update && \
    apt-get install --no-install-recommends --yes \
      binutils \
      ca-certificates \
      clang \
      file \
      libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Assert the build platform before compiling anything, so an amd64 label over
# host-platform binaries fails here rather than inside a runtime image.
RUN test "$(uname -m)" = x86_64

# The exact release is pinned. The `mojo` distribution moves between versions
# and an unpinned install would silently change the compiler under the client.
RUN pip install --no-cache-dir "mojo==${MOJO_VERSION}" && \
    mojo --version | grep -Fq "${MOJO_VERSION}"

COPY client ./client
COPY examples ./examples

# `--network=none` proves the compiler needs no service other than PyPI: no
# licence check, no telemetry round trip that could block or fail a build.
RUN --network=none set -eu; \
    mkdir -p /tmp/formatted; \
    cp -r client examples /tmp/formatted/; \
    find /tmp/formatted -name '*.mojo' -print0 | xargs -0 mojo format -q; \
    diff -ru client /tmp/formatted/client; \
    diff -ru examples /tmp/formatted/examples; \
    rm -rf /tmp/formatted

# Every binary carries an rpath for the directory the runtime image stages the
# Mojo runtime libraries in. The compiler's own rpath points into the pip
# install tree, which does not exist in the final image.
ENV MOJO_LINK="-Xlinker -lssl -Xlinker -lcrypto -Xlinker -rpath -Xlinker /usr/local/lib/convex"
RUN --network=none set -eu; \
    mkdir -p /out; \
    mojo build client/tests/conformance/adapter.mojo \
      -I client -I client/tests/conformance \
      -DMOJO_VERSION="${MOJO_VERSION}" \
      ${MOJO_LINK} -o /out/convex-adapter; \
    mojo build examples/basics/main.mojo \
      -I client ${MOJO_LINK} -o /out/convex-example; \
    mojo build client/tests/json_test.mojo -I client ${MOJO_LINK} -o /out/json-test; \
    mojo build client/tests/websocket_test.mojo -I client ${MOJO_LINK} -o /out/websocket-test; \
    mojo build client/tests/live_test.mojo -I client ${MOJO_LINK} -o /out/live-test; \
    mojo build client/tests/conformance/adapter_test.mojo \
      -I client -I client/tests/conformance ${MOJO_LINK} -o /out/adapter-test; \
    mojo build client/tests/conformance/tcp_probe.mojo \
      -I client ${MOJO_LINK} -o /out/tcp-probe; \
    file /out/convex-adapter | grep -Fq 'ELF 64-bit LSB pie executable, x86-64'; \
    file /out/convex-example | grep -Fq 'ELF 64-bit LSB pie executable, x86-64'

#
# Test stage: unit behaviour, both adapter transports, and the example's
# failure path. Everything runs while this stage is built.
#
FROM build AS test
RUN test "$(uname -m)" = x86_64
RUN /out/json-test
RUN /out/websocket-test
RUN /out/live-test
RUN /out/adapter-test

# The adapter has to answer over stdin/stdout, reject malformed input without
# an id, and close cleanly.
RUN <<'EOF'
set -eu
actual=$(printf '%s\n' \
  '{malformed' \
  '{"id":"hello","protocolVersion":1,"op":"hello"}' \
  '{"id":"unknown","op":"notAnOperation"}' \
  '{"id":"close","op":"close"}' | /out/convex-adapter)
printf '%s\n' "$actual" | grep -Fxq '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'
printf '%s\n' "$actual" | grep -Fq '"id":"hello","type":"ready","language":"mojo"'
printf '%s\n' "$actual" | grep -Fxq '{"type":"error","id":"unknown","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'
printf '%s\n' "$actual" | grep -Fxq '{"id":"close","type":"closed"}'
EOF

# ...and over the one TCP connection the shared controller actually uses.
RUN <<'EOF'
set -eu
ADAPTER_LISTEN=127.0.0.1:18080 /out/convex-adapter &
adapter_pid=$!
/out/tcp-probe
wait "$adapter_pid"
EOF

# Compiling the example is not evidence, so it is executed. With no deployment
# it must fail on stderr and print nothing at all on stdout.
RUN <<'EOF'
set -eu
status=0
/out/convex-example >/tmp/example.out 2>/tmp/example.err || status=$?
test "$status" -eq 1
test ! -s /tmp/example.out
grep -Fq 'CONVEX_URL is required' /tmp/example.err
EOF

CMD ["/bin/sh", "-c", "/out/json-test && /out/websocket-test && /out/live-test && /out/adapter-test && printf 'PASS mojo test image\\n'"]

#
# Assemble the runtime closure: the compiled binaries and nothing else.
#
FROM build AS assemble
RUN <<'EOF'
set -eu
root=/out/rootfs
modular=/usr/local/lib/python3.12/site-packages/modular/lib
mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" \
         "$root/usr/local/lib/convex" "$root/etc/ssl/certs" \
         "$root/usr/lib/x86_64-linux-gnu/ossl-modules"

# The Mojo runtime closure. libAsyncRTMojoBindings.so resolves its own
# dependencies through an `$ORIGIN` rpath, so these five have to land in one
# directory together; the executables reach that directory through the rpath
# baked in above.
for library in libKGENCompilerRTShared.so libAsyncRTMojoBindings.so \
               libAsyncRTRuntimeGlobals.so libMSupportGlobals.so libNVPTX.so; do
  cp -L "$modular/$library" "$root/usr/local/lib/convex/$library"
done

# TLS needs more than libssl: the trust store the client points OpenSSL at,
# the configuration OpenSSL reads at startup, and the provider modules it can
# load on demand.
cp -L /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"
cp -L /etc/ssl/openssl.cnf "$root/etc/ssl/openssl.cnf"
cp -L /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
      "$root/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so"

# glibc dlopens its name-service modules, so `ldd` cannot find them for us.
mkdir -p "$root/lib/x86_64-linux-gnu"
for library in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do
  cp -L "/lib/x86_64-linux-gnu/$library" "$root/lib/x86_64-linux-gnu/$library"
done
cp -L /etc/nsswitch.conf "$root/etc/nsswitch.conf"
cp -L /etc/host.conf "$root/etc/host.conf"
test ! -e /etc/gai.conf || cp -L /etc/gai.conf "$root/etc/gai.conf"

# The shared image policy and example verifier need a shell and a few POSIX
# text tools. Each is copied individually and there is no multicall binary in
# this image, so no applet hides behind any of these names.
cp -L /bin/dash "$root/bin/sh"
for tool in id cat cut head tail tr sort uniq wc uname grep sed; do
  cp -L "/usr/bin/$tool" "$root/usr/bin/$tool"
done
cp -L /usr/bin/mawk "$root/usr/bin/awk"

# Copy every shared library those objects actually load. `ldd` is run once per
# object because running it over several at a time interleaves `path:` header
# lines into the output it is being parsed from.
: > /tmp/closure
for object in /out/convex-adapter /out/convex-example \
              "$modular/libKGENCompilerRTShared.so" \
              "$modular/libAsyncRTMojoBindings.so" \
              "$modular/libAsyncRTRuntimeGlobals.so" \
              "$modular/libMSupportGlobals.so" \
              "$modular/libNVPTX.so" \
              /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
              /lib/x86_64-linux-gnu/libnss_dns.so.2 \
              /lib/x86_64-linux-gnu/libnss_files.so.2 \
              /bin/dash /usr/bin/mawk \
              /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head \
              /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq \
              /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed; do
  ldd "$object" 2>/dev/null | awk '$0 ~ /=> \// { print $3 } $0 ~ /^\t\// { print $1 }' >> /tmp/closure
done
# The Mojo runtime libraries are already staged under their rpath directory;
# copying them a second time under their build-tree path would be dead weight.
sort -u /tmp/closure | grep -v '/site-packages/modular/lib/' > /tmp/closure-unique
while IFS= read -r library; do
  test -n "$library" || continue
  cp -L --parents "$library" "$root"
done < /tmp/closure-unique

# A dereferenced copy must never leave a dangling link behind, and the ELF
# interpreter has to stay executable: the kernel loads it through the same
# permission check as the program itself.
test -z "$(find "$root" -xtype l -print)"
loader=$(find "$root" -name 'ld-linux-x86-64.so.2' -print -quit)
test -n "$loader"
chmod 0755 "$loader"
test -x "$loader"
chmod 0755 "$root/bin/sh"
EOF

#
# Runtime base: an empty filesystem plus exactly the closure assembled above.
#
FROM scratch AS runtime-base
ARG MOJO_VERSION
ENV PATH=/usr/local/bin:/usr/bin:/bin \
    LD_LIBRARY_PATH=/usr/local/lib/convex \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules
COPY --from=assemble /out/rootfs /
USER 65532:65532
RUN <<'EOF'
set -eu
test "$(id -u):$(id -g)" = 65532:65532
test "$(uname -m)" = x86_64
test -s "$SSL_CERT_FILE"
test -s /etc/ssl/openssl.cnf

# Mojo compiles ahead of time, so the runtime holds a native executable and
# its shared libraries. libKGENCompilerRTShared.so is Mojo's compiler runtime
# support library - the equivalent of libgcc, linked into every Mojo program -
# and not a compiler; there is no compiler command in this image at all.
for command_name in mojo mojo-lsp-server mojo-lldb lldb pip pip3 python python3 \
                    cc gcc g++ clang ld as ar make cmake git patch \
                    apt apt-get dpkg curl wget nc netcat busybox perl lua \
                    node npm npx ruby php go rustc cargo gem composer convex; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%s\n' "unexpected command in the final image: $command_name" >&2
    exit 1
  fi
done

# There is no multicall binary here, so an exact inventory means something.
set -- /bin/*
test "$#" -eq 1
test "$1" = /bin/sh
set -- /usr/bin/*
test "$#" -eq 13
test ! -e /usr/lib/python3.12
test ! -e /usr/local/lib/python3.12
test ! -e /var
test ! -e /tmp
EOF

FROM runtime-base AS example-runtime
COPY --from=build /out/convex-example /usr/local/bin/convex-example
RUN <<'EOF'
set -eu
test -x /usr/local/bin/convex-example
test ! -e /usr/local/bin/convex-adapter
# Executing the entrypoint from its own final image is the only way to know the
# runtime library closure is complete; a build-stage run proves nothing here.
status=0
diagnostic=$(/usr/local/bin/convex-example 2>&1 >/dev/null) || status=$?
test "$status" -eq 1
printf '%s\n' "$diagnostic" | grep -Fq 'CONVEX_URL is required'
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
RUN <<'EOF'
set -eu
test -x /usr/local/bin/convex-adapter
test ! -e /usr/local/bin/convex-example
actual=$(printf '%s\n' \
  '{"protocolVersion":1,"id":"hello","op":"hello"}' \
  '{"id":"close","op":"close"}' | /usr/local/bin/convex-adapter)
printf '%s\n' "$actual" | grep -Fq '"language":"mojo"'
printf '%s\n' "$actual" | grep -Fxq '{"id":"close","type":"closed"}'
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
