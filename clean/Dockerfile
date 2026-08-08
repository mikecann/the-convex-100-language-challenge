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
# Deliverable 1: prove the six checked-in Convex.* modules (Result, Deadline,
# Mem, Socket, TLS, Wire) actually compile and link together with this exact
# Clean 3.1 toolchain. This smoke driver is build-only scaffolding, not
# committed client or example source: it imports every module (forcing cocl
# to type-check and generate code for each of the six .icl files) and calls
# a handful of network-free functions from Result, Deadline, Mem, Wire, and
# Socket. Convex.TLS is imported but never called here — its .o is still
# linked into the binary regardless (Clean links whole per-module object
# files, not individual functions), which is what actually proves the
# `import code from library "-lssl"/"-lcrypto"` directives added to TLS.icl
# resolve against the runtime's real OpenSSL shared libraries. `pollReady`
# is called with a negative fd and a zero timeout so `poll(2)` returns
# immediately rather than touching the network at all.
RUN mkdir -p /project/smoke && printf '%b\n' \
      'module smoke' \
      '' \
      'import StdEnv' \
      'import StdMaybe' \
      'import Convex.Result' \
      'import Convex.Deadline' \
      'import Convex.Mem' \
      'import Convex.Wire' \
      'import Convex.Socket' \
      'import Convex.TLS' \
      '' \
      'Start :: *World -> *World' \
      'Start w' \
      '\t# (d, w) = deadlineIn 1000 w' \
      '\t# (rem, w) = remainingMs d w' \
      '\t# (p, w) = mallocW 8 w' \
      '\t# w = freeW p w' \
      '\t# ok = isROk (resultMap (\\x -> x + 1) (ROk rem))' \
      '\t# j = encodeJSON (JObject [("a", JInt 1)])' \
      '\t# parsed = isJust (parseJSON j)' \
      '\t# (ready, w) = pollReady (-1) False 0 w' \
      '\t# pollOk = isROk ready' \
      '\t| ok && parsed && pollOk && size j == 7 = w' \
      '\t= abort "smoke check failed"' \
      'isJust (Just _) = True' \
      'isJust Nothing = False' \
      > /project/smoke/smoke.icl
# A nonzero exit from clm (a compile error) or from running the produced
# binary (the `abort` above, if any of the five checks disagrees with what
# these modules are supposed to do) both fail this RUN step and therefore
# the whole build.
RUN cd /project/smoke \
    && clm -nt -IL Platform -I /project/client smoke -o /tmp/smoke-bin \
    && /tmp/smoke-bin
# `readelf -d`'s own NEEDED entries only list libssl.so.3 directly: nothing
# in TLS.icl calls a libcrypto-only symbol yet (every ccall so far is an
# SSL_* function), so `-lcrypto` produced no direct relocation and the
# linker correctly omitted a direct NEEDED entry for it. libcrypto is still
# a real, transitive runtime dependency of libssl itself, which `ldd`
# resolves; that is the meaningful check here; a direct NEEDED entry would
# only appear once a later module calls an X509/EVP/BIO-level function.
RUN test "$(uname -m)" = x86_64 \
    && file /tmp/smoke-bin | grep -Eq 'ELF 64-bit.*x86-64' \
    && readelf -d /tmp/smoke-bin | grep -q 'libssl\.so' \
    && ldd /tmp/smoke-bin | grep -q 'libcrypto\.so'
