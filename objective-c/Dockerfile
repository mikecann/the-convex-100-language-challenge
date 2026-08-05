# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM --platform=linux/amd64 alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS build
RUN apk add --no-cache build-base=0.5-r3 gcc-objc=14.2.0-r6 clang19=19.1.7-r6 clang19-extra-tools=19.1.7-r6 libobjc=14.2.0-r6 curl-dev=8.14.1-r3 json-c-dev=0.18-r1
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN /usr/lib/llvm19/bin/clang-format --style=LLVM -i client/ConvexClient.m client/ConvexClient.h client/tests/conformance/main.m client/tests/live_test.m examples/basics/main.m && \
    /usr/lib/llvm19/bin/clang -fobjc-runtime=gcc -I/usr/lib/gcc/x86_64-alpine-linux-musl/14.2.0/include -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m client/tests/conformance/main.m -lcurl -ljson-c -lobjc -o /out-adapter && \
    /usr/lib/llvm19/bin/clang -fobjc-runtime=gcc -I/usr/lib/gcc/x86_64-alpine-linux-musl/14.2.0/include -DCONVEX_ADAPTER_TESTING -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m client/tests/conformance/main.m -lcurl -ljson-c -lobjc -o /out-adapter-test && \
    /usr/lib/llvm19/bin/clang -fobjc-runtime=gcc -I/usr/lib/gcc/x86_64-alpine-linux-musl/14.2.0/include -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m examples/basics/main.m -lcurl -ljson-c -lobjc -o /out-example && \
    /usr/lib/llvm19/bin/clang -fobjc-runtime=gcc -I/usr/lib/gcc/x86_64-alpine-linux-musl/14.2.0/include -DCONVEX_CLIENT_TESTING -D_POSIX_C_SOURCE=200809L -std=c17 -Wall -Wextra -Werror -pthread -Iclient client/ConvexClient.m client/tests/live_test.m -lcurl -ljson-c -lobjc -lcrypto -o /out-live-test && file /out-adapter | grep 'x86-64'
FROM build AS test
RUN <<'EOF'
set -eu
test "$(uname -m)" = x86_64
actual=$(/out-adapter <<'COMMANDS'
{malformed
{"id":"hello","protocolVersion":1,"op":"hello"}
{"id":"unknown","op":"notAnOperation"}
{"id":"close","op":"close"}
COMMANDS
)
printf '%s\n' "$actual" | grep -Fx '{"type":"error","error":{"name":"ProtocolError","message":"malformed adapter command"}}'
printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready"'
printf '%s\n' "$actual" | grep -Fx '{"type":"error","id":"unknown","error":{"name":"ProtocolError","message":"unknown adapter operation"}}'
printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
EOF
RUN /out-live-test
FROM --platform=linux/amd64 alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS runtime-base
RUN apk add --no-cache libcurl=8.14.1-r3 json-c=0.18-r1 libobjc=14.2.0-r6 ca-certificates=20260611-r0 && rm -f /sbin/apk
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
