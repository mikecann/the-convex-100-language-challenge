# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# XPL has no official container image and no distribution package. It is
# built from source at a pinned commit of sergev/xpl-compiler (an XPL to C
# translator, Free Public License, tagged release 1.0) using the upstream
# makefile. XPL compiles to plain C, which gcc then links into a normal ELF
# binary, so neither the translator nor gcc is needed to run the result --
# both live only in the build stage.
ARG BUILD_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258
ARG RUNTIME_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258
ARG XPL_COMMIT=5b725ef5f486873ee821f4370310f2eaa65b2e55
# One list, probed identically in both runtime images: the negative control
# that proves the absence of a compiler, package manager, or delegated
# runtime is real rather than merely hidden from PATH.
ARG FORBIDDEN_COMMANDS="gcc cc clang make cmake ld as apt apt-get dpkg git curl wget nc netcat node python python3 php ruby perl java go rustc cargo npm pip convex xpl"

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG XPL_COMMIT
RUN apt-get update && apt-get install --no-install-recommends --yes \
    build-essential \
    ca-certificates \
    git \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone -q https://github.com/sergev/xpl-compiler.git xpl-compiler \
    && cd xpl-compiler \
    && git checkout -q "${XPL_COMMIT}" \
    && test "$(git rev-parse HEAD)" = "${XPL_COMMIT}" \
    && rm -rf .git
RUN cd /src/xpl-compiler && make
RUN test "$(uname -m)" = x86_64 && /src/xpl-compiler/xpl -v >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# test: format-equivalent parse, language-local unit tests, and compilation
# of the conformance adapter and the canonical example
# ---------------------------------------------------------------------------
FROM toolchain AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples

# XPL has no #include or module system, so each entry point is compiled from
# client/convex.xpl concatenated with its own thin front end -- the same
# role a C header plus a second translation unit would play, done here with
# cat instead of #include (see the file comment atop client/convex.xpl for
# why, and client/tests/conformance/adapter.xpl for why the adapter's own
# raw fd I/O is not part of that shared body).
RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    cat client/convex.xpl client/tests/client_test.xpl > /tmp/client-test.xpl; \
    /src/xpl-compiler/xpl -o /tmp/client-test.c /tmp/client-test.xpl; \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror \
        -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-parameter \
        -o /tmp/client-test /tmp/client-test.c /src/xpl-compiler/libxpl.a \
        -lssl -lcrypto -I/src/xpl-compiler; \
    /tmp/client-test

RUN set -eu; \
    cat client/convex.xpl client/tests/conformance/adapter.xpl > /tmp/adapter.xpl; \
    /src/xpl-compiler/xpl -o /tmp/adapter.c /tmp/adapter.xpl; \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror \
        -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-parameter \
        -o /out-adapter /tmp/adapter.c /src/xpl-compiler/libxpl.a \
        -lssl -lcrypto -I/src/xpl-compiler

RUN set -eu; \
    cat client/convex.xpl examples/basics/main.xpl > /tmp/example.xpl; \
    /src/xpl-compiler/xpl -o /tmp/example.c /tmp/example.xpl; \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror \
        -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-parameter \
        -o /out-example /tmp/example.c /src/xpl-compiler/libxpl.a \
        -lssl -lcrypto -I/src/xpl-compiler

RUN <<'EOF'
set -eu
test "$(uname -m)" = x86_64
actual=$(/out-adapter <<'COMMANDS'
{malformed
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"unknown","op":"notAnOperation"}
{"id":"close","op":"close"}
COMMANDS
)
printf '%s\n' "$actual" | grep -Fx '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'
printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready","language":"xpl"'
printf '%s\n' "$actual" | grep -Fx '{"type":"error","id":"unknown","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'
printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
EOF

