# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG POWERSHELL_IMAGE=mcr.microsoft.com/powershell:7.5-debian-12@sha256:7ab5bd5ca6f95a3351fa0c6a1205237d57048c94542355aab55519a0861a9b25
ARG RUNTIME_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

FROM ${POWERSHELL_IMAGE} AS formatter
WORKDIR /opt/convex
RUN pwsh -NoLogo -NoProfile -Command 'Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope AllUsers; if ((Get-Module PSScriptAnalyzer -ListAvailable).Version -ne [version]"1.24.0") { exit 1 }'
COPY client ./client
COPY examples ./examples
RUN cp -a client /tmp/client-before && cp -a examples /tmp/examples-before && \
    pwsh -NoLogo -NoProfile -Command 'Get-ChildItem client,examples -Recurse -Filter *.ps1 | ForEach-Object { $formatted = Invoke-Formatter -ScriptDefinition (Get-Content -Raw $_.FullName); [IO.File]::WriteAllText($_.FullName, $formatted, [Text.UTF8Encoding]::new($false)) }' && \
    diff -ru /tmp/client-before client && diff -ru /tmp/examples-before examples

FROM formatter AS test
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(uname -m)" = x86_64 && \
    pwsh -NoLogo -NoProfile -Command 'if ($PSVersionTable.Platform -ne "Unix" -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne "X64") { exit 1 }'
RUN pwsh -NoLogo -NoProfile -Command '$bad=$false; Get-ChildItem client,examples -Recurse -Filter *.ps1 | ForEach-Object { $tokens=$null; $errors=$null; [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors) | Out-Null; if ($errors.Count) { $bad=$true; $errors | ForEach-Object { Write-Error $_.Message } } }; if ($bad) { exit 1 }'
RUN pwsh -NoLogo -NoProfile -File client/tests/tests.ps1
RUN pwsh -NoLogo -NoProfile -File client/tests/conformance/adapter-tests.ps1
RUN pwsh -NoLogo -NoProfile -File client/tests/example-tests.ps1
RUN actual=$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | pwsh -NoLogo -NoProfile -File client/tests/conformance/adapter.ps1) && \
    printf '%s\n' "$actual" | grep -F '"type":"ready"' | grep -F '"language":"powershell"' && \
    printf '%s\n' "$actual" | grep -F '"id":"close"' | grep -F '"type":"closed"'
CMD ["pwsh", "-NoLogo", "-NoProfile", "-Command", "exit 0"]

