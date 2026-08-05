# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS curl-build
RUN apt-get update && apt-get install --yes --no-install-recommends \
    build-essential=12.9 \
    libssl-dev=3.0.20-1~deb12u2 \
    pkg-config=1.8.1-1 && \
    rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6 \
    https://curl.se/download/curl-8.21.0.tar.xz /tmp/curl.tar.xz
RUN tar -xJf /tmp/curl.tar.xz -C /tmp && \
    cd /tmp/curl-8.21.0 && \
    ./configure --prefix=/opt/curl --disable-shared --enable-static \
      --enable-websockets --with-openssl --without-zlib --without-libpsl \
      --without-libidn2 --without-brotli --without-zstd --without-nghttp2 \
      --without-nghttp3 --without-libssh2 --without-librtmp --disable-dict \
      --disable-file --disable-ftp --disable-gopher --disable-imap \
      --disable-ldap --disable-ldaps --disable-mqtt --disable-pop3 \
      --disable-rtsp --disable-smb --disable-smtp --disable-telnet \
      --disable-tftp --disable-manual && \
    make -j2 && \
    make install && \
    /opt/curl/bin/curl-config --protocols | grep -Fx WS && \
    /opt/curl/bin/curl-config --protocols | grep -Fx WSS

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS build
RUN apt-get update && apt-get install --yes --no-install-recommends \
    build-essential=12.9 \
    clang-14=1:14.0.6-12 \
    clang-format-14=1:14.0.6-12 \
    gnustep-make=2.9.1-2 \
    libgnustep-base-dev=1.28.1+really1.28.0-5 \
    libobjc-12-dev=12.2.0-14+deb12u1 \
    libjson-c-dev=0.16-2 \
    libssl-dev=3.0.20-1~deb12u2 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY --from=curl-build /opt/curl /opt/curl
COPY client ./client
COPY examples ./examples
RUN clang-format-14 --style=LLVM --dry-run --Werror \
      client/ConvexClient.m client/ConvexClient.h client/ConvexClientInternal.h \
      client/tests/conformance/main.m client/tests/live_test.m \
      examples/basics/main.m && \
    objc_flags="$(gnustep-config --objc-flags) -I/usr/lib/gcc/x86_64-linux-gnu/12/include" && \
    base_libs="$(gnustep-config --base-libs)" && \
    curl_libs="$(/opt/curl/bin/curl-config --static-libs)" && \
    clang-14 $objc_flags -I/opt/curl/include -D_POSIX_C_SOURCE=200809L -std=gnu17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m client/tests/conformance/main.m $curl_libs -ljson-c $base_libs -o /out-adapter && \
    clang-14 $objc_flags -I/opt/curl/include -DCONVEX_ADAPTER_TESTING -D_POSIX_C_SOURCE=200809L -std=gnu17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m client/tests/conformance/main.m $curl_libs -ljson-c $base_libs -o /out-adapter-test && \
    clang-14 $objc_flags -I/opt/curl/include -D_POSIX_C_SOURCE=200809L -std=gnu17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m examples/basics/main.m $curl_libs -ljson-c $base_libs -o /out-example && \
    clang-14 $objc_flags -I/opt/curl/include -DCONVEX_CLIENT_TESTING -D_POSIX_C_SOURCE=200809L -std=gnu17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m client/tests/live_test.m $curl_libs -ljson-c -lcrypto $base_libs -o /out-live-test && \
    readelf -h /out-adapter | grep -q 'Advanced Micro Devices X86-64' && \
    readelf -d /out-adapter | grep -q 'libgnustep-base' && \
    nm -u /out-adapter | grep -q 'objc_msg'

