# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG NIM_IMAGE=nimlang/nim:2.2.4@sha256:5c7c425b6060830de60b99bd9436b8e1a17931912b629dafc71240b18ae1eb26
FROM --platform=linux/amd64 ${NIM_IMAGE} AS build
WORKDIR /src
ADD --checksum=sha256:d4f66d6f840084738e04eda36763f5a1badb2ddf5522cdae28d587035d39e1e2 https://github.com/treeform/ws/archive/refs/tags/0.6.0.tar.gz /tmp/ws.tgz
RUN tar -xzf /tmp/ws.tgz -C /opt
COPY client ./client
COPY examples ./examples
RUN perl /src/client/patch-ws.pl /opt/ws-0.6.0/src/ws.nim && \
    grep -F 'Convex-Client' /opt/ws-0.6.0/src/ws.nim
RUN ulimit -s 65536 && \
    test "$(uname -m)" = x86_64 && \
    nim check -d:ssl --threads:on --threadAnalysis:off --mm:orc --path:/opt/ws-0.6.0/src client/convex.nim && \
    nim c -d:ssl -d:convexadapter --threads:on --threadAnalysis:off --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-convex-adapter client/tests/conformance/main.nim && \
    nim c -d:ssl --threads:on --threadAnalysis:off --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-convex-example examples/basics/main.nim && \
    nim c -d:ssl -d:convexadapter --threads:on --threadAnalysis:off --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --path:/opt/ws-0.6.0/src --out:/out-reconnect-test client/tests/conformance/reconnect_test.nim && \
    nim c --threads:on --threadAnalysis:off --mm:orc --passC:-O0 --passC:-fno-var-tracking --passC:-fno-var-tracking-assignments --passL:-O0 --hints:off --warnings:on --styleCheck:hint --out:/out-client-test client/tests/client_test.nim && \
    test -x /out-convex-adapter && test -x /out-convex-example && test -x /out-reconnect-test && test -x /out-client-test

FROM build AS test
  RUN /out-client-test && \
    printf '%s\n' '{"id":"hello","op":"hello","protocolVersion":1}' '{"id":"close","op":"close"}' | /out-convex-adapter | grep -F '"type":"ready"' >/dev/null

FROM --platform=linux/amd64 debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef AS runtime-base
RUN apt-get update && apt-get install --yes --no-install-recommends ca-certificates=20230311+deb12u1 && rm -rf /var/lib/apt/lists/* /usr/bin/apt* /usr/bin/dpkg* /usr/sbin/dpkg* /etc/apt /var/lib/apt /var/lib/dpkg && useradd --uid 65532 --no-create-home --shell /bin/sh app
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=build --chown=65532:65532 --chmod=0555 /out-convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=build --chown=65532:65532 --chmod=0555 /out-convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
