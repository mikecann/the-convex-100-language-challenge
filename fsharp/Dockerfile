# syntax=docker/dockerfile:1.7
ARG SDK=mcr.microsoft.com/dotnet/sdk:8.0.408-bookworm-slim@sha256:8ab06772f296ed5f541350334f15d9e2ce84ad4b3ce70c90f2e43db2752c30f6
ARG RUNTIME=mcr.microsoft.com/dotnet/runtime:8.0.15-bookworm-slim@sha256:72f6af5666200b0005738f8637bb1bb4e5fee3a0dbffdba7cd4eacaf526d03c2
ARG FANTOMAS_VERSION=6.3.16
FROM --platform=linux/amd64 ${SDK} AS formatter
ARG FANTOMAS_VERSION
RUN dotnet tool install fantomas --tool-path /tools --version ${FANTOMAS_VERSION}
FROM formatter AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN /tools/fantomas --check client examples && \
    dotnet build client/Convex.fsproj -c Release -warnaserror && \
    dotnet build client/tests/conformance/Adapter.fsproj -c Release -warnaserror && \
    dotnet build client/tests/FsharpTests.fsproj -c Release -warnaserror && \
    dotnet build examples/basics/Example.fsproj -c Release -warnaserror && \
    dotnet run --project client/tests/FsharpTests.fsproj -c Release --no-build && \
    dotnet publish client/tests/conformance/Adapter.fsproj -c Release -o /out/adapter --no-self-contained && \
    dotnet publish examples/basics/Example.fsproj -c Release -o /out/example --no-self-contained && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | dotnet /out/adapter/Adapter.dll | grep -q '"language":"fsharp"' && \
    test "$(uname -m)" = x86_64 && dotnet --info | grep -q 'Architecture: *x64'
FROM --platform=linux/amd64 ${RUNTIME} AS runtime-base
RUN rm -f \
      /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark \
      /usr/bin/deb-systemd-helper /usr/bin/deb-systemd-invoke \
      /usr/bin/debconf /usr/bin/debconf-apt-progress /usr/bin/debconf-communicate /usr/bin/debconf-copydb \
      /usr/bin/debconf-escape /usr/bin/debconf-set-selections /usr/bin/debconf-show \
      /usr/bin/dpkg /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper /usr/bin/dpkg-query \
      /usr/bin/dpkg-realpath /usr/bin/dpkg-split /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger \
      /usr/bin/perl /usr/bin/perl5.36.0 /usr/bin/update-alternatives \
      /usr/sbin/dpkg-fsys-usrunmess /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure && \
    mkdir -p /opt/convex /usr/local/bin && \
    for command in apt apt-cache apt-cdrom apt-config apt-get apt-key apt-mark debconf debconf-apt-progress debconf-communicate debconf-copydb debconf-escape debconf-set-selections debconf-show dpkg dpkg-deb dpkg-divert dpkg-maintscript-helper dpkg-query dpkg-realpath dpkg-split dpkg-statoverride dpkg-trigger perl perl5.36.0 update-alternatives dotnet-sdk msbuild csc fsc nuget npm npx node python python3 pip pip3 curl convex; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done && \
    ! dotnet build --help >/dev/null 2>&1
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=test /out/example /opt/convex/example
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-example
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/example/Example.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]
FROM runtime-base AS runtime
COPY --from=test /out/adapter /opt/convex/adapter
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec /usr/bin/dotnet /opt/convex/adapter/Adapter.dll "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
