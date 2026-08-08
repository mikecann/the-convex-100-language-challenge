# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Clean 3.1's own binaries (cocl, clm, cg, linker) are dynamically linked
# glibc x86-64 ELF executables built against an Ubuntu 18.04-era glibc, so a
# musl (Alpine) base cannot run them at all; Debian's own glibc is what this
# stage provides.
FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS clean-toolchain
RUN apt-get update && apt-get install --no-install-recommends --yes \
      ca-certificates \
      binutils \
      file \
      gcc \
      libc6-dev \
      libssl-dev \
      make \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:ffb03e65798246215a8c217cdbaf33fa29ae5b110cc54b144e989bb9537b3fbb \
    https://ftp.cs.ru.nl/Clean/Clean31/linux/clean3.1_64.tar.gz /tmp/clean3.1_64.tar.gz
RUN mkdir -p /opt && tar -xzf /tmp/clean3.1_64.tar.gz -C /opt && rm /tmp/clean3.1_64.tar.gz
# The extracted tarball is Clean's *source* distribution layout (bin/, exe/,
# StdEnv/, data/ side by side), not something clm's own compiled-in default
# paths (a sibling lib/ next to bin/) can run against directly. `make
# install` is the only supported way to get there: besides copying the
# compiler and every library group into $(INSTALL_DIR)/lib/..., it binary-
# patches clm's own embedded CLEANLIB/CLEANPATH/CLEANILIB strings (via the
# distribution's own `patch_bin` tool) to point at that install location,
# and bootstrap-compiles the standard environment (StdEnv/install.sh) with
# the freshly built compiler against its own source. INSTALL_DIR defaults to
# the current directory, so running make from /opt/clean installs in place.
RUN cd /opt/clean && make
ENV PATH=/opt/clean/bin:${PATH}
RUN test "$(uname -m)" = x86_64 \
    && file /opt/clean/lib/exe/cocl | grep -Eq 'ELF 64-bit.*x86-64' \
    && file /opt/clean/bin/clm | grep -Eq 'ELF 64-bit.*x86-64'

FROM clean-toolchain AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples
RUN clm -V
RUN printf '%s\n' 'module hello' '' 'Start :: Int' 'Start = 1' > /tmp/hello.icl \
    && cd /tmp && clm -nt hello -o /tmp/hello-bin \
    && /tmp/hello-bin
# Language-local unit tests, one small standalone executable per test
# module (Clean has no project-wide test runner in this distribution; each
# test file is its own `Start`-having program that aborts with a specific
# message on the first failing check). `FoundationTest` covers
# Convex.Result, Convex.Deadline, Convex.Mem, and Convex.Socket's
# network-free behaviour, and also proves — by importing but never calling
# Convex.TLS — that the `import code from library "-lssl"/"-lcrypto"`
# directives in TLS.icl resolve against this runtime's real OpenSSL,
# without needing a TLS peer to connect to (Clean links whole per-module
# object files, not individual functions). `WireTest` covers the JSON
# codec, including the integral-decimal-real regression
# (`docs`/AGENTS.md's "Convex JSON numbers may arrive in an integral
# decimal form such as 0.0" requirement). `HTTPTest` covers
# `Convex.HTTP.parseEndpoint`, the only pure (transport-free) surface of
# the HTTP layer; request/response framing itself is exercised by
# `./run verify` and `./run verify-hosted` against a real deployment.
# `ConvexCallTest` is a real end-to-end demo:state/demo:increment round
# trip, but only when CONVEX_URL is set (matching every other client's
# equivalent regression, see hare/client/convex.ha); this offline `test`
# stage never sets it, so it runs here as a documented no-op and only does
# real network I/O under `./run verify`/`verify-hosted`.
RUN for t in FoundationTest WireTest HTTPTest ConvexCallTest WebSocketTest ConvexLiveTest ClientTest; do \
      (cd /project/client/Convex && clm -nt -IL Platform -I /project/client "$t" -o "/tmp/$t-bin") \
      && "/tmp/$t-bin" \
      || exit 1; \
    done
