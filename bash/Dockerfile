# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG ALPINE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
FROM ${ALPINE} AS test
RUN apk add --no-cache bash=5.2.37-r0 jq=1.8.1-r0 openssl=3.5.7-r0 socat=1.8.1.3-r0 ca-certificates=20260611-r0
WORKDIR /opt/convex
COPY client ./client
COPY examples ./examples
RUN printf '%s\n' '#!/bin/sh' 'if test -n "$ADAPTER_LISTEN"; then listen_host=${ADAPTER_LISTEN%:*}; listen_port=${ADAPTER_LISTEN##*:}; exec socat "TCP-LISTEN:$listen_port,bind=$listen_host,reuseaddr" EXEC:"bash /opt/convex/client/tests/conformance/adapter.sh"; fi' 'exec bash /opt/convex/client/tests/conformance/adapter.sh "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter
RUN test "$(uname -m)" = x86_64 && bash -n client/convex.sh client/live.sh client/tests/conformance/adapter.sh client/tests/fixture.sh client/tests/test.sh examples/basics/main.sh && \
 printf '%s\n' '{"protocolVersion":1,"id":"h","op":"hello"}' '{"id":"c","op":"close"}' | CONVEX_URL=http://example.invalid bash client/tests/conformance/adapter.sh | grep -F '"language":"bash"'
RUN bash client/tests/test.sh

FROM ${ALPINE} AS runtime-base
RUN apk add --no-cache bash=5.2.37-r0 jq=1.8.1-r0 busybox=1.37.0-r20 openssl=3.5.7-r0 socat=1.8.1.3-r0 ca-certificates=20260611-r0 && \
 rm -f /sbin/apk /usr/sbin/apk && rm -rf /var/cache/apk
WORKDIR /opt/convex
COPY client ./client
COPY examples ./examples
RUN printf '%s\n' '#!/bin/sh' 'exec bash /opt/convex/examples/basics/main.sh "$@"' > /usr/local/bin/convex-example && \
 printf '%s\n' '#!/bin/sh' 'if test -n "$ADAPTER_LISTEN"; then listen_host=${ADAPTER_LISTEN%:*}; listen_port=${ADAPTER_LISTEN##*:}; exec socat "TCP-LISTEN:$listen_port,bind=$listen_host,reuseaddr" EXEC:"bash /opt/convex/client/tests/conformance/adapter.sh"; fi' 'exec bash /opt/convex/client/tests/conformance/adapter.sh "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-example /usr/local/bin/convex-adapter
USER 65532:65532
FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
