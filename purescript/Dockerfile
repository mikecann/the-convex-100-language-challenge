# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# PureScript has no runtime of its own: the compiler emits code for a host
# language. This client uses purerl, the Erlang backend, so the pipeline is
# `purs` (CoreFn) -> `purerl` (Erlang source) -> `erlc` (BEAM bytecode), and
# the final images carry the BEAM emulator and nothing else.
#
# The two compiler binaries are Linux glibc builds, so they run in a Debian
# stage; the BEAM toolchain is the Alpine musl build used by the rest of this
# repository. Erlang *source* crosses between them, which is portable.
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG ELIXIR_IMAGE=elixir:1.17.3-otp-26-alpine@sha256:7d6fcd52aba8170560b39ca5852759acc1aacf6d10290ae668a0a49602a04f8b
ARG ALPINE_IMAGE=alpine:3.22@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6

ARG PURESCRIPT_VERSION=0.15.14
ARG PURERL_VERSION=0.0.24

# ---------------------------------------------------------------------------
# PureScript -> Erlang source
# ---------------------------------------------------------------------------

FROM --platform=linux/amd64 ${DEBIAN_IMAGE} AS purescript-build
ARG PURESCRIPT_VERSION
ARG PURERL_VERSION
WORKDIR /app

# Both compilers are statically linked apart from libc, libm, libz, and libgmp.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      libgmp10 \
    && rm -rf /var/lib/apt/lists/*

# The compilers are the only network inputs and both are pinned by content
# hash, so this build cannot silently follow a re-tagged release. There is no
# package set and no package manager: the client depends on nothing but these.
ADD --checksum=sha256:8936fd52b34d82d3c0be311b4ef90d4afa81632b0fa419e205358846d63be144 \
    https://github.com/purescript/purescript/releases/download/v0.15.14/linux64.tar.gz \
    /tmp/purescript.tar.gz
ADD --checksum=sha256:fb0b2ab1c07f35f1ed85a8ad8214c6d772e1cff2f807c5ed5f40a0362bd197e3 \
    https://github.com/purerl/purerl/releases/download/v0.0.24/linux64.tar.gz \
    /tmp/purerl.tar.gz
RUN set -eu; \
    tar -xzf /tmp/purescript.tar.gz -C /tmp; \
    tar -xzf /tmp/purerl.tar.gz -C /tmp; \
    install -m 0755 /tmp/purescript/purs /usr/local/bin/purs; \
    install -m 0755 /tmp/purerl/purerl /usr/local/bin/purerl; \
    rm -rf /tmp/purescript /tmp/purerl /tmp/purescript.tar.gz /tmp/purerl.tar.gz

# A genuine linux/amd64 stage, and the exact compilers the adapter reports as
# its runtime, so a drifting declaration cannot change the evidence.
RUN test "$(uname -m)" = x86_64
RUN purs --version | grep -Fqx "${PURESCRIPT_VERSION}"
RUN purerl --version | grep -Fq "${PURERL_VERSION}"

# purerl finds an FFI module by replacing the `.purs` extension of the source
# path, so each `.erl` has to sit beside its module. The educational layout
# stays flat in the repository and is copied into that tree here.
COPY client/Convex.purs ./src/Convex.purs
COPY client/Convex/ ./src/Convex/
COPY client/tests/Check.purs ./src/Check.purs
COPY client/tests/CodecTest.purs ./src/CodecTest.purs
COPY client/tests/LiveSocketTest.purs ./src/LiveSocketTest.purs
COPY client/tests/conformance/Adapter.purs ./src/Adapter.purs
COPY client/tests/conformance/AdapterTest.purs ./src/AdapterTest.purs
COPY examples/basics/Main.purs ./src/Main.purs
COPY examples/basics/MainTest.purs ./src/MainTest.purs

# Style gate. purs-tidy is a separate community tool distributed as a Node
# package, and adding a JavaScript runtime to this build only to reformat
# source would undercut the point of a two-binary toolchain. These checks are
# what the repository actually enforces on the checked-in source instead.
RUN set -eu; \
    for file in $(find src -name '*.purs' -o -name '*.erl'); do \
      if grep -q "$(printf '\t')" "$file"; then \
        printf '%s\n' "tab character in $file" >&2; exit 1; \
      fi; \
      if grep -qE ' +$' "$file"; then \
        printf '%s\n' "trailing whitespace in $file" >&2; exit 1; \
      fi; \
      if grep -q "$(printf '\r')" "$file"; then \
        printf '%s\n' "carriage return in $file" >&2; exit 1; \
      fi; \
      if [ -n "$(awk 'length > 100 { print; exit }' "$file")" ]; then \
        printf '%s\n' "line longer than 100 columns in $file" >&2; exit 1; \
      fi; \
      if [ -n "$(tail -c 1 "$file")" ]; then \
        printf '%s\n' "missing final newline in $file" >&2; exit 1; \
      fi; \
      head -n 1 "$file" | grep -qE '^(-- \||%%|module )' || { \
        printf '%s\n' "missing leading documentation in $file" >&2; exit 1; \
      }; \
    done

# Type-check and emit CoreFn, then translate that to Erlang. `purs` never sees
# the `.erl` files; it records the foreign imports and `purerl` resolves them.
RUN purs compile --codegen corefn $(find src -name '*.purs')
# purerl's positional FILES argument loads `.purs` sources for its REPL; it is
# not a way to hand it a list of corefn.json paths, and passing one produces
# an optparse-applicative "Missing:" usage error rather than a compile error.
# With no arguments purerl walks its default `-o` directory (also "output",
# the same one `purs` just wrote) and translates every module it finds there.
RUN purerl

# Collect the generated Erlang alongside the hand-written FFI. purerl copies
# each foreign module into its output directory; the fallback below keeps a
# change in that behaviour an explicit, named failure rather than an undefined
# function at run time.
RUN set -eu; \
    mkdir -p erl-src; \
    find output -name '*.erl' -exec cp {} erl-src/ \; ; \
    find output -name '*.hrl' -exec cp {} erl-src/ \; ; \
    for pair in Prelude:convex_prelude Bytes:convex_bytes Sys:convex_sys; do \
      source_name=${pair%%:*}; \
      module=${pair##*:}; \
      if [ ! -f "erl-src/${module}@foreign.erl" ]; then \
        cp "src/Convex/${source_name}.erl" "erl-src/${module}@foreign.erl"; \
      fi; \
    done; \
    for module in convex_prelude convex_bytes convex_sys; do \
      test -f "erl-src/${module}@foreign.erl"; \
      test -f "erl-src/${module}@ps.erl"; \
    done; \
    for module in convex convex_json convex_error convex_http convex_ws \
                  convex_live adapter main; do \
      test -f "erl-src/${module}@ps.erl"; \
    done

# ---------------------------------------------------------------------------
# Erlang bytecode, language-local tests, and adapter smoke tests
# ---------------------------------------------------------------------------

FROM --platform=linux/amd64 ${ELIXIR_IMAGE} AS erlang-build
WORKDIR /app
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"
COPY --from=purescript-build /app/erl-src ./erl-src

# The BEAM that will actually execute the client is also linux/amd64.
RUN test "$(uname -m)" = x86_64
RUN erl -noshell -eval 'true = lists:prefix("x86_64", erlang:system_info(system_architecture)), halt().'

# `-Werror` is the lint gate for the three hand-written FFI modules: an unused
# variable, a missing clause, or an export that does not match a definition
# fails the build there. Generated code is compiled without it, because its
# warnings would be a report about purerl rather than about this client.
RUN set -eu; \
    mkdir -p ebin; \
    erlc -Werror -I erl-src -o ebin \
      'erl-src/convex_prelude@foreign.erl' \
      'erl-src/convex_bytes@foreign.erl' \
      'erl-src/convex_sys@foreign.erl'; \
    generated=""; \
    for file in erl-src/*.erl; do \
      case "$file" in *@foreign.erl) ;; *) generated="$generated $file" ;; esac; \
    done; \
    erlc -I erl-src -o ebin $generated

# Language-local behaviour, run against the compiled bytecode the same way the
# runtime images will, so nothing is proved through a build-tool wrapper that
# will not exist in the final image.
RUN erl -noshell -pa ebin -eval "('convex_test_codec@ps':main())(), halt(0)."
RUN erl -noshell -pa ebin -eval "('convex_test_adapter@ps':main())(), halt(0)."
RUN erl -noshell -pa ebin -eval "('convex_test_example@ps':main())(), halt(0)."
RUN erl -noshell -pa ebin -eval "('convex_test_live@ps':main())(), halt(0)."

# The adapter must speak protocol v1 over stdin/stdout before anything relies
# on it.
RUN set -eu; \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 erl -noshell -pa ebin \
        -eval "('adapter@ps':main())(), halt(0)." >/tmp/adapter.ndjson; \
    grep -Fq '"language":"purescript"' /tmp/adapter.ndjson; \
    grep -Fq '"type":"closed"' /tmp/adapter.ndjson

# Adversarial input: an unterminated line is discarded, malformed commands are
# answered with protocol errors that keep their command id where one could be
# recovered, and an oversized line neither grows the process nor desynchronises
# the stream.
RUN set -eu; \
    adapter() { \
      CONVEX_URL=http://127.0.0.1:9 erl -noshell -pa ebin \
        -eval "('adapter@ps':main())(), halt(0)."; \
    }; \
    long_id=$(head -c 129 /dev/zero | tr '\000' x); \
    printf '%s' '{"id":"partial","op":"close"}' | adapter >/tmp/partial.ndjson; \
    test ! -s /tmp/partial.ndjson; \
    printf '%s\n' '{]' '{"op":"close"}' \
      '{"id":"bad-query","op":"query","path":"demo:state"}' \
      '{"protocolVersion":1,"id":"extra","op":"hello","extra":true}' \
      '{"protocolVersion":1,"id":7,"op":"hello"}' \
      '{"id":"bad-auth","op":"setAuth","token":"bad\nheader"}' \
      "{\"protocolVersion\":1,\"id\":\"$long_id\",\"op\":\"hello\"}" \
      '{"id":"close","op":"close"}' \
      | adapter >/tmp/malformed.ndjson; \
    test "$(grep -c '"name":"ProtocolError"' /tmp/malformed.ndjson)" -eq 7; \
    grep -Fq '"type":"closed"' /tmp/malformed.ndjson; \
    { head -c 9437185 /dev/zero | tr '\000' x; \
      printf '\n%s\n' '{"id":"close","op":"close"}'; } \
      | adapter >/tmp/oversized.ndjson; \
    grep -Fq '"name":"ProtocolError"' /tmp/oversized.ndjson; \
    grep -Fq '"type":"closed"' /tmp/oversized.ndjson

# Split the bytecode into the three disjoint sets the images need. Only
# bytecode crosses into a runtime image; sources and build state do not.
RUN set -eu; \
    mkdir -p core-ebin example-ebin adapter-ebin; \
    for module in convex@ps convex_prelude@ps convex_prelude@foreign \
                  convex_bytes@ps convex_bytes@foreign \
                  convex_sys@ps convex_sys@foreign \
                  convex_json@ps convex_error@ps convex_http@ps \
                  convex_ws@ps convex_live@ps; do \
      cp "ebin/${module}.beam" core-ebin/; \
    done; \
    cp ebin/main@ps.beam example-ebin/; \
    cp ebin/adapter@ps.beam adapter-ebin/; \
    test ! -e 'core-ebin/convex_test_check@ps.beam'

FROM erlang-build AS test
CMD ["/bin/true"]

# ---------------------------------------------------------------------------
# Minimal BEAM runtime
# ---------------------------------------------------------------------------

FROM --platform=linux/amd64 ${ELIXIR_IMAGE} AS target-erlang-runtime

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS runtime-base
RUN apk add --no-cache ca-certificates=20260611-r0 libcrypto3=3.5.7-r0 libssl3=3.5.7-r0 libstdc++=14.2.0-r6 ncurses-libs=6.5_p20250503-r0 dash=0.5.12-r3 coreutils=9.7-r1 diffutils=3.12-r0 grep=3.12-r0 sed=4.9-r2 mawk=1.3.4-r11

# The whole Erlang tree is copied and then pruned, because the ERTS version
# inside the pinned image is not knowable outside Docker. The probe at the end
# of this stage is what actually proves the result is minimal: it checks that
# no compiler command or compile server module survived.
COPY --from=target-erlang-runtime /usr/local/lib/erlang /usr/local/lib/erlang
# This non-distributed client boots on kernel and stdlib and reaches TLS
# through crypto, ssl, public_key, and asn1. Nothing else is in the application
# closure, including the compiler and SASL. Only the emulator and the two
# helpers it execs are kept from the ERTS binaries.
RUN set -eu; \
    cd /usr/local/lib/erlang; \
    for application in lib/*/; do \
      name=${application#lib/}; \
      case "${name%%-*}" in \
        kernel|stdlib|crypto|ssl|public_key|asn1) ;; \
        *) rm -rf "$application" ;; \
      esac; \
    done; \
    rm -f lib/stdlib-*/ebin/erl_compile.beam lib/kernel-*/ebin/erl_compile_server.beam; \
    for path in erts-*/bin/*; do \
      case "${path##*/}" in \
        beam.smp|erl_child_setup|erlexec|inet_gethost) ;; \
        *) rm -f "$path" ;; \
      esac; \
    done; \
    for path in bin/*; do \
      case "${path##*/}" in \
        erl|start.boot) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done; \
    rm -rf erts-*/src erts-*/include erts-*/lib erts-*/doc usr misc releases; \
    ln -s ../lib/erlang/bin/erl /usr/local/bin/erl

