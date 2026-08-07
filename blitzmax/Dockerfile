# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BUILD_IMAGE=gcc:14.2.0-bookworm@sha256:82549aa8f90ada3236a8be70c74543132a76662ef33f0c3271ed802b81584a82
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
# One list, probed identically in two stages: the build stage asserts that the
# probe finds these commands where they genuinely exist, and the runtime stage
# asserts that it finds none. Without the negative control a probe that always
# passes reads exactly like a clean image.
ARG FORBIDDEN_COMMANDS="gcc cc clang make cmake ld as apt apt-get dpkg curl wget nc netcat node python python3 php ruby perl java go rustc cargo npm pip convex bmk bcc"

# BlitzMax NG ships as one prebuilt archive per platform. It is pinned by its
# immutable release URL and by content hash, so a rebuilt image compiles the
# same compiler, the same runtime modules, and the same statically linked
# mbed TLS and jansson as the image that produced the evidence.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG BLITZMAX_VERSION=0.165.3.61.202608020404
ARG BLITZMAX_SHA256=9f3817e162ed90068069f5a39e23d450fd122c95b57d402fbf05a40a8fcc63ee
ADD --checksum=sha256:${BLITZMAX_SHA256} \
    https://github.com/bmx-ng/bmx-ng/releases/download/v${BLITZMAX_VERSION}.linux.x64/BlitzMax_linux_x64_${BLITZMAX_VERSION}.tar.xz \
    /tmp/blitzmax.tar.xz
RUN mkdir -p /opt && tar -xJf /tmp/blitzmax.tar.xz -C /opt && rm /tmp/blitzmax.tar.xz && test -x /opt/BlitzMax/bin/bmk
ENV BMXPATH=/opt/BlitzMax \
    PATH=/opt/BlitzMax/bin:/usr/local/bin:/usr/bin:/bin

FROM toolchain AS test
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64

# BlitzMax has no standard formatter, so the checked-in style is asserted
# directly. These are the rules the README and the website depend on: the
# canonical example is displayed verbatim, so a stray tab-versus-space or a
# trailing carriage return would show up in the rendered code panel.
RUN <<'EOF' bash -euo pipefail
files="$(find client examples -type f -name '*.bmx' | sort)"
test -n "$files"
status=0
for file in $files; do
  if [ "$(head -n 1 "$file")" != "SuperStrict" ]; then
    echo "$file: every source file must begin with SuperStrict" >&2
    status=1
  fi
  if grep -qP '\r' "$file"; then
    echo "$file: uses CRLF line endings" >&2
    status=1
  fi
  if grep -nqP '[ \t]+$' "$file"; then
    echo "$file: has trailing whitespace" >&2
    status=1
  fi
  if grep -nqP '^\t* +\S' "$file"; then
    echo "$file: indents with spaces; BlitzMax sources here use tabs" >&2
    status=1
  fi
  if [ -n "$(tail -c 1 "$file")" ]; then
    echo "$file: does not end with a newline" >&2
    status=1
  fi
done
exit "$status"
EOF

RUN mkdir -p /out

# Language-local gates. Each executable is compiled and then run, because
# compiling a BlitzMax program proves nothing about what it does at runtime.
RUN bmk makeapp -r -t console -o /out/convex-client-tests client/tests/client_tests.bmx \
    && /out/convex-client-tests
RUN bmk makeapp -r -t console -o /out/convex-http-raw-peer-tests client/tests/http_raw_peer_tests.bmx \
    && /out/convex-http-raw-peer-tests
RUN bmk makeapp -r -t console -o /out/convex-live-raw-peer-tests client/tests/live_raw_peer_tests.bmx \
    && /out/convex-live-raw-peer-tests
RUN bmk makeapp -r -t console -o /out/convex-adapter-tests client/tests/conformance/adapter_tests.bmx \
    && /out/convex-adapter-tests

# The two binaries that reach the minimal runtime images.
RUN bmk makeapp -r -t console -o /out/convex-adapter client/tests/conformance/adapter_main.bmx
RUN bmk makeapp -r -t console -o /out/convex-example examples/basics/main.bmx