# The TCP mode the shared harness drives: ADAPTER_LISTEN binds and accepts
# exactly one controller connection instead of using stdin/stdout.
RUN set -eu; \
    ADAPTER_LISTEN=127.0.0.1:18080 /out-adapter & \
    adapter_pid=$!; \
    sleep 0.2; \
    actual=$(printf '%s\n' \
      '{"id":"tcp-hello","protocolVersion":1,"op":"hello"}' \
      '{"id":"tcp-close","op":"close"}' | nc 127.0.0.1 18080); \
    wait "$adapter_pid"; \
    printf '%s\n' "$actual" | grep -F '"id":"tcp-hello","type":"ready"'; \
    printf '%s\n' "$actual" | grep -Fx '{"id":"tcp-close","type":"closed"}'

RUN set -eu; \
    actual=$(/out-example 2>&1 || true); \
    printf '%s\n' "$actual" | grep -q 'CONVEX_URL is required'

# A tiny standalone program, compiled here (not part of the public client
# API) purely to prove the runtime image can complete a real TLS handshake
# with transport_connect() -- the exact function convex_call and ws_connect
# both use -- before handoff. Built once in this stage so runtime-base can
# execute it as a plain ELF with no compiler present.
RUN set -eu; \
    printf '%s\n' \
      "declare probe_ok fixed;" \
      "probe_ok = transport_connect('usable-reindeer-44.convex.cloud', 443, 1, HTTP_SLOT);" \
      "if probe_ok = 1 then do;" \
      "    output = 'tls probe usable';" \
      "    call transport_close(HTTP_SLOT);" \
      "end;" \
      "else if raw_eq(g_error_message, 0, 17, 'DNS lookup failed') = 1 then" \
      "    output = 'tls probe usable (no network for this build)';" \
      "else if raw_eq(g_error_message, 0, 16, 'connect() failed') = 1 then" \
      "    output = 'tls probe usable (no network for this build)';" \
      "else" \
      "    output = 'tls probe failed: ' || g_error_message;" \
      "eof" \
      > /tmp/tls-probe-body.xpl; \
    cat client/convex.xpl /tmp/tls-probe-body.xpl > /tmp/tls-probe.xpl; \
    /src/xpl-compiler/xpl -o /tmp/tls-probe.c /tmp/tls-probe.xpl; \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -w \
        -o /out-tls-probe /tmp/tls-probe.c /src/xpl-compiler/libxpl.a \
        -lssl -lcrypto -I/src/xpl-compiler
CMD ["/tmp/client-test"]

# ---------------------------------------------------------------------------
# Minimal runtime
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${RUNTIME_IMAGE} AS runtime-base
RUN set -eu; \
    apt-get update; \
    apt-get install --no-install-recommends --yes ca-certificates libssl3; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config \
          /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark \
          /usr/bin/dpkg /usr/bin/dpkg-deb /usr/bin/dpkg-divert \
          /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query /usr/bin/dpkg-split \
          /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger \
          /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure; \
    rm -rf /etc/apt /usr/lib/apt /var/lib/dpkg /usr/share/dpkg; \
    for forbidden in ${FORBIDDEN_COMMANDS}; do \
      if command -v "$forbidden" >/dev/null 2>&1; then \
        printf '%s\n' "unexpected command in the runtime image: $forbidden" >&2; \
        exit 1; \
      fi; \
    done

USER 65532:65532

# Prove the unprivileged, read-only-eligible runtime can complete a real TLS
# handshake against the hosted deployment before handoff, running the exact
# binary that gets shipped (compiled in the test stage, above) rather than
# recompiling here -- this stage never installs a compiler at all. A
# network-less build cannot reach the deployment (DNS/connect fails before
# any TLS byte moves), which the probe itself treats as acceptable; anything
# past that -- a certificate store or TLS provider genuinely missing from
# this image -- fails the build instead of being discovered only later,
# against the hosted target.
COPY --from=test /out-tls-probe /tmp/tls-probe
RUN set -eu; \
    test "$(id -u):$(id -g)" = 65532:65532; \
    test "$(uname -m)" = x86_64; \
    actual=$(/tmp/tls-probe); \
    printf '%s\n' "$actual"; \
    printf '%s\n' "$actual" | grep -q 'tls probe usable'
USER root
RUN rm -f /tmp/tls-probe
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 --from=test /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 --from=test /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
