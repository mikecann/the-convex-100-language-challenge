# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BUILD_IMAGE=gcc:14.2.0-bookworm@sha256:82549aa8f90ada3236a8be70c74543132a76662ef33f0c3271ed802b81584a82
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
RUN apt-get update && apt-get install -y --no-install-recommends \
    busybox=1:1.35.0-4+deb12u1+b1 \
    ca-certificates=20230311 \
    libgee-0.8-dev=0.20.6-1 \
    libjson-glib-dev=1.6.6-1 \
    libsoup-3.0-dev=3.2.3-0+deb12u2 \
    uncrustify=0.72.0+dfsg1-2 \
    valac=0.56.3-1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 && test "$(valac --version)" = "Vala 0.56.3"
RUN find client examples -type f -name '*.vala' -print0 | sort -z | xargs -0 uncrustify -l VALA -c client/uncrustify.cfg --check
RUN mkdir -p /out
RUN valac --pkg gee-0.8 --pkg gio-2.0 --pkg json-glib-1.0 --pkg libsoup-3.0 \
    --target-glib=2.74 \
    -o /out/convex-adapter client/convex.vala client/tests/conformance/adapter.vala
RUN valac --pkg gee-0.8 --pkg gio-2.0 --pkg json-glib-1.0 --pkg libsoup-3.0 \
    --target-glib=2.74 \
    -o /out/convex-example client/convex.vala examples/basics/main.vala
RUN valac --pkg gee-0.8 --pkg gio-2.0 --pkg json-glib-1.0 --pkg libsoup-3.0 \
    --target-glib=2.74 \
    -o /out/convex-client-tests client/convex.vala client/tests/client_tests.vala \
    && /out/convex-client-tests
RUN valac --pkg gee-0.8 --pkg gio-2.0 --pkg json-glib-1.0 --pkg libsoup-3.0 \
    --target-glib=2.74 \
    -o /out/convex-live-raw-peer-tests client/convex.vala client/tests/live_raw_peer_tests.vala \
    && /out/convex-live-raw-peer-tests
RUN valac -D ADAPTER_TEST --pkg gee-0.8 --pkg gio-2.0 --pkg json-glib-1.0 --pkg libsoup-3.0 \
    --target-glib=2.74 \
    -o /out/convex-adapter-live-raw-peer-tests client/convex.vala client/tests/conformance/adapter.vala \
    client/tests/live_raw_peer_tests.vala client/tests/conformance/adapter_live_raw_peer_tests.vala \
    && /out/convex-adapter-live-raw-peer-tests
RUN valac -D ADAPTER_STRESS_PEER --pkg gee-0.8 --pkg gio-2.0 --pkg json-glib-1.0 --pkg libsoup-3.0 \
    --target-glib=2.74 \
    -o /out/convex-adapter-stress-peer client/convex.vala client/tests/live_raw_peer_tests.vala
RUN printf '%s\n' \
    '{"protocolVersion":1,"id":"hello","op":"hello"}' \
    '{"id":"close","op":"close"}' | /out/convex-adapter > /tmp/events \
    && grep -Fq '"language":"vala"' /tmp/events && grep -Fq '"type":"closed"' /tmp/events
RUN invalid="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello","unexpected":true}' '{"id":"","op":"close"}' '{"id":"missing-token","op":"setAuth"}' '{"id":"missing-subscription","op":"unsubscribe"}' '{"id":"final-close","op":"close"}' | /out/convex-adapter)"; \
    echo "$invalid" | grep -Fq '"type":"error"'; \
    ! echo "$invalid" | grep -Fq '"type":"ready"'; \
    ! echo "$invalid" | grep -Fq '"id":"missing-token","type":"ack"'; \
    ! echo "$invalid" | grep -Fq '"id":"missing-subscription","type":"ack"'; \
    echo "$invalid" | grep -Fq '"id":"final-close","type":"closed"'
RUN ADAPTER_LISTEN=127.0.0.1:18080 /out/convex-adapter >/tmp/tcp.out 2>/tmp/tcp.err & \
    pid=$!; sleep 1; actual="$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | busybox nc 127.0.0.1 18080)"; \
    echo "$actual" | grep -Fq '"language":"vala"'; echo "$actual" | grep -Fq '"type":"closed"'; wait "$pid"

