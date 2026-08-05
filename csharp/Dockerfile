# syntax=docker/dockerfile:1.7
ARG SDK=mcr.microsoft.com/dotnet/sdk:8.0.408-bookworm-slim@sha256:8ab06772f296ed5f541350334f15d9e2ce84ad4b3ce70c90f2e43db2752c30f6
ARG RUNTIME=mcr.microsoft.com/dotnet/runtime:8.0.15-bookworm-slim@sha256:72f6af5666200b0005738f8637bb1bb4e5fee3a0dbffdba7cd4eacaf526d03c2
FROM --platform=linux/amd64 ${SDK} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md
RUN dotnet build client/Convex.csproj -c Release -warnaserror && \
    dotnet build client/tests/conformance/Adapter.csproj -c Release -warnaserror && \
    dotnet build examples/basics/Example.csproj -c Release -warnaserror && \
    dotnet publish client/tests/conformance/Adapter.csproj -c Release -o /out/adapter --no-self-contained && \
    dotnet publish examples/basics/Example.csproj -c Release -o /out/example --no-self-contained && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | dotnet /out/adapter/Adapter.dll | grep -q '"language":"csharp"' && \
    test "$(uname -m)" = x86_64 && dotnet --info | grep -q 'Architecture: *x64'
CMD ["/bin/sh", "-ec", "dotnet --info >/dev/null; test \"$(uname -m)\" = x86_64"]

FROM --platform=linux/amd64 ${RUNTIME} AS runtime-base
RUN mkdir -p /opt/convex /usr/local/bin && \
    for command in dotnet-sdk msbuild csc fsc nuget npm npx node python python3 pip pip3 curl convex; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done && \
    ! dotnet build --help >/dev/null 2>&1
USER 65532:65532

FROM runtime-base AS adapter-runtime-files
COPY --from=test /out/adapter /opt/convex/adapter
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/adapter/Adapter.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]

FROM runtime-base AS example-runtime
COPY --from=test /out/example /opt/convex/example
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-example
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/example/Example.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter stage last: `./run build` builds Docker's default target.
FROM runtime-base AS runtime
COPY --from=test /out/adapter /opt/convex/adapter
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/adapter/Adapter.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
