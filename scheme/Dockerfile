# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       guile-3.0=3.0.8-2 guile-json=4.7.3-2 ca-certificates=20230311+deb12u1 \
    && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 \
    && guile --version | head -1 | grep -Fqx 'guile (GNU Guile) 3.0.8' \
    && guile -L client client/tests/http.scm \
    && printf '%s\n%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
       | guile -L client client/tests/conformance/adapter.scm \
       | grep -Fqx '{"id":"close","type":"closed"}'

# The image is intentionally test-only until the Live runtime entrypoints exist.
# A final runtime would need a direct Scheme RFC 6455 implementation plus the
# audited Guile/GnuTLS closure, then it can replace this explicit failing target.
FROM test AS runtime
RUN false
