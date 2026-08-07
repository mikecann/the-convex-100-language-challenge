# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ca-certificates=20230311+deb12u1 \
       libssl3=3.0.20-1~deb12u2 \
       libssl-dev=3.0.20-1~deb12u2 \
       openssl=3.0.20-1~deb12u2 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       binutils=2.40-2 \
       file=1:5.44-3 \
    && rm -rf /var/lib/apt/lists/*

# The Factor release is a pinned upstream tarball; Debian ships no Factor
# package. The digest is the one GitHub publishes for this release asset.
ADD --checksum=sha256:9f971e935414c0d46d9090632464d66994ee797bacc91cc8b739db3b0857a25a \
    https://github.com/factor/factor/releases/download/0.101/factor-linux-x86-64-0.101.tar.gz \
    /tmp/factor.tar.gz
RUN mkdir -p /opt \
    && tar -xzf /tmp/factor.tar.gz -C /opt \
    && rm -f /tmp/factor.tar.gz \
    && test -x /opt/factor/factor \
    && test "$(uname -m)" = x86_64 \
    && file /opt/factor/factor | grep -Eq 'ELF 64-bit.*x86-64'

# Factor loads a vocabulary from its own directory tree, so the Docker build
# projects the educational layout under client/ and examples/ into the
# toolchain's expected shape instead of reshaping the repository.
COPY client ./client
COPY examples ./examples
RUN set -eu; \
    root=/opt/factor/work/convex; \
    mkdir -p "$root/json" "$root/transport" "$root/live" "$root/adapter" \
             "$root/example/tests" "$root/tests/support" "$root/tests/json" \
             "$root/tests/http" "$root/tests/websocket" "$root/tests/live" \
             "$root/tests/adapter" "$root/tests/tls" "$root/tests/lint"; \
    cp client/convex.factor "$root/convex.factor"; \
    cp client/json.factor "$root/json/json.factor"; \
    cp client/transport.factor "$root/transport/transport.factor"; \
    cp client/live.factor "$root/live/live.factor"; \
    cp client/tests/conformance/adapter.factor "$root/adapter/adapter.factor"; \
    cp client/deploy-adapter.factor "$root/adapter/deploy.factor"; \
    cp examples/basics/main.factor "$root/example/example.factor"; \
    cp client/deploy-example.factor "$root/example/deploy.factor"; \
    cp examples/basics/main-test.factor "$root/example/tests/tests.factor"; \
    cp client/tests/support.factor "$root/tests/support/support.factor"; \
    cp client/tests/json-test.factor "$root/tests/json/json.factor"; \
    cp client/tests/http-test.factor "$root/tests/http/http.factor"; \
    cp client/tests/websocket-test.factor \
       "$root/tests/websocket/websocket.factor"; \
    cp client/tests/live-test.factor "$root/tests/live/live.factor"; \
    cp client/tests/adapter-test.factor "$root/tests/adapter/adapter.factor"; \
    cp client/tests/tls-test.factor "$root/tests/tls/tls.factor"; \
    cp client/tests/lint.factor "$root/tests/lint/lint.factor"

# Factor ships no standalone formatter, so the checked-in sources are checked
# for the presentation rules the README and website depend on.
RUN /opt/factor/factor -run=convex.tests.lint \
       /project/client/convex.factor \
       /project/client/json.factor \
       /project/client/transport.factor \
       /project/client/live.factor \
       /project/client/deploy-adapter.factor \
       /project/client/deploy-example.factor \
       /project/client/tests/support.factor \
       /project/client/tests/lint.factor \
       /project/client/tests/json-test.factor \
       /project/client/tests/http-test.factor \
       /project/client/tests/websocket-test.factor \
       /project/client/tests/live-test.factor \
       /project/client/tests/adapter-test.factor \
       /project/client/tests/tls-test.factor \
       /project/client/tests/conformance/adapter.factor \
       /project/examples/basics/main.factor \
       /project/examples/basics/main-test.factor

# Compiling every vocabulary is Factor's own stack-effect check: a word whose
# effect cannot be inferred fails to load here rather than at run time.
RUN /opt/factor/factor -e='USING: vocabs.loader ; "convex" require "convex.adapter" require "convex.example" require'

RUN /opt/factor/factor -run=convex.tests.json
RUN /opt/factor/factor -run=convex.tests.http
RUN /opt/factor/factor -run=convex.tests.websocket
RUN /opt/factor/factor -run=convex.tests.live
RUN /opt/factor/factor -run=convex.tests.adapter
RUN /opt/factor/factor -run=convex.example.tests

# A local CA and server certificate let the TLS closure be exercised here
# instead of being discovered during hosted verification.
RUN mkdir -p /tmp/factor-tls \
    && openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
       -subj '/CN=factor-test-ca' \
       -keyout /tmp/factor-tls/ca.key \
       -out /tmp/factor-tls/ca.crt >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -sha256 -nodes \
       -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
       -keyout /tmp/factor-tls/server.key \
       -out /tmp/factor-tls/server.csr >/dev/null 2>&1 \
    && openssl x509 -req -sha256 -days 1 \
       -in /tmp/factor-tls/server.csr \
       -CA /tmp/factor-tls/ca.crt -CAkey /tmp/factor-tls/ca.key \
       -CAcreateserial -copy_extensions copy \
       -out /tmp/factor-tls/server.crt >/dev/null 2>&1 \
    && cat /tmp/factor-tls/server.crt /tmp/factor-tls/server.key \
       > /tmp/factor-tls/server.pem
RUN SSL_CERT_FILE=/tmp/factor-tls/ca.crt \
    /opt/factor/factor -run=convex.tests.tls

# Deploy produces a single self-contained executable: the Factor VM with a
# stripped image embedded in it. The dictionary and word definitions are
# stripped, so neither runtime image carries an interactive compiler.
#
# `deploy` ignores the working directory `cd /out` sets up: it changes into
# `deploy-directory get`, which defaults to `resource:` (the Factor install
# tree), and on this platform `tools.deploy.unix` appends a `.out` suffix.
# The directory is named after `deploy-name` (from each deploy.factor config)
# but the file inside it is named after the *vocabulary*, not the deploy
# name: deploying "convex.adapter" with deploy-name "convex-adapter" lands at
# `/opt/factor/convex-adapter/convex.adapter.out`, not `/out/convex-adapter`
# -- confirmed by deploying it directly and inspecting where it landed. `find`
# locates it by vocab name without hard-coding that internal directory path,
# which is not documented and not part of Factor's public interface.
RUN mkdir -p /out \
    && cd /out \
    && /opt/factor/factor -e='USING: tools.deploy ; "convex.adapter" deploy' \
    && /opt/factor/factor -e='USING: tools.deploy ; "convex.example" deploy' \
    && find /opt/factor -type f -name 'convex.adapter.out' \
       -exec mv {} /out/convex-adapter \; \
    && find /opt/factor -type f -name 'convex.example.out' \
       -exec mv {} /out/convex-example \; \
    && chmod 0755 /out/convex-adapter /out/convex-example \
    && file /out/convex-adapter /out/convex-example \
       | grep -Eq 'ELF 64-bit.*x86-64'

# Record the dynamic closure the deployed binaries actually need, and fail the
# build here rather than in a minimal image if it grows unexpectedly.
RUN ldd /out/convex-adapter > /tmp/adapter-ldd.txt \
    && ldd /out/convex-example > /tmp/example-ldd.txt \
    && ! grep -q 'not found' /tmp/adapter-ldd.txt \
    && ! grep -q 'not found' /tmp/example-ldd.txt \
    && cat /tmp/adapter-ldd.txt \
    && for library in libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1 \
         libpthread.so.0 libdl.so.2 librt.so.1; do \
         grep -Fq "$library" /tmp/adapter-ldd.txt \
           || printf 'note: %s is not directly linked\n' "$library"; \
       done

# The deployed binaries dlopen OpenSSL by its unversioned name, so both
# aliases have to exist in the runtime image.
RUN cp -L /usr/lib/x86_64-linux-gnu/libssl.so /tmp/libssl.so \
    && cp -L /usr/lib/x86_64-linux-gnu/libcrypto.so /tmp/libcrypto.so

RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 /out/convex-adapter > /tmp/probe.ndjson \
    && grep -Fq '"type":"ready"' /tmp/probe.ndjson \
    && grep -Fq '"language":"factor"' /tmp/probe.ndjson \
    && grep -Fq '{"id":"close","type":"closed"}' /tmp/probe.ndjson

RUN code=0 \
    && /out/convex-example >/tmp/example.out 2>/tmp/example.err || code=$? \
    && test "$code" -eq 1 \
    && test ! -s /tmp/example.out \
    && grep -Fq 'CONVEX_URL is required' /tmp/example.err

CMD ["/opt/factor/factor", "-run=convex.tests.json"]

# Start from the pinned non-scratch carrier, remove its broad filesystem with a
# temporary static helper, then copy back only the declared runtime closure.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      /busybox rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) /busybox rm -rf "$path" ;; \
      esac; \
    done; \
    /busybox rm -rf /etc/.pwd.lock; \
    /busybox mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/libdl.so.2
COPY --from=test /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/libpthread.so.0
COPY --from=test /lib/x86_64-linux-gnu/librt.so.1 /lib/x86_64-linux-gnu/librt.so.1
COPY --from=test /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/libgcc_s.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/x86_64-linux-gnu/libstdc++.so.6
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /tmp/libssl.so /usr/lib/x86_64-linux-gnu/libssl.so
COPY --from=test /tmp/libcrypto.so /usr/lib/x86_64-linux-gnu/libcrypto.so
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(uname -m)" = x86_64 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /etc/update-motd.d \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /opt \
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
    && set -- /usr/lib/x86_64-linux-gnu/ossl-modules/* \
    && test "$#" -eq 1 \
    && for command_name in factor gcc cc clang make cmake ld apt apt-get \
         dpkg curl wget nc netcat openssl node python python3 ruby perl \
         java php go rustc cargo npm pip tclsh convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build factor` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
       | grep -Fq '{"id":"close","type":"closed"}'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
