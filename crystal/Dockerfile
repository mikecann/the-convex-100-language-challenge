# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG CRYSTAL_IMAGE=crystallang/crystal:1.14.1-alpine@sha256:e99593ba1bb7cec5bc686d46523217c09617e3b935588841b7f7961fc710a3ce
ARG ALPINE_IMAGE=alpine:3.20.3@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a
ARG ALPINE_BUILDER_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

# Build the verifier's shell from audited source with only seven applets. The
# stock BusyBox image also contains wget/nc/ftp applets reachable through the
# multicall binary even when their symlinks are removed.
FROM --platform=linux/amd64 ${ALPINE_BUILDER_IMAGE} AS busybox-builder
RUN apk add --no-cache \
      build-base=0.5-r3 \
      linux-headers=6.14.2-r0
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
WORKDIR /src
# A single GCC job keeps this source build reproducible under linux/amd64
# emulation on arm64 publication runners without changing the applet set.
RUN tar -xjf /tmp/busybox.tar.bz2 && \
    cd busybox-1.37.0 && \
    printf '%s\n' \
      'CONFIG_STATIC=y' \
      'CONFIG_BUSYBOX=y' \
      'CONFIG_ASH=y' \
      'CONFIG_ASH_ECHO=y' \
      'CONFIG_ASH_PRINTF=y' \
      'CONFIG_ASH_TEST=y' \
      'CONFIG_ASH_CMDCMD=y' \
      'CONFIG_SH_IS_ASH=y' \
      'CONFIG_TEST=y' \
      'CONFIG_TEST1=y' \
      'CONFIG_TEST2=y' \
      'CONFIG_ID=y' \
      'CONFIG_GREP=y' \
      > /tmp/minimal.config && \
    make allnoconfig >/dev/null && \
    while IFS= read -r setting; do \
      name="${setting%%=*}"; \
      sed -i "s/^# $name is not set$/$setting/" .config; \
    done < /tmp/minimal.config && \
    make oldconfig </dev/null >/dev/null && \
    make -j1 busybox && \
    mkdir -p /out && \
    cp busybox /out/busybox
RUN cd busybox-1.37.0 && \
    file ./busybox | grep -q 'statically linked' && \
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" && \
    for tool in apk apt apt-get apt-key curl dpkg ftpget ftpput nc rpm telnet tftp wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

FROM ${CRYSTAL_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN crystal tool format --check client examples
RUN test "$(uname -m)" = x86_64
RUN crystal build --release --static --no-debug examples/basics/main.cr -o /tmp/convex-example
RUN crystal build --release --static --no-debug -Dexample_count_test examples/basics/count_test.cr -o /tmp/crystal-example-count-test
RUN crystal build --release --static --no-debug client/tests/conformance/adapter.cr -o /tmp/convex-adapter
RUN crystal build --release --static --no-debug -Dlive_test client/tests/live_test.cr -o /tmp/crystal-live-test
RUN crystal build --release --static --no-debug -Dadapter_test client/tests/adapter_test.cr -o /tmp/crystal-adapter-test
RUN /tmp/crystal-live-test
RUN /tmp/crystal-adapter-test
RUN /tmp/crystal-example-count-test
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | CONVEX_URL=http://127.0.0.1 /tmp/convex-adapter | grep -Fx '{"protocolVersion":1,"id":"hello","type":"ready","language":"crystal","implementation":"native-crystal-1.14.1","runtime":"crystal-1.14.1"}'

FROM ${CRYSTAL_IMAGE} AS build
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 && mkdir -p /out && crystal build --release --static --no-debug examples/basics/main.cr -o /out/convex-example && crystal build --release --static --no-debug client/tests/conformance/adapter.cr -o /out/convex-adapter && crystal build --release --static --no-debug client/tests/conformance/stopped_reader_controller.cr -o /out/stopped-reader-controller

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260413-r0

# BusyBox supplies only the shell and POSIX tools the shared verifier needs.
# Alpine's package database and apk executable stop at the certificates stage.
FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
COPY --from=busybox-builder /out/busybox /restricted-busybox
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# Crystal's OpenSSL build follows Alpine's canonical certificate and config
# paths. Keeping only the bundle leaves the final static executable unable to
# verify a normal TLS peer even though the certificate bytes are present.
COPY --from=certificates /etc/ssl/cert.pem /etc/ssl/cert.pem
COPY --from=certificates /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox find /bin -mindepth 1 -maxdepth 1 ! -name busybox -delete; \
    /bin/busybox rm -rf /sbin /usr; \
    /bin/busybox mkdir -p /bin /usr/bin /usr/local/bin; \
    /bin/busybox ln -s busybox /bin/sh; \
    /bin/busybox ln -s ../../bin/busybox /usr/bin/id; \
    /bin/busybox ln -s ../../bin/busybox /usr/bin/grep; \
    /bin/busybox mv /restricted-busybox /bin/busybox' \
    && test "$(/bin/busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" \
    && for tool in apk apt apt-get apt-key curl dpkg ftpget ftpput nc rpm telnet tftp wget; do test "$(/bin/busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; done \
    && ! test -e /sbin/apk \
    && ! command -v apk \
    && for command in crystal shards npm npx node python python3 pip pip3 curl convex gcc cc clang make; do ! command -v "$command"; done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build --chmod=0555 /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS memory-controller
COPY --from=build --chmod=0555 /out/stopped-reader-controller /usr/local/bin/stopped-reader-controller
ENTRYPOINT ["/usr/local/bin/stopped-reader-controller"]

# Keep runtime last because ./run build crystal builds the default target.
FROM runtime-base AS runtime
COPY --from=build --chmod=0555 /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
