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
COPY examples ./examples

# Simula has no standard formatter, so the style gate is explicit, matching
# the same rules the ALGOL 60 client in this repository holds itself to:
# spaces only, no trailing blanks, a final newline. The canonical example is
# held to 80 columns because it is rendered verbatim in the README and on
# the website; everything else is held to 120.
RUN set -eu; \
    files=$(find client examples -name '*.sim'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      case "$f" in examples/*) width=80 ;; *) width=120 ;; esac; \
      if awk -v width="$width" \
             'length > width { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over $width columns in $f" >&2; exit 1; \
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
# procedure or declaration in this client (client/convex-buffer.sim,
# convex-json.sim, convex-http.sim, convex-ws.sim, convex-live.sim) is a
# bank of outer-level declarations meant to be pasted inside one shared
# begin block together with whichever entry point needs them, because a
# bare begin block following other declarations in the same compilation
# unit does not parse on its own -- confirmed empirically against the
# compiler's own diagnostics, not assumed from the manual. The external C
# procedure headings in client/convex-native.sim are the one exception:
# they are a genuine preamble that must precede that shared block.
#
# The default GNU Cim runtime memory pool is far too small for this
# client's real buffer footprint (a few dozen fixed-size integer arrays,
# a little over a megabyte in total): a program built without a larger
# pool aborts with "Alloc: Virtual memory exhausted" while allocating its
# own top-level array declarations, before running any code, confirmed by
# the crash line pointing at a plain declaration rather than a loop.
# cim -m32 -M96 raises the initial pool to 32MB and its ceiling to 96MB,
# comfortably inside the shared 128MiB runtime-image limit once the rest
# of the process (glibc, OpenSSL, the stack) is accounted for.
RUN set -eu; \
    mkdir -p /build; \
    assemble_flat() { \
      cat client/convex-native.sim > "$2"; \
      echo 'begin' >> "$2"; \
      tail -n +21 client/convex-buffer.sim >> "$2"; \
      cat client/convex-json.sim client/convex-http.sim client/convex-ws.sim >> "$2"; \
      cat "$1" >> "$2"; \
      echo 'end;' >> "$2"; \
    }; \
    assemble_live() { \
      cat client/convex-native.sim > "$2"; \
      echo 'begin' >> "$2"; \
      tail -n +21 client/convex-buffer.sim >> "$2"; \
      cat client/convex-json.sim client/convex-http.sim client/convex-ws.sim \
          client/convex-live.sim >> "$2"; \
      cat "$1" >> "$2"; \
      echo 'end;' >> "$2"; \
    }; \
    assemble_live client/tests/client-test.sim /build/client-test.sim; \
    assemble_live examples/basics/main.sim /build/example.sim; \
    ( cd /build && cim -m32 -M96 -S client-test.sim ); \
    ( cd /build && cim -m32 -M96 -S example.sim ); \
    gcc -w -c /build/client-test.c -o /build/client-test.o; \
    gcc -O2 -o /build/client-test /build/client-test.o /project/convexrt.o \
        /usr/local/lib/libcim.a -lssl -lcrypto -lm; \
    gcc -w -c /build/example.c -o /build/example.o; \
    gcc -O2 -o /build/convex-example /build/example.o /project/convexrt.o \
        /usr/local/lib/libcim.a -lssl -lcrypto -lm

# The conformance adapter is assembled the same way as the example, but its
# entry point (a call to adaptermain) is appended after the Live layer
# rather than living inside the source file itself, because that file is
# also test infrastructure this Dockerfile alone drives, not public client
# code with its own canonical entry point.
RUN set -eu; \
    cat client/convex-native.sim > /build/adapter.sim; \
    echo 'begin' >> /build/adapter.sim; \
    tail -n +21 client/convex-buffer.sim >> /build/adapter.sim; \
    cat client/convex-json.sim client/convex-http.sim client/convex-ws.sim \
        client/convex-live.sim client/tests/conformance/adapter.sim >> /build/adapter.sim; \
    echo 'adaptermain;' >> /build/adapter.sim; \
    echo 'end;' >> /build/adapter.sim; \
    ( cd /build && cim -m32 -M96 -S adapter.sim ); \
    gcc -w -c /build/adapter.c -o /build/adapter.o; \
    gcc -O2 -o /build/convex-adapter /build/adapter.o /project/convexrt.o \
        /usr/local/lib/libcim.a -lssl -lcrypto -lm

RUN set -eu; /build/client-test

# The example must fail loudly without a deployment, and must print nothing
# on stdout when it does, because stdout is the shared happy-path transcript.
RUN set -eu; \
    code=0; \
    /build/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# The commands are written to a file first and read with < rather than
# piped directly, so the adapter's own poll-and-read loop never races a
# concurrently running producer process for its very first bytes.
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    code=0; \
    CONVEX_URL=http://127.0.0.1:1 /build/convex-adapter \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out 2>/tmp/adapter-probe.err \
      || code=$?; \
    echo "adapter exit code: $code"; \
    echo "--- stdout ---"; cat /tmp/adapter-probe.out; \
    echo "--- stderr ---"; cat /tmp/adapter-probe.err; \
    echo "--- end ---"; \
    test "$code" -eq 0; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"simula"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# Stage the shared part of the runtime closure - everything except the two
# program binaries themselves, which are copied separately into their own
# final stage below so that convex-example never ships beside
# convex-adapter or vice versa. Both are genuine native ELF binaries --
# libcim is linked statically, so no GNU Cim runtime, interpreter or libcc
# cache travels with them -- and ldd resolves the small set of shared
# libraries each one actually needs.
#
# The shared policy and example verifier currently require /bin/sh and
# basic POSIX text tools in every runtime image, so a small set of
# individual coreutils binaries (never a multicall BusyBox, whose applet
# table would reintroduce exactly the surface this image is trying to not
# have) is copied in even though neither convex-example nor convex-adapter
# themselves call out to a shell or a text tool.
RUN set -eu; \
    mkdir -p /closure/bin /closure/usr/bin /closure/usr/local/bin \
             /closure/etc/ssl/certs \
             /closure/usr/lib/x86_64-linux-gnu/ossl-modules \
             /closure/usr/lib/x86_64-linux-gnu \
             /closure/tmp; \
    chmod 1777 /closure/tmp; \
    for name in cat cut head tail tr sort uniq wc uname grep sed id; do \
      cp -aL "$(command -v "$name")" /closure/usr/bin/"$name"; \
    done; \
    cp -aL /usr/bin/mawk /closure/usr/bin/awk; \
    cp -aL /bin/dash /closure/bin/sh; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /closure/etc/ssl/certs/; \
    cp -aL /etc/ssl/openssl.cnf /closure/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /closure/etc/nsswitch.conf; \
    cp -aL /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so \
           /closure/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so; \
    for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL /lib/x86_64-linux-gnu/"$lib" \
             /closure/usr/lib/x86_64-linux-gnu/"$lib"; \
    done; \
    for round in 1 2 3; do \
      for elf in /build/convex-example \
                 /build/convex-adapter \
                 /closure/bin/sh \
                 /closure/usr/bin/*; do \
        ldd "$elf" 2>/dev/null \
          | awk '{ for (i = 1; i <= NF; i++) \
                     if (substr($i, 1, 1) == "/") print $i }'; \
      done \
        | sort -u \
        | while read -r lib; do \
            test -e "/closure$lib" || { \
              mkdir -p "/closure$(dirname "$lib")"; \
              cp -aL "$lib" "/closure$(dirname "$lib")/"; \
            }; \
          done; \
    done

# The two entrypoints are staged separately so each minimal image carries
# only its own program. The room argument reaches the example through
# EXAMPLE_ROOM, matching every other native client in this project.
RUN set -eu; \
    mkdir -p /entry; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# The verifier passes a unique room as the first argument.' \
      'if [ "$#" -gt 0 ]; then' \
      '  EXAMPLE_ROOM="$1"' \
      '  export EXAMPLE_ROOM' \
      'fi' \
      'exec /usr/local/bin/convex-example' \
      > /entry/convex-example; \
    chmod 755 /entry/convex-example

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its filesystem removed and only the
# declared closure copied back
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN set -eu; \
    set -- /bin /boot /home /lib /lib64 /media /mnt /opt /root \
           /run /sbin /srv /usr /var /etc/.pwd.lock; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) set -- "$@" "$path" ;; \
      esac; \
    done; \
    rm -rf "$@"
COPY --from=test /closure/ /
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532

# Prove the policy the shared verifier depends on from inside the final
# filesystem, not from the build stage that produced it.
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test -s "$SSL_CERT_FILE"; \
    test "$(uname -m)" = x86_64; \
    test "$(printf 'ok\n' | cat)" = ok; \
    test "$(printf 'a:b\n' | cut -d: -f2)" = b; \
    test "$(printf 'first\nsecond\n' | head -n 1)" = first; \
    test "$(printf 'first\nsecond\n' | tail -n 1)" = second; \
    test "$(printf 'a\n' | tr a A)" = A; \
    test "$(printf 'b\na\n' | sort | head -n 1)" = a; \
    test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1; \
    printf 'needle\n' | grep -Fqx needle; \
    test "$(printf 'before\n' | sed 's/before/after/')" = after; \
    test "$(printf 'value\n' | awk '{print $1}')" = value; \
    test ! -e /etc/dpkg; \
    test ! -e /var; \
    test ! -e /usr/share/doc; \
    test ! -e /usr/include; \
    test ! -e /usr/src; \
    set -- /bin/*; test "$#" -eq 1; test "$1" = /bin/sh; \
    for command_name in gcc cc clang ld make cmake libtool cim apt apt-get \
        dpkg curl wget nc netcat ssh openssl node python python3 ruby perl \
        java php go rustc cargo npm pip convex; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test --chmod=755 /build/convex-example /usr/local/bin/convex-example
COPY --from=test --chmod=755 /entry/convex-example /usr/local/bin/convex-example-entry
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example-entry; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example-entry"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build simula` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test --chmod=755 /build/convex-adapter /usr/local/bin/convex-adapter
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    > /tmp/adapter-probe.in; \
    CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
      < /tmp/adapter-probe.in > /tmp/adapter-probe.out; \
    cat /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