FROM build AS test
RUN <<'EOF'
set -eu
test "$(uname -m)" = x86_64
actual=$(/out-adapter <<'COMMANDS'
{malformed
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"unknown","op":"notAnOperation"}
{"id":"close","op":"close"}
COMMANDS
)
printf '%s\n' "$actual" | grep -Fx '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'
printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready"'
printf '%s\n' "$actual" | grep -Fx '{"type":"error","id":"unknown","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'
printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
EOF
RUN /out-live-test

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
RUN apt-get update && apt-get install --yes --no-install-recommends \
    ca-certificates=20230311+deb12u1 \
    libgnustep-base1.28=1.28.1+really1.28.0-5 \
    libjson-c5=0.16-2 && \
    rm -f /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* \
      /usr/sbin/dpkg-* \
      /usr/bin/debconf /usr/bin/debconf-* /usr/bin/deb-systemd-* \
      /usr/bin/update-alternatives \
      /usr/sbin/invoke-rc.d /usr/sbin/policy-rc.d /usr/sbin/service \
      /usr/sbin/start-stop-daemon /usr/sbin/update-rc.d \
      /usr/sbin/installkernel /usr/sbin/pam-auth-update \
      /usr/sbin/update-ca-certificates /usr/sbin/update-passwd \
      /usr/sbin/add-shell /usr/sbin/remove-shell /usr/sbin/update-shells \
      /usr/bin/ischroot /usr/bin/run-parts /usr/bin/savelog \
      /usr/bin/tempfile /usr/sbin/iconvconfig /usr/sbin/ldconfig \
      /usr/sbin/shadowconfig \
      /usr/bin/openssl /usr/bin/c_rehash \
      /usr/bin/perl /usr/bin/perl[0-9]* /usr/bin/cpan* /usr/bin/corelist \
      /usr/bin/instmodsh /usr/bin/json_pp /usr/bin/perlbug /usr/bin/perldoc \
      /usr/bin/prove /usr/bin/ptar* /usr/bin/shasum /usr/bin/splain && \
    rm -rf /etc/apt /etc/dpkg /var/lib/apt /var/cache/apt /var/log/apt \
      /var/lib/dpkg /var/cache/debconf /usr/lib/apt /usr/lib/dpkg \
      /usr/libexec/dpkg /usr/share/dpkg /usr/share/debconf \
      /usr/lib/*/perl /usr/lib/perl /usr/lib/perl5 /usr/share/perl \
      /usr/share/perl5 /usr/share/doc/apt /usr/share/doc/dpkg \
      /etc/alternatives /etc/cron.daily/apt-compat /etc/cron.daily/dpkg \
      /etc/debconf.conf /etc/init.d /etc/logrotate.d/alternatives \
      /etc/logrotate.d/apt /etc/logrotate.d/dpkg /etc/rc0.d /etc/rc1.d \
      /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d \
      /etc/rcS.d /etc/systemd /usr/lib/systemd /usr/share/systemd \
      /var/lib/systemd /usr/share/bash-completion /usr/share/bug \
      /usr/share/doc/debconf /usr/share/doc/libapt-pkg6.0 \
      /usr/share/doc/libdebconfclient0 /usr/share/lintian/profiles/dpkg \
      /usr/share/polkit-1/actions/org.dpkg.pkexec.update-alternatives.policy \
      /var/cache/ldconfig /var/log/dpkg.log && \
    rm -f /usr/lib/*/libapt-pkg.so* /usr/lib/*/libapt-private.so* \
      /usr/lib/*/libdebconfclient.so* && \
    ln -sf mawk /usr/bin/awk && \
    rm -rf /tmp && ln -s /dev/shm /tmp && \
    hash -r && \
    test ! -e /bin/busybox && \
    for required in sh dash id grep sed awk mawk cat; do command -v "$required" >/dev/null; done && \
    for forbidden in busybox wget nc netcat telnet ftp openssl c_rehash apt apt-get apt-cache apt-config apt-cdrom apt-key apt-mark dpkg dpkg-deb dpkg-divert dpkg-maintscript-helper dpkg-query dpkg-realpath dpkg-split dpkg-statoverride dpkg-trigger dpkg-reconfigure dpkg-preconfigure dpkg-fsys-usrunmess debconf debconf-apt-progress debconf-communicate debconf-copydb debconf-escape debconf-set-selections debconf-show deb-systemd-helper deb-systemd-invoke update-alternatives invoke-rc.d policy-rc.d service start-stop-daemon update-rc.d installkernel pam-auth-update update-ca-certificates update-passwd add-shell remove-shell update-shells ischroot run-parts savelog tempfile iconvconfig ldconfig shadowconfig perl clang gcc make curl node npm npx python python3 pip pip3 convex; do \
      if command -v "$forbidden" >/dev/null 2>&1; then exit 1; fi; \
    done && \
    package_artifacts="$(find /etc /usr /var -xdev \
      \( -name 'apt' -o -name 'apt-*' -o -name 'dpkg' -o -name 'dpkg-*' \
      -o -name 'debconf' -o -name 'debconf-*' -o -name 'deb-systemd-*' \
      -o -name 'update-alternatives' -o -name 'invoke-rc.d' \
      -o -name 'policy-rc.d' -o -name 'service' \
      -o -name 'start-stop-daemon' -o -name 'update-rc.d' \
      -o -name 'installkernel' -o -name 'pam-auth-update' \
      -o -name 'update-ca-certificates' -o -name 'update-passwd' \
      -o -name 'add-shell' -o -name 'remove-shell' \
      -o -name 'update-shells' -o -name 'ischroot' -o -name 'run-parts' \
      -o -name 'savelog' -o -name 'tempfile' -o -name 'iconvconfig' \
      -o -name 'ldconfig' -o -name 'shadowconfig' -o -name 'c_rehash' \
      \) -print)" && \
    if test -n "$package_artifacts"; then \
      printf '%s\n' "$package_artifacts" >&2; \
      exit 1; \
    fi && \
    find /usr/bin /usr/sbin -xdev \( -type f -o -type l \) \
      ! -name sh ! -name dash ! -name id ! -name grep ! -name sed \
      ! -name awk ! -name mawk ! -name cat -delete && \
    for candidate in /usr/bin/* /usr/sbin/*; do \
      if test ! -e "$candidate" && test ! -L "$candidate"; then continue; fi; \
      case "${candidate##*/}" in sh|dash|id|grep|sed|awk|mawk|cat) ;; *) exit 1 ;; esac; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build --chown=65532:65532 --chmod=0555 /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build --chown=65532:65532 --chmod=0555 /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
