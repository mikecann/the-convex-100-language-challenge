# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GCC_IMAGE=gcc:14.2.0-bookworm@sha256:82549aa8f90ada3236a8be70c74543132a76662ef33f0c3271ed802b81584a82
ARG DEBIAN_RUNTIME_IMAGE=debian:bookworm-slim@sha256:362e64223cc0da95422b3b13c045186fc0a81250e765d31c025fbddf257f6143
ARG ODIN_COMMIT=ea5175d865c2034b033ebf5653d83638f10bba54
ARG CURL_VERSION=8.21.0

FROM --platform=linux/amd64 ${GCC_IMAGE} AS build-base
# A dated HTTPS Debian snapshot makes every apt-installed build input immutable
# even though the packages are expressed by name. `trusted=yes` avoids a known
# gpgv failure under amd64 emulation on Apple Silicon; the timestamped origin is
# still fixed, and nothing from apt enters the final runtime.
RUN printf '%s\n' \
      'deb [trusted=yes check-valid-until=no] https://snapshot.debian.org/archive/debian/20260601T000000Z bookworm main' \
      'deb [trusted=yes check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20260601T000000Z bookworm-security main' \
      > /etc/apt/sources.list && \
    rm -f /etc/apt/sources.list.d/debian.sources && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get -o Acquire::Check-Valid-Until=false install --no-install-recommends --yes \
      ca-certificates \
      clang-14 \
      file \
      libmbedtls-dev \
      libssl-dev \
      llvm-14-dev \
      pkg-config \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

FROM build-base AS build-input-audit
RUN dpkg-query -W -f='${binary:Package}=${Version}\n' | sort > /build-inputs.txt && \
    grep -Eq '^clang-14(:amd64)?=1:14\.0\.6-12$' /build-inputs.txt && \
    grep -Eq '^libssl-dev(:amd64)?=3\.0\.20-1~deb12u1$' /build-inputs.txt && \
    grep -Eq '^llvm-14-dev(:amd64)?=1:14\.0\.6-12$' /build-inputs.txt

FROM build-base AS curl-builder
ARG CURL_VERSION
ADD --checksum=sha256:aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6 \
    https://curl.se/download/curl-${CURL_VERSION}.tar.xz /tmp/curl.tar.xz
COPY client/tests/transport/curl-connect-only-pending.patch /tmp/curl-connect-only-pending.patch
COPY client/tests/transport/curl-connect-only-pending-test.c /tmp/curl-connect-only-pending-test.c
RUN mkdir -p /tmp/curl && \
    tar -xJf /tmp/curl.tar.xz --strip-components=1 -C /tmp/curl && \
    grep -Fq 'GOOD_EASY_HANDLE(data) && Curl_is_in_callback(data) &&' /tmp/curl/lib/ws.c && \
    patch --directory=/tmp/curl --strip=1 --input=/tmp/curl-connect-only-pending.patch && \
    grep -Fq 'only a pending-input signal until curl_ws_recv() succeeds' /tmp/curl/lib/ws.c && \
    ! grep -Fq 'GOOD_EASY_HANDLE(data) && Curl_is_in_callback(data) &&' /tmp/curl/lib/ws.c && \
    cd /tmp/curl && \
    CC=clang-14 AR=llvm-ar-14 RANLIB=llvm-ranlib-14 \
      CFLAGS='-O1 -pthread' LDFLAGS='-pthread' ./configure \
      --build=aarch64-linux-gnu \
      --host=x86_64-linux-gnu \
      --prefix=/opt/curl \
      --disable-static \
      --enable-shared \
      --enable-threaded-resolver \
      --enable-versioned-symbols \
      --enable-websockets \
      --with-openssl \
      --without-brotli \
      --without-libidn2 \
      --without-libpsl \
      --without-libssh2 \
      --without-nghttp2 \
      --without-nghttp3 \
      --without-ngtcp2 \
      --without-quiche \
      --without-zlib \
      --without-zstd \
      --disable-alt-svc \
      --disable-basic-auth \
      --disable-bearer-auth \
      --disable-cookies \
      --disable-dateparse \
      --disable-dict \
      --disable-docs \
      --disable-dnsshuffle \
      --disable-doh \
      --disable-file \
      --disable-form-api \
      --disable-ftp \
      --disable-get-easy-options \
      --disable-gopher \
      --disable-headers-api \
      --disable-hsts \
      --disable-http-auth \
      --disable-imap \
      --disable-ipfs \
      --disable-kerberos-auth \
      --disable-ldap \
      --disable-ldaps \
      --disable-manual \
      --disable-mime \
      --disable-mqtt \
      --disable-negotiate-auth \
      --disable-netrc \
      --disable-pop3 \
      --disable-progress-meter \
      --disable-proxy \
      --disable-proxy-http3 \
      --disable-rtsp \
      --disable-smb \
      --disable-smtp \
      --disable-telnet \
      --disable-tftp \
      --disable-tls-srp \
      --disable-unix-sockets
