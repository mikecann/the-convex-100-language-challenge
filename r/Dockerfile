# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# R's interpreter is the declared target runtime. The three ordinary packages
# are pinned below and supply only TLS/HTTP, JSON, and WebSocket primitives.
ARG R_IMAGE=rocker/r-ver:4.5.1@sha256:03b023fbf7b1b24ac1bb8b2ac5fd7e15a767e67b40ff50c155e328110981c2aa
FROM ${R_IMAGE} AS test
WORKDIR /work
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4-openssl-dev libssl-dev libz-dev make g++ ca-certificates && rm -rf /var/lib/apt/lists/*
RUN R -q -e 'install.packages(c("curl", "jsonlite", "websocket"), repos="https://packagemanager.posit.co/cran/__linux__/noble/latest")'
COPY client ./client
COPY examples ./examples
RUN Rscript -e 'for (f in c(list.files("client", recursive=TRUE, full.names=TRUE, pattern="\\.R$"), list.files("examples", recursive=TRUE, full.names=TRUE, pattern="\\.R$"))) parse(f)'
RUN Rscript client/tests/client_test.R
RUN Rscript examples/basics/main_test.R
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | CONVEX_CLIENT_PATH=/work/client Rscript client/tests/conformance/adapter.R
CMD ["Rscript", "-e", "quit(status=0)"]

FROM test AS runtime-base
# Keep the runtime interpreter and its libraries, but remove package managers,
# compilers, and build headers after package installation.
RUN rm -f /usr/bin/apt /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/dpkg /usr/bin/g++ /usr/bin/gcc /usr/bin/cc /usr/bin/make && \
    find /usr/lib/R -type f \( -name 'Rcmd' -o -name 'INSTALL' \) -delete || true
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV TMPDIR=/dev/shm
COPY client /opt/convex/client
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.R /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.R /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
