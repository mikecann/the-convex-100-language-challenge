# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BUILD_IMAGE=gcc:14.2.0-bookworm@sha256:82549aa8f90ada3236a8be70c74543132a76662ef33f0c3271ed802b81584a82
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
# The MoonBit toolchain is pinned to one published build. `moon version --all`
# is asserted against this value below, so a moved upstream tag fails the build
# instead of silently changing what the evidence describes.
ARG MOONBIT_VERSION=0.10.6+80dc50f24
ARG ASYNC_VERSION=0.20.3
# One list, probed identically in two stages: the build stage asserts that the
# probe finds these commands where they genuinely exist, and the runtime stage
# asserts that it finds none. Without the negative control a probe that always
# passes reads exactly like a clean image.
ARG FORBIDDEN_COMMANDS="gcc cc clang make cmake apt apt-get dpkg curl wget nc netcat node python python3 php ruby perl java go rustc cargo npm pip convex moon moonc moonrun tcc"

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG MOONBIT_VERSION
ARG ASYNC_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
    busybox=1:1.35.0-4+deb12u1+b1 \
    ca-certificates=20230311 \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# MoonBit's native backend compiles to C and links with the system compiler, so
# the toolchain lives in the build stage only and never reaches a runtime image.
ENV MOON_HOME=/opt/moon
ENV PATH=/opt/moon/bin:${PATH}
RUN MOONBIT_INSTALL_VERSION="${MOONBIT_VERSION}" MOON_HOME=/opt/moon \
    curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
RUN test "$(uname -m)" = x86_64 \
    && moon version --all > /tmp/toolchain.txt \
    && cat /tmp/toolchain.txt \
    && grep -Fq "${MOONBIT_VERSION}" /tmp/toolchain.txt

# The native backend's thread pool (in moonbitlang/async, a pinned dependency,
# not this client's own code) calls the glibc extension
# `posix_spawn_file_actions_addchdir_np`. glibc only declares that symbol when
# `_GNU_SOURCE` is defined before `<spawn.h>` is included, which the vendored
# C stub does not do, so a stock `cc` invocation fails with an implicit
# function declaration error. `moon` always drives the C compiler through
# `MOON_CC` (falling back to a bare `cc`/`clang` lookup only when it is unset),
# so pointing it at a thin wrapper that adds the define is the correct place
# to fix this: it changes nothing about the vendored dependency and applies
# uniformly to every native compile this build performs. `ar` has to sit next
# to the wrapper because `moon` derives the archiver path from the compiler's
# directory.
RUN mkdir -p /opt/moon-cc && \
    printf '%s\n' '#!/bin/sh' 'exec cc -D_GNU_SOURCE "$@"' \
      > /opt/moon-cc/cc && \
    chmod 755 /opt/moon-cc/cc && \
    ln -s "$(command -v ar)" /opt/moon-cc/ar
ENV MOON_CC=/opt/moon-cc/cc

WORKDIR /src
COPY client ./client
COPY examples ./examples

# The adapter reports its runtime and provenance in the `hello` response. Assert
# here that both match what this build actually used, so the conformance
# evidence cannot describe a toolchain that never ran.
RUN grep -Fq "${MOONBIT_VERSION}" client/tests/conformance/main.mbt \
    && grep -Fq "moonbitlang/async ${ASYNC_VERSION}" client/tests/conformance/main.mbt \
    && grep -Fq "moonbitlang/async@${ASYNC_VERSION}" client/moon.mod

