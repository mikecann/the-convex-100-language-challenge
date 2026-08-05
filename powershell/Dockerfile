# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG POWERSHELL_IMAGE=mcr.microsoft.com/powershell:7.5-debian-12@sha256:7ab5bd5ca6f95a3351fa0c6a1205237d57048c94542355aab55519a0861a9b25

FROM ${POWERSHELL_IMAGE} AS test
WORKDIR /opt/convex
COPY client ./client
COPY examples ./examples
RUN test "$(dpkg --print-architecture)" = amd64 && test "$(uname -m)" = x86_64 && pwsh -NoLogo -NoProfile -Command 'if ($PSVersionTable.Platform -ne "Unix") { exit 1 }'
RUN pwsh -NoLogo -NoProfile -File client/tests/tests.ps1
RUN actual=$(printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | pwsh -NoLogo -NoProfile -File client/tests/conformance/adapter.ps1) && printf '%s\n' "$actual" | grep -F '"type":"ready"' | grep -F '"language":"powershell"' && printf '%s\n' "$actual" | grep -F '"id":"close"' | grep -F '"type":"closed"'
CMD ["pwsh", "-NoLogo", "-NoProfile", "-Command", "exit 0"]

FROM ${POWERSHELL_IMAGE} AS runtime-base
WORKDIR /opt/convex
ENV TMPDIR=/dev/shm
ENV HOME=/tmp
ENV XDG_CACHE_HOME=/tmp
# The final image retains pwsh because it is PowerShell's runtime, but removes
# Debian's package frontend and its database. No compiler, SDK, Node, Python,
# curl, or Convex tool is copied into either runtime target.
RUN rm -f /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* /usr/bin/dselect /usr/bin/apt-cache /usr/bin/apt-cdrom /usr/bin/apt-config /usr/bin/apt-get /usr/bin/apt-mark /usr/bin/apt-sortpkgs /usr/bin/update-alternatives && rm -rf /etc/apt /var/lib/apt /var/cache/apt /var/lib/dpkg /usr/lib/apt /usr/share/dpkg /tmp && ln -s /dev/shm /tmp && for command_name in apt apt-get dpkg node npm python python3 curl convex csc dotnet; do ! command -v "$command_name" >/dev/null 2>&1 || exit 1; done
COPY client/Convex.ps1 /opt/convex/client/Convex.ps1
RUN printf '%s\n' '#!/bin/sh' 'exec pwsh -NoLogo -NoProfile -File /opt/convex/client/tests/conformance/adapter.ps1 "$@"' > /usr/local/bin/convex-adapter && chmod 0555 /usr/local/bin/convex-adapter && printf '%s\n' '#!/bin/sh' 'exec pwsh -NoLogo -NoProfile -File /opt/convex/examples/basics/main.ps1 "$@"' > /usr/local/bin/convex-example && chmod 0555 /usr/local/bin/convex-example
USER 65532:65532

FROM runtime-base AS example-runtime
COPY examples/basics/main.ps1 /opt/convex/examples/basics/main.ps1
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY client/tests/conformance/adapter.ps1 /opt/convex/client/tests/conformance/adapter.ps1
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
