# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM --platform=linux/amd64 ocaml/opam:debian-ocaml-5.2@sha256:c1a66243d2d5203eed3071a889c2dfbacf6503e3cab63daebdf3f9b62f54e597 AS build
WORKDIR /src
USER opam
RUN test "$(uname -m)" = x86_64
RUN opam install dune.3.17.2 yojson.2.2.2 ssl.0.7.0 ocamlformat.0.27.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends file && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN chown -R opam:opam /src
USER opam
# `dune build @fmt` checks formatting and fails on a diff. It is deliberately
# not --auto-promote: promoting would rewrite the source inside the container
# and leave the checked-in file, which the README and website display, unchecked.
RUN \
    opam install ./client --deps-only --with-test && \
    cp examples/basics/main.ml client/example_main.ml && \
    cd client && \
    opam exec -- dune build @fmt && \
    opam exec -- dune runtest && \
    opam exec -- dune build tests/conformance/main.exe example_main.exe
USER root
RUN \
    cp client/_build/default/tests/conformance/main.exe /out-adapter && \
    cp client/_build/default/example_main.exe /out-example && \
    file /out-adapter | grep -E 'ELF 64-bit.*x86-64' && \
    file /out-example | grep -E 'ELF 64-bit.*x86-64'

FROM build AS test
RUN /out-adapter <<'EOF'
{"protocolVersion":1,"id":"hello","op":"hello"}
{"id":"close","op":"close"}
EOF

FROM --platform=linux/amd64 debian@sha256:34cd9e9fd437c0a095ec39cb2e73422c9f30821b0d0848ed74fd0d43bae4d958 AS runtime-base
# apt-get install completes, including every postinst hook the ca-certificates
# package runs, before any of this image's own cleanup begins. Debian's base
# rootfs carries perl-base regardless of what gets installed on top of it, and
# nothing in this image's entrypoint is a perl script, so it is deleted here
# by file rather than through apt: purging an Essential package can refuse or
# cascade, and dpkg is being removed in the same layer anyway and will never
# run again to care whether its database still agrees with the filesystem.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 libffi8 && \
    rm -rf /var/lib/apt/lists/* /usr/bin/apt* /usr/bin/dpkg* /usr/sbin/update-ca-certificates && \
    rm -rf /usr/bin/perl* /usr/lib/*/perl* /usr/share/perl* /etc/perl \
           /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
           /var/lib/dpkg /var/cache/debconf && \
    groupadd --system --gid 65532 convex && useradd --system --uid 65532 --gid 65532 --no-create-home convex
USER 65532:65532
# The build stage working proves nothing about the minimal image: it has its own
# library closure, CA bundle, and user. Prove those here rather than discovering
# a missing shared object during hosted verification.
RUN test "$(uname -m)" = x86_64 \
    && test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s /etc/ssl/certs/ca-certificates.crt \
    && for command_name in ocaml ocamlfind ocamlopt dune opam gcc cc clang make \
         cmake apt apt-get dpkg curl wget node python python3 npm pip convex \
         perl perl5 cpan; do \
         ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
       done

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
# Run the real entrypoint. Without CONVEX_URL it must fail loudly on stderr and
# print nothing on stdout, which also proves its shared libraries resolve here.
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter \
    && code=0 \
    && /usr/local/bin/convex-example >/tmp/example.out 2>/tmp/example.err || code=$? \
    && test "$code" -ne 0 \
    && test ! -s /tmp/example.out \
    && grep -Fq 'CONVEX_URL is required' /tmp/example.err
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last so the default build target is the conformance runtime.
FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