# MoonBit expects a module root with one directory per package. The educational
# repository keeps client, example, and conformance sources where a reader
# expects them, so the toolchain layout is assembled here instead of leaking
# into the checked-in tree.
#
# Two trees are assembled from the same sources:
#
#   /build   library + conformance adapter + example + stress peer, debug
#            profile, which is where the adapter-only reconnect hook exists.
#   /release library + example only, release profile, which is a build the hook
#            genuinely cannot be part of.
RUN set -eu; \
    mkdir -p /build/convex /build/adapter /build/stress /build/example; \
    cp client/moon.mod /build/moon.mod; \
    cp client/*.mbt client/moon.pkg /build/convex/; \
    cp client/tests/conformance/*.mbt client/tests/conformance/moon.pkg /build/adapter/; \
    cp client/tests/conformance/stress/*.mbt client/tests/conformance/stress/moon.pkg /build/stress/; \
    cp examples/basics/*.mbt examples/basics/moon.pkg /build/example/; \
    mkdir -p /release/convex /release/example; \
    cp client/moon.mod /release/moon.mod; \
    cp client/*.mbt client/moon.pkg /release/convex/; \
    cp examples/basics/*.mbt examples/basics/moon.pkg /release/example/

WORKDIR /build
RUN moon update && moon install
# Formatting, type checking, and the language-local test suite all run before
# anything is built for shipping.
RUN moon fmt --check
RUN moon check --target native
RUN moon test --target native

RUN moon build --target native
RUN set -eu; mkdir -p /out; \
    for package in adapter stress; do \
      found="$(find _build/native/debug/build -type f -perm -u+x -name "${package}*" ! -name '*.c' ! -name '*.o' ! -name '*.h' | sort)"; \
      test "$(printf '%s\n' "$found" | grep -c .)" -eq 1 || { echo "expected exactly one ${package} binary, found: ${found}" >&2; exit 1; }; \
      cp "$found" "/out/${package}.bin"; \
    done; \
    mv /out/adapter.bin /out/convex-adapter; \
    mv /out/stress.bin /out/convex-stress-peer

# The canonical example ships from the release tree, which has no adapter and
# therefore no reason to contain the reconnect hook.
WORKDIR /release
RUN moon install && moon build --release --target native
RUN set -eu; \
    found="$(find _build/native/release/build -type f -perm -u+x -name 'example*' ! -name '*.c' ! -name '*.o' ! -name '*.h' | sort)"; \
    test "$(printf '%s\n' "$found" | grep -c .)" -eq 1 || { echo "expected exactly one example binary, found: ${found}" >&2; exit 1; }; \
    cp "$found" /out/convex-example

# Negative control for the conditional compilation: a release build of the
# adapter must fail, because `debug_hook.mbt` is compiled in debug builds only.
# Without this the "test-only" claim would rest on a comment.
RUN set -eu; \
    if moon -C /build check --release --target native >/tmp/release-check.log 2>&1; then \
      echo "the adapter compiled in release mode, so the debug-only hook is not debug-only" >&2; \
      exit 1; \
    fi; \
    grep -Fq "debug_disconnect" /tmp/release-check.log \
      || { echo "release build failed for an unrelated reason:" >&2; cat /tmp/release-check.log >&2; exit 1; }

WORKDIR /build
# The adapter answers on stdin and exits cleanly. `CONVEX_URL` points at a port
# nothing listens on: `hello` and `close` must not touch the network.
RUN set -eu; \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 /out/convex-adapter > /tmp/hello.out; \
    grep -Fq '"language":"moonbit"' /tmp/hello.out; \
    grep -Fq '"type":"ready"' /tmp/hello.out; \
    grep -F '"type":"closed"' /tmp/hello.out | grep -Fq '"id":"close"'

# Malformed input must produce structured errors, must never produce a `ready`,
# and must not stop the adapter from serving later commands.
RUN set -eu; \
    printf '%s\n' \
      '' \
      '   ' \
      'not json at all' \
      '{"id":"no-op"}' \
      '{"id":"","op":"close"}' \
      '{"id":"bad-op","op":"teleport"}' \
      '{"protocolVersion":2,"id":"old","op":"hello"}' \
      '{"id":"final","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 /out/convex-adapter > /tmp/invalid.out; \
    grep -Fq '"type":"error"' /tmp/invalid.out; \
    ! grep -Fq '"type":"ready"' /tmp/invalid.out; \
    ! grep -Fq '"id":"bad-op","type":"ack"' /tmp/invalid.out; \
    grep -F '"type":"closed"' /tmp/invalid.out | grep -Fq '"id":"final"'

# The same NDJSON stream must work over the TCP transport the shared controller
# uses. BusyBox `nc` stands in for the controller.
RUN set -eu; \
    CONVEX_URL=http://127.0.0.1:1 ADAPTER_LISTEN=127.0.0.1:18080 /out/convex-adapter >/tmp/tcp.out 2>/tmp/tcp.err & \
    pid=$!; \
    sleep 1; \
    actual="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
      | busybox nc 127.0.0.1 18080)"; \
    printf '%s\n' "$actual" | grep -Fq '"language":"moonbit"'; \
    printf '%s\n' "$actual" | grep -Fq '"type":"closed"'; \
    wait "$pid"

# Stopped-reader memory proof against the real adapter binary.
#
# The peer serves a fake deployment whose every reply is just under the client's
# two megabyte HTTP response limit, issues a burst of calls, and then stops
# reading. Resident set is sampled from outside the process being measured. The
# ceiling is a small fraction of the shared 128 MiB container limit, so passing
# it means "comfortably below", not "just inside".
RUN set -eu; \
    CONVEX_URL=http://127.0.0.1:19091 ADAPTER_LISTEN=127.0.0.1:19092 \
      /out/convex-adapter >/tmp/stress.out 2>/tmp/stress.err & \
    adapter=$!; \
    sleep 1; \
    /out/convex-stress-peer 19091 127.0.0.1:19092 12000 >/tmp/peer.out 2>/tmp/peer.err & \
    peer=$!; \
    peak=0; \
    samples=0; \
    while [ "$samples" -lt 90 ]; do \
      test -d "/proc/$adapter" || break; \
      rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$adapter/status" 2>/dev/null || true)"; \
      if [ -n "$rss" ] && [ "$rss" -gt "$peak" ]; then peak="$rss"; fi; \
      samples=$((samples + 1)); \
      sleep 0.2; \
    done; \
    wait "$peer"; \
    wait "$adapter"; \
    echo "adapter peak resident set: ${peak} kB"; \
    test "$peak" -gt 0; \
    test "$peak" -lt 65536

# The runtime probe below must be able to fail. Prove it here, where the whole
# forbidden list genuinely exists, before trusting a clean result downstream.
ARG FORBIDDEN_COMMANDS
RUN set -eu; \
    found=""; \
    for command in ${FORBIDDEN_COMMANDS}; do \
      if command -v "$command" >/dev/null 2>&1; then found="$found $command"; fi; \
    done; \
    for expected in gcc cc make apt apt-get dpkg perl moon moonc; do \
      case " $found " in *" $expected "*) ;; *) echo "negative control failed: probe missed $expected" >&2; exit 1;; esac; \
    done

FROM test AS rootfs
# OpenSSL is loaded with `dlopen` by the TLS transport, so `readelf` cannot see
# it. It and the NSS resolver modules are named explicitly; everything else is
# discovered from the ELF closure below.
RUN set -eu; root=/rootfs; mkdir -p "$root"; \
    explicit="/lib64/ld-linux-x86-64.so.2 /bin/dash /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed /usr/bin/mawk /out/convex-adapter /out/convex-example"; \
    for library in /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libresolv.so.2; do \
      test -e "$library" || { echo "missing required runtime library $library" >&2; exit 1; }; \
      explicit="$explicit $library"; \
    done; \
    for program in $explicit; do cp --parents "$program" "$root"; done; \
    queue=/tmp/runtime-closure; : > "$queue"; \
    for program in $explicit; do echo "$program" >> "$queue"; done; \
    while :; do cp "$queue" "$queue.before"; while IFS= read -r object; do \
      readelf -d "$object" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | while IFS= read -r soname; do \
        resolved=; for directory in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64 /usr/lib; do if test -e "$directory/$soname"; then resolved="$directory/$soname"; break; fi; done; \
        test -n "$resolved" || { echo "unresolved runtime dependency $soname from $object" >&2; exit 1; }; \
        grep -Fqx "$resolved" "$queue" || echo "$resolved" >> "$queue"; \
      done; \
    done < "$queue.before"; cmp -s "$queue" "$queue.before" && break; done; \
    while IFS= read -r library; do target="$(readlink -f "$library")"; cp -P --parents "$library" "$root"; test "$target" = "$library" || cp --parents "$target" "$root"; done < "$queue"; \
    # Keep real copies in both loader search directories. The final base has a
    # real /lib from its pruner, so a top-level merged-usr symlink cannot be
    # copied over it; duplicating this small closure is deterministic.
    if test -d "$root/lib/x86_64-linux-gnu"; then mkdir -p "$root/usr/lib"; cp -a "$root/lib/x86_64-linux-gnu" "$root/usr/lib/"; fi; \
    test -e "$root/lib64/ld-linux-x86-64.so.2"; \
    while IFS= read -r library; do target="$(readlink -f "$library")"; test -e "$root$target" || { echo "missing final closure target $target" >&2; exit 1; }; done < "$queue"; \
    mkdir -p "$root/usr/local/bin" "$root/bin" "$root/usr/bin" "$root/etc/ssl/certs" "$root/etc"; \
    mv "$root/out/convex-adapter" "$root/usr/local/bin/convex-adapter"; \
    mv "$root/out/convex-example" "$root/usr/local/bin/convex-example"; rmdir "$root/out"; \
    ln -s dash "$root/bin/sh"; ln -s mawk "$root/usr/bin/awk"; \
    cp -a /etc/ssl/certs/. "$root/etc/ssl/certs/"; \
    # Debian's OpenSSL reaches its configuration through /usr/lib/ssl, which the
    # pruner removes along with the rest of /usr/lib. Carry the real file and
    # point OPENSSL_CONF at it below rather than letting the runtime discover a
    # missing config only when it first tries to negotiate TLS.
    test -e /etc/ssl/openssl.cnf || { echo "missing /etc/ssl/openssl.cnf" >&2; exit 1; }; \
    cp /etc/ssl/openssl.cnf "$root/etc/ssl/openssl.cnf"; \
    # OpenSSL 3 loads providers as separate modules. The default provider is
    # built into libcrypto, but copying the shipped module directory means a
    # configuration that asks for another one finds it instead of failing the
    # handshake.
    if test -d /usr/lib/x86_64-linux-gnu/ossl-modules; then \
      mkdir -p "$root/usr/lib/x86_64-linux-gnu"; \
      cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$root/usr/lib/x86_64-linux-gnu/"; \
    fi; \
    cp /etc/nsswitch.conf "$root/etc/nsswitch.conf"

# A static, single-purpose pruner lets the final image shed Debian's package
# surface before its runtime loader is replaced by the explicitly copied closure.
FROM test AS pruner
RUN <<'EOF' gcc -static -Os -s -x c - -o /pruner
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static void erase(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) return;
  if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) { unlink(path); return; }
  DIR *dir = opendir(path); if (!dir) return;
  struct dirent *entry;
  char child[4096];
  while ((entry = readdir(dir)) != NULL) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    snprintf(child, sizeof child, "%s/%s", path, entry->d_name); erase(child);
  }
  closedir(dir); rmdir(path);
}
int main(void) {
  const char *paths[] = {"/bin","/boot","/etc","/home","/lib","/lib64","/media","/mnt","/opt","/pruner","/root","/run","/sbin","/srv","/usr","/var",NULL};
  for (int i = 0; paths[i]; i++) erase(paths[i]);
  mkdir("/bin",0755); mkdir("/etc",0755); mkdir("/lib",0755); mkdir("/lib64",0755); mkdir("/usr",0755); mkdir("/usr/bin",0755); mkdir("/usr/lib",0755); mkdir("/usr/local",0755); mkdir("/usr/local/bin",0755);
  return 0;
}
EOF

FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-base
COPY --from=pruner /pruner /pruner
RUN /pruner
COPY --from=rootfs /rootfs /
ARG FORBIDDEN_COMMANDS
# A `for ... do ! command -v ...; done` loop reports only its last iteration, so
# it passes even where every tool is present. Accumulate instead, then assert
# once on the accumulated result.
RUN set -eu; \
    test "$(id -u):$(id -g)" = 0:0; \
    test ! -e /etc/dpkg; test ! -e /usr/bin/apt; test ! -e /opt/moon; \
    found=""; \
    for command in ${FORBIDDEN_COMMANDS}; do \
      if command -v "$command" >/dev/null 2>&1; then found="$found $command"; fi; \
    done; \
    if test -n "$found"; then echo "forbidden commands present in the runtime image:$found" >&2; exit 1; fi; \
    test -x /usr/local/bin/convex-adapter; \
    test -x /usr/local/bin/convex-example; \
    test -s /etc/ssl/certs/ca-certificates.crt; \
    test -s /etc/ssl/openssl.cnf
# OpenSSL is dlopened, and Debian's compiled-in defaults live under /usr/lib/ssl
# which the pruner removed. Name the bundle and the configuration explicitly
# rather than relying on a default path surviving the pruned filesystem.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
