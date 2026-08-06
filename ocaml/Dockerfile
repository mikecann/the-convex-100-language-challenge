# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM ocaml/opam:debian-ocaml-5.2@sha256:c1a66243d2d5203eed3071a889c2dfbacf6503e3cab63daebdf3f9b62f54e597 AS build
WORKDIR /src
USER opam
RUN opam install dune.3.17.2 yojson.2.2.2 ssl.0.7.0 ocamlformat.0.27.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends file && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN chown -R opam:opam /src
USER opam
RUN \
    opam install ./client --deps-only --with-test && \
    cp examples/basics/main.ml client/example_main.ml && \
    cd client && \
    opam exec -- dune build @fmt --auto-promote && \
    opam exec -- dune runtest && \
    opam exec -- dune build tests/conformance/main.exe example_main.exe
USER root
RUN \
    cp client/_build/default/tests/conformance/main.exe /out-adapter && \
    cp client/_build/default/example_main.exe /out-example && \
    file /out-adapter | grep -E 'x86-64|x86-64,.*dynamically linked'

FROM build AS test
RUN /out-adapter <<'EOF'
{"protocolVersion":1,"id":"hello","op":"hello"}
{"id":"close","op":"close"}
EOF

FROM debian@sha256:34cd9e9fd437c0a095ec39cb2e73422c9f30821b0d0848ed74fd0d43bae4d958 AS runtime-base
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 libffi8 && \
    rm -rf /var/lib/apt/lists/* /usr/bin/apt* /usr/bin/dpkg* /usr/sbin/update-ca-certificates && \
    groupadd --system --gid 65532 convex && useradd --system --uid 65532 --gid 65532 --no-create-home convex
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
