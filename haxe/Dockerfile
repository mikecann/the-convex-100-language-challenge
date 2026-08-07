# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

# The stage name is fixed by `./run test <language>`.
FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS test
RUN apt-get update && apt-get install -y --no-install-recommends \
      haxe=1:4.2.5-1 neko=2.3.0-1+b2 ca-certificates file binutils && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN haxe -version | grep -Fx 4.2.5 && neko -version | grep -Fx 2.3.0
RUN mkdir -p /out && \
    haxe -cp client -cp examples/basics -main Main -neko /out/convex-example.n && \
    haxe -cp client -cp client/tests/conformance -main Adapter -neko /out/convex-adapter.n && \
    haxe -cp client -cp client/tests -cp client/tests/conformance -cp examples/basics \
      -main Tests -neko /out/haxe-tests.n && \
    haxe -cp client -cp client/tests -main TlsProbe -neko /out/tls-probe.n
RUN neko /out/haxe-tests.n
# The example refuses to run without a deployment rather than printing a
# partial transcript that the shared verifier would then compare.
RUN code=0; CONVEX_URL= neko /out/convex-example.n >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -ne 0 && test ! -s /tmp/example.out && grep -Fq 'CONVEX_URL is required' /tmp/example.err
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(uname -m)" = x86_64 && \
    file /usr/bin/neko | grep -Eq 'ELF 64-bit.*x86-64' && \
    readelf -h /usr/bin/neko | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
ENV CONVEX_URL=http://127.0.0.1:9
CMD ["/bin/sh", "-ec", "printf '%s\\n' '{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}' '{\"id\":\"close\",\"op\":\"close\"}' | neko /out/convex-adapter.n"]

# Assemble the exact runtime closure: the Neko VM, the modules it loads, their
# shared libraries, the certificate bundle, and the small POSIX set the shared
# runtime verifier requires.
FROM test AS runtime-rootfs
# cp --parents recreates each source path under the destination relative to the
# working directory, so the absolute paths below only resolve from /.
WORKDIR /
RUN set -eu; root=/runtime-root; \
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib" "$root/usr/local/bin" "$root/etc/ssl"; \
    cp /bin/dash "$root/bin/dash"; ln -s dash "$root/bin/sh"; \
    cp /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head /usr/bin/tail /usr/bin/tr \
       /usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed /usr/bin/mawk "$root/usr/bin/"; \
    cp /usr/bin/chmod /usr/bin/rm "$root/usr/bin/"; \
    ln -s mawk "$root/usr/bin/awk"; cp /usr/bin/neko "$root/usr/bin/neko"; \
    modules=""; \
    for path in /usr/lib/neko /usr/lib/x86_64-linux-gnu/neko; do \
      test ! -d "$path" || { cp -a --parents "$path" "$root"; modules="$modules $path/*.ndll"; }; \
    done; \
    test -n "$modules"; \
    { eval "ldd /usr/bin/neko $modules /bin/dash /usr/bin/id /usr/bin/cat /usr/bin/cut \
        /usr/bin/head /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq /usr/bin/wc \
        /usr/bin/uname /usr/bin/grep /usr/bin/sed /usr/bin/mawk /usr/bin/chmod /usr/bin/rm" || true; } | \
      awk '/=> \/.* \(0x/ {print $3} $1 ~ /^\// && $1 !~ /:$/ {print $1}' | sort -u | \
      while IFS= read -r library; do cp -L --parents "$library" "$root"; done; \
    cp -a /etc/ssl/certs "$root/etc/ssl/certs"; \
    test -s "$root/etc/ssl/certs/ca-certificates.crt"; \
    for path in /usr/lib/ssl /usr/lib/x86_64-linux-gnu/ossl-modules; do test ! -e "$path" || cp -a --parents "$path" "$root"; done; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS runtime-base
COPY --from=runtime-rootfs /runtime-root /
ENV PATH=/usr/local/bin:/usr/bin:/bin
# Remove the base image's multicall binary and every applet symlink that could
# still reach it, then prove the forbidden commands are genuinely gone.
RUN find /bin /usr/bin -type l ! -path /bin/sh ! -path /usr/bin/awk -delete && \
    rm -rf /etc/apk /lib/apk /usr/lib/libapk* /sbin/apk /usr/sbin/apk /usr/bin/apk \
      /bin/busybox /lib/ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1 && \
    for command in apk apt apt-get dpkg bash busybox curl wget nc telnet openssl \
      haxe haxelib nekoc nekotools gcc g++ cc make cmake node python python3 php convex; do \
      ! command -v "$command" >/dev/null 2>&1; \
    done
# Exercise TLS from this exact rootfs so a missing bundle or module is found
# here rather than during hosted verification, then remove the probe.
COPY --from=test /out/tls-probe.n /opt/convex/tls-probe.n
USER 65532:65532
RUN /usr/bin/neko /opt/convex/tls-probe.n | grep -Fx 'tls probe ok'
USER 0:0
RUN rm -f /opt/convex/tls-probe.n

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example.n /opt/convex/convex-example.n
RUN printf '%s\n' '#!/bin/sh' 'exec /usr/bin/neko /opt/convex/convex-example.n "$@"' > /usr/local/bin/convex-example && \
    chmod 0555 /usr/local/bin/convex-example && \
    test ! -e /usr/local/bin/convex-adapter && \
    exec rm -f /usr/bin/chmod /usr/bin/rm
USER 65532:65532
RUN set -eu; test "$(id -u):$(id -g)" = 65532:65532; \
    code=0; CONVEX_URL= /usr/local/bin/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -ne 0 && test ! -s /tmp/example.out && \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err && \
    rm -f /tmp/example.out /tmp/example.err
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last so the default build target is the conformance image.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter.n /opt/convex/convex-adapter.n
RUN printf '%s\n' '#!/bin/sh' 'exec /usr/bin/neko /opt/convex/convex-adapter.n "$@"' > /usr/local/bin/convex-adapter && \
    chmod 0555 /usr/local/bin/convex-adapter && \
    test ! -e /usr/local/bin/convex-example && \
    exec rm -f /usr/bin/chmod /usr/bin/rm
USER 65532:65532
RUN set -eu; test "$(id -u):$(id -g)" = 65532:65532 && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter > /tmp/probe.out && \
    grep -Fq '"type":"closed"' /tmp/probe.out && \
    rm -f /tmp/probe.out
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
