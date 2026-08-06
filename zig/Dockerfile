# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS test-build
WORKDIR /project
RUN apk add --no-cache zig=0.14.1-r0 file=5.46-r2 binutils=2.44-r3 openssl=3.5.7-r0
# Keep the stopped-reader controller out of the expensive compile layers. It
# is copied into the dedicated probe stage below, so shell-only fixture repairs
# can be exercised against the exact same already-built adapter artifacts.
COPY client/convex.zig ./client/convex.zig
COPY client/tests/conformance/main.zig ./client/tests/conformance/main.zig
COPY client/tests/conformance/memory_fixture.zig ./client/tests/conformance/memory_fixture.zig
COPY client/tests/conformance/sync_readme_example.sh ./client/tests/conformance/sync_readme_example.sh
COPY client/tests/tls_fixture.sh ./client/tests/tls_fixture.sh
COPY examples ./examples
COPY README.md ./README.md
RUN zig version | grep -Fx '0.14.1'
RUN zig fmt --check client examples
RUN sh client/tests/conformance/sync_readme_example.sh --check
RUN zig test client/convex.zig
# Repeat only the real-TLS regression against a locally trusted certificate.
# It proves Zig's TLS-internal plaintext buffer participates in readiness, so
# coalesced frames do not stall waiting for a second raw-socket poll edge.
RUN sh client/tests/tls_fixture.sh zig test client/convex.zig --test-filter 'real TLS'
RUN zig test --dep convex -Mroot=examples/basics/main.zig -Mconvex=client/convex.zig
RUN zig test --dep convex -Mroot=client/tests/conformance/main.zig -Mconvex=client/convex.zig
RUN mkdir -p /out
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl --dep convex -Mroot=client/tests/conformance/main.zig -Mconvex=client/convex.zig -femit-bin=/out/convex-adapter
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl --dep convex -Mroot=examples/basics/main.zig -Mconvex=client/convex.zig -femit-bin=/out/convex-example
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl -Mroot=client/tests/conformance/memory_fixture.zig -femit-bin=/out/convex-memory-fixture

FROM test-build AS stopped-reader-test
COPY client/tests/conformance/stopped_reader_controller.sh ./client/tests/conformance/stopped_reader_controller.sh
# Exercise the checked-in stopped-reader fixture against the real adapter in
# the language-local test image. Root verification later repeats this with the
# adapter in its own 128 MiB cgroup; this gate ensures the fixture cannot drift
# into an unexecuted evidence prop between reviews.
RUN set -eu; \
    /out/convex-memory-fixture >/tmp/memory-fixture.log 2>&1 & fixture_pid=$!; \
    CONVEX_URL=http://127.0.0.1:32101 ADAPTER_LISTEN=127.0.0.1:32100 \
      /out/convex-adapter >/tmp/memory-adapter.log 2>&1 & adapter_pid=$!; \
    cleanup() { kill "$fixture_pid" "$adapter_pid" 2>/dev/null || true; }; \
    report() { \
      status=$?; \
      trap - EXIT INT TERM; \
      if [ "$status" -ne 0 ]; then \
        echo "stopped-reader fixture failed (status $status)" >&2; \
        cat /tmp/memory-fixture.log >&2 || true; \
        cat /tmp/memory-adapter.log >&2 || true; \
        wc -c /tmp/events >&2 || true; \
        tail -c 4096 /tmp/events >&2 || true; \
      fi; \
      cleanup; \
      exit "$status"; \
    }; \
    trap report EXIT INT TERM; \
    sleep 1; \
    ADAPTER_HOST=127.0.0.1 sh client/tests/conformance/stopped_reader_controller.sh; \
    wait "$adapter_pid"; \
    wait "$fixture_pid"; \
    trap - EXIT INT TERM; \
    cleanup

FROM stopped-reader-test AS test

# The minimal runtime images below keep Debian's pinned ancestry but delete the
# filesystem Debian ships, so the tool that performs the deletion must not
# depend on anything it deletes. Alpine's BusyBox cannot do this job: it is
# dynamically linked against musl and Debian has no musl loader, so it would
# fail to execute at all. This pruner is built by the same pinned Zig toolchain
# into a genuinely static binary, it is bind mounted for exactly one
# instruction, and it never becomes part of a layer.
COPY <<'ZIG' /build/prune_runtime.zig
const std = @import("std");

// Kept while pruning: the kernel filesystems, the /etc directory whose entries
// are pruned separately, and the pruner's own read-only bind mount.
const kept_root = [_][]const u8{ "dev", "proc", "sys", "etc", "convex-prune" };
// Docker bind mounts /etc/hosts and /etc/resolv.conf into the build container,
// so they cannot be unlinked, and the runtime needs both for DNS anyway.
const kept_etc = [_][]const u8{ "hosts", "resolv.conf" };
// Deleting /etc/hostname and /.dockerenv is preferred, but some daemons mount
// them. A mounted entry may survive; anything else surviving means the prune
// did not happen and the build must fail instead of shipping Debian's tools.
const tolerated_root = [_][]const u8{ "dev", "proc", "sys", "etc", "convex-prune", ".dockerenv" };
const tolerated_etc = [_][]const u8{ "hosts", "resolv.conf", "hostname" };

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn pruneDirectory(absolute_path: []const u8, kept: []const []const u8) !void {
    var dir = try std.fs.openDirAbsolute(absolute_path, .{ .iterate = true });
    defer dir.close();

    // Collect first. Deleting entries while the directory cursor is still open
    // can skip siblings, which would silently leave Debian metadata behind.
    var names = std.ArrayList([]u8).init(std.heap.page_allocator);
    defer {
        for (names.items) |name| std.heap.page_allocator.free(name);
        names.deinit();
    }
    var listing = dir.iterate();
    while (try listing.next()) |entry| {
        if (contains(kept, entry.name)) continue;
        try names.append(try std.heap.page_allocator.dupe(u8, entry.name));
    }
    // A bind mount reports a busy error rather than unlinking. Individual
    // failures are tolerated here and judged by the verification pass, so the
    // pruner never has to guess which paths the daemon mounted.
    for (names.items) |name| dir.deleteTree(name) catch {};
}

