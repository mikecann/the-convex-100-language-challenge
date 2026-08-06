# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# Gleam 1.9.1 and its Erlang runtime are fixed by this immutable image digest.
# The in-container version probe below still protects the adapter evidence from
# an accidental change to this declaration.
ARG GLEAM_IMAGE=ghcr.io/gleam-lang/gleam@sha256:d461f5a1e272fa90473fc8aa771d078d5a36694036cbbd7f04ef659c5d0626cb

FROM --platform=linux/amd64 ${GLEAM_IMAGE} AS build
WORKDIR /app
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"

# Gleam expects one project tree. The educational layout stays flat in the
# repository and is copied into that tree here rather than reshaping the
# repository around a build tool.
COPY client/gleam.toml ./gleam.toml
COPY client/manifest.toml ./manifest.toml
RUN gleam deps download
COPY client/convex.gleam client/convex_error.gleam client/convex_http.gleam \
     client/convex_json.gleam client/convex_live.gleam client/convex_sys.gleam \
     client/convex_ws.gleam client/convex_ffi.erl ./src/
COPY client/tests/convex_check.gleam client/tests/convex_codec_test.gleam \
     client/tests/convex_live_socket_test.gleam ./src/
COPY client/tests/conformance/adapter.gleam \
     client/tests/conformance/adapter_test.gleam \
     client/tests/conformance/adapter_pressure.erl ./src/
COPY examples/basics/main.gleam examples/basics/main_test.gleam ./src/

# The toolchain in the image must be the one the adapter reports as its
# runtime, so a drifting base image cannot silently change the evidence.
RUN gleam --version | grep -Fq "1.9.1"
# A genuine linux/amd64 image, asserted for the container and for the BEAM
# that will actually execute the client.
RUN test "$(uname -m)" = x86_64
RUN erl -noshell -eval 'true = lists:prefix("x86_64", erlang:system_info(system_architecture)), halt().'

RUN gleam format --check src
RUN gleam build --target erlang

# Language-local behaviour: codecs, the fixture sync server, and the exact
# decoding the canonical example performs. These run the compiled bytecode the
# same way the runtime images do, so nothing is proved through a build-tool
# wrapper that will not exist in the final image.
RUN erl -noshell -pa build/dev/erlang/*/ebin -s convex_codec_test main -s init stop
RUN erl -noshell -pa build/dev/erlang/*/ebin -s convex_live_socket_test main -s init stop
RUN erl -noshell -pa build/dev/erlang/*/ebin -s adapter_test main -s init stop
RUN erl -noshell -pa build/dev/erlang/*/ebin -s adapter_pressure self_test -s init stop
RUN erl -noshell -pa build/dev/erlang/*/ebin -s main_test main -s init stop

# The adapter must speak protocol v1 over stdin/stdout before anything else
# relies on it.
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
    | erl -noshell -pa build/dev/erlang/*/ebin -s adapter main -s init stop >/tmp/adapter.ndjson \
    && grep -Fq '"language":"gleam"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson

