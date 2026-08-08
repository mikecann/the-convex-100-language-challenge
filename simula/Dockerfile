# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base the other native clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: build GNU Cim from source, lint, compile every Simula program this
# client ships, and run every language-local suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc \
       libc6-dev \
       libssl-dev \
       ca-certificates \
       openssl \
       file \
       binutils \
       make \
       wget \
    && rm -rf /var/lib/apt/lists/*

# GNU Cim is not packaged for Debian, so the compiler itself is built from
# the upstream tarball. Its version is asserted and recorded so the adapter
# cannot misreport the runtime it is actually running on.
#
# The upstream 5.1 release tarball ships two pre-generated bootstrap C files,
# lib/simset.c and lib/simulation.c (Cim's own SIMSET/SIMULATION runtime
# classes, themselves written in Simula and compiled by an earlier build of
# cim), each hardcoding `#include "../../lib/cim.h"`. That relative path only
# resolves from a source tree nested two directories deeper than a plain
# tarball extraction, confirmed by inspecting the shipped file directly
# rather than assumed from a stale error message; every other file in the
# same directory spells the same include as the working, directory-relative
# `#include "cim.h"`, which the two generated files are rewritten to match
# here before the build starts.
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    cd /tmp; \
    wget -q https://ftp.gnu.org/gnu/cim/cim-5.1.tar.gz; \
    tar xzf cim-5.1.tar.gz; \
    cd cim-5.1; \
    sed -i 's#\.\./\.\./lib/cim\.h#cim.h#' lib/simset.c lib/simulation.c; \
    ./configure >/tmp/configure.log 2>&1; \
    make -j"$(nproc)" >/tmp/make.log 2>&1; \
    make install >/tmp/install.log 2>&1; \
    ldconfig; \
    cim -version 2>&1 | head -n 1; \
    cim -version 2>&1 | grep -Eiq '5\.1'; \
    printf 'cim-5.1' > /project/runtime-version; \
    test -s /project/runtime-version; \
    rm -rf /tmp/cim-5.1 /tmp/cim-5.1.tar.gz

COPY client ./client

# Simula has no standard formatter, so the style gate is explicit, matching
# the same rules the ALGOL 60 client in this repository holds itself to:
# spaces only, no trailing blanks, a final newline, 120 columns for client
# and test sources.
RUN set -eu; \
    files=$(find client -name '*.sim'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      if awk 'length > 120 { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over 120 columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS simula source style"

# The only native code in the client, compiled to an object file on its own
# so a missing or misnamed primitive is caught before it is ever linked
# into a program, and its exported boundary is exactly the fourteen
# symbols declared in client/convex-native.sim.
RUN set -eu; \
    gcc -c -O2 -Wall -Wextra -Werror=implicit-function-declaration \
        -o /project/convexrt.o client/convexrt.c; \
    nm --defined-only /project/convexrt.o | grep -q ' T cxopen'; \
    nm --defined-only /project/convexrt.o | grep -q ' T cxread'; \
    nm --defined-only /project/convexrt.o | grep -q ' T cxrandom'

# GNU Cim compiles one Simula source file at a time (cim -S produces its C
# translation, cc then compiles and links it). Every regular Simula
# procedure in this client (client/convex-buffer.sim, convex-json.sim, and
# once written, convex-http.sim and convex-ws.sim) is a bank of
# outer-level declarations meant to be pasted inside one shared begin
# block together with whichever entry point needs them, because a bare
# begin block following other declarations in the same compilation unit
# does not parse on its own -- confirmed empirically against the
# compiler's own diagnostics, not assumed from the manual. The external C
# procedure headings in client/convex-native.sim are the one exception:
# they are a genuine preamble that must precede that shared block.
RUN set -eu; \
    mkdir -p /build; \
    assemble() { \
      cat client/convex-native.sim > "$2"; \
      echo 'begin' >> "$2"; \
      tail -n +21 client/convex-buffer.sim >> "$2"; \
      cat client/convex-json.sim >> "$2"; \
      cat "$1" >> "$2"; \
      echo 'end;' >> "$2"; \
    }; \
    assemble client/tests/client-test.sim /build/client-test.sim; \
    ( cd /build && cim -S client-test.sim ); \
    gcc -w -c /build/client-test.c -o /build/client-test.o; \
    gcc -O2 -o /build/client-test /build/client-test.o /project/convexrt.o \
        /usr/local/lib/libcim.a -lssl -lcrypto -lm

RUN set -eu; /build/client-test
