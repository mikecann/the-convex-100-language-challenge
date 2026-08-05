# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG ELIXIR_IMAGE=elixir:1.17.3-otp-26-alpine@sha256:7d6fcd52aba8170560b39ca5852759acc1aacf6d10290ae668a0a49602a04f8b

FROM --platform=$BUILDPLATFORM ${ELIXIR_IMAGE} AS dependencies
WORKDIR /app
ENV MIX_ENV=prod
# Keep native BUILDPLATFORM compilation deterministic and conservative. The
# resulting dependency BEAM files are portable and run under target ERTS later.
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"
RUN mix local.hex --force && mix local.rebar --force
COPY client/mix.exs client/mix.lock ./
RUN mix deps.get --only prod
# Compile each dependency in a fresh native BEAM VM to avoid compiler-state
# instability when several dependency projects share one compilation process.
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
COPY client/tests/conformance/*_test.exs ./test/conformance/
COPY examples/basics/main_test.exs ./test/example_test.exs
COPY client/.formatter.exs ./

FROM source AS test-build
ENV MIX_ENV=test
RUN mix deps.get
RUN mix deps.compile castore
RUN mix deps.compile cowlib
RUN mix deps.compile gun
RUN mix deps.compile jason
RUN mix format --check-formatted
RUN mix compile --warnings-as-errors
# Mix normally compiles `.exs` tests while starting the test runner. That
# compiler path is unreliable under amd64 QEMU on Apple Silicon, so compile the
# exact test modules here and persist their portable BEAM bytecode plus a module
# manifest for the target-platform runner below.
RUN mix run --no-start -e 'ExUnit.start(autorun: false); output = "_build/test/lib/convex_client/ebin"; modules = Path.wildcard("test/**/*_test.exs") |> Enum.flat_map(fn path -> Code.compile_file(path) end) |> Enum.map(fn {module, bytecode} -> File.write!(Path.join(output, Atom.to_string(module) <> ".beam"), bytecode); module end); File.write!("_build/test/precompiled_test_modules", :erlang.term_to_binary(modules))'

# BEAM files produced above are architecture-independent. Execute the checks
# and every ExUnit test again with the pinned target-platform Elixir and ERTS,
# so an amd64-labelled test image can never contain arm64 test evidence.
FROM --platform=$TARGETPLATFORM ${ELIXIR_IMAGE} AS test
WORKDIR /app
ENV MIX_ENV=test
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1"
COPY --from=test-build /app /app
COPY --from=test-build /root/.mix /root/.mix
RUN test "$(uname -m)" = "x86_64" && \
    elixir -e 'architecture = :erlang.system_info(:system_architecture) |> List.to_string(); unless String.starts_with?(architecture, "x86_64"), do: raise("expected x86_64 ERTS, got #{architecture}")'
RUN mix format --check-formatted
RUN mix compile --warnings-as-errors
RUN mix run --no-start --no-compile --no-deps-check -e 'ExUnit.start(autorun: false); modules = "_build/test/precompiled_test_modules" |> File.read!() |> :erlang.binary_to_term([:safe]); Enum.each(modules, &Code.ensure_loaded!/1); results = ExUnit.run(modules); System.halt(if results.failures == 0, do: 0, else: 1)'
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
# The installed shared libraries are immutable runtime inputs. Remove Alpine's
# installer and its database, repositories, keys, cache, and helper data so the
# unprivileged final process cannot treat this image as a package environment.
RUN rm -f /sbin/apk && \
    rm -rf /etc/apk /lib/apk /var/cache/apk /var/lib/apk /usr/share/apk
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
# This educational client runs as one foreground process. Avoid the distributed
# node and its epmd sidecar, and keep one scheduler so the canonical example
# stays comfortably inside the shared verification resource limits.
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1" \
    RELEASE_DISTRIBUTION=none
USER 65532:65532
# Prove the final runtime keeps the POSIX tools used by shared verification,
# exposes no package/build frontends, and can boot the real adapter release to
# a clean EOF-driven shutdown as the same unprivileged user used in production.
RUN set -eu; \
    for required in sh id grep erl; do command -v "$required" >/dev/null; done; \
    for forbidden in apk elixir elixirc iex mix hex rebar rebar3 erlc cc gcc clang make node npm python python3 curl convex; do \
      if command -v "$forbidden" >/dev/null 2>&1; then exit 1; fi; \
    done; \
    test ! -e /sbin/apk; \
    test ! -e /etc/apk; \
    test ! -e /lib/apk; \
    test ! -e /var/cache/apk; \
    test ! -e /usr/share/apk; \
    CONVEX_ENTRYPOINT=adapter CONVEX_URL=http://127.0.0.1 /opt/convex/bin/convex_client start </dev/null

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/entrypoint.sh /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
