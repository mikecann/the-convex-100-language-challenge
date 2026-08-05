# syntax=docker/dockerfile:1.7
ARG SDK=mcr.microsoft.com/dotnet/sdk:8.0.408-bookworm-slim@sha256:8ab06772f296ed5f541350334f15d9e2ce84ad4b3ce70c90f2e43db2752c30f6
ARG RUNTIME=mcr.microsoft.com/dotnet/runtime:8.0.15-bookworm-slim@sha256:72f6af5666200b0005738f8637bb1bb4e5fee3a0dbffdba7cd4eacaf526d03c2

FROM --platform=linux/amd64 ${SDK} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md
RUN dotnet build client/Convex.vbproj -c Release -warnaserror && \
    dotnet build client/tests/conformance/Adapter.vbproj -c Release -warnaserror && \
    dotnet build client/tests/VisualBasicDotNetTests.vbproj -c Release -warnaserror && \
    dotnet build examples/basics/Example.vbproj -c Release -warnaserror && \
    dotnet build examples/basics/tests/ExampleTests.vbproj -c Release -warnaserror && \
    dotnet run --project client/tests/VisualBasicDotNetTests.vbproj -c Release --no-build && \
    dotnet run --project examples/basics/tests/ExampleTests.vbproj -c Release --no-build && \
    dotnet publish client/tests/conformance/Adapter.vbproj -c Release -o /out/adapter --no-self-contained && \
    dotnet publish examples/basics/Example.vbproj -c Release -o /out/example --no-self-contained && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | dotnet /out/adapter/Adapter.dll | grep -q '"language":"visual-basic-dotnet"' && \
    test "$(uname -m)" = x86_64 && dotnet --info | grep -q 'Architecture: *x64'
CMD ["/bin/sh", "-ec", "dotnet --info >/dev/null; test \"$(uname -m)\" = x86_64"]

FROM --platform=linux/amd64 ${RUNTIME} AS runtime-base
RUN mkdir -p /opt/convex /usr/local/bin && \
    for command in dotnet-sdk msbuild vbc csc fsc nuget npm npx node python python3 pip pip3 curl convex; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done && \
    ! dotnet build --help >/dev/null 2>&1
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /out/example /opt/convex/example
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-example
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/example/Example.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter target last because ./run build uses Docker's default target.
FROM runtime-base AS runtime
COPY --from=test /out/adapter /opt/convex/adapter
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/adapter/Adapter.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
