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
RUN alr exec -- gprbuild -j1 -XGNATCOLL_BUILD_MODE=DEBUG -P convex_ada_subset.gpr \
      convex.adb convex-live.adb convex_websocket.adb \
      -cargs:Ada -O0 -fno-inline \
    && alr exec -- gprbuild -j1 -XGNATCOLL_BUILD_MODE=DEBUG -P convex_ada_subset.gpr -cargs:Ada -O0 -fno-inline
RUN ./bin/convex_tests \
    && if test -x ./bin/convex_socket_tests; then ./bin/convex_socket_tests; fi \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 ./bin/convex_adapter \
       | grep -Fqx '{"id":"close","type":"closed"}'
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
    test -f /out/lib/libgnat-14.so; \
    test -f /out/lib/libgnarl-14.so; \
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
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
