# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG GCC_IMAGE=gcc:14.2.0-bookworm@sha256:82549aa8f90ada3236a8be70c74543132a76662ef33f0c3271ed802b81584a82
FROM --platform=linux/amd64 ${GCC_IMAGE} AS test
WORKDIR /work
RUN apt-get update && apt-get install -y --no-install-recommends libboost-dev=1.74.0.3 nlohmann-json3-dev=3.11.2-2 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 && test "$(g++ -dumpmachine | cut -d- -f1)" = x86_64
RUN mkdir -p /out && g++ -std=c++20 -Wall -Wextra -Werror -pedantic -DCONVEX_ADAPTER_BUILD -Iclient client/convex.cpp client/live.cpp client/tests/conformance/adapter.cpp -lssl -lcrypto -lpthread -o /out/convex-adapter
RUN g++ -std=c++20 -Wall -Wextra -Werror -pedantic -Iclient client/tests/conformance/adapter_live_process_test.cpp -lssl -lcrypto -lpthread -o /tmp/adapter-live-process-test && timeout 30s /tmp/adapter-live-process-test
RUN g++ -std=c++20 -Wall -Wextra -Werror -pedantic -Iclient client/convex.cpp client/live.cpp client/tests/client_test.cpp -lssl -lcrypto -lpthread -o /tmp/client-test && /tmp/client-test
RUN g++ -std=c++20 -Wall -Wextra -Werror -pedantic -Iclient client/tests/api_surface_test.cpp -o /tmp/api-surface-test && /tmp/api-surface-test
RUN g++ -std=c++20 -Wall -Wextra -Werror -pedantic -DCONVEX_ADAPTER_BUILD -DCONVEX_CLIENT_TESTING -Iclient client/convex.cpp client/live.cpp client/tests/live_test.cpp -lssl -lcrypto -lpthread -o /tmp/live-test && /tmp/live-test
RUN g++ -std=c++20 -Wall -Wextra -Werror -pedantic -Iclient client/convex.cpp client/live.cpp examples/basics/main.cpp -lssl -lcrypto -lpthread -o /out/convex-example
RUN g++ -std=c++20 -Wall -Wextra -Werror -pedantic -DCONVEX_ADAPTER_BUILD -Iclient -Iclient/tests/conformance client/convex.cpp client/live.cpp client/tests/conformance/adapter_integration_test.cpp -lssl -lcrypto -lpthread -o /tmp/adapter-integration-test && /tmp/adapter-integration-test
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | /out/convex-adapter >/tmp/events && grep -Fq '"language":"cpp"' /tmp/events && grep -Fq '"type":"closed"' /tmp/events
# The adapter accepts one TCP controller and runs exactly the same NDJSON
# lifecycle over that socket as it does over stdin/stdout.
RUN bash -ec '(ADAPTER_LISTEN=127.0.0.1:45678 /out/convex-adapter >/tmp/tcp.out 2>/tmp/tcp.err &) ; sleep 1; exec 3<>/dev/tcp/127.0.0.1/45678; printf "%s\\n" "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}" >&3; IFS= read -r ready <&3; grep -Fq "\"language\":\"cpp\"" <<<"$ready"; printf "%s\\n" "{\"id\":\"close\",\"op\":\"close\"}" >&3; IFS= read -r closed <&3; grep -Fq "\"type\":\"closed\"" <<<"$closed"'
CMD ["/bin/sh", "-c", "true"]

FROM test AS runtime-rootfs
RUN set -eu; root=/rootfs; mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" "$root/etc"; cp /bin/dash "$root/bin/sh"; cp /usr/bin/id "$root/usr/bin/id"; cp /usr/bin/grep "$root/usr/bin/grep"; cp /out/convex-example "$root/usr/local/bin/convex-example"; cp /out/convex-adapter "$root/usr/local/bin/convex-adapter"; { ldd /bin/dash /usr/bin/id /usr/bin/grep /out/convex-example /out/convex-adapter; } | awk '$3 ~ /^\// {print $3} $1 ~ /^\// {name=$1; sub(/:$/, "", name); print name}' | sort -u | xargs -r -I{} cp --parents {} "$root"; cp -a /etc/ssl "$root/etc/ssl"; cp /etc/nsswitch.conf "$root/etc/nsswitch.conf"; cp /etc/hosts "$root/etc/hosts"
FROM scratch AS runtime-base
COPY --from=runtime-rootfs /rootfs /
USER 65532:65532
FROM runtime-base AS example-runtime
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