fn verifyDirectory(absolute_path: []const u8, tolerated: []const []const u8) !void {
    // Reopen: a directory handle cannot be iterated twice from the start.
    var dir = try std.fs.openDirAbsolute(absolute_path, .{ .iterate = true });
    defer dir.close();
    var listing = dir.iterate();
    while (try listing.next()) |entry| {
        if (!contains(tolerated, entry.name)) return error.RuntimePruneIncomplete;
    }
}

pub fn main() !void {
    try pruneDirectory("/", &kept_root);
    try pruneDirectory("/etc", &kept_etc);
    try verifyDirectory("/", &tolerated_root);
    try verifyDirectory("/etc", &tolerated_etc);
}
ZIG
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl -Mroot=/build/prune_runtime.zig -femit-bin=/out/convex-prune
RUN test "$(uname -m)" = x86_64 \
    && file /out/convex-adapter | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && file /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && file /out/convex-memory-fixture | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && file /out/convex-prune | grep -Eq 'ELF 64-bit.*x86-64.*(statically linked|static-pie linked)' \
    && ! readelf -l /out/convex-prune | grep -Fq 'INTERP' \
    && readelf -h /out/convex-adapter | grep -Eq 'Machine:.*Advanced Micro Devices X86-64'
ENV CONVEX_URL=http://127.0.0.1:9
CMD ["/bin/sh", "-ec", "/out/convex-adapter <<'EOF'\n{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\nEOF"]

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS certificates
RUN apk add --no-cache ca-certificates=20260611-r0

# Preserve the pinned non-scratch Debian ancestry, but remove the entire broad
# filesystem it ships. `runtime-tools` keeps an unpruned copy of the same
# pinned image so the CA bundle, dash, and the separate POSIX verifier tools
# can be copied back into the pruned root below.
FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-tools

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS runtime-base
# The pruner is statically linked, so it keeps running after it has unlinked
# the dynamic loader, libc, and every command Debian shipped. It is bind
# mounted read-only for this one instruction, so it never enters a layer, and
# it verifies its own result: if anything other than a daemon bind mount
# survives, it exits non-zero and the build stops here. The COPY instructions
# below recreate the directories they need, so the pruner never has to.
RUN --mount=type=bind,from=test,source=/out/convex-prune,target=/convex-prune,readonly \
    /convex-prune
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=runtime-tools /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=runtime-tools /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
COPY --from=runtime-tools /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=runtime-tools /bin/dash /bin/sh
COPY --from=runtime-tools /usr/bin/id /usr/bin/id
COPY --from=runtime-tools /usr/bin/cat /usr/bin/cat
COPY --from=runtime-tools /usr/bin/cut /usr/bin/cut
COPY --from=runtime-tools /usr/bin/head /usr/bin/head
COPY --from=runtime-tools /usr/bin/tail /usr/bin/tail
COPY --from=runtime-tools /usr/bin/tr /usr/bin/tr
COPY --from=runtime-tools /usr/bin/sort /usr/bin/sort
COPY --from=runtime-tools /usr/bin/uniq /usr/bin/uniq
COPY --from=runtime-tools /usr/bin/wc /usr/bin/wc
COPY --from=runtime-tools /usr/bin/uname /usr/bin/uname
COPY --from=runtime-tools /usr/bin/grep /usr/bin/grep
COPY --from=runtime-tools /usr/bin/sed /usr/bin/sed
COPY --from=runtime-tools /usr/bin/mawk /usr/bin/awk
ENV PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /convex-prune \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /etc/dpkg \
    && test ! -e /bin/bash \
    && test ! -e /usr/bin/bash \
    && test ! -e /usr/bin/perl \
    && test ! -e /usr/bin/perl5.36.0 \
    && test ! -e /usr/bin/debconf \
    && test ! -e /usr/bin/ldd \
    && test ! -e /usr/sbin/chroot \
    && test ! -e /usr/sbin/debugfs \
    && test ! -e /usr/sbin/mke2fs \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && for command in bash busybox perl perl5.36.0 debconf debconf-apt-progress \
         ldd chroot debugfs mke2fs mkfs fdisk mount umount su passwd groupadd \
         useradd apk apt apt-get dpkg dpkg-query wget nc telnet openssl zig \
         zigfmt gcc cc make cmake node python python3 npm pip curl convex; do \
         ! command -v "$command" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter runtime last because the root build command selects the
# default Docker target when it builds a language.
FROM runtime-base AS runtime
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
