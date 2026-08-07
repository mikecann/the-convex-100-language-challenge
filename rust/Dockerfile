# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG RUST_IMAGE=rust:1.89.0-bookworm@sha256:948f9b08a66e7fe01b03a98ef1c7568292e07ec2e4fe90d88c07bb14563c84ff
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${RUST_IMAGE} AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN apt-get update \
    && apt-get install --no-install-recommends --yes binutils file musl-tools \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add rustfmt \
    && rustup target add x86_64-unknown-linux-musl
RUN cargo fmt --manifest-path client/Cargo.toml --check
RUN cargo test --locked --manifest-path client/Cargo.toml
RUN cargo build --locked --release --target x86_64-unknown-linux-musl \
    --manifest-path client/Cargo.toml --bin convex-adapter --bin convex-example
RUN test "$(uname -m)" = x86_64 \
    && rustc --print cfg --target x86_64-unknown-linux-musl | grep -qx 'target_arch="x86_64"' \
    && file client/target/x86_64-unknown-linux-musl/release/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && file client/target/x86_64-unknown-linux-musl/release/convex-example | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && readelf -h client/target/x86_64-unknown-linux-musl/release/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
CMD ["/bin/sh", "-ec", "test \"$(uname -m)\" = x86_64 && /project/client/target/x86_64-unknown-linux-musl/release/convex-adapter <<'EOF'\n{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\nEOF"]

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260611-r0

# The stock BusyBox image this runtime is built FROM ships httpd, ftpd, inetd,
# wget, nc, telnet, ar, dpkg and rpm as applets of the same multicall binary
# that provides /bin/sh: removing their symlinks would not remove the
# applets, which stay reachable through `busybox wget` or a forged argv[0].
# This stage compiles a from-source BusyBox whose applet table contains only
# the seven entries the shared verifier and this Dockerfile's own checks use,
# so the dangerous applets are never compiled in, not merely hidden off PATH.
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
    file ./busybox | grep -q 'statically linked' && \
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" && \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

# The final rootfs receives only the restricted BusyBox above, the CA bundle,
# and one static Rust binary; Alpine's apk database and package manager never
# cross this stage boundary, and the stock BusyBox multicall binary this stage
# starts FROM does not survive it either. The restricted binary is
# hard-linked under the applet names it serves — sh, id, grep — and never
# written to a path literally named busybox, because a from-source rebuild
# that still ends up at /bin/busybox only proves the applet table changed,
# not that the image stopped being "a copy of BusyBox with a longer denylist".
FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=busybox-builder /out/busybox /restricted-busybox
# BusyBox's multicall dispatcher only enters "top-level" mode (--list,
# explicit `busybox <applet>`) when argv[0]'s basename is literally
# "busybox"; invoked under any other name it looks that name up directly in
# the compiled applet table. That makes a file named anything else than
# "busybox" impossible to introspect with --list, which is favourable here:
# the applet table is re-checked below through a copy that is deleted before
# this layer ends, so the assertion runs but the name never ships.
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox mkdir /policy /verify; \
    /bin/busybox cp /bin/busybox /policy/busybox; \
    /bin/busybox cp /restricted-busybox /verify/busybox; \
    test "$(/verify/busybox --list)" = "$(printf "%s\n" "[" "[[" ash grep id sh test)"; \
    for tool in apk apt apt-get apt-key curl dpkg nc rpm wget; do \
      test "$(/verify/busybox "$tool" 2>/dev/null; printf "%s" "$?")" = 127; \
    done; \
    /policy/busybox rm -rf /verify; \
    /policy/busybox rm -rf /etc/group /etc/localtime /etc/mtab /etc/network /etc/passwd /etc/shadow /.cache /home /root /sbin /tmp /usr /var /lib; \
    /policy/busybox find /bin -mindepth 1 -maxdepth 1 -delete; \
    /policy/busybox mkdir -p /usr/bin /usr/local/bin; \
    /policy/busybox mv /restricted-busybox /bin/sh; \
    /policy/busybox ln /bin/sh /usr/bin/id; \
    /policy/busybox ln /bin/sh /usr/bin/grep; \
    test -x /bin/sh; \
    test -x /usr/bin/id; \
    test -x /usr/bin/grep; \
    for name in wget nc httpd ftpd ftpget ftpput tftp telnet inetd ar dpkg dpkg-deb rpm apk apt apt-get curl; do \
      implicit="$(/bin/sh -c "exec -a $name /bin/sh" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$implicit" = 127; \
      explicit="$(/bin/sh -c "exec -a busybox /bin/sh $name" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$explicit" = 127; \
    done; \
    forbidden="$(/policy/busybox find / -xdev -path /policy -prune -o \( -type f -o -type l \) \( -name apk -o -name apt -o -name apt-get -o -name apt-key -o -name busybox -o -name curl -o -name dpkg -o -name nc -o -name rpm -o -name wget \) -print)"; \
    test -z "$forbidden"; \
    /policy/busybox rm -rf /policy; \
    test ! -e /policy'
RUN set -eu; \
    for command_name in apk cargo rustc rustfmt rustup gcc cc make node python python3 npm pip curl convex; do \
      ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /project/client/target/x86_64-unknown-linux-musl/release/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because `./run build rust` builds the default target.
FROM runtime-base AS runtime
COPY --from=test /project/client/target/x86_64-unknown-linux-musl/release/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
