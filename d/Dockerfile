# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:38a76d01668772e381ad2826d876627c89e7133e2f8a0f5d567306798b0f2a16

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS build
RUN apt-get update && apt-get install --no-install-recommends --yes \
    ca-certificates=20250419 file=1:5.46-5 ldc=1:1.40.0-5 gcc=4:14.2.0-1 libc6-dev=2.41-12+deb13u3 libcurl4-openssl-dev=8.14.1-2+deb13u4 \
    && curl-config --protocols | grep -Fx WS \
    && curl-config --protocols | grep -Fx WSS \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN ldc2 -wi -w -d-version=ConvexAdapter -of=/out-client-test -Iclient -unittest client/convex.d client/tests/client_test.d client/tests/transport_test.d client/tests/live_test.d -L-lcurl \
    && /out-client-test \
    && ldc2 -wi -w -d-version=ConvexAdapter -d-version=AdapterUnitTest -unittest -of=/out-adapter-test -Iclient client/convex.d client/tests/conformance/main.d -L-lcurl \
    && /out-adapter-test \
    && ldc2 -wi -w -d-version=ConvexAdapter -of=/out-adapter -Iclient client/convex.d client/tests/conformance/main.d -L-lcurl \
    && ldc2 -wi -w -of=/out-example -Iclient client/convex.d examples/basics/main.d -L-lcurl \
    && test "$(uname -m)" = x86_64 \
    && file /out-adapter | grep -F 'x86-64'

FROM build AS test
RUN set -eu; \
    actual=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"unknown","op":"nope"}' \
      '{"id":"live","op":"subscribe","subscriptionId":"s","path":"demo:state","args":{}}' \
      '{"id":"close","op":"close"}' | /out-adapter); \
    printf '%s\n' "$actual" | grep -F '"id":"hello"' | grep -F '"type":"ready"'; \
    printf '%s\n' "$actual" | grep -F '"id":"unknown"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"live"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"close","type":"closed"'
RUN set -eu; \
    ADAPTER_LISTEN=127.0.0.1:18080 /out-adapter & adapter_pid=$!; \
    sleep 0.2; \
    actual=$(printf '%s\n' '{"protocolVersion":1,"id":"tcp","op":"hello"}' '{"id":"close","op":"close"}' | bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080; cat >&3; cat <&3'); \
    wait "$adapter_pid"; \
    printf '%s\n' "$actual" | grep -F '"id":"tcp"' | grep -F '"type":"ready"'

FROM build AS runtime-libs
# Phobos opens libcurl at runtime, so it is not visible in the adapter's own
# ELF dependencies. Resolve both graphs here and copy precisely that closure.
RUN set -eu; \
    mkdir -p /runtime-root; \
    copy_library() { \
      library=$(readlink -f "$1"); \
      cp --parents "$library" /runtime-root; \
      soname=$(objdump -p "$library" | awk '/SONAME/ { print $2; exit }'); \
      if test -n "$soname" && test "$soname" != "$(basename "$library")"; then \
        ln -sf "$(basename "$library")" "/runtime-root$(dirname "$library")/$soname"; \
      fi; \
    }; \
    { ldd /out-adapter; ldd /lib/x86_64-linux-gnu/libcurl.so.4.8.0; echo /lib/x86_64-linux-gnu/libcurl.so.4.8.0; } | \
      awk '/=> \/[^ ]+/ { print $3 } /^\// { print $1 }' | sort -u | \
      while read -r library; do copy_library "$library"; done; \
    cp --parents /etc/ssl/certs/ca-certificates.crt /etc/ssl/openssl.cnf /runtime-root; \
    cp -a --parents /usr/lib/x86_64-linux-gnu/ossl-modules /runtime-root; \
    if test -d /usr/lib/x86_64-linux-gnu/engines-3; then \
      cp -a --parents /usr/lib/x86_64-linux-gnu/engines-3 /runtime-root; \
    fi

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
RUN rm -rf /var/lib/apt /var/lib/dpkg /var/cache/apt /var/cache/debconf /var/log/* \
      /var/lib/systemd /etc/init.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d \
      /etc/perl /usr/lib/perl* /usr/share/perl* /usr/share/doc/perl* /usr/share/man/man1/perl* \
    && rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark \
      /usr/bin/dpkg /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query /usr/bin/dpkg-realpath /usr/bin/dpkg-split /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger \
      /usr/bin/dpkg-preconfigure /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure \
      /usr/bin/perl /usr/bin/perl5.* /usr/bin/bash /usr/bin/bashbug /usr/bin/rbash \
      /usr/bin/deb-systemd-helper /usr/bin/deb-systemd-invoke /usr/sbin/invoke-rc.d /usr/sbin/policy-rc.d /usr/sbin/service /usr/sbin/update-rc.d /usr/sbin/start-stop-daemon \
      /usr/bin/debconf /usr/bin/debconf-* /usr/sbin/update-alternatives /usr/sbin/update-shells /usr/bin/sqv \
    && ! command -v apt && ! command -v apt-get && ! command -v dpkg && ! command -v curl && ! command -v wget \
    && ! command -v gcc && ! command -v ldc2 && ! command -v dub && ! command -v perl && ! command -v bash \
    && ! command -v node && ! command -v python && ! command -v python3 && ! command -v service
# Debian's /lib is a symlink to /usr/lib, so copy the resolved directory rather
# than attempting to overwrite that symlink.
COPY --from=runtime-libs /runtime-root/usr/lib/x86_64-linux-gnu/ /usr/lib/x86_64-linux-gnu/
COPY --from=runtime-libs /runtime-root/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=runtime-libs /runtime-root/etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