# Adapter smoke checks against the real executable, over both transports.
RUN printf '%s\n' \
    '{"protocolVersion":1,"id":"hello","op":"hello"}' \
    '{"id":"close","op":"close"}' | /out/convex-adapter > /tmp/events \
    && grep -Fq '"language":"blitzmax"' /tmp/events \
    && grep -Fq '"type":"closed"' /tmp/events
RUN <<'EOF' bash -euo pipefail
# A strict adapter answers each malformed command with an error, never a ready
# or an acknowledgement, and still serves the close that follows them.
invalid="$(printf '%s\n' \
  '{"protocolVersion":1,"id":"hello","op":"hello","unexpected":true}' \
  '{"id":"","op":"close"}' \
  '{"id":"missing-token","op":"setAuth"}' \
  '{"id":"missing-subscription","op":"unsubscribe"}' \
  '{"id":"final-close","op":"close"}' | /out/convex-adapter)"
echo "$invalid" | grep -Fq '"type":"error"'
! echo "$invalid" | grep -Fq '"type":"ready"'
! echo "$invalid" | grep -Fq '"id":"missing-token","type":"ack"'
! echo "$invalid" | grep -Fq '"id":"missing-subscription","type":"ack"'
echo "$invalid" | grep -Fq '"id":"final-close","type":"closed"'
EOF
RUN <<'EOF' bash -euo pipefail
# The shared controller drives the adapter over TCP, so that transport is
# exercised here with bash's own socket support rather than an extra package.
ADAPTER_LISTEN=127.0.0.1:18080 /out/convex-adapter >/tmp/tcp.out 2>/tmp/tcp.err &
adapter=$!
for _ in $(seq 1 50); do
  if exec 3<>/dev/tcp/127.0.0.1/18080 2>/dev/null; then break; fi
  sleep 0.1
done
printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' >&3
# read consumes exactly one line; head would buffer past the event and could
# swallow the close reply that has to be asserted next.
IFS= read -r ready <&3
printf '%s' "$ready" | grep -Fq '"language":"blitzmax"'
printf '%s\n' '{"id":"close","op":"close"}' >&3
IFS= read -r closed <&3
printf '%s' "$closed" | grep -Fq '"type":"closed"'
exec 3<&-
wait "$adapter"
EOF

# The runtime probe below must be able to fail. Prove it here, where the whole
# forbidden list genuinely exists, before trusting a clean result downstream.
ARG FORBIDDEN_COMMANDS
RUN <<'EOF' bash -euo pipefail
found=""
for command_name in ${FORBIDDEN_COMMANDS}; do
  if command -v "$command_name" >/dev/null 2>&1; then found="$found $command_name"; fi
done
for expected in gcc cc make apt apt-get dpkg perl bmk bcc; do
  case " $found " in
    *" $expected "*) ;;
    *) echo "negative control failed: probe missed $expected" >&2; exit 1;;
  esac
done
EOF

# `./run test blitzmax` runs this image, so rerunning the gates is the default.
RUN <<'EOF' bash -euo pipefail
cat > /usr/local/bin/blitzmax-tests <<'SCRIPT'
#!/bin/sh
set -eu
/out/convex-client-tests
/out/convex-http-raw-peer-tests
/out/convex-live-raw-peer-tests
/out/convex-adapter-tests
SCRIPT
chmod +x /usr/local/bin/blitzmax-tests
EOF
CMD ["/usr/local/bin/blitzmax-tests"]

FROM test AS rootfs
# The runtime closure is assembled explicitly rather than inherited. mbed TLS
# and jansson are compiled into the BlitzMax binaries, so what remains is the
# C runtime, the name-service modules glibc loads by hand for DNS, and the
# POSIX text tools the shared runtime policy still requires.
RUN <<'EOF' bash -euo pipefail
root=/rootfs
mkdir -p "$root"
programs="/lib64/ld-linux-x86-64.so.2 /bin/dash /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed /usr/bin/mawk /out/convex-adapter /out/convex-example"
# getaddrinfo dlopens these, so they never appear in any ELF dependency list.
for candidate in /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2 /usr/lib/x86_64-linux-gnu/libnss_dns.so.2 /usr/lib/x86_64-linux-gnu/libnss_files.so.2; do
  if [ -e "$candidate" ]; then programs="$programs $candidate"; fi
