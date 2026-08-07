# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# The same pinned Debian base other clients in this repository use.
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# test: install emacs-nox, build the adapter-only stdin-poll helper, lint
# every source file, and run every language-local test suite
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
ENV HOME=/home/convex
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       emacs-nox=1:28.2+1-15+deb12u4 \
       gcc \
       libc6-dev \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/convex

RUN set -eu; test "$(uname -m)" = x86_64
RUN set -eu; test "$(emacs --version | head -n 1)" = 'GNU Emacs 28.2'

COPY client ./client
COPY examples ./examples

# Emacs Lisp has no standard formatter, so the style gate is explicit:
# spaces only, no trailing blanks, a final newline, and a line-width bound.
RUN set -eu; \
    files=$(find client examples -name '*.el'); \
    test -n "$files"; \
    for f in $files; do \
      if awk '/\t/ { exit 0 } END { exit 1 }' "$f"; then \
        echo "tab in $f" >&2; exit 1; \
      fi; \
      if grep -q ' $' "$f"; then echo "trailing space in $f" >&2; exit 1; fi; \
      case "$f" in examples/*) width=100 ;; *) width=132 ;; esac; \
      if awk -v width="$width" \
             'length > width { print FILENAME ":" NR; found = 1 } \
              END { exit !found }' "$f"; then \
        echo "line over $width columns in $f" >&2; exit 1; \
      fi; \
      if [ "$(tail -c 1 "$f" | wc -l)" -ne 1 ]; then \
        echo "no final newline in $f" >&2; exit 1; \
      fi; \
    done; \
    echo "PASS emacs-lisp source style"

# Byte-compiling every source file is the closest thing Emacs Lisp has to a
# static check: it surfaces a genuinely undefined function or free variable
# as a warning even though it cannot execute the file to find a logic bug.
# Warnings, not just errors, fail this step - convex.el and adapter.el are
# both meant to load cleanly with zero of either.
# adapter.el's own top-level form loads convex.el before referencing any
# of its symbols, but batch-byte-compile only compiles the one file it is
# given: without loading convex.el first here too, every convex-* symbol
# adapter.el uses looks like a free variable or an unknown function to the
# byte compiler, which is a false positive, not the real check.
RUN set -eu; \
    emacs --batch -Q \
      --eval "(setq byte-compile-error-on-warn t)" \
      -f batch-byte-compile client/convex.el 2>/tmp/compile.err \
      || { cat /tmp/compile.err >&2; exit 1; }; \
    if grep -qi 'warning\|error' /tmp/compile.err; then \
      echo "byte-compile warnings in client/convex.el:" >&2; cat /tmp/compile.err >&2; exit 1; \
    fi; \
    emacs --batch -Q -l client/convex.el \
      --eval "(setq byte-compile-error-on-warn t)" \
      -f batch-byte-compile client/tests/conformance/adapter.el 2>/tmp/compile2.err \
      || { cat /tmp/compile2.err >&2; exit 1; }; \
    if grep -qi 'warning\|error' /tmp/compile2.err; then \
      echo "byte-compile warnings in client/tests/conformance/adapter.el:" >&2; \
      cat /tmp/compile2.err >&2; exit 1; \
    fi; \
    rm -f client/convex.elc client/tests/conformance/adapter.elc

# stdin-poll.c is the only native code anywhere in this client, and it
# exists solely for the test-only NDJSON adapter (adapter.el), never for
# convex.el. See its own header comment for exactly why it exists: Emacs
# batch mode has no way to poll its own inherited stdin with a timeout, the
# same blocking-I/O constraint several other single-threaded languages in
# this project hit for the identical reason, solved the identical way (a
# poll(2) readiness check on stdin). convex.el's HTTP, TLS, JSON, and
# hand-rolled WebSocket layers never touch this file.
RUN set -eu; \
    gcc -O2 -Wall -Wextra -Werror \
        -o client/tests/conformance/stdin-poll \
        client/tests/conformance/stdin-poll.c

RUN set -eu; emacs --batch -Q -l client/tests/unit_test.el

# live_test.el needs a second, real OS process to be its wire-protocol
# peer (see the block comment at the top of both files for why this cannot
# be one process): the fixture is started first and the test waits for it.
RUN set -eu; \
    emacs --batch -Q -l client/tests/live_test_fixture.el >/tmp/live_test_fixture.out 2>&1 & \
    fixture_pid=$!; \
    sleep 2; \
    emacs --batch -Q -l client/tests/live_test.el; \
    wait "$fixture_pid" || { cat /tmp/live_test_fixture.out >&2; exit 1; }

# The conformance adapter must compile and answer hello/close correctly
# before any Docker socket exists to test it against a real deployment.
# This is a bare hello/close probe, matching every other client in this
# repository's own Docker-stage adapter smoke test: real subscribe/Live
# coverage over the adapter is the shared harness's job, not this build's.
RUN set -eu; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 emacs --batch -Q -l client/tests/conformance/adapter.el \
    | tee /tmp/adapter-probe.out; \
    grep -Fq '"type":"ready"' /tmp/adapter-probe.out; \
    grep -Fq '"language":"emacs-lisp"' /tmp/adapter-probe.out; \
    grep -Fq '"type":"closed"' /tmp/adapter-probe.out

# The same probe over the TCP mode the shared harness actually uses.
RUN set -eu; \
    CONVEX_URL=http://127.0.0.1:1 ADAPTER_LISTEN=0.0.0.0:18080 \
      emacs --batch -Q -l client/tests/conformance/adapter.el & \
    adapter_pid=$!; \
    sleep 2; \
    { printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"close","op":"close"}'; \
      sleep 1; \
    } | timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18080; cat >&3; cat <&3' \
    | tee /tmp/adapter-tcp-probe.out; \
    grep -Fq '"type":"ready"' /tmp/adapter-tcp-probe.out; \
    wait "$adapter_pid" || true

# The example must fail loudly without a deployment, and must print nothing
# on stdout when it does, because stdout is the shared happy-path transcript.
RUN set -eu; \
    code=0; \
    emacs --batch -Q -l examples/basics/main.el >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -eq 1; \
    test ! -s /tmp/example.out; \
    grep -Fq 'CONVEX_URL is required' /tmp/example.err

# Stage the exact runtime closure. Resolving shared libraries with ldd
# (once per binary, since ldd on multiple arguments prints a "path:" header
# line per binary rather than one flat list) instead of listing them by hand
# keeps the minimal image honest when a dependency changes underneath it.
# Emacs itself dynamically links a genuinely large closure (GnuTLS, libxml2,
# ICU, systemd, and more), unlike this project's smaller interpreters -
# automatic discovery is essential here, not merely convenient. Its own
# lisp and native-compilation directories are copied separately: ldd only
# finds ELF shared-library dependencies, not the interpreted .el/.eln files
# Emacs loads at startup (url.el, subr.el, and the rest of its standard
# library), which live under /usr/share/emacs and /usr/lib/emacs instead.
RUN set -eu; \
    mkdir -p /closure/bin /closure/usr/local/bin \
             /closure/usr/local/lib/convex-emacs-lisp /closure/etc/ssl/certs \
             /closure/lib/x86_64-linux-gnu /closure/lib64 \
             /closure/usr/share /closure/usr/lib /closure/usr/libexec; \
    for name in cat cut head tail tr sort uniq wc uname grep sed id; do \
      cp -aL "$(command -v "$name")" /closure/usr/local/bin/"$name"; \
    done; \
    cp -aL /usr/bin/mawk /closure/usr/local/bin/awk; \
    cp -aL /bin/dash /closure/bin/sh; \
    mkdir -p /closure/usr/bin; \
    cp -aL /usr/bin/emacs /closure/usr/bin/emacs; \
    cp -aL /usr/share/emacs /closure/usr/share/emacs; \
    cp -aL /usr/lib/emacs /closure/usr/lib/emacs; \
    cp -aL /usr/libexec/emacs /closure/usr/libexec/emacs; \
    cp -aL /etc/ssl/certs/ca-certificates.crt /closure/etc/ssl/certs/; \
    cp -aL /etc/ssl/openssl.cnf /closure/etc/ssl/openssl.cnf; \
    cp -aL /etc/nsswitch.conf /closure/etc/nsswitch.conf; \
    for lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
      cp -aL /lib/x86_64-linux-gnu/"$lib" /closure/lib/x86_64-linux-gnu/"$lib"; \
    done; \
    for round in 1 2 3 4; do \
      find /closure -type f \
        -not -path '/closure/usr/share/emacs/*' \
        -not -path '/closure/usr/lib/emacs/*' \
        -not -path '/closure/usr/libexec/emacs/*' \
        -exec sh -c ' \
        for elf; do \
          case "$(head -c4 "$elf" | od -An -tx1 | tr -d " \n")" in \
            7f454c46) echo "$elf" ;; \
          esac; \
        done' sh {} + \
        | while read -r elf; do \
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
    done; \
    mkdir -p /closure/usr/local/lib/convex-emacs-lisp/client \
             /closure/usr/local/lib/convex-emacs-lisp/examples/basics; \
    cp client/convex.el /closure/usr/local/lib/convex-emacs-lisp/client/; \
    printf 'emacs-28.2\n' > /closure/usr/local/lib/convex-emacs-lisp/runtime

RUN set -eu; \
    mkdir -p /entry; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# The verifier passes a unique room as the first argument.' \
      'cd /usr/local/lib/convex-emacs-lisp' \
      'exec /usr/bin/emacs --batch -Q -l examples/basics/main.el "$@"' \
      > /entry/convex-example; \
    printf '%s\n' \
      '#!/bin/sh' \
      'cd /usr/local/lib/convex-emacs-lisp' \
      'exec /usr/bin/emacs --batch -Q -l client/tests/conformance/adapter.el' \
      > /entry/convex-adapter; \
    chmod 755 /entry/convex-example /entry/convex-adapter

# ---------------------------------------------------------------------------
# runtime-base: the pinned image with its filesystem removed and only the
# declared closure copied back
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
# `rm` must be exec'd exactly once: looking it up on $PATH once per path in a
# loop means the first iteration that deletes /bin or /usr removes the `rm`
# binary itself, so the shell fails to find it on the next iteration. Every
# path is collected into positional parameters first, then handed to one
# `rm -rf` call, so exec happens only once while rm's own code and libraries
# are still resident.
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
ENV HOME=/home/convex \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
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
    for command_name in gcc cc clang ld make cmake libtool apt apt-get dpkg \
        curl wget nc netcat ssh openssl node python python3 ruby perl java \
        php go rustc cargo npm pip convex; do \
      if command -v "$command_name" >/dev/null 2>&1; then \
        echo "unexpected command in runtime image: $command_name" >&2; \
        exit 1; \
      fi; \
    done

# emacs is the target language runtime and is expected here; prove it can
# run with no compiler present.
RUN set -eu; \
    test "$(emacs --batch -Q --eval '(princ "ok")')" = ok

# ---------------------------------------------------------------------------
# example-runtime
# ---------------------------------------------------------------------------
FROM runtime-base AS example-runtime
COPY --from=test /entry/convex-example /usr/local/bin/convex-example
COPY --from=test /project/examples/basics/main.el \
     /usr/local/lib/convex-emacs-lisp/examples/basics/main.el
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-example; \
    test ! -e /usr/local/bin/convex-adapter; \
    test ! -e /usr/local/lib/convex-emacs-lisp/client/tests
ENTRYPOINT ["/usr/local/bin/convex-example"]

# ---------------------------------------------------------------------------
# runtime: last, because `./run build emacs-lisp` uses the default target
# ---------------------------------------------------------------------------
FROM runtime-base AS runtime
COPY --from=test /entry/convex-adapter /usr/local/bin/convex-adapter
COPY --from=test /project/client/tests/conformance/adapter.el \
     /usr/local/lib/convex-emacs-lisp/client/tests/conformance/adapter.el
COPY --from=test /project/client/tests/conformance/stdin-poll \
     /usr/local/lib/convex-emacs-lisp/client/tests/conformance/stdin-poll
USER 65532:65532
RUN set -eu; \
    test -x /usr/local/bin/convex-adapter; \
    test -x /usr/local/lib/convex-emacs-lisp/client/tests/conformance/stdin-poll; \
    test ! -e /usr/local/bin/convex-example; \
    test ! -e /usr/local/lib/convex-emacs-lisp/examples/basics/main.el; \
    printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-adapter \
    | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