# Adversarial input: an unterminated line is discarded, malformed commands are
# answered with protocol errors, and an oversized line does not grow the
# process or desynchronise the stream.
RUN set -eu; \
    adapter() { erl -noshell -pa build/dev/erlang/*/ebin -s adapter main -s init stop; }; \
    long_id=$(head -c 129 /dev/zero | tr '\000' x); \
    printf '%s' '{"id":"partial","op":"close"}' | adapter >/tmp/partial.ndjson; \
    test ! -s /tmp/partial.ndjson; \
    printf '%s\n' '{]' '{"op":"close"}' '{"id":"bad-query","op":"query","path":"demo:state"}' \
      '{"protocolVersion":1,"id":"extra","op":"hello","extra":true}' \
      '{"protocolVersion":1,"id":7,"op":"hello"}' \
      '{"id":"bad-auth","op":"setAuth","token":"bad\nheader"}' \
      "{\"protocolVersion\":1,\"id\":\"$long_id\",\"op\":\"hello\"}" \
      '{"id":"close","op":"close"}' \
      | adapter >/tmp/malformed.ndjson; \
    test "$(grep -c '"name":"ProtocolError"' /tmp/malformed.ndjson)" -eq 7; \
    grep -Fq '"type":"closed"' /tmp/malformed.ndjson; \
    { head -c 9437185 /dev/zero | tr '\000' x; printf '\n%s\n' '{"id":"close","op":"close"}'; } \
      | adapter >/tmp/oversized.ndjson; \
    grep -Fq '"name":"ProtocolError"' /tmp/oversized.ndjson; \
    grep -Fq '"type":"closed"' /tmp/oversized.ndjson

# Split the compiled modules into the three disjoint sets the images need.
# Only bytecode crosses into a runtime image; sources and build state do not.
RUN set -eu; \
    ebin=build/dev/erlang/convex/ebin; \
    mkdir -p core-ebin example-ebin adapter-ebin; \
    for module in convex convex_error convex_ffi convex_http convex_json \
                  convex_live convex_sys convex_ws; do \
      cp "$ebin/$module.beam" core-ebin/; \
    done; \
    cp "$ebin/main.beam" example-ebin/; \
    cp "$ebin/adapter.beam" adapter-ebin/; \
    test ! -e core-ebin/convex_check.beam

FROM build AS test
CMD ["/bin/true"]

FROM --platform=linux/amd64 ${GLEAM_IMAGE} AS target-erlang-runtime

FROM --platform=linux/amd64 alpine:3.22@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6 AS runtime-base
RUN apk add --no-cache ca-certificates=20260611-r0 libcrypto3=3.5.7-r0 libssl3=3.5.7-r0 libstdc++=14.2.0-r6 ncurses-libs=6.5_p20250503-r0 dash=0.5.12-r3 coreutils=9.7-r1 diffutils=3.12-r0 grep=3.12-r0 sed=4.9-r2 mawk=1.3.4-r11

# The whole Erlang tree is copied and then pruned, because the ERTS version
# inside the pinned Gleam image is not knowable outside Docker. The probe at
# the end of this stage is what actually proves the result is minimal: it
# checks that no compiler command or compile server module survived.
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

COPY --from=build /app/core-ebin /opt/convex
# Only the two Gleam libraries this client depends on contribute bytecode.
COPY --from=build /app/build/dev/erlang/gleam_stdlib/ebin /opt/convex/deps/gleam_stdlib/ebin
COPY --from=build /app/build/dev/erlang/gleam_erlang/ebin /opt/convex/deps/gleam_erlang/ebin

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
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1" ERL_LIBS=/opt/convex/deps ERL_CRASH_DUMP=/dev/null
USER 65532:65532
# Prove the shape of the image rather than assuming it: the tools the shared
# policy needs are present, every package, network, compiler, and delegated
# runtime command is absent, and TLS actually initialises.
RUN set -eu; \
    for command in sh id cat cmp cut grep head sed sort tail tr awk erl; do command -v "$command" >/dev/null; done; \
    for command in busybox wget nc netcat apk gleam erlc escript dialyzer typer ct_run elixir iex mix rebar rebar3 hex cc gcc clang make node npm python python3 curl convex openssl ssl_client c_rehash scanelf; do \
      ! command -v "$command" >/dev/null 2>&1 || exit 1; \
    done; \
    test ! -e /bin/busybox; \
    test "$(uname -m)" = x86_64; \
    erl -noshell -pa /opt/convex -eval 'true = lists:prefix("x86_64", erlang:system_info(system_architecture)), {non_existing, non_existing} = {code:which(erl_compile), code:which(erl_compile_server)}, {ok, _} = application:ensure_all_started(ssl), <<_:8>> = crypto:strong_rand_bytes(1), {module, convex} = code:ensure_loaded(convex), {module, gleam@list} = code:ensure_loaded(gleam@list), {ok, Socket} = convex_ffi:connect(tls, <<"convex.cloud">>, 443, 10000, true), nil = convex_ffi:socket_close(Socket), halt().'

FROM runtime-base AS example-runtime
COPY --from=build /app/example-ebin /opt/convex
COPY --chmod=0555 examples/basics/entrypoint.sh /usr/local/bin/convex-example
RUN set -eu; \
    test -f /opt/convex/main.beam; \
    test ! -e /opt/convex/adapter.beam; \
    test ! -e /opt/convex/convex_check.beam; \
    test ! -e /opt/convex/convex_codec_test.beam; \
    test ! -e /opt/convex/convex_live_socket_test.beam; \
    test ! -e /opt/convex/adapter_test.beam; \
    test ! -e /opt/convex/main_test.beam; \
    code=0; CONVEX_URL=invalid /usr/local/bin/convex-example >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -ne 0 && test ! -s /tmp/example.out
ENTRYPOINT ["/usr/local/bin/convex-example"]

# These two images contain only the checked-in pressure fixture/controller and
# the same minimal Erlang runtime. The host-side probe runs them in sibling
# cgroups while the untouched `runtime` image runs its exact default adapter
# entrypoint under the 128 MiB limit.
FROM runtime-base AS adapter-pressure-fixture
COPY --from=build /app/build/dev/erlang/convex/ebin/adapter_pressure.beam /opt/pressure/adapter_pressure.beam
ENTRYPOINT ["erl", "-noshell", "-pa", "/opt/pressure", "-s", "adapter_pressure", "fixture_main", "-s", "init", "stop"]

FROM runtime-base AS adapter-pressure-controller
COPY --from=build /app/build/dev/erlang/convex/ebin/adapter_pressure.beam /opt/pressure/adapter_pressure.beam
ENTRYPOINT ["erl", "-noshell", "-pa", "/opt/pressure", "-s", "adapter_pressure", "controller_main", "-s", "init", "stop"]

FROM runtime-base AS runtime
COPY --from=build /app/adapter-ebin /opt/convex
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
RUN set -eu; \
    test -f /opt/convex/adapter.beam; \
    test ! -e /opt/convex/main.beam; \
    test ! -e /opt/convex/convex_check.beam; \
    test ! -e /opt/convex/convex_codec_test.beam; \
    test ! -e /opt/convex/convex_live_socket_test.beam; \
    test ! -e /opt/convex/adapter_test.beam; \
    test ! -e /opt/convex/main_test.beam; \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter >/tmp/final-adapter.ndjson; \
    grep -Fq '"language":"gleam"' /tmp/final-adapter.ndjson; \
    grep -Fq '"type":"closed"' /tmp/final-adapter.ndjson
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
