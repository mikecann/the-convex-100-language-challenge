# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# BCPL has no package manager and no released toolchain image, so the Cintcode
# system is built from Martin Richards' distribution pinned to one commit of a
# mirror. A commit identifier is the content: the tree cannot change under the
# build the way an unversioned tarball URL can.
#
# This client targets the distribution's 64-bit Cintcode system (cintsys64,
# selected by -DforLinux64 -DforLinuxAMD64), not the 32-bit one. The 32-bit
# interpreter stores a raw C pointer -- such as the stdio FILE* a file
# primitive receives from fopen() -- directly inside a 32-bit BCPL word; on a
# 64-bit host a heap or mmap address routinely lands above 2**32, so the low
# 32 bits alone are not a valid pointer and dereferencing the reconstructed
# value corrupts memory. Confirmed directly on this host: `gdb --batch -ex run
# -ex bt` on the plain, unmodified 32-bit `bcpl` compiler compiling a
# five-line "hello world" program shows a SIGSEGV inside libc ftell(), called
# with a sign-extended garbage FILE*, deep inside the distribution's own
# cintsys.c dosys() -- before any client source is ever reached. It reproduces
# with no Convex extension linked in at all, so it is a property of the
# 32-bit interpreter on this architecture, not a defect in this client. The
# 64-bit interpreter's BCPLWORD is 64 bits, wide enough for a real pointer, so
# this class of corruption cannot occur.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG BCPL_COMMIT=bad6eec7682368ca7ded866005cc4a47e8a67569

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG BCPL_COMMIT
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gcc=4:12.2.0-3 \
       libc6-dev=2.36-9+deb12u14 \
       make=4.3-4.1 \
       libssl-dev=3.0.20-1~deb12u2 \
       ca-certificates=20230311+deb12u1 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
       git \
    && rm -rf /var/lib/apt/lists/*

# The whole toolchain, fetched by commit and verified by commit.
RUN test "$(uname -m)" = x86_64 \
    && git init --quiet /opt/bcpl-source \
    && git -C /opt/bcpl-source remote add origin https://github.com/8l/bcpl.git \
    && git -C /opt/bcpl-source fetch --quiet --depth 1 origin "${BCPL_COMMIT}" \
    && git -C /opt/bcpl-source checkout --quiet --detach FETCH_HEAD \
    && test "$(git -C /opt/bcpl-source rev-parse HEAD)" = "${BCPL_COMMIT}" \
    && rm -rf /opt/bcpl-source/.git

WORKDIR /opt/bcpl-source/cintcode

# The pinned commit's cintsys64.c dosys() switch never received the 2014
# addition of sys(Sys_ext, ...) that cintsys.c (the 32-bit interpreter) has --
# there is no `case 68` (Sys_ext's value, from g/libhdr.h) in it at all, so a
# BCPL program built for cintsys64 has no way to reach a user C extension. The
# 32-bit interpreter's own case is one line: `return extfn(&W[p+4], &W[g],
# W);`. This patch adds the identical case to cintsys64.c, anchored right
# after the neighbouring Sys_sdl case so a future upstream sync that already
# carries this fix fails the anchor check instead of silently duplicating it.
RUN set -eu; \
    anchor='    case Sys_sdl: /* res := sys(Sys_sdl, fno, a1, a2,...) */'; \
    body='      return sdlfn(&W[p+4], &W[g], W);'; \
    grep -Fq "$anchor" sysc/cintsys64.c; \
    grep -Fq "$body" sysc/cintsys64.c; \
    awk -v anchor="$anchor" -v body="$body" ' \
      { print } \
      $0 == body { \
        print ""; \
        print "    case 68: /* res := sys(Sys_ext, fno, a1, a2,...) -- see g/libhdr.h */"; \
        print "      return extfn(&W[p+4], &W[g], W);"; \
      }' sysc/cintsys64.c > sysc/cintsys64.c.patched; \
    mv sysc/cintsys64.c.patched sysc/cintsys64.c; \
    grep -Fq 'case 68: /* res := sys(Sys_ext' sysc/cintsys64.c

# The distribution ships prebuilt 64-bit Cintcode for both endiannesses;
# x86-64 is a little ender, so install that set exactly as the upstream
# Makefile's litender64 target does.
RUN set -eu; \
    for part in syslib boot blib dlib cli; do \
      cp "enderlit64/$part" cin64/syscin/"$part"; \
    done; \
    for part in bcpl c echo; do \
      cp "enderlit64/$part" cin64/"$part"; \
    done

COPY client/native/convexext.c sysc/convexext.c

# Build the 64-bit interpreter with the client's native transport boundary in
# place of the distribution's empty extfn.c stub. sdlfn.c and glfn are
# deliberately not compiled from the vendor tree: convexext.c supplies its own
# no-op sdlfn/glfn definitions (cintsys64.c's dosys() only ever calls sdlfn;
# it has no Sys_gl case at all), which keeps SDL and OpenGL out of the image
# entirely and avoids a duplicate-symbol link error against sdlfn.c.
RUN set -eu; \
    mkdir -p obj bin; \
    gcc -O2 -o /tmp/mkint-h sysc/mkint-h.c; \
    /tmp/mkint-h > sysc/INT.h; \
    rm -f /tmp/mkint-h; \
    cflags="-O2 -std=gnu99 -fcommon -w -DforLinux64 -DforLinuxAMD64 -DEXTavail -Isysc"; \
    gcc $cflags -c sysc/cintsys64.c -o obj/cintsys64.o; \
    gcc $cflags -c sysc/cinterp64.c -o obj/cinterp64.o; \
    gcc $cflags -DFASTyes -c sysc/cinterp64.c -o obj/fasterp64.o; \
    gcc $cflags -c sysc/kblib64.c -o obj/kblib64.o; \
    gcc $cflags -c sysc/nrastlib64.c -o obj/nrastlib64.o; \
    gcc $cflags -c sysc/convexext.c -o obj/extfn64.o; \
    gcc -o bin/cintsys64 \
        obj/cintsys64.o obj/cinterp64.o obj/fasterp64.o obj/kblib64.o \
        obj/nrastlib64.o obj/extfn64.o \
        -lm -lssl -lcrypto; \
    file bin/cintsys64 | grep -Eq 'ELF 64-bit.*x86-64'

ENV BCPL64ROOT=/opt/bcpl-source/cintcode \
    BCPL64PATH=/opt/bcpl-source/cintcode/cin64 \
    BCPL64HDRS=/opt/bcpl-source/cintcode/g \
    PATH=/opt/bcpl-source/cintcode/bin:/usr/local/bin:/usr/bin:/bin

RUN cintsys64 -c echo bcpl-cintcode-ready 2>&1 | grep -Fq bcpl-cintcode-ready

WORKDIR /project
COPY client ./client
COPY examples ./examples

# BCPL predates the idea of a code formatter and no BCPL implementation ships
# one, so the checked-in sources are held to an explicit hygiene contract
# instead of being reformatted by a tool that does not exist. The C boundary is
# additionally held to a warning-free build.
RUN set -eu; \
    tab=$(printf '\t'); \
    carriage=$(printf '\r'); \
    for file in client/convexhdr.h client/base.b client/digest.b client/json.b \
                client/http.b client/ws.b client/live.b client/convex.b \
                client/tests/clienttests.b client/tests/livetests.b \
                client/tests/conformance/adapter.b \
                client/tests/conformance/events.b \
                client/tests/conformance/eventshdr.h examples/basics/main.b \
                client/native/convexext.c client/native/convexlaunch.c; do \
      test -f "$file"; \
      if grep -q "$tab" "$file"; then echo "$file: tab" >&2; exit 1; fi; \
      if grep -q "$carriage" "$file"; then echo "$file: CRLF" >&2; exit 1; fi; \
      if grep -qE ' +$' "$file"; then echo "$file: trailing space" >&2; exit 1; fi; \
      if awk 'length($0) > 100 { exit 1 }' "$file"; then :; else \
        echo "$file: line over 100 columns" >&2; exit 1; fi; \
      test "$(tail -c 1 "$file" | wc -l)" -eq 1; \
      if LC_ALL=C grep -q '[^ -~]' "$file"; then \
        echo "$file: byte outside printable ASCII" >&2; exit 1; fi; \
    done; \
    gcc -fsyntax-only -std=gnu11 -Wall -Wextra -Werror \
      client/native/convexlaunch.c

# Compile the client. Each program is one object holding two sections: the
# library, textually included through GET, and the program that uses it.
#
# convexhdr.h is installed alongside libhdr.h in the compiler's header
# directory as well as being left beside the sources, so `GET "convexhdr"`
# resolves exactly the way `GET "libhdr"` does whichever search the compiler
# performs first. The libhdr.h assertion fails the build loudly if the header
# directory is ever somewhere else.
RUN set -eu; \
    mkdir -p /build/src /build/cin /out/bcpl/bin /out/bcpl/cin64/syscin; \
    test -f "$BCPL64HDRS/libhdr.h"; \
    cp client/convexhdr.h "$BCPL64HDRS/convexhdr.h"; \
    cp client/*.b client/*.h /build/src/; \
    cp client/tests/clienttests.b client/tests/livetests.b /build/src/; \
    cp client/tests/conformance/events.b client/tests/conformance/eventshdr.h \
       /build/src/; \
    cp client/tests/conformance/adapter.b /build/src/adapter.b; \
    cp examples/basics/main.b /build/src/example.b; \
    cd /build/src; \
    for program in adapter:convexadapter example:convexexample \
                   clienttests:clienttests livetests:livetests; do \
      source=${program%%:*}.b; \
      object=/build/cin/${program##*:}; \
      name=${program##*:}; \
      status=0; \
      cintsys64 -m 8000000 -c bcpl64 "$source" to "$name" size 600000 \
        > "/tmp/$name.log" 2>&1 || status=$?; \
      cat "/tmp/$name.log"; \
      test "$status" -eq 0; \
      if grep -q 'Error near' "/tmp/$name.log"; then exit 1; fi; \
      test -s "$name"; \
      mv "$name" "$object"; \
    done

# Install the runtime tree. The BCPL compiler is deliberately not part of it:
# only the boot image, the standard library and this client's own objects.
RUN set -eu; \
    cp /opt/bcpl-source/cintcode/bin/cintsys64 /out/bcpl/bin/cintsys64; \
    for part in boot blib syslib dlib cli; do \
      cp "/opt/bcpl-source/cintcode/cin64/syscin/$part" /out/bcpl/cin64/syscin/"$part"; \
    done; \
    cp /build/cin/convexadapter /build/cin/convexexample /out/bcpl/cin64/; \
    test ! -e /out/bcpl/cin64/bcpl64; \
    test ! -e /out/bcpl/cin64/c; \
    mkdir -p /usr/local/lib; \
    cp -R /out/bcpl /usr/local/lib/bcpl

# The two entrypoints. They differ only in which Cintcode object they run.
RUN set -eu; \
    gcc -O2 -std=gnu11 -Wall -Wextra -Werror \
        -DCONVEX_PROGRAM='"convexadapter"' \
        client/native/convexlaunch.c -o /out/convex-adapter; \
    gcc -O2 -std=gnu11 -Wall -Wextra -Werror \
        -DCONVEX_PROGRAM='"convexexample"' \
        client/native/convexlaunch.c -o /out/convex-example; \
    file /out/convex-adapter /out/convex-example | grep -Eq 'ELF 64-bit.*x86-64'

# Language-local unit tests: JSON, digests, bounds, adapter event bytes.
RUN set -eu; \
    cp /build/cin/clienttests /build/cin/livetests /opt/bcpl-source/cintcode/cin64/; \
    status=0; \
    cintsys64 -m 3000000 -c clienttests > /tmp/clienttests.out 2>&1 || status=$?; \
    cat /tmp/clienttests.out; \
    test "$status" -eq 0; \
    ! grep -q FAIL /tmp/clienttests.out; \
    grep -q '^1\.\.' /tmp/clienttests.out

# Loopback WebSocket and Live tests, including the hostile-peer matrix and the
# bounded-close deadlines.
RUN set -eu; \
    status=0; \
    cintsys64 -m 3000000 -c livetests > /tmp/livetests.out 2>&1 || status=$?; \
    cat /tmp/livetests.out; \
    test "$status" -eq 0; \
    ! grep -q FAIL /tmp/livetests.out; \
    grep -q '^1\.\.' /tmp/livetests.out

# The adapter over stdin and stdout. This also proves the launcher's stream
# split: the Cintcode banner and prompt must not appear on the protocol stream.
RUN set -eu; \
    actual=$(printf '%s\n' \
      '{malformed' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"unknown","op":"notAnOperation"}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 /out/convex-adapter 2>/tmp/adapter.err); \
    printf '%s\n' "$actual"; \
    printf '%s\n' "$actual" \
      | grep -Fqx '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'; \
    printf '%s\n' "$actual" | grep -Fq '"id":"hello","type":"ready","language":"bcpl"'; \
    printf '%s\n' "$actual" \
      | grep -Fqx '{"id":"unknown","type":"error","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'; \
    printf '%s\n' "$actual" | grep -Fqx '{"id":"close","type":"closed"}'; \
    ! printf '%s\n' "$actual" | grep -Fq 'Cintcode System'

# The TCP mode the shared controller uses.
RUN set -eu; \
    CONVEX_URL=http://127.0.0.1:1 ADAPTER_LISTEN=127.0.0.1:18080 \
      /out/convex-adapter 2>/tmp/adapter-tcp.err & \
    adapter=$!; \
    sleep 2; \
    actual=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"tcp-hello","op":"hello"}' \
      '{"id":"tcp-close","op":"close"}' \
      | busybox nc 127.0.0.1 18080); \
    wait "$adapter"; \
    printf '%s\n' "$actual"; \
    printf '%s\n' "$actual" | grep -Fq '"id":"tcp-hello","type":"ready"'; \
    printf '%s\n' "$actual" | grep -Fqx '{"id":"tcp-close","type":"closed"}'

# The canonical example refuses to run without a deployment, writes nothing to
# stdout when it fails, and says why on stderr. The exit status is asserted as
# non-zero rather than as a particular number: BCPL's stop() reaches the shell
# through the Cintcode system, which is free to map it, and the shared example
# verifier only distinguishes success from failure.
RUN set -eu; \
    code=0; \
    /out/convex-example > /tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -ne 0; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# Start from the pinned image, remove its broad filesystem with a temporary
# static helper, then copy back only the declared runtime closure.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /usr/lib/x86_64-linux-gnu/ossl-modules /usr/local/bin /usr/local/lib; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libz.so.1
COPY --from=test /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
COPY --from=test /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so /usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
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
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
# libacl's own dependency. Copying a library without its closure is the usual
# way a pruned image passes its build and then fails on first use.
COPY --from=test /lib/x86_64-linux-gnu/libattr.so.1 /lib/x86_64-linux-gnu/libattr.so.1
# The BCPL 64-bit Cintcode system: the interpreter, its boot image and its
# standard library. This is the language runtime, in the same sense a virtual
# machine is a language runtime; the BCPL compiler (bcpl64) is not here.
COPY --from=test /out/bcpl/bin/cintsys64 /usr/local/lib/bcpl/bin/cintsys64
COPY --from=test /out/bcpl/cin64/syscin /usr/local/lib/bcpl/cin64/syscin
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
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
    && test -x /usr/local/lib/bcpl/bin/cintsys64 \
    && test -s /usr/local/lib/bcpl/cin64/syscin/cli \
    && test ! -e /usr/local/lib/bcpl/cin64/bcpl64 \
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/include \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && set -- /lib64/* \
    && test "$#" -eq 1 \
    && set -- /usr/lib/x86_64-linux-gnu/ossl-modules/* \
    && test "$#" -eq 1 \
    && for command_name in bcpl bcpl64 cintsys cintsys64 gcc cc clang make \
         cmake apt apt-get dpkg curl wget nc netcat openssl node python \
         python3 ruby perl java php go rustc cargo npm npx pip pip3 convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test /out/bcpl/cin64/convexexample /usr/local/lib/bcpl/cin64/convexexample
COPY --from=test /out/convex-example /usr/local/bin/convex-example
# No deployment is configured here, so the example must refuse to run, write
# nothing at all to stdout, and say why on stderr. That is also the proof that
# the launcher keeps the Cintcode system's own console output off the
# transcript stream.
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/lib/bcpl/cin64/convexadapter; \
    code=0; \
    transcript=$(/usr/local/bin/convex-example 2>/dev/null) || code=$?; \
    test "$code" -ne 0; \
    test -z "$transcript"; \
    diagnostics=$(/usr/local/bin/convex-example 2>&1 >/dev/null || true); \
    printf '%s\n' "$diagnostics" | grep -Fq 'CONVEX_URL is required'
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build bcpl` uses the default target.
FROM runtime-base AS runtime
COPY --from=test /out/bcpl/cin64/convexadapter /usr/local/lib/bcpl/cin64/convexadapter
COPY --from=test /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && test ! -e /usr/local/lib/bcpl/cin64/convexexample \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
       | grep -Fqx '{"id":"close","type":"closed"}'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
