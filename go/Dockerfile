# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GO_IMAGE=golang:1.25.6-bookworm@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS busybox

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS busybox-builder
RUN apk add --no-cache \
      build-base=0.5-r3 \
      linux-headers=6.14.2-r0
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
WORKDIR /src
RUN tar -xjf /tmp/busybox.tar.bz2 && \
    cd busybox-1.37.0 && \
    printf '%s\n' \
      'CONFIG_STATIC=y' \
      'CONFIG_BUSYBOX=y' \
      'CONFIG_ASH=y' \
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
    make -j2 busybox && \
    mkdir -p /out && \
    cp busybox /out/busybox
RUN cd busybox-1.37.0 && \
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" && \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

FROM ${GO_IMAGE} AS dependencies
WORKDIR /src
COPY client/go.mod client/go.sum ./
RUN go mod download

FROM dependencies AS test
# Assemble a conventional Go module only inside the container. The repository
# keeps client and example ownership obvious for people reading the project.
COPY client/*.go ./
COPY client/tests ./tests
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 && \
    test "$(go env GOHOSTARCH)" = amd64 && \
    test "$(go env GOARCH)" = amd64
RUN test -z "$(gofmt -l .)"
RUN go test -race ./...
RUN go test -race -tags convexadapter ./...
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -trimpath -ldflags="-s -w -buildid=" \
      -o /tmp/convex-go-example ./examples/basics && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -tags convexadapter -trimpath -ldflags="-s -w -buildid=" \
      -o /tmp/convex-go-adapter ./tests/conformance && \
    test "$(od -An -t x1 -j 18 -N 2 /tmp/convex-go-example | tr -d ' \n')" = 3e00 && \
    test "$(od -An -t x1 -j 18 -N 2 /tmp/convex-go-adapter | tr -d ' \n')" = 3e00 && \
    rm -f /tmp/convex-go-example /tmp/convex-go-adapter

FROM test AS example-build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath \
    -ldflags="-s -w -buildid=" \
    -o /out/convex-go-example ./examples/basics && \
    test "$(od -An -t x1 -j 18 -N 2 /out/convex-go-example | tr -d ' \n')" = 3e00

FROM test AS build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -tags convexadapter -trimpath \
    -ldflags="-s -w -buildid=" \
    -o /out/convex-go-adapter ./tests/conformance && \
    test "$(od -An -t x1 -j 18 -N 2 /out/convex-go-adapter | tr -d ' \n')" = 3e00

FROM example-build AS runtime-rootfs
RUN mkdir -p /runtime/etc/ssl/certs /runtime/usr/local/bin && \
    cp /etc/ssl/certs/ca-certificates.crt /runtime/etc/ssl/certs/ca-certificates.crt && \
    cp /out/convex-go-example /runtime/usr/local/bin/convex-example && \
    true
COPY --from=build /out/convex-go-adapter /runtime/usr/local/bin/convex-adapter

FROM busybox AS runtime-base
USER 0:0
COPY --from=busybox-builder /out/busybox /restricted-busybox
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox mkdir /policy; \
    cp /bin/busybox /policy/busybox; \
    /bin/busybox rm -rf /etc/group /etc/localtime /etc/mtab /etc/network /etc/passwd /etc/shadow /.cache /home /root /sbin /tmp /usr /var /lib; \
    /bin/busybox find /bin -mindepth 1 -maxdepth 1 ! -name busybox -delete; \
    /bin/busybox mkdir -p /usr/bin /usr/local/bin; \
    /bin/busybox ln -s busybox /bin/sh; \
    /bin/busybox ln -s ../../bin/busybox /usr/bin/id; \
    /bin/busybox ln -s ../../bin/busybox /usr/bin/grep; \
    /bin/busybox mv /restricted-busybox /bin/busybox; \
    test "$(/bin/busybox --list | /bin/busybox grep -c "^")" = 7; \
    for applet in "[" "[[" ash grep id sh test; do /bin/busybox --list | /bin/busybox grep -Fqx "$applet"; done; \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      if /bin/busybox "$tool" >/dev/null 2>&1; then exit 1; else test "$?" = 127; fi; \
    done; \
    forbidden="$(/policy/busybox find / -xdev \( -type f -o -type l \) \( -name apk -o -name apt -o -name apt-get -o -name apt-key -o -name curl -o -name dpkg -o -name nc -o -name rpm -o -name wget \) -print)"; \
    test -z "$forbidden"; \
    /policy/busybox rm -rf /policy'
COPY --from=runtime-rootfs /runtime /
RUN set -eu; \
    test -x /bin/sh && test -x /usr/bin/id && test -x /usr/bin/grep; \
    test "$(/bin/busybox --list | /bin/busybox grep -c "^")" = 7; \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget gcc cc make node npm python python3 convex; do ! command -v "$tool"; done; \
    test -r /etc/ssl/certs/ca-certificates.crt
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
