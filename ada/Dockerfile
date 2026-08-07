# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project/client
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
       binutils=2.40-2 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       ca-certificates=20230311+deb12u1 \
       curl=7.88.1-10+deb12u15 \
       file=1:5.44-3 \
       git=1:2.39.5-0+deb12u3 \
       libc6-dev=2.36-9+deb12u14 \
       libssl-dev=3.0.20-1~deb12u2 \
       make=4.3-4.1 \
       unzip=6.0-28 \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:e3b32cb0afe981b23d1a68da77452cf81ee1d82de8ebaf01c5e233be8b463fbe \
    https://github.com/alire-project/alire/releases/download/v2.1.0/alr-2.1.0-bin-x86_64-linux.zip /tmp/alr.zip
RUN unzip -q /tmp/alr.zip -d /opt/alire \
    && install -m 0755 /opt/alire/bin/alr /usr/local/bin/alr \
    && rm -rf /tmp/alr.zip /opt/alire \
    && test "$(uname -m)" = x86_64 \
    && alr --version | grep -Fq 'alr 2.1.0'
RUN alr index --add \
       git+https://github.com/alire-project/alire-index#6d5ac6687c1a0f64dd861e80c75405e6c7ec1e62 \
       --name community \
    && alr index --list | grep -Fq '6d5ac6687c1a0f64dd861e80c75405e6c7ec1e62' \
    && alr toolchain --select gnat_native=14.2.1 gprbuild=25.0.1 \
    && alr install gnatformat_bin=26.0.0 \
    && /root/.alire/bin/gnatformat --version | grep -Fq 'GNATformat 26.0'

# AWS must be configured explicitly. Its default SSL implementation is a
# compile-time dummy even when OpenSSL headers happen to be present.
ENV SOCKET=openssl \
    LIBRARY_TYPE=static \
    SSL_LIBRARY_TYPE=static \
    PRJ_BUILD=Release
COPY client/alire.toml ./alire.toml
RUN alr with --solve \
    && alr build --stop-after=post-fetch --release
RUN aws_gpr="$(find /root/.local/share/alire/builds -type f -name aws.gpr -print \
      | while IFS= read -r candidate; do \
          candidate_root="$(dirname "$candidate")"; \
          if test -d "$candidate_root/src"; then printf '%s\n' "$candidate"; break; fi; \
        done)" \
    && aws_root="$(dirname "$aws_gpr")" \
    && ln -s "$aws_root" /opt/aws \
    && test -d /opt/aws/src \
    && gnatcoll_gpr="$(find /root/.local/share/alire/builds -type f -name gnatcoll.gpr -print \
      | while IFS= read -r candidate; do \
          candidate_root="$(dirname "$candidate")"; \
          if test -d "$candidate_root/core/src"; then printf '%s\n' "$candidate"; break; fi; \
        done)" \
    && ln -s "$(dirname "$gnatcoll_gpr")" /opt/gnatcoll \
    && test -d /opt/gnatcoll/core/src
