# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
#
# Seed7 (https://seed7.net) has no package manager and no prebuilt binaries
# worth trusting inside a hermetic build: the only reproducible route is
# compiling the interpreter (s7) and the Seed7-to-C compiler (s7c) from the
# project's own source tarball with the host's gcc, exactly the way upstream
# documents it. s7c then compiles this client's own Seed7 source into a
# genuine native ELF executable (it drives gcc itself, once, at image build
# time) with no residual dependency on the Seed7 toolchain at runtime.
FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS toolchain
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      gcc=4:12.2.0-3 \
      make=4.3-4.1 \
      libc6-dev=2.36-9+deb12u14 \
      libncurses-dev=6.4-4 \
      libx11-dev=2:1.8.4-2+deb12u2 \
      ca-certificates=20230311+deb12u1 \
      busybox-static=1:1.35.0-4+deb12u1+b1 \
      binutils=2.40-2 \
      file=1:5.44-3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# The only network fetch this build performs: one pinned upstream source
# tarball, verified by digest before it is ever unpacked. Nothing else is
# downloaded at build time and nothing is fetched at container start time.
ADD --checksum=sha256:531d1883e2dbccdda65735bf09731b451f5304fa837e9f8373fd08de21f8da56 \
    https://sourceforge.net/projects/seed7/files/seed7/seed7_05_20260711/seed7_05_20260711.tgz/download /src/seed7.tgz
RUN tar xzf seed7.tgz && rm seed7.tgz
WORKDIR /src/seed7/src
# Build the bytecode interpreter (s7), then the Seed7-to-C compiler (s7c).
# s7c is itself a Seed7 program: the freshly built s7 interpreter compiles
# it, which is why the interpreter has to exist first.
RUN cp mk_linux.mak makefile && make depend && make -j"$(nproc)" \
    && test "$(uname -m)" = x86_64 \
    && file ../bin/s7 | grep -Eq 'ELF 64-bit.*x86-64'
RUN make s7c \
    && file ../bin/s7c | grep -Eq 'ELF 64-bit.*x86-64'
ENV PATH="/src/seed7/bin:${PATH}"

FROM toolchain AS test
WORKDIR /project
COPY client ./client
COPY examples ./examples
# s7c's own formatting convention is enforced by hand (Seed7 has no
# standalone formatter binary): two-space indentation, and every checked-in
# .s7i/.sd7 file must compile without warnings under -O2. The compiler
# checks below double as that formatting/lint gate.
RUN mkdir -p /out \
    && s7c -w2 -O2 -l client -l /src/seed7/lib -b /src/seed7/bin client/tests/conformance/adapter.sd7 \
       2>&1 | tee /tmp/adapter.build.log \
    && ! grep -qi 'warning' /tmp/adapter.build.log \
    && cp client/tests/conformance/adapter /out/convex-adapter \
    && s7c -w2 -O2 -l client -l /src/seed7/lib -b /src/seed7/bin examples/basics/main.sd7 \
       2>&1 | tee /tmp/example.build.log \
    && ! grep -qi 'warning' /tmp/example.build.log \
    && cp examples/basics/main /out/convex-example \
    && s7c -w2 -O2 -l client -l /src/seed7/lib -b /src/seed7/bin client/tests/client_test.sd7 \
       2>&1 | tee /tmp/test.build.log \
    && ! grep -qi 'warning' /tmp/test.build.log \
    && cp client/tests/client_test /out/convex-client-test \
    && test "$(uname -m)" = x86_64 \
    && file /out/convex-adapter /out/convex-example /out/convex-client-test | grep -Eq 'ELF 64-bit.*x86-64'
RUN /out/convex-client-test
RUN <<'EOF'
set -eu
actual=$(/out/convex-adapter <<'COMMANDS'
{malformed
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"unknown","op":"notAnOperation"}
{"id":"close","op":"close"}
COMMANDS
)
printf '%s\n' "$actual" | grep -Fq '"error":{"name":"ProtocolError"'
printf '%s\n' "$actual" | grep -F '"id":"hello"' | grep -Fq '"type":"ready"'
printf '%s\n' "$actual" | grep -Fq '"id":"unknown"'
printf '%s\n' "$actual" | grep -Fqx '{"id":"close","type":"closed"}'
EOF
RUN <<'EOF'
set -eu
ADAPTER_LISTEN=127.0.0.1:18080 /out/convex-adapter &
adapter_pid=$!
waited=0
until grep -Fq ':46A0 ' /proc/net/tcp 2>/dev/null; do
  waited=$((waited + 1)); test "$waited" -lt 50; sleep 0.1
