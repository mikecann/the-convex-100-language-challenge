# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS build
RUN apt-get update && apt-get install --no-install-recommends --yes \
    ca-certificates=20230311+deb12u1 file=1:5.44-3 ldc=1:1.30.0-1+b1 gcc=4:12.2.0-3 libc6-dev=2.36-9+deb12u14 libcurl4-openssl-dev=7.88.1-10+deb12u15 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN ldc2 -wi -w -of=/out-client-test -Iclient -unittest client/convex.d client/tests/client_test.d client/tests/transport_test.d \
    && /out-client-test \
    && ldc2 -wi -w -of=/out-adapter -Iclient client/convex.d client/tests/conformance/main.d -L-lcurl \
    && ldc2 -wi -w -of=/out-example examples/basics/main.d \
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
    cp --parents /etc/ssl/certs/ca-certificates.crt /runtime-root

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
RUN rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/lib/dpkg/info/* \
    && rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark \
      /usr/bin/dpkg /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query /usr/bin/dpkg-realpath /usr/bin/dpkg-split /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger \
    && ! command -v apt && ! command -v apt-get && ! command -v dpkg && ! command -v curl && ! command -v gcc && ! command -v ldc2
# Debian's /lib is a symlink to /usr/lib, so copy the resolved directory rather
# than attempting to overwrite that symlink.
COPY --from=runtime-libs /runtime-root/usr/lib/x86_64-linux-gnu/ /usr/lib/x86_64-linux-gnu/
COPY --from=runtime-libs /runtime-root/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