done
for program in $programs; do cp --parents "$program" "$root"; done
queue=/tmp/runtime-closure
: > "$queue"
for program in $programs; do echo "$program" >> "$queue"; done
while :; do
  cp "$queue" "$queue.before"
  while IFS= read -r object; do
    readelf -d "$object" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | while IFS= read -r soname; do
      resolved=
      for directory in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64 /usr/lib; do
        if [ -e "$directory/$soname" ]; then resolved="$directory/$soname"; break; fi
      done
      test -n "$resolved" || { echo "unresolved runtime dependency $soname from $object" >&2; exit 1; }
      grep -Fqx "$resolved" "$queue" || echo "$resolved" >> "$queue"
    done
  done < "$queue.before"
  cmp -s "$queue" "$queue.before" && break
done
while IFS= read -r library; do
  target="$(readlink -f "$library")"
  cp -P --parents "$library" "$root"
  test "$target" = "$library" || cp --parents "$target" "$root"
done < "$queue"
# Keep real copies in both loader search directories. The final base has a real
# /lib from its pruner, so a top-level merged-usr symlink cannot be copied over
# it; duplicating this small closure is deterministic.
if [ -d "$root/lib/x86_64-linux-gnu" ]; then
  mkdir -p "$root/usr/lib"
  cp -a "$root/lib/x86_64-linux-gnu" "$root/usr/lib/"
fi
test -e "$root/lib64/ld-linux-x86-64.so.2"
while IFS= read -r library; do
  target="$(readlink -f "$library")"
  test -e "$root$target" || { echo "missing final closure target $target" >&2; exit 1; }
done < "$queue"
mkdir -p "$root/usr/local/bin" "$root/bin" "$root/usr/bin" "$root/etc/ssl/certs" "$root/etc"
mv "$root/out/convex-adapter" "$root/usr/local/bin/convex-adapter"
mv "$root/out/convex-example" "$root/usr/local/bin/convex-example"
rmdir "$root/out"
ln -s dash "$root/bin/sh"
ln -s mawk "$root/usr/bin/awk"
cp /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"
cp /etc/nsswitch.conf "$root/etc/nsswitch.conf"
EOF

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
  mkdir("/bin",0755); mkdir("/etc",0755); mkdir("/lib",0755); mkdir("/lib64",0755);
  mkdir("/usr",0755); mkdir("/usr/bin",0755); mkdir("/usr/lib",0755);
  mkdir("/usr/local",0755); mkdir("/usr/local/bin",0755);
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
    test ! -e /etc/dpkg; test ! -e /usr/bin/apt; test ! -e /opt/BlitzMax; \
    test -x /usr/local/bin/convex-adapter; test -x /usr/local/bin/convex-example; \
    test -s /etc/ssl/certs/ca-certificates.crt; \
    found=""; \
    for command_name in ${FORBIDDEN_COMMANDS}; do \
      if command -v "$command_name" >/dev/null 2>&1; then found="$found $command_name"; fi; \
    done; \
    if test -n "$found"; then echo "forbidden commands present in the runtime image:$found" >&2; exit 1; fi
# Both entrypoints are executed from the final image here, so a missing library
# or certificate path is found now rather than during hosted verification.
RUN set -eu; \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
      | /usr/local/bin/convex-adapter | grep -Fq '"language":"blitzmax"'; \
    if /usr/local/bin/convex-example probe-room >/tmp/example.out 2>/tmp/example.err; then \
      echo "the example must fail without a deployment URL" >&2; exit 1; \
    fi; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err; \
    rm -f /tmp/example.out /tmp/example.err
ENV PATH=/usr/local/bin:/usr/bin:/bin
# The base image's CMD would otherwise be appended to the entrypoint, so running
# the example by hand would silently use "bash" as its room name.
CMD []
USER 65532:65532

FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