# `readelf -d`'s own NEEDED entries only list libssl.so.3 directly: nothing
# in TLS.icl calls a libcrypto-only symbol yet (every ccall so far is an
# SSL_* function), so `-lcrypto` produced no direct relocation and the
# linker correctly omitted a direct NEEDED entry for it. libcrypto is still
# a real, transitive runtime dependency of libssl itself, which `ldd`
# resolves; that is the meaningful check here; a direct NEEDED entry would
# only appear once a later module calls an X509/EVP/BIO-level function.
RUN test "$(uname -m)" = x86_64 \
    && file /tmp/FoundationTest-bin | grep -Eq 'ELF 64-bit.*x86-64' \
    && readelf -d /tmp/FoundationTest-bin | grep -q 'libssl\.so' \
    && ldd /tmp/FoundationTest-bin | grep -q 'libcrypto\.so'
# The canonical example and the test-only NDJSON adapter, built here so the
# `test` gate proves they compile even offline; `example-runtime`/`runtime`
# below copy these exact binaries rather than rebuilding them.
RUN mkdir -p /out \
    && (cd /project/examples/basics && clm -nt -IL Platform -IL ArgEnv -I /project/client main -o /out/convex-example) \
    && (cd /project/client/tests/conformance && clm -nt -IL Platform -I /project/client main -o /out/convex-adapter) \
    && test "$(uname -m)" = x86_64 \
    && file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64' \
    && file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64'
# Proves the real adapter binary's hello/close NDJSON lifecycle at build
# time, against the exact binary shipped in /out. CONVEX_URL is a dummy
# value scoped to this one RUN: neither hello nor close ever calls
# ensureClient, so the adapter never opens a network connection here.
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:9 /out/convex-adapter >/tmp/convex-adapter-hello.ndjson \
    && grep -Fq '"language":"clean"' /tmp/convex-adapter-hello.ndjson \
    && grep -Fq '"type":"closed"' /tmp/convex-adapter-hello.ndjson
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
    libraries="$({ for binary in /bin/dash /usr/bin/id /usr/bin/grep /out/convex-example /out/convex-adapter; do ldd "$binary"; done; } | awk '$3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' | sort -u)"; \
    for library in $libraries; do \
      cp --parents -L "$library" "$root"; \
    done; \
    # glibc's NSS modules (nss_dns/nss_files, for gethostbyname's real
    # hostname resolution against a hosted deployment) are dlopen'd at
    # runtime rather than linked, so `ldd` above never finds them; copied
    # explicitly here instead.
    for nss in /usr/lib/x86_64-linux-gnu/libnss_dns.so.2 /usr/lib/x86_64-linux-gnu/libnss_files.so.2 /usr/lib/x86_64-linux-gnu/libresolv.so.2; do \
      test -e "$nss" && cp --parents -L "$nss" "$root" || true; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl" 2>/dev/null || true; \
    cp -a /usr/lib/x86_64-linux-gnu/engines-3 "$root/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$root/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true; \
    cp /etc/nsswitch.conf /etc/hosts "$root/etc/"
RUN set -eu; \
    test -r /runtime/etc/ssl/certs/ca-certificates.crt; \
    events="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | chroot /runtime /usr/local/bin/convex-adapter)"; \
    echo "$events" | /usr/bin/grep -Fq '"language":"clean"'; \
    echo "$events" | /usr/bin/grep -Fq '"type":"closed"'

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
# Keep the Debian provenance required by the shared verifier, but replace
# its filesystem with the individually allowlisted shell, text tools,
# client executables, and their complete runtime closure assembled above —
# matching this project's other dynamically-linked native clients (see
# odin/Dockerfile).
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
    for candidate in /bin/* /usr/bin/* /usr/local/bin/*; do \
      case "$candidate" in \
        /bin/sh|/usr/bin/id|/usr/bin/grep|/usr/local/bin/convex-example|/usr/local/bin/convex-adapter) ;; \
        *) test ! -x "$candidate" ;; \
      esac; \
    done; \
    for command in apk apt apt-get dpkg gcc g++ cc clang clang++ make cmake cocl clm cg cpm htoclean cargo rustc node npm npx python python3 pip pip3 curl wget nc convex; do \
      ! command -v "$command" >/dev/null 2>&1; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because ./run's default build target
# selects the last stage.
FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