COPY client/convex_ada.gpr ./convex_ada.gpr
COPY client/convex_ada_subset.gpr ./convex_ada_subset.gpr
COPY client/*.ads client/*.adb ./
COPY client/tests ./tests
COPY examples /project/examples
RUN /root/.alire/bin/gnatformat --no-project --check --charset utf-8 \
      convex.ads convex.adb convex-live.ads convex-live.adb \
      convex_websocket.ads convex_websocket.adb convex_url.ads convex_url.adb \
      tests/conformance/*.ads tests/conformance/*.adb tests/*.adb \
      /project/examples/basics/*.adb

# AWS 25.2 contains a large Ada dependency graph. Keep this language-local
# build deterministic and below the remote runner's 10 GiB VM limit. The
# dependency build also avoids optimizer memory spikes in GNAT 14; the final
# runtime is still built from these complete native objects.
RUN mkdir -p obj \
    && alr exec -- gcc -c /opt/gnatcoll/minimal/src/gnatcoll_support.c \
         -o obj/gnatcoll_minimal_support.o \
    && alr exec -- gcc -c /opt/gnatcoll/core/src/os/unix/libc-wrappers.c \
         -o obj/gnatcoll_libc_wrappers.o \
    && alr exec -- gcc -c /opt/aws/config/ssl/openssl/wrappers.c \
         -o obj/aws_openssl_wrappers.o \
    && alr exec -- gprbuild -c -j1 -XGNATCOLL_BUILD_MODE=DEBUG -P convex_ada_subset.gpr \
      convex.adb convex-live.adb convex_websocket.adb \
      -cargs:Ada -O0 -fno-inline \
    && alr exec -- gprbuild -j1 -XGNATCOLL_BUILD_MODE=DEBUG -P convex_ada_subset.gpr -cargs:Ada -O0 -fno-inline
RUN ./bin/convex_tests \
    && ./bin/convex_adapter_event_tests \
    && ./bin/convex_adapter_output_tests \
    && ./bin/convex_socket_tests \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 ./bin/convex_adapter \
       | grep -Fqx '{"id":"close","type":"closed"}'
# An identifier the shared schema would reject must never come back inside an
# otherwise well-formed event, so the error line has to omit id entirely.
RUN set -eu; \
    long_id="$(awk 'BEGIN { s = ""; for (i = 0; i < 200; i++) s = s "x"; print s }')"; \
    printf '%s\n' \
      "{\"protocolVersion\":1,\"id\":\"$long_id\",\"op\":\"hello\"}" \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 ./bin/convex_adapter > /tmp/oversize-id.ndjson; \
    head -n 1 /tmp/oversize-id.ndjson \
      | grep -Fqx '{"type":"error","error":{"name":"ProtocolError","message":"id must contain 1 to 128 Unicode characters"}}'; \
    ! grep -Fq "$long_id" /tmp/oversize-id.ndjson; \
    grep -Fqx '{"id":"close","type":"closed"}' /tmp/oversize-id.ndjson; \
    rm -f /tmp/oversize-id.ndjson
# A Live delivery close to the client's four-megabyte message ceiling is
# schema-valid traffic. It has to reach the controller intact, and the adapter
# has to finish normally afterwards: an output limit that refuses it would
# raise out of the main loop and end the process instead of the delivery.
RUN set -eu; \
    rm -f /tmp/relay.log /tmp/relay.ndjson; \
    FIXTURE_PORT=19092 FIXTURE_VALUE_BYTES=4000000 \
      ./bin/convex_adapter_fixture > /tmp/relay.log 2>&1 & \
    fixture_pid=$!; \
    waited=0; \
    until grep -Fq 'adapter fixture ready' /tmp/relay.log; do \
      waited=$((waited + 1)); test "$waited" -lt 200; sleep 0.1; \
    done; \
    { printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"sub","op":"subscribe","subscriptionId":"pressure","path":"fixture:large","args":{}}'; \
      sleep 3; \
      printf '%s\n' '{"id":"close","op":"close"}'; } \
      | CONVEX_URL=http://127.0.0.1:19092 ./bin/convex_adapter > /tmp/relay.ndjson; \
    wait "$fixture_pid" || true; \
    test "$(wc -L < /tmp/relay.ndjson)" -gt 3000000; \
    grep -Fq '{"type":"subscription","subscriptionId":"pressure","value":"' \
      /tmp/relay.ndjson; \
    ! grep -Fq 'ProtocolError' /tmp/relay.ndjson; \
    grep -Fqx '{"id":"close","type":"closed"}' /tmp/relay.ndjson; \
    rm -f /tmp/relay.log /tmp/relay.ndjson
# An event-count limit is not a memory limit when one delivery may approach the
# client's four-megabyte message ceiling. Relay five near-ceiling values to a
# controller that connects and then never reads, and require the real adapter
# to stay far below the shared 128 MiB limit, to end on its own bounded write
# deadline rather than growing, and to say what it was holding when it did.
RUN set -eu; \
    rm -f /tmp/fixture.log /tmp/adapter.log /tmp/hwm.txt; \
    FIXTURE_PORT=19090 FIXTURE_VALUE_BYTES=4000000 \
      ./bin/convex_adapter_fixture > /tmp/fixture.log 2>&1 & \
    fixture_pid=$!; \
    waited=0; \
    until grep -Fq 'adapter fixture ready' /tmp/fixture.log; do \
      waited=$((waited + 1)); test "$waited" -lt 200; sleep 0.1; \
    done; \
    CONVEX_URL=http://127.0.0.1:19090 ADAPTER_LISTEN=127.0.0.1:19091 \
      ./bin/convex_adapter > /tmp/adapter.log 2>&1 & \
    adapter_pid=$!; \
    waited=0; \
    until grep -Fq ':4A93 ' /proc/net/tcp; do \
      waited=$((waited + 1)); test "$waited" -lt 200; sleep 0.1; \
    done; \
    ADAPTER_HOST=127.0.0.1 ADAPTER_PORT=19091 \
      ./bin/convex_adapter_stopped_reader > /dev/null 2>&1 & \
    reader_pid=$!; \
    waited=0; \
    while kill -0 "$adapter_pid" 2>/dev/null; do \
      awk '/^VmHWM:/ { print $2 }' "/proc/$adapter_pid/status" >> /tmp/hwm.txt \
        2>/dev/null || true; \
      waited=$((waited + 1)); test "$waited" -lt 300; sleep 0.2; \
    done; \
    adapter_status=0; \
    wait "$adapter_pid" || adapter_status=$?; \
    wait "$reader_pid" || true; \
    wait "$fixture_pid" || true; \
    peak_kb="$(sort -n /tmp/hwm.txt | tail -n 1)"; \
    printf 'stopped reader peak RSS: %s KiB\n' "$peak_kb"; \
    test -n "$peak_kb"; \
    test "$peak_kb" -lt 98304; \
    test "$adapter_status" -ne 0; \
    grep -Fq 'peakBytes' /tmp/adapter.log; \
    rm -f /tmp/fixture.log /tmp/adapter.log /tmp/hwm.txt
# Hostname verification is proved with key material that is minted here and
# never committed: the fixture generates one ephemeral CA and two leaves for
# it, one named localhost and one named wrong.invalid. The trust store is
# replaced with that CA alone while the test runs, so the only difference
# between the accepted and refused connections is the certificate's name, and
# it is restored byte-for-byte afterwards.
RUN alr exec -- gcc -O1 -Wall tests/convex_tls_fixture.c \
      -o bin/convex_tls_fixture -lssl -lcrypto
RUN set -eu; \
    anchors=/etc/ssl/certs/ca-certificates.crt; \
    original="$(sha256sum < "$anchors")"; \
    cp "$anchors" /tmp/anchors.original; \
    rm -f /tmp/convex-test-ca.pem /tmp/convex-test-ca.pem.partial; \
    ./bin/convex_tls_fixture /tmp/convex-test-ca.pem 19443 19444 & \
    fixture_pid=$!; \
    waited=0; \
    until test -f /tmp/convex-test-ca.pem; do \
      waited=$((waited + 1)); test "$waited" -lt 300; sleep 0.1; \
    done; \
    cp /tmp/convex-test-ca.pem "$anchors"; \
    status=0; \
    CONVEX_TLS_PORT=19443 CONVEX_TLS_WRONG_HOST_PORT=19444 \
      ./bin/convex_tls_tests || status=$?; \
    cp /tmp/anchors.original "$anchors"; \
    fixture_status=0; \
    if test "$status" -eq 0; then \
      wait "$fixture_pid" || fixture_status=$?; \
    else \
      kill "$fixture_pid" 2>/dev/null || true; \
      wait "$fixture_pid" || true; \
    fi; \
    rm -f /tmp/convex-test-ca.pem /tmp/anchors.original; \
    test "$status" -eq 0; \
    test "$fixture_status" -eq 0; \
    test "$(sha256sum < "$anchors")" = "$original"
RUN file bin/convex_adapter | grep -Eq 'ELF 64-bit.*x86-64' \
    && file bin/convex_example | grep -Eq 'ELF 64-bit.*x86-64' \
    && ! ldd bin/convex_adapter | grep -Fq 'not found' \
    && ! ldd bin/convex_example | grep -Fq 'not found' \
    && nm -A bin/convex_adapter | grep -Fq 'SSL_set1_host'
RUN set -eu; \
    mkdir -p /out/lib; \
    cp bin/convex_adapter /out/convex-adapter; \
    cp bin/convex_example /out/convex-example; \
    { ldd bin/convex_adapter; ldd bin/convex_example; } \
      | awk '$3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }' \
      | sort -u \
      | while IFS= read -r library; do cp -L "$library" "/out/lib/$(basename "$library")"; done; \
    chmod 0555 /out/convex-adapter /out/convex-example; \
    ! ldd bin/convex_adapter | grep -Eq 'libgnat|libgnarl'; \
    ! ldd bin/convex_example | grep -Eq 'libgnat|libgnarl'; \
    test -f /out/lib/ld-linux-x86-64.so.2
CMD ["/bin/sh", "-c", "true"]

# Begin with a pinned, non-scratch Debian image, remove it with a temporary
# static helper, then reconstruct only the reviewed runtime closure.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) "$pruner" rm -rf "$path" ;; esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /out/lib/ /lib/x86_64-linux-gnu/
COPY --from=test /out/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
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
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
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
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && for command_name in alr gnat gcc cc clang make ld as apt apt-get dpkg \
         curl wget nc netcat openssl node python python3 ruby perl java php go \
         rustc cargo npm pip convex busybox; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build ada` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
       | grep -Fqx '{"id":"close","type":"closed"}'
# The plaintext check above never asks AWS.Net.SSL to do anything: it proves
# the binary runs, not that this pruned image's OpenSSL/CA closure actually
# works. Force a real TLS code path here. Port 9 refuses the TCP connection
# immediately, so a correctly wired image fails the query as an ordinary
# connect failure; a CA bundle, OPENSSL_CONF, or provider/module problem in
# this minimal runtime would instead surface as a TLS setup or handshake
# error, which the negative grep below would catch. No file is written:
# /tmp does not exist in this image, so the transcript stays in a variable.
RUN set -eu; \
    output="$(printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"q","op":"query","path":"messages:count","args":{}}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=https://127.0.0.1:9 /usr/local/bin/convex-adapter)"; \
    printf '%s\n' "$output" | grep -Fqx '{"id":"close","type":"closed"}'; \
    printf '%s\n' "$output" | grep -Fq '"id":"q"'; \
    printf '%s\n' "$output" | grep -Fq '"name":"TransportError"'; \
    ! printf '%s\n' "$output" | grep -Eiq \
      'ca-certificat|openssl_conf|provider|no such file|unable to load|legacy\.so|x509 lookup|certificate verify|SSL_CTX'; \
    printf '%s\n' "$output" | grep -Fqi 'refused'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
