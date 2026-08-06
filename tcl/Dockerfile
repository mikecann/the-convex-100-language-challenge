# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       tcl=8.6.13 \
       tcl8.6=8.6.13+dfsg-2 \
       tcllib=1.21+dfsg-1 \
       tcl-tls=1.7.22-3+b1 \
       libssl3=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
    && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 \
    && test "$(printf 'puts [info patchlevel]\\n' | tclsh)" = 8.6.13 \
    && tclsh client/tests/run.tcl \
    && tclsh client/tests/live_socket.test.tcl \
    && tclsh client/tests/stopped_reader.test.tcl \
    && tclsh examples/basics/main.test.tcl
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | \
    CONVEX_CLIENT_PATH=/project/client tclsh client/tests/conformance/adapter.tcl > /tmp/adapter.ndjson \
    && grep -Fqx '{"protocolVersion":1,"id":"hello","type":"ready","language":"tcl","implementation":"native-tcl-8.6.13","runtime":"tcl-8.6.13"}' /tmp/adapter.ndjson \
    && grep -Fqx '{"id":"close","type":"closed"}' /tmp/adapter.ndjson

# Use a pinned non-scratch Debian carrier, then rebuild its visible filesystem
# from the explicit Tcl/TLS/CA closure. BusyBox exists only in this build stage
# to prune the carrier and never reaches either exported runtime image.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root /run /sbin /srv /usr /var; do /busybox rm -rf "$path"; done; \
    for path in /etc/*; do case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) /busybox rm -rf "$path" ;; esac; done; \
    /busybox mkdir -p /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin /usr/lib/tcltk/x86_64-linux-gnu /usr/local/bin /usr/share/tcltk
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/libgcc_s.so.1
COPY --from=test /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libz.so.1
COPY --from=test /lib/x86_64-linux-gnu/libtcl8.6.so /lib/x86_64-linux-gnu/libtcl8.6.so
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /usr/bin/tclsh8.6 /usr/local/bin/tclsh
COPY --from=test /usr/share/tcltk/tcl8.6 /usr/share/tcltk/tcl8.6
COPY --from=test /usr/share/tcltk/tcllib1.21 /usr/share/tcltk/tcllib1.21
COPY --from=test /usr/lib/tcltk/x86_64-linux-gnu/tcltls1.7.22 /usr/lib/tcltk/x86_64-linux-gnu/tcltls1.7.22
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
    TCLLIBPATH=/usr/share/tcltk/tcllib1.21 \
    PATH=/usr/local/bin:/usr/bin:/bin
COPY client/convex.tcl /opt/convex/client/convex.tcl
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(uname -m)" = x86_64 \
    && tclsh <<'EOF'
package require http
package require tls
package require json
package require sha1
puts [info patchlevel]
EOF

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.tcl /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.tcl /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