RUN cd /tmp/curl && \
    make -C lib -j1 && \
    make -C lib install && \
    make -C include install && \
    clang-14 -O1 -Wall -Wextra -Werror -pthread /tmp/curl-connect-only-pending-test.c \
      -I/opt/curl/include -L/opt/curl/lib -Wl,-rpath,/opt/curl/lib \
      -lcurl -lcrypto -o /tmp/curl-connect-only-pending-test && \
    timeout 15 /tmp/curl-connect-only-pending-test

FROM build-base AS odin-compiler
ARG ODIN_COMMIT
ADD --checksum=sha256:85bf26671c3e13d5ee70a55545df3b81f9c9bdeffed7f05b3493f639c597237e \
    https://github.com/odin-lang/Odin/archive/${ODIN_COMMIT}.tar.gz /tmp/odin.tar.gz
RUN mkdir -p /opt/odin && \
    tar -xzf /tmp/odin.tar.gz --strip-components=1 -C /opt/odin && \
    cd /opt/odin && \
    LLVM_CONFIG=llvm-config-14 CXX=clang++-14 ./build_odin.sh release && \
    ./odin version | grep -F 'dev-2026-08'

FROM build-base AS odin-toolchain
COPY --from=odin-compiler /opt/odin /opt/odin
COPY --from=curl-builder /opt/curl /opt/curl
COPY --from=build-input-audit /build-inputs.txt /opt/build-inputs.txt
ENV PATH=/opt/odin:${PATH}
ENV LIBRARY_PATH=/opt/curl/lib
ENV LD_LIBRARY_PATH=/opt/curl/lib

FROM odin-toolchain AS test
RUN ln -s /usr/bin/clang-14 /usr/local/bin/clang
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 && \
    file /opt/odin/odin | grep -Eq 'ELF 64-bit.*x86-64' && \
    readelf -h /opt/odin/odin | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
RUN printf '%s\n' \
      '#include <curl/curl.h>' \
      '#include <string.h>' \
      'int main(void) {' \
	  '  if (curl_global_init(CURL_GLOBAL_ALL)) return 1;' \
      '  curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);' \
      '  int ws = 0, wss = 0;' \
      '  for (const char * const *p = info->protocols; p && *p; ++p) {' \
      '    ws |= strcmp(*p, "ws") == 0; wss |= strcmp(*p, "wss") == 0;' \
      '  }' \
      '  int openssl = (info->features & CURL_VERSION_SSL) && info->ssl_version &&' \
      '    strstr(info->ssl_version, "OpenSSL/") == info->ssl_version;' \
      '  int threaded_dns = (info->features & CURL_VERSION_ASYNCHDNS) != 0;' \
      '  CURL *easy = curl_easy_init();' \
	  '  if (!easy) { curl_global_cleanup(); return 1; }' \
      '  curl_easy_setopt(easy, CURLOPT_URL, "http://localhost:1/");' \
      '  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, 1000L);' \
      '  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);' \
      '  CURLcode localhost = curl_easy_perform(easy);' \
      '  curl_easy_cleanup(easy);' \
      '  int dns_ok = localhost != CURLE_COULDNT_RESOLVE_HOST;' \
	  '  int failed = !(ws && wss && openssl && threaded_dns && dns_ok &&' \
	  '    curl_ws_send && curl_ws_recv);' \
	  '  curl_global_cleanup();' \
	  '  return failed;' \
      '}' | \
    gcc -x c - -I/opt/curl/include -L/opt/curl/lib -Wl,-rpath,/opt/curl/lib -lcurl -o /tmp/curl-websocket-check && \
    /tmp/curl-websocket-check
RUN odin check client -no-entry-point -strict-style -vet
RUN timeout 90 odin test client \
      -define:ODIN_TEST_THREADS=1 \
      -strict-style -vet
RUN mkdir -p /out && \
    odin build examples/basics \
      -collection:convex=/src/client \
      -strict-style -vet -o:speed \
      -out:/out/convex-example && \
    odin build client/tests/conformance \
      -collection:convex=/src/client \
      -strict-style -vet -o:speed \
      -out:/out/convex-adapter && \
    odin build client/tests/process_fixture \
      -collection:convex=/src/client \
      -strict-style -vet -o:speed \
      -out:/out/convex-process-fixture && \
    file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64' && \
    file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64' && \
    readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
RUN odin test client/tests/conformance \
      -collection:convex=/src/client \
      -strict-style -vet
RUN actual="$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | /out/convex-adapter)" && \
    printf '%s\n' "$actual" | grep -Fq '"language":"odin"' && \
    printf '%s\n' "$actual" | grep -Fq '"type":"closed"'
