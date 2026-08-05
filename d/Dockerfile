# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:38a76d01668772e381ad2826d876627c89e7133e2f8a0f5d567306798b0f2a16

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS build
RUN apt-get update && apt-get install --no-install-recommends --yes \
    ca-certificates=20250419 dub=1.40.0-1 file=1:5.46-5 ldc=1:1.40.0-5 gcc=4:14.2.0-1 libc6-dev=2.41-12+deb13u3 libcurl4-openssl-dev=8.14.1-2+deb13u4 \
    && curl-config --protocols | grep -Fx WS \
    && curl-config --protocols | grep -Fx WSS \
    && rm -rf /var/lib/apt/lists/*
RUN dub fetch libdparse@0.25.1 \
    && dub run dfmt@0.15.1 -- --version \
    && test -x /root/.dub/packages/dfmt/0.15.1/dfmt/bin/dfmt
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN set -eu; \
    formatter=/root/.dub/packages/dfmt/0.15.1/dfmt/bin/dfmt; \
    find client examples -name '*.d' -type f -print | sort | while read -r source; do \
      "$formatter" "$source" > /tmp/formatted.d; \
      cmp -s "$source" /tmp/formatted.d || { echo "dfmt check failed: $source" >&2; exit 1; }; \
    done; \
    ldc2 -wi -w -d-version=ConvexAdapter -of=/out-client-test -Iclient -unittest client/convex.d client/tests/client_test.d client/tests/transport_test.d client/tests/live_test.d -L-lcurl -L-lcrypto \
    && /out-client-test \
    && ldc2 -wi -w -d-version=ConvexAdapter -d-version=AdapterUnitTest -unittest -of=/out-adapter-test -Iclient client/convex.d client/tests/conformance/main.d -L-lcurl -L-lcrypto \
    && /out-adapter-test \
    && ldc2 -wi -w -d-version=ConvexAdapter -of=/out-adapter -Iclient client/convex.d client/tests/conformance/main.d -L-lcurl -L-lcrypto \
    && ldc2 -wi -w -of=/out-stopped-reader-server client/tests/stopped_reader_server.d \
    && ldc2 -wi -w -d-version=ExampleUnitTest -unittest -of=/out-example-test -Iclient client/convex.d examples/basics/main.d -L-lcurl -L-lcrypto \
    && /out-example-test \
    && ldc2 -wi -w -of=/out-example -Iclient client/convex.d examples/basics/main.d -L-lcurl -L-lcrypto \
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
RUN set -eu; \
    /out-stopped-reader-server & server_pid=$!; \
    sleep 0.1; \
    mkfifo /tmp/stopped-output; \
    exec 3<>/tmp/stopped-output; \
    printf '%s\n' '{"id":"large","op":"query","path":"demo:state","args":{}}' > /tmp/stopped-input; \
    CONVEX_URL=http://127.0.0.1:18153 /out-adapter < /tmp/stopped-input > /tmp/stopped-output & adapter_pid=$!; \
    peak_kib=0; checks=0; \
    while kill -0 "$adapter_pid" 2>/dev/null; do \
      rss_kib=$(awk '/VmRSS:/ { print $2 }' "/proc/$adapter_pid/status" 2>/dev/null || echo 0); \
      test "$rss_kib" -le "$peak_kib" || peak_kib=$rss_kib; \
      checks=$((checks + 1)); \
      test "$checks" -lt 100; \
      sleep 0.02; \
    done; \
    wait "$adapter_pid"; \
    wait "$server_pid"; \
    exec 3>&-; \
    test "$peak_kib" -gt 0; \
    test "$peak_kib" -lt 131072; \
    printf 'stopped-reader peak RSS: %s KiB\n' "$peak_kib"

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
      /etc/apt /etc/dpkg /etc/systemd /usr/lib/apt /usr/lib/dpkg /usr/lib/systemd \
      /var/lib/systemd /etc/init.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d \
      /etc/cron.daily/apt-compat /etc/cron.daily/dpkg /etc/logrotate.d/apt /etc/logrotate.d/dpkg \
      /etc/perl /usr/lib/perl* /usr/share/perl* /usr/share/doc/perl* /usr/share/man/man1/perl* \
      /usr/sbin/* \
    && rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark \
      /usr/bin/dpkg /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query /usr/bin/dpkg-realpath /usr/bin/dpkg-split /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger \
      /usr/bin/dpkg-preconfigure /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure \
      /usr/bin/perl /usr/bin/perl5.* /usr/bin/bash /usr/bin/bashbug /usr/bin/rbash \
      /usr/bin/deb-systemd-helper /usr/bin/deb-systemd-invoke /usr/sbin/invoke-rc.d /usr/sbin/policy-rc.d /usr/sbin/service /usr/sbin/update-rc.d /usr/sbin/start-stop-daemon \
      /usr/bin/debconf /usr/bin/debconf-* /usr/bin/update-alternatives /usr/bin/run-parts /usr/bin/ischroot /usr/bin/savelog /usr/bin/tempfile /usr/bin/localedef /usr/bin/ldd /usr/bin/sqv \
    && ! command -v apt && ! command -v apt-get && ! command -v dpkg && ! command -v curl && ! command -v wget \
    && ! command -v gcc && ! command -v ldc2 && ! command -v dub && ! command -v perl && ! command -v bash \
    && ! command -v node && ! command -v python && ! command -v python3 && ! command -v service \
    && ! command -v update-alternatives && ! command -v installkernel && ! command -v run-parts \
    && ! command -v ischroot && ! command -v savelog && ! command -v tempfile \
    && ! command -v pam-auth-update && ! command -v update-passwd && ! command -v add-shell \
    && ! command -v remove-shell && ! command -v ldconfig && ! command -v ldd && ! command -v localedef
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