FROM test AS rootfs
RUN set -eu; root=/rootfs; mkdir -p "$root"; \
    for program in /lib64/ld-linux-x86-64.so.2 /bin/dash /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed /usr/bin/mawk /out/convex-adapter /out/convex-example /usr/lib/x86_64-linux-gnu/libgee-0.8.so.2 /usr/lib/x86_64-linux-gnu/gio/modules/libgiognutls.so; do cp --parents "$program" "$root"; done; \
    queue=/tmp/runtime-closure; : > "$queue"; \
    for program in /lib64/ld-linux-x86-64.so.2 /bin/dash /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed /usr/bin/mawk /out/convex-adapter /out/convex-example /usr/lib/x86_64-linux-gnu/gio/modules/libgiognutls.so; do echo "$program" >> "$queue"; done; \
    while :; do cp "$queue" "$queue.before"; while IFS= read -r object; do \
      readelf -d "$object" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | while IFS= read -r soname; do \
        resolved=; for directory in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64 /usr/lib; do if test -e "$directory/$soname"; then resolved="$directory/$soname"; break; fi; done; \
        test -n "$resolved" || { echo "unresolved runtime dependency $soname from $object" >&2; exit 1; }; \
        grep -Fqx "$resolved" "$queue" || echo "$resolved" >> "$queue"; \
      done; \
    done < "$queue.before"; cmp -s "$queue" "$queue.before" && break; done; \
    while IFS= read -r library; do target="$(readlink -f "$library")"; cp -P --parents "$library" "$root"; test "$target" = "$library" || cp --parents "$target" "$root"; done < "$queue"; \
    # Keep real copies in both loader search directories. The final base has
    # a real /lib from its pruner, so a top-level merged-usr symlink cannot be
    # copied over it; duplicating this small closure is deterministic.
    if test -d "$root/lib/x86_64-linux-gnu"; then mkdir -p "$root/usr/lib"; cp -a "$root/lib/x86_64-linux-gnu" "$root/usr/lib/"; fi; \
    test -e "$root/lib64/ld-linux-x86-64.so.2"; \
    while IFS= read -r library; do target="$(readlink -f "$library")"; test -e "$root$target" || { echo "missing final closure target $target" >&2; exit 1; }; done < "$queue"; \
    mkdir -p "$root/usr/local/bin" "$root/bin" "$root/usr/bin" "$root/etc/ssl/certs" "$root/etc" "$root/usr/share/glib-2.0/schemas"; \
    mv "$root/out/convex-adapter" "$root/usr/local/bin/convex-adapter"; mv "$root/out/convex-example" "$root/usr/local/bin/convex-example"; rmdir "$root/out"; \
    ln -s dash "$root/bin/sh"; ln -s mawk "$root/usr/bin/awk"; \
    cp /etc/ssl/certs/ca-certificates.crt "$root/etc/ssl/certs/ca-certificates.crt"; cp /etc/nsswitch.conf "$root/etc/nsswitch.conf"; \
    cp /usr/share/glib-2.0/schemas/gschemas.compiled "$root/usr/share/glib-2.0/schemas/gschemas.compiled"

# A static, single-purpose pruner lets the final image shed Debian's package
# surface before its runtime loader is replaced by the explicitly copied closure.
FROM test AS pruner
RUN <<'EOF' gcc -static -Os -s -x c - -o /pruner
#include <dirent.h>
#include <errno.h>
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
RUN test "$(id -u):$(id -g)" = 0:0 && \
    test ! -e /etc/dpkg && test ! -e /usr/bin/apt && test ! -e /usr/bin/valac && \
    for command in gcc cc clang make cmake apt apt-get dpkg curl wget nc netcat node python python3 php ruby perl java go rustc cargo npm pip convex; do ! command -v "$command" >/dev/null 2>&1; done
ENV GIO_EXTRA_MODULES=/usr/lib/x86_64-linux-gnu/gio/modules \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