RUN set -eu; \
	  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	    -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1' \
	    -keyout /tmp/tls-key.pem -out /tmp/tls-cert.pem >/dev/null 2>&1; \
	  openssl s_server -quiet -www -accept 19443 \
	    -key /tmp/tls-key.pem -cert /tmp/tls-cert.pem >/tmp/tls-server.log 2>&1 & \
	  tls_pid=$!; \
	  trap 'kill "$tls_pid" 2>/dev/null || true; wait "$tls_pid" 2>/dev/null || true' EXIT; \
	  sleep 1; \
	  actual="$(printf '%s\n' \
	    '{"id":"tls","op":"query","path":"demo:state","args":{}}' \
	    '{"id":"close","op":"close"}' | \
	    CURL_CA_BUNDLE=/tmp/tls-cert.pem CONVEX_URL=https://127.0.0.1:19443 /out/convex-adapter)"; \
	  printf '%s\n' "$actual" | grep -Fq '"id":"tls","type":"error"'; \
	  printf '%s\n' "$actual" | grep -Fq '"name":"TransportError"'; \
	  printf '%s\n' "$actual" | grep -Fq 'SSL peer certificate'; \
	  printf '%s\n' "$actual" | grep -Fq '"id":"close","type":"closed"'
RUN timeout 60 client/tests/conformance/process-test.sh

# This target is for the root-owned memory lane. Building it is not evidence;
# its checked-in command must be run with --memory=128m as documented inside.
FROM test AS memory-probe
ENTRYPOINT ["/src/client/tests/conformance/memory-probe.sh"]

FROM test AS runtime-rootfs
RUN set -eu; \
    root=/runtime; \
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" "$root/etc" \
      "$root/usr/lib/x86_64-linux-gnu"; \
    cp /bin/dash "$root/bin/sh"; \
    cp /usr/bin/id "$root/usr/bin/id"; \
    cp /usr/bin/grep "$root/usr/bin/grep"; \
    cp /out/convex-example "$root/usr/local/bin/convex-example"; \
    cp /out/convex-adapter "$root/usr/local/bin/convex-adapter"; \
    libraries="$({ ldd /bin/dash /usr/bin/id /usr/bin/grep /out/convex-example /out/convex-adapter; } | awk '$3 ~ /^\// {print $3} $1 ~ /^\// {name=$1; sub(/:$/, "", name); print name}' | sort -u)"; \
    for library in $libraries; do \
      case "$library" in \
        /opt/curl/lib/*) cp -L "$library" "$root/usr/lib/x86_64-linux-gnu/$(basename "$library")" ;; \
        *) cp --parents -L "$library" "$root" ;; \
      esac; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/lib/x86_64-linux-gnu/engines-3 /usr/lib/x86_64-linux-gnu/ossl-modules "$root/usr/lib/x86_64-linux-gnu/"; \
    cp /etc/nsswitch.conf /etc/hosts "$root/etc/"
RUN set -eu; \
    test -r /runtime/etc/ssl/certs/ca-certificates.crt; \
    events="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | chroot /runtime /usr/local/bin/convex-adapter)"; \
    echo "$events" | /usr/bin/grep -Fq '"language":"odin"'; \
    echo "$events" | /usr/bin/grep -Fq '"type":"closed"'; \
    tls_events="$(printf '%s\n' '{"id":"tls","op":"query","path":"demo:state","args":{}}' '{"id":"close","op":"close"}' | CONVEX_URL=https://127.0.0.1:1 chroot /runtime /usr/local/bin/convex-adapter)"; \
    echo "$tls_events" | /usr/bin/grep -Fq '"id":"tls","type":"error"'; \
    echo "$tls_events" | /usr/bin/grep -Fq '"name":"TransportError"'; \
    echo "$tls_events" | /usr/bin/grep -Fq '"id":"close","type":"closed"'

FROM --platform=linux/amd64 ${DEBIAN_RUNTIME_IMAGE} AS runtime-base
# Keep the Debian provenance required by the shared verifier, but replace its
# filesystem with the individually allowlisted shell, text tools, client
# executables, and their complete runtime closure assembled above.
RUN set -eu; \
    for entry in /etc/*; do \
      case "$entry" in \
        /etc/hostname|/etc/hosts|/etc/resolv.conf) ;; \
        *) /usr/bin/rm -rf "$entry" ;; \
      esac; \
    done; \
    /usr/bin/rm -rf /bin /sbin /usr /lib /lib64 /var /opt /root /home /tmp
COPY --from=runtime-rootfs /runtime /
RUN set -eu; \
    for command in sh id grep; do command -v "$command" >/dev/null; done; \
    test ! -e /bin/busybox; \
    for candidate in /bin/* /usr/bin/* /usr/local/bin/*; do \
      case "$candidate" in \
        /bin/sh|/usr/bin/id|/usr/bin/grep|/usr/local/bin/convex-example|/usr/local/bin/convex-adapter) ;; \
        *) test ! -x "$candidate" ;; \
      esac; \
    done; \
    for command in apk apt apt-get dpkg gcc g++ cc clang clang++ make cmake odin cargo rustc node npm npx corepack php composer pear pecl phpize php-config python python3 pip pip3 pip3.13 curl wget nc convex; do \
      ! command -v "$command" >/dev/null 2>&1; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because `./run build odin` builds the default target.
FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
