# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG ELIXIR_IMAGE=elixir:1.17.3-otp-26-alpine@sha256:7d6fcd52aba8170560b39ca5852759acc1aacf6d10290ae668a0a49602a04f8b

FROM --platform=$BUILDPLATFORM ${ELIXIR_IMAGE} AS dependencies
WORKDIR /app
ENV MIX_ENV=prod
# A single scheduler avoids QEMU races in compiler protocol consolidation when
# the required amd64 build runs on an Apple Silicon Docker host.
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"
RUN mix local.hex --force && mix local.rebar --force
COPY client/mix.exs client/mix.lock ./
RUN mix deps.get --only prod
# Compile each dependency in a fresh BEAM VM. Elixir's amd64 compiler can keep
# a completed module marked read-only when several projects are compiled in one
# emulated process on Apple Silicon.
RUN mix deps.compile castore
RUN mix deps.compile cowlib
RUN mix deps.compile gun
RUN mix deps.compile jason

FROM dependencies AS source
# Assemble Mix's conventional source tree only inside Docker. The repository
# keeps the client, teaching example, and conformance adapter visibly separate.
COPY client/*.ex ./source/
COPY client/tests/conformance/*.ex ./source/conformance/
COPY examples/basics/main.ex ./source/example.ex
COPY client/test ./test
COPY client/.formatter.exs ./

FROM source AS test
ENV MIX_ENV=test
RUN mix deps.get
RUN mix deps.compile castore
RUN mix deps.compile cowlib
RUN mix deps.compile gun
RUN mix deps.compile jason
RUN mix format --check-formatted
RUN mix compile --warnings-as-errors
RUN mix test
CMD ["/bin/true"]

FROM source AS release-build
ENV MIX_ENV=prod
RUN mix compile --warnings-as-errors
RUN mix release convex_client

FROM --platform=$TARGETPLATFORM ${ELIXIR_IMAGE} AS target-erlang-runtime

FROM alpine:3.22@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6 AS runtime-base
RUN apk add --no-cache \
    ca-certificates=20260611-r0 \
    libstdc++=14.2.0-r6 \
    ncurses-libs=6.5_p20250503-r0 \
    openssl=3.5.7-r0
# Copy only the target-platform Erlang runtime, not Mix, Elixir's compiler
# executable, Hex, Rebar, or the rest of the language build image.
COPY --from=target-erlang-runtime /usr/local/lib/erlang/erts-14.2.5.15 /usr/local/lib/erlang/erts-14.2.5.15
COPY --from=target-erlang-runtime /usr/local/lib/erlang/bin/erl /usr/local/lib/erlang/bin/erl
RUN ln -s ../lib/erlang/bin/erl /usr/local/bin/erl
# A release without bundled ERTS also expects its declared OTP applications.
# Copy only that runtime closure instead of the full Erlang build installation.
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/asn1-5.2.2.1 /usr/local/lib/erlang/lib/asn1-5.2.2.1
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/compiler-8.4.3.4 /usr/local/lib/erlang/lib/compiler-8.4.3.4
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/crypto-5.4.2.4 /usr/local/lib/erlang/lib/crypto-5.4.2.4
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/inets-9.1.0.7 /usr/local/lib/erlang/lib/inets-9.1.0.7
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/kernel-9.2.4.11 /usr/local/lib/erlang/lib/kernel-9.2.4.11
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/public_key-1.15.1.7 /usr/local/lib/erlang/lib/public_key-1.15.1.7
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/sasl-4.2.1 /usr/local/lib/erlang/lib/sasl-4.2.1
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/ssl-11.1.4.13 /usr/local/lib/erlang/lib/ssl-11.1.4.13
COPY --from=target-erlang-runtime /usr/local/lib/erlang/lib/stdlib-5.2.3.6 /usr/local/lib/erlang/lib/stdlib-5.2.3.6
COPY --from=release-build /app/_build/prod/rel/convex_client /opt/convex
ENV ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1"
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/entrypoint.sh /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
