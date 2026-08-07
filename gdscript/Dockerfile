# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

# Godot ships one editor binary and a separate set of export templates. The
# editor is a build tool and stays in the build stages; the Linux release
# template is an engine runtime with no editor, no exporter, and no script
# tooling, and it is the only Godot binary the runtime images contain.
FROM ${DEBIAN_IMAGE} AS godot-dist
ADD https://github.com/godotengine/godot/releases/download/4.4.1-stable/Godot_v4.4.1-stable_linux.x86_64.zip /tmp/godot.zip
ADD https://github.com/godotengine/godot/releases/download/4.4.1-stable/Godot_v4.4.1-stable_export_templates.tpz /tmp/templates.tpz
RUN apt-get update && apt-get install -y --no-install-recommends unzip=6.0-28 \
    && rm -rf /var/lib/apt/lists/*
# Checksums are the ones published in the 4.4.1-stable release's
# SHA512-SUMS.txt. Docker's ADD checksum option takes sha256 only, so the
# published sha512 values are verified explicitly instead.
RUN set -eu; \
    godot_sum=ef4e76880a514257175544952c61191106fdef3095b909bafed9fcbeb230c3e5533920a0f3012882dd4bbde83028a67549825794e2d2c3cf76eba7918b71370e; \
    templates_sum=8f461c7d6e91a0fbabfc95b1e4ca70ff1732c6f2920956a16b086ec2a85b5f7e238baf4dbce60dcc5630fae3bcb9a1fa2ae2027b92cb495c02d082705715e441; \
    printf '%s  %s\n' "$godot_sum" /tmp/godot.zip > /tmp/sums; \
    printf '%s  %s\n' "$templates_sum" /tmp/templates.tpz >> /tmp/sums; \
    sha512sum -c /tmp/sums; \
    unzip -q /tmp/godot.zip -d /tmp/editor; \
    install -Dm0555 /tmp/editor/Godot_v4.4.1-stable_linux.x86_64 /out/godot; \
    unzip -q /tmp/templates.tpz -d /tmp/unpacked; \
    mkdir -p /out/templates; \
    cp -a /tmp/unpacked/templates/. /out/templates/; \
    test -f /out/templates/linux_release.x86_64; \
    # The runtime binary must be a real x86-64 ELF, not an amd64 label over
    # something else. Byte 18 of the ELF header is the machine type.
    test "$(od -An -tx1 -j18 -N1 /out/templates/linux_release.x86_64 | tr -d ' ')" = 3e; \
    test "$(od -An -tx1 -j18 -N1 /out/godot | tr -d ' ')" = 3e

# The runtime shell is built from checksum-pinned source with only the applets
# below in its compiled table, so renaming it to wget or nc cannot recover the
# full upstream BusyBox command surface.
FROM ${DEBIAN_IMAGE} AS busybox-builder
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
RUN apt-get update && apt-get install -y --no-install-recommends \
    bzip2=1.0.8-5+b1 gcc=4:12.2.0-3 libc6-dev=2.36-9+deb12u14 \
    make=4.3-4.1 musl-tools=1.2.3-1 \
    && rm -rf /var/lib/apt/lists/*
RUN tar -xjf /tmp/busybox.tar.bz2 -C /tmp
WORKDIR /tmp/busybox-1.37.0
# ASH_ECHO, ASH_PRINTF and ASH_TEST are builtins inside ash rather than
# standalone applets, so they change behaviour without adding entries to
# --list; the expected applet count below accounts for that.
RUN make allnoconfig >/dev/null && \
    for option in STATIC BUSYBOX ASH ASH_ECHO ASH_PRINTF ASH_TEST AWK BASENAME CAT CMP CUT DIRNAME ENV GREP HEAD ID SED SORT TAIL TEST TR TRUE FALSE UNAME UNIQ WC; do \
      sed -i "s/# CONFIG_${option} is not set/CONFIG_${option}=y/" .config; \
    done && \
    CC=musl-gcc make -j2 busybox >/dev/null && \
    test "$(./busybox --list | wc -l)" -eq 22 && \
    test "$(./busybox sh -c 'printf shell-ok')" = shell-ok && \
    ! ./busybox --list | grep -E '^(wget|nc|telnet|ftp|ftpget|ftpput|httpd|tftp)$' && \
    install -Dm0555 busybox /out/busybox

FROM ${DEBIAN_IMAGE} AS test
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates=20230311+deb12u1 \
    python3=3.11.2-1+b1 python3-venv=3.11.2-1+b1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=godot-dist /out/godot /usr/local/bin/godot
# The editor needs its export templates in the versioned location before it
# can write an export pack.
COPY --from=godot-dist /out/templates /root/.local/share/godot/export_templates/4.4.1.stable
# gdformat and gdlint are the GDScript ecosystem's standard formatter and
# linter. They are Python tools and stay in this build stage only.
RUN python3 -m venv /opt/gdtoolkit && \
    /opt/gdtoolkit/bin/pip install --no-cache-dir "gdtoolkit==4.3.4"
ENV PATH="/opt/gdtoolkit/bin:${PATH}"

WORKDIR /work
# Godot expects one project root. The repository keeps client/ and examples/
# as educational directories and the project metadata under client/, so the
# temporary project tree is assembled here rather than in the repository.
COPY client ./project/client
COPY examples ./project/examples
RUN set -eu; \
    mv project/client/project.godot project/project.godot; \
    mv project/client/export_presets.cfg project/export_presets.cfg; \
    mv project/client/.gdlintrc project/.gdlintrc

# Formatting and linting come before anything is executed, because the README
# and the website publish this source verbatim.
RUN cd /work/project && gdformat --check $(find client examples -name '*.gd')
RUN cd /work/project && gdlint $(find client examples -name '*.gd')
# Import once so the global class cache exists, then parse every script.
RUN godot --headless --path /work/project --import
RUN cd /work/project && for script in $(find client examples -name '*.gd'); do \
      godot --headless --path /work/project --check-only --script "res://$script" || exit 1; \
    done

# Language-local behaviour, in dependency order.
RUN godot --headless --path /work/project --script res://client/tests/values_test.gd
RUN godot --headless --path /work/project --script res://client/tests/http_test.gd
RUN godot --headless --path /work/project --script res://client/tests/live_test.gd
RUN godot --headless --path /work/project --script res://client/tests/websocket_test.gd
RUN godot --headless --path /work/project --script res://client/tests/conformance/output_test.gd
RUN godot --headless --path /work/project --script res://client/tests/conformance/adapter_test.gd
RUN godot --headless --path /work/project --script res://client/tests/conformance/tcp_test.gd
# End of input is a clean shutdown, not a hang: the adapter must exit by
# itself with no controller and no deployment configured.
RUN timeout 30 godot --headless --path /work/project \
      --script res://client/tests/conformance/adapter.gd </dev/null >/dev/null

# Two packs, one entry point each. The example pack is exported after
# rewriting the main loop, so neither minimal image can start the other
# image's program.
RUN set -eu; \
    mkdir -p /out; \
    godot --headless --path /work/project --export-pack convex-adapter /out/convex-adapter.pck; \
    sed -i 's/"ConvexAdapterMain"/"ConvexExampleMain"/' /work/project/project.godot; \
    godot --headless --path /work/project --export-pack convex-example /out/convex-example.pck; \
    test -s /out/convex-adapter.pck; \
    test -s /out/convex-example.pck

CMD ["/bin/sh", "-c", "test \"$(uname -m)\" = x86_64 && godot --headless --version | grep -q '^4[.]4[.]1[.]stable'"]

# Godot's Linux template is dynamically linked against glibc and loads X11,
# audio, and udev libraries with dlopen only when a display server needs them,
# which headless never does. TLS needs no files either: Godot compiles the
# Mozilla CA bundle into the binary and uses its own statically linked
# mbedTLS, so there is no OpenSSL configuration, engine, or provider to carry.
# What the runtime does need is the glibc closure plus the name-service
# modules and configuration DNS resolution loads at run time.
FROM ${DEBIAN_IMAGE} AS runtime-rootfs
COPY --from=godot-dist /out/templates/linux_release.x86_64 /tmp/godot
RUN set -eu; root=/runtime-root; \
    mkdir -p "$root/opt/convex" "$root/etc"; \
    install -Dm0555 /tmp/godot "$root/opt/convex/godot"; \
    ldd /tmp/godot | \
      awk '{ if ($3 ~ /^\//) print $3; if ($1 ~ /^\//) { path = $1; sub(/:$/, "", path); print path } }' | \
      sort -u | while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libresolv.so.2; do \
      test ! -e "$library" || cp --parents "$library" "$root"; \
    done; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      test ! -e "$config" || cp --parents "$config" "$root"; \
    done; \
    # Godot writes nothing at run time, but it does check for its user data
    # directory at startup. Pre-creating it keeps a read-only filesystem quiet
    # without granting the process anywhere to write.
    mkdir -p "$root/opt/convex/state/godot/app_userdata/convex"; \
    mkdir -p "$root/opt/convex/state/godot_config" "$root/opt/convex/state/godot_cache"; \
    ! ldd /tmp/godot | grep -Eq 'libX11|libwayland|libasound|libpulse|libudev|libssl|libcrypto'; \
    test -z "$(find "$root" -type f \( -name 'libapt*' -o -name 'libpam*' -o -name 'libsystemd*' \) -print -quit)"

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-os
COPY --from=busybox-builder /out/busybox /tmp/restricted-busybox
RUN set -eu; \
    mkdir /tmp/full; \
    cp /bin/busybox /tmp/full/busybox; \
    for path in /bin/*; do /tmp/full/busybox rm -f "$path"; done; \
    for tool in sh awk basename cat cmp cut dirname env grep head id sed sort tail test tr true false uname uniq wc; do \
      /tmp/full/busybox ln /tmp/restricted-busybox "/bin/$tool"; \
    done; \
    /tmp/full/busybox rm -rf /sbin /usr/bin /usr/sbin; \
    /tmp/full/busybox rm -rf /tmp/restricted-busybox /tmp/full

FROM runtime-os AS runtime-base
COPY --from=runtime-rootfs /runtime-root /
# Godot resolves its user, config, and cache directories from these variables.
# They point at directories that already exist in the image, so nothing is
# created at run time and a read-only filesystem produces no startup error.
ENV XDG_DATA_HOME=/opt/convex/state \
    XDG_CONFIG_HOME=/opt/convex/state/godot_config \
    XDG_CACHE_HOME=/opt/convex/state/godot_cache \
    HOME=/opt/convex/state
RUN set -eu; \
    test -x /opt/convex/godot; \
    for applet in wget nc telnet ftp ftpget ftpput httpd tftp; do \
      ! /bin/sh -c "exec -a $applet /bin/sh" >/dev/null 2>&1; \
      ! /bin/sh -c "exec -a busybox /bin/sh $applet" >/dev/null 2>&1; \
    done; \
    for command in busybox apk apt apt-get apt-cache dpkg gcc cc make scons \
        node npm npx python python3 pip pip3 curl wget nc telnet convex godot \
        gdformat gdlint; do \
      ! command -v "$command" >/dev/null 2>&1; \
    done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example.pck /opt/convex/convex.pck
# A Godot program is an engine binary plus a pack rather than one executable,
# so the entry point is a two-line wrapper that names both. It adds no logic.
RUN printf '%s\n%s\n' '#!/bin/sh' \
      'exec /opt/convex/godot --headless --main-pack /opt/convex/convex.pck -- "$@"' \
      > /usr/local/bin/convex-example && \
    chmod 0555 /usr/local/bin/convex-example
USER 65532:65532
# Prove, as the runtime user, that the pack boots in this minimal image, that
# the example fails closed without configuration, and that standard output
# stays completely empty on that path. The shared verifier compares stdout
# byte for byte, so an engine banner there would be a defect.
RUN set -eu; \
    if /usr/local/bin/convex-example probe-room >/dev/null 2>&1; then exit 1; fi; \
    output=$(/usr/local/bin/convex-example probe-room 2>/dev/null || true); \
    test -z "$output"; \
    diagnostics=$(/usr/local/bin/convex-example probe-room 2>&1 >/dev/null || true); \
    echo "$diagnostics" | grep -Fq 'CONVEX_URL is required'
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter.pck /opt/convex/convex.pck
RUN printf '%s\n%s\n' '#!/bin/sh' \
      'exec /opt/convex/godot --headless --main-pack /opt/convex/convex.pck -- "$@"' \
      > /usr/local/bin/convex-adapter && \
    chmod 0555 /usr/local/bin/convex-adapter
USER 65532:65532
# Standard output carries protocol events and nothing else: exactly two lines
# for a hello and a close, with every diagnostic on standard error.
RUN set -eu; \
    events=$(printf '%s\n' '{"protocolVersion":1,"id":"h","op":"hello"}' '{"id":"c","op":"close"}' \
      | /usr/local/bin/convex-adapter 2>/dev/null); \
    test "$(echo "$events" | wc -l)" -eq 2; \
    echo "$events" | head -n 1 | grep -Fq '"language":"gdscript"'; \
    echo "$events" | tail -n 1 | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
