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
    dotnet publish client/tests/conformance/Adapter.fsproj -c Release -o /out/adapter --no-self-contained -p:UseAppHost=false -p:DebugType=None -p:DebugSymbols=false && \
    dotnet publish examples/basics/Example.fsproj -c Release -o /out/example --no-self-contained -p:UseAppHost=false -p:DebugType=None -p:DebugSymbols=false && \
    find /out -type f -exec chmod 0444 {} + && \
    find /out -type d -exec chmod 0555 {} + && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | dotnet /out/adapter/Adapter.dll | grep -q '"language":"fsharp"' && \
    test "$(uname -m)" = x86_64 && dotnet --info | grep -q 'Architecture: *x64'
FROM --platform=linux/amd64 ${RUNTIME} AS runtime-base
RUN keep='[ arch awk base64 basename cat cksum cmp comm cp cut dash date dd df diff diff3 dirname dotnet echo egrep env expand expr false fgrep find fmt fold getconf getent grep head hostname id join link ln ls mawk mkdir mkfifo mktemp mv nawk nice nl od paste pathchk printenv printf pwd readlink realpath rm rmdir sed seq sh sha256sum sleep sort split stat sum tail tee test touch tr true truncate tsort tty uname unexpand uniq unlink vdir wc whoami xargs yes' && \
    for path in /usr/bin/*; do \
      name=${path##*/}; \
      case " $keep " in *" $name "*) ;; *) rm -f "$path" ;; esac; \
    done && \
    rm -rf /usr/sbin/* && \
    mkdir -p /opt/convex /usr/local/bin && \
    for command in apt apt-get debconf dpkg perl update-alternatives openssl c_rehash bash gpgv gzip gunzip tar login passwd su mount umount nsenter unshare setpriv localedef ldd script logger run-parts adduser useradd chroot service update-ca-certificates gcc g++ cc make cmake ld as ar strip objcopy objdump readelf git svn hg wget curl ssh scp sftp dotnet-sdk msbuild csc fsc nuget npm npx node python python3 pip pip3 convex; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done && \
    test -z "$(find /usr/sbin -mindepth 1 -maxdepth 1 -print -quit)" && \
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
