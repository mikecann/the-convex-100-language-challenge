# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       chicken-bin=5.3.0-1 \
       gcc=4:12.2.0-3 \
       make=4.3-4.1 \
       libssl-dev=3.0.20-1~deb12u2 \
       zlib1g-dev=1:1.2.13.dfsg-1 \
       ca-certificates=20230311+deb12u1 \
       patch=2.7.6-7 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
    && rm -rf /var/lib/apt/lists/*
COPY client/eggs.lock client/eggs.lock
RUN test "$(uname -m)" = x86_64 \
    && csi -version 2>&1 | grep -Fq 'Version 5.3.0' \
    && chicken-install -keep -from-list client/eggs.lock
COPY client/openssl.patch client/openssl.patch
RUN patch --batch --forward --fuzz=0 \
       -d /root/.cache/chicken-install/openssl -p1 \
       < client/openssl.patch \
    && cd /root/.cache/chicken-install/openssl \
    && chicken-install -force
COPY client/ws-client.patch client/ws-client.patch
RUN patch --batch --forward --fuzz=0 \
       -d /root/.cache/chicken-install/ws-client -p1 \
       < client/ws-client.patch \
    && cd /root/.cache/chicken-install/ws-client \
    && chicken-install -force
COPY client ./client
COPY examples ./examples
RUN mkdir -p /build /out \
    && cd /build \
    && csc -O2 -d1 -s -J -o convex.so /project/client/convex.scm
RUN mkdir -p /tmp/scheme-tls \
    && openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
       -subj '/CN=scheme-test-ca' \
       -keyout /tmp/scheme-tls/ca.key \
       -out /tmp/scheme-tls/ca.crt >/dev/null 2>&1 \
    && openssl req -newkey rsa:2048 -sha256 -nodes \
       -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
       -keyout /tmp/scheme-tls/server.key \
       -out /tmp/scheme-tls/server.csr >/dev/null 2>&1 \
    && openssl x509 -req -sha256 -days 1 \
       -in /tmp/scheme-tls/server.csr \
       -CA /tmp/scheme-tls/ca.crt -CAkey /tmp/scheme-tls/ca.key \
       -CAcreateserial -copy_extensions copy \
       -out /tmp/scheme-tls/server.crt >/dev/null 2>&1
RUN csc -O2 -d1 -o /build/tls-test client/tests/tls-test.scm \
    && SSL_CERT_FILE=/tmp/scheme-tls/ca.crt /build/tls-test
RUN csc -O2 -d1 -I /build -o /build/http-test client/tests/http-test.scm \
    && CHICKEN_REPOSITORY_PATH=/build:/var/lib/chicken/11 /build/http-test
RUN csc -O2 -d1 -I /build -o /build/live-test client/tests/live-test.scm \
    && CHICKEN_REPOSITORY_PATH=/build:/var/lib/chicken/11 /build/live-test
RUN cd client/tests \
    && csc -O2 -d1 -I /build -o /build/adapter-test adapter-test.scm \
    && ADAPTER_LIBRARY_ONLY=1 \
       CHICKEN_REPOSITORY_PATH=/build:/var/lib/chicken/11 \
       /build/adapter-test
RUN cd client/tests \
    && csc -O2 -d1 -feature adapter-test-hooks -I /build \
       -o /build/adapter-live-test \
       adapter-live-test.scm \
    && ADAPTER_LIBRARY_ONLY=1 \
       CHICKEN_REPOSITORY_PATH=/build:/var/lib/chicken/11 \
       /build/adapter-live-test
RUN csc -O2 -d1 -I /build -o /build/convex-example examples/basics/main.scm \
    && code=0 \
    && CHICKEN_REPOSITORY_PATH=/build:/var/lib/chicken/11 \
       /build/convex-example >/tmp/example.out 2>/tmp/example.err || code=$? \
    && test "$code" -eq 1 \
    && test ! -s /tmp/example.out \
    && grep -Fq 'CONVEX_URL is required' /tmp/example.err
RUN csc -static -O3 -d1 -L -lssl -L -lcrypto -L -lz \
       -o /out/convex-adapter client/build-adapter.scm \
    && csc -static -O3 -d1 -L -lssl -L -lcrypto -L -lz \
       -o /out/convex-example client/build-example.scm \
    && rm -f /out/*.link \
    && file /out/convex-adapter /out/convex-example \
       | grep -Eq 'ELF 64-bit.*x86-64' \
    && ldd /out/convex-adapter | grep -Fq 'libssl.so.3' \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | /out/convex-adapter \
       | grep -Fq '"type": "closed"'
RUN csc -O2 -d1 -I /build -o /build/main-test \
       examples/basics/main-test.scm \
    && EXAMPLE_BINARY=/out/convex-example \
       CHICKEN_REPOSITORY_PATH=/build:/var/lib/chicken/11 \
       /build/main-test

# Start from the pinned non-scratch image, remove its broad filesystem with a
# temporary static helper, then copy back only the declared runtime closure.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
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
      /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libz.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
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
    && test ! -e /etc/update-motd.d \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/lib/x86_64-linux-gnu/gconv \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && set -- /lib/x86_64-linux-gnu/* \
    && test "$#" -eq 10 \
    && set -- /lib64/* \
    && test "$#" -eq 1 \
    && set -- /usr/lib/x86_64-linux-gnu/ossl-modules/* \
    && test "$#" -eq 1 \
    && for command_name in csi csc chicken chicken-install gcc cc clang make \
         cmake apt apt-get dpkg curl wget nc netcat openssl node python python3 \
         ruby perl java php go rustc cargo npm pip convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build scheme` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | /usr/local/bin/convex-adapter \
       | grep -Fq '"type": "closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
