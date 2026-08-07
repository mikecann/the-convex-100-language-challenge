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
    dotnet build client/tests/CsharpTests.csproj -c Release -warnaserror && \
    dotnet build examples/basics/Example.csproj -c Release -warnaserror && \
    dotnet build examples/basics/tests/ExampleTests.csproj -c Release -warnaserror && \
    dotnet run --project client/tests/CsharpTests.csproj -c Release --no-build && \
    dotnet run --project examples/basics/tests/ExampleTests.csproj -c Release --no-build && \
    dotnet publish client/tests/conformance/Adapter.csproj -c Release -o /out/adapter --no-self-contained && \
    dotnet publish examples/basics/Example.csproj -c Release -o /out/example --no-self-contained && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | dotnet /out/adapter/Adapter.dll | grep -q '"language":"csharp"' && \
    test "$(uname -m)" = x86_64 && dotnet --info | grep -q 'Architecture: *x64'
CMD ["/bin/sh", "-ec", "dotnet --info >/dev/null; test \"$(uname -m)\" = x86_64"]

FROM --platform=linux/amd64 ${RUNTIME} AS runtime-base
# RUNTIME is Debian bookworm-slim underneath and its rootfs carries apt,
# dpkg and perl-base (Priority: important) independently of anything
# dotnet-specific -- confirmed on this exact pinned digest with
# `apt-get remove --simulate perl-base`, which reports zero reverse
# dependencies (only perl-base itself would be removed; dpkg still marks
# it Essential, so apt-get refuses the real removal and the files are
# deleted directly below). Nothing in this client or the dotnet runtime
# ever invokes perl, apt or dpkg, so strip them before publishing either
# minimal runtime image.
RUN mkdir -p /opt/convex /usr/local/bin && \
    rm -f /usr/bin/apt /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config \
          /usr/bin/apt-get /usr/bin/apt-key /usr/bin/apt-mark /usr/bin/dpkg \
          /usr/bin/dpkg-deb /usr/bin/dpkg-divert /usr/bin/dpkg-maintscript-helper \
          /usr/bin/dpkg-query /usr/bin/dpkg-realpath /usr/bin/dpkg-split \
          /usr/bin/dpkg-statoverride /usr/bin/dpkg-trigger /usr/bin/debconf* \
          /usr/bin/update-alternatives /usr/sbin/dpkg-fsys-usrunmess \
          /usr/sbin/dpkg-preconfigure /usr/sbin/dpkg-reconfigure \
          /usr/sbin/invoke-rc.d /usr/sbin/update-rc.d \
          /usr/bin/perl /usr/bin/perl5.36.0 && \
    rm -rf /etc/apt /var/lib/apt /var/cache/apt /var/lib/dpkg /var/cache/debconf \
           /usr/lib/apt /usr/lib/dpkg /usr/share/dpkg /usr/lib/x86_64-linux-gnu/perl-base && \
    for command in dotnet-sdk msbuild csc fsc nuget npm npx node python python3 pip pip3 curl convex \
                   apt apt-get apt-cache dpkg dpkg-deb perl; do \
      ! command -v "$command" >/dev/null 2>&1 || exit 1; \
    done && \
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
