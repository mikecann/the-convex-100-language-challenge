# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Janet is built from its own pinned release tag because Debian does not ship a
# recent enough interpreter, and because building it here is what lets the
# final image contain the interpreter and nothing else.
#
# The apt package pins below are exact on purpose. If a build fails resolving
# one of them, Debian has superseded that version in the archive: read the
# candidate reported by the error and update the matching ARG. Nothing else in
# this file needs to change.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG JANET_VERSION=1.37.1

#
# Build stage: compile Janet, the native byte transport, and nothing else.
#
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
ARG JANET_VERSION
WORKDIR /work
# A dated Debian snapshot makes every apt-installed build input immutable even
# though the packages are expressed by name. The previous per-package
# `=version` pins broke because Debian's live archive keeps only the latest
# point release of each package, so a rebuild after any upstream update could
# no longer resolve the old pin; the snapshot's fixed timestamp does not move.
#
# Plain HTTP rather than HTTPS: this base image ships no CA trust store (unlike
# odin's gcc-based build image), and bootstrapping one from the live archive
# first pulls in a newer libssl3 than this snapshot has, which then collides
# with libssl-dev's exact `= <version>` dependency on the older one ("held
# broken packages"). The snapshot's fixed, dated, content-addressed path is
# the actual integrity anchor either way; `trusted=yes` (no upstream
# signature check) matches the convention already established for the same
# gpgv limitation in odin/Dockerfile.
RUN printf '%s\n' \
      'deb [trusted=yes check-valid-until=no] http://snapshot.debian.org/archive/debian/20260601T000000Z bookworm main' \
      'deb [trusted=yes check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260601T000000Z bookworm-security main' \
      > /etc/apt/sources.list && \
    rm -f /etc/apt/sources.list.d/debian.sources && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get -o Acquire::Check-Valid-Until=false install --no-install-recommends --yes \
      ca-certificates \
      build-essential \
      git \
      libssl-dev \
      openssl \
      file && \
    dpkg-query -W -f='${binary:Package}=${Version}\n' | sort > /tmp/build-inputs.txt && \
    grep -Eq '^libssl-dev(:amd64)?=3\.0\.20-1~deb12u1$' /tmp/build-inputs.txt && \
    grep -Eq '^openssl=3\.0\.20-1~deb12u1$' /tmp/build-inputs.txt && \
    rm -rf /var/lib/apt/lists/* /tmp/build-inputs.txt

# The build platform is asserted before anything is compiled, so an amd64 label
# over host-platform binaries fails here rather than in a runtime image.
RUN test "$(uname -m)" = x86_64

RUN git clone --depth 1 --branch "v${JANET_VERSION}" \
      https://github.com/janet-lang/janet.git /tmp/janet \
    && cd /tmp/janet \
    && make -j"$(nproc)" \
    && make install PREFIX=/usr/local \
    && janet -v | grep -Fq "${JANET_VERSION}" \
    && printf 'built janet %s from commit %s\n' "${JANET_VERSION}" "$(git rev-parse HEAD)"

COPY client /work/client
COPY examples /work/examples

# The transport is the only compiled unit. Warnings are errors because a
# warning in a socket and TLS layer is a bug waiting to be a security report.
RUN cc -shared -fPIC -O2 -std=c11 -Wall -Wextra -Werror \
      -I/usr/local/include \
      -o /work/client/transport.so /work/client/transport.c \
      -lssl -lcrypto \
    && file /work/client/transport.so | grep -q 'ELF 64-bit.*x86-64'

#
# Test stage: style, unit behaviour, TLS verification, and both adapter modes.
#
FROM build AS test
ARG JANET_VERSION
# A single directory, which is how Janet reads JANET_PATH. Relative imports
# inside the sources resolve against each file, so this only matters to the
# one-liner probes below.
ENV JANET_PATH=/work/client \
    JANET_VERSION=${JANET_VERSION}

RUN janet /work/client/tests/lint.janet \
      /work/client/convex.janet \
      /work/client/codec.janet \
      /work/client/errors.janet \
      /work/client/http.janet \
      /work/client/json.janet \
      /work/client/websocket.janet \
      /work/client/tests/check.janet \
      /work/client/tests/fixture.janet \
      /work/client/tests/lint.janet \
      /work/client/tests/codec_test.janet \
      /work/client/tests/json_test.janet \
      /work/client/tests/http_test.janet \
      /work/client/tests/live_test.janet \
      /work/client/tests/tls_test.janet \
      /work/client/tests/conformance/adapter.janet \
      /work/client/tests/conformance/adapter_test.janet \
      /work/client/tests/conformance/adapter_memory_test.janet \
      /work/examples/basics/main.janet

RUN janet /work/client/tests/codec_test.janet
RUN janet /work/client/tests/json_test.janet
RUN janet /work/client/tests/http_test.janet
RUN janet /work/client/tests/live_test.janet

# A TLS client that connects is not a TLS client that verifies. A throwaway
# authority signs a certificate for `localhost` only, so the test can prove an
# untrusted chain and a name mismatch are both refused.
RUN <<'EOF'
set -eu
mkdir -p /tmp/tls
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=janet-test-ca' -keyout /tmp/tls/ca.key -out /tmp/tls/ca.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -sha256 -nodes -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost' \
  -keyout /tmp/tls/server.key -out /tmp/tls/server.csr >/dev/null 2>&1
openssl x509 -req -sha256 -days 1 -in /tmp/tls/server.csr \
  -CA /tmp/tls/ca.crt -CAkey /tmp/tls/ca.key -CAcreateserial -copy_extensions copy \
  -out /tmp/tls/server.crt >/dev/null 2>&1
openssl s_server -accept 14443 -cert /tmp/tls/server.crt -key /tmp/tls/server.key -www \
  >/tmp/tls/server.log 2>&1 &
server_pid=$!
sleep 2
TLS_PORT=14443 TLS_CA=/tmp/tls/ca.crt janet /work/client/tests/tls_test.janet
kill "$server_pid" 2>/dev/null || true
EOF

RUN ADAPTER_LIBRARY_ONLY=1 janet /work/client/tests/conformance/adapter_test.janet
RUN ADAPTER_LIBRARY_ONLY=1 janet /work/client/tests/conformance/adapter_memory_test.janet

# The adapter has to answer over stdin/stdout as well as over a TCP controller,
# and both are exercised here rather than only in shared conformance.
RUN <<'EOF'
set -eu
actual=$(printf '%s\n' \
  '{"protocolVersion":1,"id":"hello","op":"hello"}' \
  '{"id":"bogus","op":"notAnOperation"}' \
  '{"id":"close","op":"close"}' \
  | janet /work/client/tests/conformance/adapter.janet)
printf '%s\n' "$actual" | grep -Fq '"language":"janet"'
printf '%s\n' "$actual" | grep -Fq '"id":"bogus"'
printf '%s\n' "$actual" | grep -Fq '"name":"ProtocolError"'
printf '%s\n' "$actual" | grep -Fq '"type":"closed"'
EOF

RUN <<'EOF'
set -eu
ADAPTER_LISTEN=127.0.0.1:18080 janet /work/client/tests/conformance/adapter.janet &
adapter_pid=$!
janet -e '
(import transport :as transport)
(var conn nil)
(var attempts 0)
(while (and (nil? conn) (< attempts 100))
  (set conn (try (transport/connect "127.0.0.1" 18080 false 1000) ([_] nil)))
  (unless conn (os/sleep 0.05))
  (set attempts (+ attempts 1)))
(unless conn (error "could not reach the TCP adapter"))
(def commands
  (string "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"
          "{\"id\":\"close\",\"op\":\"close\"}\n"))
(var offset 0)
(while (< offset (length commands))
  (set offset (+ offset (transport/write conn commands offset 1000))))
(def out (buffer/new 1024))
(var rounds 0)
(while (and (< rounds 200) (nil? (string/find "\"type\":\"closed\"" (string out))))
  (transport/read conn out 65536 50)
  (set rounds (+ rounds 1)))
(def text (string out))
(unless (string/find "\"language\":\"janet\"" text)
  (error "the TCP adapter did not answer hello"))
(unless (string/find "\"type\":\"closed\"" text)
  (error "the TCP adapter did not close cleanly"))
(print "PASS janet adapter TCP mode")'
wait "$adapter_pid"
EOF

# Compiling the example is not evidence, so the example is executed. Without a
# deployment it must fail on stderr with nothing at all on stdout.
RUN <<'EOF'
set -eu
code=0
janet /work/examples/basics/main.janet >/tmp/example.out 2>/tmp/example.err || code=$?
test "$code" -eq 1
test ! -s /tmp/example.out
grep -Fq 'CONVEX_URL is required' /tmp/example.err
EOF

# Every test above ran while this stage was built. `./run test janet` also runs
# the image, so give it something fast and readable to print.
CMD ["/bin/sh", "-c", "janet /work/client/tests/codec_test.janet \
  && janet /work/client/tests/json_test.janet \
  && printf 'PASS janet test image\n'"]

#
# Assemble the runtime closure: the interpreter, the client, and nothing else.
#
FROM build AS assemble
ARG JANET_VERSION
RUN <<'EOF'
set -eu
root=/out/rootfs
mkdir -p "$root/app/client/tests/conformance" "$root/app/examples/basics" \
         "$root/usr/local/bin" "$root/usr/bin" "$root/bin" "$root/etc/ssl/certs" \
         "$root/usr/lib/x86_64-linux-gnu/ossl-modules"

cp /usr/local/bin/janet "$root/usr/local/bin/janet"
for module in transport.so convex.janet codec.janet errors.janet http.janet \
              json.janet websocket.janet; do
  cp "/work/client/$module" "$root/app/client/$module"
done
cp /work/client/tests/conformance/adapter.janet \
   "$root/app/client/tests/conformance/adapter.janet"
cp /work/examples/basics/main.janet "$root/app/examples/basics/main.janet"

# TLS needs more than the library: the CA bundle, the configuration OpenSSL
# reads at startup, and the provider modules it loads on demand.
cp /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"
cp /etc/ssl/openssl.cnf "$root/etc/ssl/openssl.cnf"
cp /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
   "$root/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so"

# Name resolution is dlopened by glibc, so ldd cannot find these for us.
cp /etc/nsswitch.conf "$root/etc/nsswitch.conf"
mkdir -p "$root/lib/x86_64-linux-gnu"
cp /lib/x86_64-linux-gnu/libnss_dns.so.2 "$root/lib/x86_64-linux-gnu/libnss_dns.so.2"
cp /lib/x86_64-linux-gnu/libnss_files.so.2 "$root/lib/x86_64-linux-gnu/libnss_files.so.2"
cp /lib/x86_64-linux-gnu/libresolv.so.2 "$root/lib/x86_64-linux-gnu/libresolv.so.2"

# The shared image policy and example verifier need a shell and a small set of
# POSIX text tools. They are copied individually; there is no multicall binary
# in this image, so there are no hidden applets behind these names.
cp /bin/dash "$root/bin/sh"
for tool in id cat cut head tail tr sort uniq wc uname grep sed; do
  cp "/usr/bin/$tool" "$root/usr/bin/$tool"
done
cp /usr/bin/mawk "$root/usr/bin/awk"

# Copy every shared library those binaries actually load.
{
  printf '%s\n' /usr/local/bin/janet /work/client/transport.so /bin/dash
  printf '%s\n' /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
  printf '%s\n' /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
  printf '/usr/bin/%s\n' id cat cut head tail tr sort uniq wc uname grep sed mawk
} | xargs ldd \
  | awk '$0 ~ /=> \// {print $3} $0 ~ /^\t\// {print $1}' \
  | sort -u \
  | xargs -r -I{} cp --parents {} "$root"

# Neither entrypoint is written here. runtime-base's rootfs deliberately
# stages no `rm` (it is `FROM scratch`, and this image's whole point is
# to hold nothing beyond what serving Convex traffic requires), so the
# example and adapter variants below each COPY in only their own
# launcher rather than both being written here and one later deleted.
EOF

#
# Runtime base: an empty filesystem plus exactly the closure assembled above.
#
FROM scratch AS runtime-base
ARG JANET_VERSION
COPY --from=assemble /out/rootfs /
ENV JANET_PATH=/app/client \
    JANET_VERSION=${JANET_VERSION} \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN <<'EOF'
set -eu
test "$(id -u):$(id -g)" = 65532:65532
test "$(uname -m)" = x86_64
test -x /usr/local/bin/janet
test -s "$SSL_CERT_FILE"
test -s /etc/ssl/openssl.cnf

# The interpreter boots, loads the native transport, and can open a TLS
# context, which is the part that silently fails when a provider is missing.
janet -e '(import transport :as transport)
          (assert (= 20 (length (transport/sha1 "abc"))))
          (assert (= 4 (length (transport/random 4))))
          (assert (> (transport/monotonic-ms) 0))'
janet -e '(import convex :as convex)
          (assert (= "janet-0.1.0" convex/client-version))'

# Janet is a Lisp: `compile` and `eval` are part of its runtime and cannot be
# removed without removing the language. No compiler *command* exists here, and
# that is what the policy is about.
for command_name in jpm janet-jpm cc gcc clang ld make cmake git patch \
                    apt apt-get dpkg curl wget nc netcat ssh openssl \
                    node python python3 ruby perl php go rustc cargo \
                    npm npx pip pip3 gem composer convex; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%s\n' "unexpected command in the final image: $command_name" >&2
    exit 1
  fi
done

# There is no multicall binary here, so an exact inventory is meaningful.
set -- /bin/*
test "$#" -eq 1
test "$1" = /bin/sh
set -- /usr/bin/*
test "$#" -eq 13
test ! -e /usr/include
test ! -e /var
test ! -e /tmp
EOF

# Each final image keeps only its own entrypoint: runtime-base carries
# neither, and each variant COPYs in exactly the one it needs.
FROM runtime-base AS example-runtime
COPY --chmod=0755 client/bin/convex-example /usr/local/bin/convex-example
RUN <<'EOF'
set -eu
test "$(id -u):$(id -g)" = 65532:65532
test -x /usr/local/bin/convex-example
test ! -e /usr/local/bin/convex-adapter
test -f /app/examples/basics/main.janet
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

# The adapter target is last so `./run build janet` gets it by default.
FROM runtime-base AS runtime
COPY --chmod=0755 client/bin/convex-adapter /usr/local/bin/convex-adapter
RUN <<'EOF'
set -eu
test "$(id -u):$(id -g)" = 65532:65532
test -x /usr/local/bin/convex-adapter
test ! -e /usr/local/bin/convex-example
actual=$(printf '%s\n' \
  '{"protocolVersion":1,"id":"hello","op":"hello"}' \
  '{"id":"close","op":"close"}' | /usr/local/bin/convex-adapter)
printf '%s\n' "$actual" | grep -Fq '"language":"janet"'
printf '%s\n' "$actual" | grep -Fq '"type":"closed"'
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
