# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ELIXIR_IMAGE=elixir:1.17.3-otp-26-alpine@sha256:7d6fcd52aba8170560b39ca5852759acc1aacf6d10290ae668a0a49602a04f8b

FROM --platform=$TARGETPLATFORM ${ELIXIR_IMAGE} AS build
WORKDIR /app
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"
COPY client/mix.exs mix.exs
RUN mix local.hex --force && mix local.rebar --force && mix deps.get && mix deps.compile
COPY client/*.erl ./src/
COPY client/tests/conformance/*.erl ./src/
COPY examples/basics/main.erl ./src/
COPY client/tests/codec_test.erl ./src/
RUN test "$(uname -m)" = x86_64 && erl -noshell -eval 'true = lists:prefix("x86_64", erlang:system_info(system_architecture)), halt().'
RUN mkdir -p ebin && erlc -Werror -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -o ebin src/*.erl
RUN erl -noshell -pa ebin -pa _build/dev/lib/jsx/ebin -s codec_test main -s init stop
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | erl -noshell -pa ebin -pa _build/dev/lib/jsx/ebin -pa _build/dev/lib/gun/ebin -pa _build/dev/lib/cowlib/ebin -s adapter main -s init stop >/tmp/adapter.ndjson && grep -Fq '"language":"erlang"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson

FROM build AS test
CMD ["/bin/true"]

FROM --platform=$TARGETPLATFORM ${ELIXIR_IMAGE} AS target-erlang-runtime

FROM alpine:3.22@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6 AS runtime-base
RUN apk add --no-cache ca-certificates=20260611-r0 libstdc++=14.2.0-r6 ncurses-libs=6.5_p20250503-r0 openssl=3.5.7-r0
COPY --from=target-erlang-runtime /usr/local/lib/erlang/erts-14.2.5.15 /usr/local/lib/erlang/erts-14.2.5.15
COPY --from=target-erlang-runtime /usr/local/lib/erlang/bin/erl /usr/local/lib/erlang/bin/erl
COPY --from=target-erlang-runtime /usr/local/lib/erlang/bin/start.boot /usr/local/lib/erlang/bin/start.boot
COPY --from=target-erlang-runtime /usr/local/lib/erlang/bin/start.script /usr/local/lib/erlang/bin/start.script
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/asn1-5.2.2.1 /usr/local/lib/erlang/lib/asn1-5.2.2.1
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/crypto-5.4.2.4 /usr/local/lib/erlang/lib/crypto-5.4.2.4
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/inets-9.1.0.7 /usr/local/lib/erlang/lib/inets-9.1.0.7
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/kernel-9.2.4.11 /usr/local/lib/erlang/lib/kernel-9.2.4.11
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/public_key-1.15.1.7 /usr/local/lib/erlang/lib/public_key-1.15.1.7
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/sasl-4.2.1 /usr/local/lib/erlang/lib/sasl-4.2.1
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/ssl-11.1.4.13 /usr/local/lib/erlang/lib/ssl-11.1.4.13
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/stdlib-5.2.3.6 /usr/local/lib/erlang/lib/stdlib-5.2.3.6
RUN ln -s ../lib/erlang/bin/erl /usr/local/bin/erl
COPY --from=build /app/ebin /opt/convex
COPY --from=build /app/_build/dev/lib/gun /opt/convex/deps/gun
COPY --from=build /app/_build/dev/lib/cowlib /opt/convex/deps/cowlib
COPY --from=build /app/_build/dev/lib/jsx /opt/convex/deps/jsx
RUN rm -f /sbin/apk && rm -rf /etc/apk /lib/apk /var/cache/apk /var/lib/apk /usr/share/apk
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1" ERL_LIBS=/opt/convex/deps
USER 65532:65532
RUN set -eu; for command in sh id grep erl; do command -v "$command" >/dev/null; done; for command in apk elixir elixirc iex mix hex rebar rebar3 erlc cc gcc clang make node npm python python3 curl convex; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done; erl -noshell -pa /opt/convex -eval 'application:ensure_all_started(gun), halt().'

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/entrypoint.sh /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
