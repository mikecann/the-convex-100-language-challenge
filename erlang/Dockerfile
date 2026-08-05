# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ELIXIR_IMAGE=elixir:1.17.3-otp-26-alpine@sha256:7d6fcd52aba8170560b39ca5852759acc1aacf6d10290ae668a0a49602a04f8b

FROM --platform=$TARGETPLATFORM ${ELIXIR_IMAGE} AS build
WORKDIR /app
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"
COPY client/mix.exs client/mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get && mix deps.compile
COPY client/*.erl ./src/
COPY client/tests/conformance/*.erl ./src/
COPY examples/basics/main.erl ./src/
COPY client/tests/*.erl ./src/
RUN test "$(uname -m)" = x86_64 && erl -noshell -eval 'true = lists:prefix("x86_64", erlang:system_info(system_architecture)), halt().'
RUN mkdir -p core-ebin adapter-ebin example-ebin test-ebin && erlc -Werror -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -o core-ebin src/convex.erl src/convex_json.erl src/live.erl && erlc -Werror -pa core-ebin -pa _build/dev/lib/jsx/ebin -o adapter-ebin src/adapter.erl && erlc -Werror -pa core-ebin -pa _build/dev/lib/jsx/ebin -o example-ebin src/main.erl && erlc -DTEST -Werror -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -o test-ebin src/*.erl
RUN erl -noshell -pa test-ebin -pa _build/dev/lib/jsx/ebin -s codec_test main -s init stop
RUN erl -noshell -pa test-ebin -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -s live_socket_test main -s init stop
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | erl -noshell -pa core-ebin -pa adapter-ebin -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -s adapter main -s init stop >/tmp/adapter.ndjson && grep -Fq '"language":"erlang"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
RUN set -eu; adapter() { erl -noshell -pa core-ebin -pa adapter-ebin -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -s adapter main -s init stop; }; printf '%s' '{"id":"partial","op":"close"}' | adapter >/tmp/partial.ndjson; test ! -s /tmp/partial.ndjson; printf '%s\n' '{]' '{"op":"close"}' '{"id":"bad-query","op":"query","path":"demo:state"}' '{"id":"close","op":"close"}' | adapter >/tmp/malformed.ndjson; test "$(grep -c '"name":"ProtocolError"' /tmp/malformed.ndjson)" -eq 3; grep -Fq '"type":"closed"' /tmp/malformed.ndjson; (head -c 1048577 /dev/zero | tr '\000' x; printf '\n%s\n' '{"id":"close","op":"close"}') | adapter >/tmp/oversized.ndjson; grep -Fq '"name":"ProtocolError"' /tmp/oversized.ndjson; grep -Fq '"type":"closed"' /tmp/oversized.ndjson

FROM build AS test
CMD ["/bin/true"]

FROM --platform=$TARGETPLATFORM ${ELIXIR_IMAGE} AS target-erlang-runtime

FROM alpine:3.22@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6 AS runtime-base
RUN apk add --no-cache ca-certificates=20260611-r0 libcrypto3=3.5.7-r0 libssl3=3.5.7-r0 libstdc++=14.2.0-r6 ncurses-libs=6.5_p20250503-r0 dash=0.5.12-r3 coreutils=9.7-r1 diffutils=3.12-r0 grep=3.12-r0 sed=4.9-r2 mawk=1.3.4-r11
# The BEAM emulator and its two runtime helpers are sufficient for this
# non-distributed client. Compiler commands, static libraries, headers,
# dialyzer, epmd, escript, and the rest of the ERTS development tree stay out.
COPY --from=target-erlang-runtime /usr/local/lib/erlang/erts-14.2.5.15/bin/beam.smp /usr/local/lib/erlang/erts-14.2.5.15/bin/beam.smp
COPY --from=target-erlang-runtime /usr/local/lib/erlang/erts-14.2.5.15/bin/erl_child_setup /usr/local/lib/erlang/erts-14.2.5.15/bin/erl_child_setup
COPY --from=target-erlang-runtime /usr/local/lib/erlang/erts-14.2.5.15/bin/erlexec /usr/local/lib/erlang/erts-14.2.5.15/bin/erlexec
COPY --from=target-erlang-runtime /usr/local/lib/erlang/erts-14.2.5.15/bin/inet_gethost /usr/local/lib/erlang/erts-14.2.5.15/bin/inet_gethost
COPY --from=target-erlang-runtime /usr/local/lib/erlang/bin/erl /usr/local/lib/erlang/bin/erl
COPY --from=target-erlang-runtime /usr/local/lib/erlang/bin/start.boot /usr/local/lib/erlang/bin/start.boot
# OTP applications contribute only BEAM bytecode and the two NIF directories
# that certificate parsing and cryptography load at runtime. SASL is not in the
# application closure for inets, ssl, Gun, Cowlib, or JSX.
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/asn1-5.2.2.1/ebin /usr/local/lib/erlang/lib/asn1-5.2.2.1/ebin
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/asn1-5.2.2.1/priv/lib /usr/local/lib/erlang/lib/asn1-5.2.2.1/priv/lib
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/crypto-5.4.2.4/ebin /usr/local/lib/erlang/lib/crypto-5.4.2.4/ebin
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/crypto-5.4.2.4/priv/lib/crypto.so /usr/local/lib/erlang/lib/crypto-5.4.2.4/priv/lib/crypto.so
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/crypto-5.4.2.4/priv/lib/crypto_callback.so /usr/local/lib/erlang/lib/crypto-5.4.2.4/priv/lib/crypto_callback.so
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/inets-9.1.0.7/ebin /usr/local/lib/erlang/lib/inets-9.1.0.7/ebin
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/kernel-9.2.4.11/ebin /usr/local/lib/erlang/lib/kernel-9.2.4.11/ebin
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/public_key-1.15.1.7/ebin /usr/local/lib/erlang/lib/public_key-1.15.1.7/ebin
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/ssl-11.1.4.13/ebin /usr/local/lib/erlang/lib/ssl-11.1.4.13/ebin
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/stdlib-5.2.3.6/ebin /usr/local/lib/erlang/lib/stdlib-5.2.3.6/ebin
RUN ln -s ../lib/erlang/bin/erl /usr/local/bin/erl
COPY --from=build /app/core-ebin /opt/convex
# Only BEAM bytecode and application metadata are runtime inputs. Sources,
# headers, package manifests, and build products stay in the build stage.
COPY --from=build /app/_build/dev/lib/gun/ebin /opt/convex/deps/gun/ebin
COPY --from=build /app/_build/dev/lib/cowlib/ebin /opt/convex/deps/cowlib/ebin
COPY --from=build /app/_build/dev/lib/jsx/ebin /opt/convex/deps/jsx/ebin
# Stock Alpine BusyBox contains wget and nc even when their symlinks are
# removed, because callers can select applets through argv[0] or the multicall
# command. Install a separate shell and text tools, then remove every BusyBox
# link and the multicall binary itself from the final filesystem.
RUN ln -sf /usr/bin/dash /bin/sh && for path in /bin/* /sbin/* /usr/bin/* /usr/sbin/*; do if test -L "$path"; then target=$(readlink "$path"); case "$target" in *busybox*) rm -f "$path" ;; esac; fi; done && ln -sf /usr/bin/mawk /usr/bin/awk && rm -f /bin/busybox /sbin/apk && rm -rf /etc/apk /lib/apk /var/cache/apk /var/lib/apk /usr/share/apk
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1" ERL_LIBS=/opt/convex/deps
USER 65532:65532
RUN set -eu; for command in sh id cat cmp cut grep head sed sort tail tr awk erl; do command -v "$command" >/dev/null; done; for command in busybox wget nc netcat apk elixir elixirc iex mix hex rebar rebar3 erlc cc gcc clang make node npm python python3 curl convex openssl; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done; test ! -e /bin/busybox; test ! -e /usr/local/lib/erlang/erts-14.2.5.15/bin/erlc; erl -noshell -pa /opt/convex -eval '{ok, _} = application:ensure_all_started(inets), {ok, _} = application:ensure_all_started(ssl), {ok, _} = application:ensure_all_started(gun), <<_:8>> = crypto:strong_rand_bytes(1), halt().'

FROM runtime-base AS example-runtime
COPY --from=build /app/example-ebin /opt/convex
COPY --chmod=0555 examples/basics/entrypoint.sh /usr/local/bin/convex-example
RUN test -f /opt/convex/main.beam && test ! -e /opt/convex/adapter.beam && test ! -e /opt/convex/codec_test.beam && test ! -e /opt/convex/live_socket_test.beam
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /app/adapter-ebin /opt/convex
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
RUN test -f /opt/convex/adapter.beam && test ! -e /opt/convex/main.beam && test ! -e /opt/convex/codec_test.beam && test ! -e /opt/convex/live_socket_test.beam
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
