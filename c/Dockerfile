# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS build
RUN apk add --no-cache build-base=0.5-r3 curl-dev=8.14.1-r3 json-c-dev=0.18-r1
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -Iclient client/convex.c client/tests/conformance/main.c -lcurl -ljson-c -o /out-adapter && \
    gcc -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -Iclient client/convex.c examples/basics/main.c -lcurl -ljson-c -o /out-example && \
    file /out-adapter | grep 'x86-64'
FROM build AS test
RUN /out-adapter <<'EOF'
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"close","op":"close"}
EOF
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS runtime-base
RUN apk add --no-cache libcurl=8.14.1-r3 json-c=0.18-r1 ca-certificates=20260611-r0
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