done
actual=$(printf '%s\n' \
  '{"id":"tcp-hello","protocolVersion":1,"op":"hello"}' \
  '{"id":"tcp-close","op":"close"}' \
  | timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080; cat >&3; cat <&3')
wait "$adapter_pid"
printf '%s\n' "$actual" | grep -Fq '"id":"tcp-hello"'
printf '%s\n' "$actual" | grep -Fqx '{"id":"tcp-close","type":"closed"}'
EOF
# Resolve the full shared-library closure here, inside the unpruned build
# environment, rather than in runtime-base after that image's own /bin/sh
# has already been swapped out: readelf, ldconfig and every tool this needs
# still have a working libc at this point, which is exactly what running
# this same resolution after the swap does not guarantee (this project's
# checklist calls that out by name -- a runtime image's own RUN step is not
# a safe place to bootstrap the runtime image).
RUN set -eu; \
    mkdir -p /out/lib; \
    resolved=/tmp/resolved-libs.txt; queue=/tmp/lib-queue.txt; \
    : > "$resolved"; : > "$queue"; \
    for elf in /out/convex-adapter /out/convex-example \
               /bin/dash /usr/bin/id /usr/bin/cat /usr/bin/cut /usr/bin/head \
               /usr/bin/tail /usr/bin/tr /usr/bin/sort /usr/bin/uniq \
               /usr/bin/wc /usr/bin/uname /usr/bin/grep /usr/bin/sed \
               /usr/bin/mawk; do \
      readelf -d "$elf" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' >> "$queue"; \
    done; \
    sort -u -o "$queue" "$queue"; \
    while [ -s "$queue" ]; do \
      soname="$(head -n 1 "$queue")"; sed -i '1d' "$queue"; \
      if grep -Fqx "$soname" "$resolved" 2>/dev/null; then continue; fi; \
      echo "$soname" >> "$resolved"; \
      libpath="$(ldconfig -p | awk -v s="$soname" '$1 == s { print $NF; exit }')"; \
      test -n "$libpath"; test -f "$libpath"; \
      cp -aL "$libpath" "/out/lib/$(basename "$libpath")"; \
      readelf -d "$libpath" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' >> "$queue"; \
      sort -u -o "$queue" "$queue"; \
    done; \
    cp -aL /lib64/ld-linux-x86-64.so.2 /out/ld-linux-x86-64.so.2; \
    find /out -xtype l -print -exec false {} +; \
    rm -f "$resolved" "$queue"
CMD ["/bin/sh", "-c", "true"]

# Reconstruct the runtime from a pruned copy of the exact same pinned base
# image used to build: only the compiled binaries, their real shared-library
# closure (no SONAME symlink is staged without its target, resolved above
# while the environment doing the resolving still had a working libc), the
# CA trust store the TLS code path loads, and enough POSIX text tooling to
# satisfy the shared example verifier (which still requires /bin/sh, not
# scratch). The pruner is a statically linked busybox bind-mounted in from
# the test stage: it depends on none of the paths it is about to delete,
# unlike the base image's own /rm and /mkdir, which live in /usr/bin
# alongside each other and would otherwise risk deleting a binary this same
# layer still needs to call.
FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in /etc/hosts|/etc/resolv.conf) ;; *) "$pruner" rm -rf "$path" ;; esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
COPY --from=test /out/convex-example /usr/local/bin/convex-example
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /out/lib/ /lib/x86_64-linux-gnu/
COPY --from=test /out/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
RUN chmod 0555 /usr/local/bin/convex-adapter /usr/local/bin/convex-example
ENV PATH=/usr/local/bin:/usr/bin:/bin
RUN test "$(printf 'ok\n' | cat)" = ok \
    && test "$(uname -m)" = x86_64 \
    && for command_name in gcc cc make s7 s7c apt apt-get dpkg busybox \
         wget curl nc netcat telnet; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
RUN test -x /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
RUN test -x /usr/local/bin/convex-adapter \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
       | grep -Fq '"id":"close"'
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