FROM ${POWERSHELL_IMAGE} AS runtime-rootfs
# Copy an explicit glibc/PowerShell runtime closure. The compiler assemblies,
# package modules, interactive shell tooling, and every OS package frontend are
# deliberately excluded from the final filesystem.
RUN set -eu; \
    root=/runtime-root; \
    mkdir -p "$root/bin" "$root/lib" "$root/usr/bin" "$root/usr/local/bin" "$root/usr/lib/x86_64-linux-gnu" "$root/usr/share" "$root/etc" "$root/opt/microsoft/powershell"; \
    cp /bin/dash "$root/bin/dash"; \
    ln -s dash "$root/bin/sh"; \
    cp /bin/rm /bin/mkdir /bin/chmod "$root/bin/"; \
    cp /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/uname /usr/bin/which "$root/usr/bin/"; \
    cp -a /opt/microsoft/powershell/7 "$root/opt/microsoft/powershell/7"; \
    ln -s /opt/microsoft/powershell/7/pwsh "$root/usr/bin/pwsh"; \
    rm -f "$root"/opt/microsoft/powershell/7/Microsoft.CodeAnalysis*.dll "$root"/opt/microsoft/powershell/7/System.CodeDom.dll; \
    find "$root/opt/microsoft/powershell/7/Modules" -mindepth 1 -maxdepth 1 -type d \
      ! -name Microsoft.PowerShell.Management ! -name Microsoft.PowerShell.Utility -exec rm -rf {} +; \
    { \
      ldd /opt/microsoft/powershell/7/pwsh /opt/microsoft/powershell/7/*.so /bin/dash /bin/rm /bin/mkdir /bin/chmod /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/uname /usr/bin/which || true; \
    } | awk '/=> \/.* \(0x/ { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | \
      while IFS= read -r library; do cp -L --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do test ! -e "$library" || cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libicu*.so*; do test ! -e "$library" || cp -L --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libssl.so* /lib/x86_64-linux-gnu/libcrypto.so*; do test ! -e "$library" || cp -L --parents "$library" "$root"; done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$root/usr/lib/x86_64-linux-gnu/ossl-modules"; \
    cp -a /usr/share/ca-certificates "$root/usr/share/ca-certificates"; \
    test ! -d /usr/lib/locale/C.utf8 || cp -a --parents /usr/lib/locale/C.utf8 "$root"; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done

FROM ${RUNTIME_IMAGE} AS runtime-base
ENV TMPDIR=/dev/shm
ENV HOME=/dev/shm
ENV XDG_CACHE_HOME=/dev/shm
ENV LANG=C.UTF-8
COPY --from=runtime-rootfs /runtime-root /
COPY client/Convex.ps1 /opt/convex/client/Convex.ps1
RUN mkdir -p /opt/convex/examples/basics /opt/convex/client/tests/conformance && \
    chmod -R a+rX /opt/convex && \
    rm -rf /tmp && ln -s /dev/shm /tmp && \
    find /bin /sbin /usr/bin /usr/sbin -type l ! -path /bin/sh ! -path /usr/bin/pwsh -delete && \
    rm -f /bin/busybox /sbin/apk /usr/sbin/apk /usr/bin/apk /lib/ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1 && \
    rm -rf /etc/apk /lib/apk /usr/lib/libapk* && \
    for command_path in /bin/*; do case "$command_path" in /bin/chmod|/bin/dash|/bin/mkdir|/bin/rm|/bin/sh) ;; *) rm -f "$command_path" ;; esac; done && \
    for command_path in /usr/bin/*; do case "$command_path" in /usr/bin/grep|/usr/bin/id|/usr/bin/pwsh|/usr/bin/sed|/usr/bin/uname|/usr/bin/which) ;; *) rm -f "$command_path" ;; esac; done && \
    rm -f /sbin/* /usr/sbin/* && \
    for command in apk apt apt-get dpkg bash perl ssh openssl gcc g++ cc clang make node npm python python3 curl wget convex dotnet csc; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done
RUN /usr/bin/pwsh -NoLogo -NoProfile -NonInteractive -Command 'try { Add-Type -TypeDefinition "public class ForbiddenCompilerSurface {}" -ErrorAction Stop; exit 1 } catch { exit 0 }'

FROM runtime-base AS example-runtime
COPY --chmod=0444 examples/basics/main.ps1 /opt/convex/examples/basics/main.ps1
RUN printf '%s\n' '#!/bin/sh' 'exec /usr/bin/pwsh -NoLogo -NoProfile -NonInteractive -File /opt/convex/examples/basics/main.ps1 "$@"' > /usr/local/bin/convex-example && \
    chmod 0555 /usr/local/bin/convex-example && chmod -R a+rX /opt/convex/examples && rm /bin/chmod
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0444 client/tests/conformance/adapter.ps1 /opt/convex/client/tests/conformance/adapter.ps1
RUN printf '%s\n' '#!/bin/sh' 'exec /usr/bin/pwsh -NoLogo -NoProfile -NonInteractive -File /opt/convex/client/tests/conformance/adapter.ps1 "$@"' > /usr/local/bin/convex-adapter && \
    chmod 0555 /usr/local/bin/convex-adapter && chmod -R a+rX /opt/convex/client && rm /bin/chmod
USER 65532:65532
RUN actual=$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | /usr/local/bin/convex-adapter) && \
    printf '%s\n' "$actual" | grep -F '"type":"ready"' | grep -F '"language":"powershell"' && \
    printf '%s\n' "$actual" | grep -F '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