COPY --from=erlang-build /app/core-ebin /opt/convex

# Stock Alpine BusyBox still contains wget and nc when its symlinks are
# removed, because an applet can be selected through argv[0] or the multicall
# command. Install a separate shell and text tools, then remove every BusyBox
# link, the multicall binary, package state, boot hooks, and certificate
# sources that are redundant with the runtime bundle.
RUN set -eu; \
    ln -sf /usr/bin/dash /bin/sh; \
    for path in /bin/* /sbin/* /usr/bin/* /usr/sbin/*; do \
        if test -L "$path"; then \
            target=$(readlink "$path"); \
            case "$target" in *busybox*) rm -f "$path" ;; esac; \
        fi; \
    done; \
    ln -sf /usr/bin/mawk /usr/bin/awk; \
    rm -f \
        /bin/busybox /sbin/apk /sbin/ldconfig \
        /usr/sbin/chroot /usr/sbin/update-ca-certificates \
        /usr/bin/c_rehash /usr/bin/scanelf /usr/bin/ssl_client \
        /usr/lib/libapk.so*; \
    rm -rf \
        /etc/apk /lib/apk /lib/sysctl.d \
        /etc/ca-certificates/update.d \
        /etc/busybox-paths.d /etc/crontabs /etc/periodic \
        /etc/inittab /etc/logrotate.d /etc/profile /etc/profile.d \
        /etc/fstab /etc/issue /etc/modprobe.d /etc/modules \
        /etc/modules-load.d /etc/network /etc/opt /etc/secfixes.d \
        /etc/securetty /etc/shells /etc/sysctl.conf /etc/sysctl.d \
        /etc/udhcpc /etc/motd \
        /home /media /mnt /root /run /srv /var \
        /usr/share /usr/local/share
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1" ERL_CRASH_DUMP=/dev/null
USER 65532:65532
# Prove the shape of the image rather than assuming it: the tools the shared
# policy needs are present, every package, network, compiler, and delegated
# runtime command is absent, the client modules load, and TLS actually
# completes a verified handshake against a real Convex host.
RUN set -eu; \
    for command in sh id cat cmp cut grep head sed sort tail tr awk erl; do command -v "$command" >/dev/null; done; \
    for command in busybox wget nc netcat apk purs purerl spago erlc escript \
                   dialyzer typer ct_run elixir iex mix rebar rebar3 hex cc gcc \
                   clang make node npm npx yarn python python3 pip pip3 curl \
                   convex openssl ssl_client c_rehash scanelf; do \
      ! command -v "$command" >/dev/null 2>&1 || exit 1; \
    done; \
    test ! -e /bin/busybox; \
    test "$(uname -m)" = x86_64; \
    erl -noshell -pa /opt/convex -eval 'true = lists:prefix("x86_64", erlang:system_info(system_architecture)), {non_existing, non_existing} = {code:which(erl_compile), code:which(erl_compile_server)}, {ok, _} = application:ensure_all_started(ssl), <<_:8>> = crypto:strong_rand_bytes(1), {module, '\''convex@ps'\''} = code:ensure_loaded('\''convex@ps'\''), {module, '\''convex_sys@foreign'\''} = code:ensure_loaded('\''convex_sys@foreign'\''), {ok, Socket} = ssl:connect("convex.cloud", 443, [binary, {active, false}, {verify, verify_peer}, {depth, 10}, {cacertfile, "/etc/ssl/certs/ca-certificates.crt"}, {server_name_indication, "convex.cloud"}, {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}], 10000), ok = ssl:close(Socket), halt().'

# ---------------------------------------------------------------------------
# Runtime images
# ---------------------------------------------------------------------------

FROM runtime-base AS example-runtime
COPY --from=erlang-build /app/example-ebin /opt/convex
COPY --chmod=0555 examples/basics/entrypoint.sh /usr/local/bin/convex-example
RUN set -eu; \
    test -f '/opt/convex/main@ps.beam'; \
    test ! -e '/opt/convex/adapter@ps.beam'; \
    test ! -e '/opt/convex/convex_test_codec@ps.beam'; \
    test ! -e '/opt/convex/convex_test_live@ps.beam'; \
    test ! -e '/opt/convex/convex_test_adapter@ps.beam'; \
    test ! -e '/opt/convex/convex_test_example@ps.beam'; \
    code=0; CONVEX_URL=invalid /usr/local/bin/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -ne 0; \
    test ! -s /tmp/example.out
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=erlang-build /app/adapter-ebin /opt/convex
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
RUN set -eu; \
    test -f '/opt/convex/adapter@ps.beam'; \
    test ! -e '/opt/convex/main@ps.beam'; \
    test ! -e '/opt/convex/convex_test_codec@ps.beam'; \
    test ! -e '/opt/convex/convex_test_live@ps.beam'; \
    test ! -e '/opt/convex/convex_test_adapter@ps.beam'; \
    test ! -e '/opt/convex/convex_test_example@ps.beam'; \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
        >/tmp/final-adapter.ndjson; \
    grep -Fq '"language":"purescript"' /tmp/final-adapter.ndjson; \
    grep -Fq '"type":"closed"' /tmp/final-adapter.ndjson

# The memory proof, run against the real final adapter rather than a build
# stage. A named pipe is opened for reading and never read, so every write
# blocks in the kernel; the input is six commands at the 9 MiB frame limit
# followed by enough valid commands to overrun the 16-event output budget.
# Both bounds are therefore exercised at once, and peak resident memory has to
# stay far below the 128 MiB the shared conformance run allows.
RUN set -eu; \
    cd /tmp; \
    mkfifo stalled; \
    sleep 120 < stalled & \
    holder=$!; \
    ( { i=0; \
        while [ "$i" -lt 6 ]; do \
          head -c 9437185 /dev/zero | tr '\000' x; printf '\n'; \
          i=$((i + 1)); \
        done; \
        j=0; \
        while [ "$j" -lt 4000 ]; do \
          printf '{"protocolVersion":1,"id":"h%s","op":"hello"}\n' "$j"; \
          j=$((j + 1)); \
        done; \
        sleep 30; \
      } | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
            >stalled 2>adapter.err ) & \
    adapter=""; \
    attempt=0; \
    while [ -z "$adapter" ] && [ "$attempt" -lt 100 ]; do \
      for pid in /proc/[0-9]*; do \
        if [ -r "$pid/comm" ] && [ "$(cat "$pid/comm" 2>/dev/null)" = beam.smp ]; then \
          adapter=${pid#/proc/}; \
          break; \
        fi; \
      done; \
      attempt=$((attempt + 1)); \
      sleep 0.2; \
    done; \
    test -n "$adapter"; \
    peak=0; \
    attempt=0; \
    while [ "$attempt" -lt 200 ] && [ -r "/proc/$adapter/status" ]; do \
      rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$adapter/status" 2>/dev/null || true); \
      if [ -n "$rss" ] && [ "$rss" -gt "$peak" ]; then peak=$rss; fi; \
      attempt=$((attempt + 1)); \
      sleep 0.2; \
    done; \
    kill "$holder" 2>/dev/null || true; \
    kill "$adapter" 2>/dev/null || true; \
    printf 'peak adapter RSS with a stopped reader: %s kB\n' "$peak" >&2; \
    test "$peak" -gt 0; \
    test "$peak" -lt 98304; \
    grep -Fq 'controller output budget exceeded' adapter.err; \
    rm -f stalled adapter.err
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
