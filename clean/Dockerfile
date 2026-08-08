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
RUN for t in FoundationTest WireTest HTTPTest ConvexCallTest; do \
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
