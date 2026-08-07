# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f
ARG RUNTIME_BASE_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# EiffelStudio 25.02's free GPL edition ships as a plain tarball with no
# license key or account for the compiler this Dockerfile actually uses
# (`ec'); only its GUI (`estudio') needs the GTK stack this build also
# installs solely because `ec' itself is dynamically linked against it.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS build
ARG EIFFEL_VERSION=25.02
ARG EIFFEL_BUILD=98732
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
       ca-certificates=20260601~22.04.1 \
       curl=7.81.0-1ubuntu1.25 \
       bzip2=1.0.8-5build1 \
       libgtk-3-0=3.24.33-1ubuntu2.2 \
       libssl-dev=3.0.2-0ubuntu1.26 \
       libc6-dev=2.35-0ubuntu3.14 \
       gcc=4:11.2.0-1ubuntu1 \
       make=4.3-4.1build1 \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --output /tmp/eiffel.tar.bz2 \
       --url "https://du1rajjxb27dl.cloudfront.net/EiffelStudio/${EIFFEL_VERSION}/${EIFFEL_BUILD}/Eiffel_${EIFFEL_VERSION}_rev_${EIFFEL_BUILD}-linux-x86-64.tar.bz2" \
    && echo "7bbdf0e00459f26a1a24f60a73c392df81f9ac2b990621492da51803dec879ff  /tmp/eiffel.tar.bz2" > /tmp/eiffel.sha256 \
    && sha256sum --check /tmp/eiffel.sha256 \
    && mkdir -p /opt/Eiffel \
    && tar xjf /tmp/eiffel.tar.bz2 -C /opt/Eiffel --strip-components=1 \
    && rm -f /tmp/eiffel.tar.bz2 /tmp/eiffel.sha256
ENV ISE_EIFFEL=/opt/Eiffel \
    ISE_LIBRARY=/opt/Eiffel \
    ISE_PLATFORM=linux-x86-64 \
    PATH=/opt/Eiffel/studio/spec/linux-x86-64/bin:$PATH
RUN ec -version | grep -F '25.02'

WORKDIR /project/client
COPY client/ ./
COPY examples/ /project/examples/

# EiffelStudio 25.02.9.8732's own "C inline" feature bodies get bundled
# together with many other classes' generated code into one large
# translation unit ("big_file") once a project has enough classes, and that
# bundling step reliably corrupts the build for a handful of sizeable
# inline bodies: the C compiler reports the last bundled class's functions
# as redeclared with conflicting linkage ("static declaration ... follows
# non-static declaration"), and the actual big_file*.c is one #include
# short of complete. Every TLS, raw-socket, and select(2) call therefore
# lives in this ordinary, separately compiled translation unit instead
# (convex_native.c/.h), with only plain "C signature" externals declared
# on the Eiffel side; that combination never goes through the buggy
# bundling path. See convex_native.h for the full note.
RUN gcc -c -fPIC -O2 -Wall -Werror convex_native.c -o convex_native.o

# `ec -freeze' (EiffelStudio's incremental "workbench" mode) links a
# runtime that, when its own GC or scheduling timer signal interrupts a
# blocking syscall such as select(2), reports the ordinary EINTR as a
# fatal "operating system signal" exception and kills the process, rather
# than the syscall returning to its caller as usual. `-finalize' is
# EiffelStudio's ahead-of-time optimized build mode and does not carry
# that workbench-only signal handling, so every target below that will
# actually run (unit tests, the adapter, the example) is finalized rather
# than frozen; there is no compiler in the runtime images regardless.
RUN build_target() { \
      target="$1"; \
      ec -config convex.ecf -target "$target" -finalize -batch \
      || { echo "ec -freeze failed for $target" >&2; exit 1; }; \
      cp convex_native.h convex_native.o "EIFGENs/$target/F_code/"; \
      for dir in "EIFGENs/$target/F_code"/*/; do \
        cp convex_native.h "$dir" 2>/dev/null || true; \
      done; \
      ( cd "EIFGENs/$target/F_code" && finish_freezing ) \
      || { echo "finish_freezing failed for $target" >&2; exit 1; }; \
    }; \
    build_target convex_tests \
    && build_target convex_adapter \
    && build_target convex_example
RUN ./EIFGENs/convex_tests/F_code/convex | grep -Fqx ALL_TESTS_PASSED
RUN readelf -h ./EIFGENs/convex_adapter/F_code/convex | grep -Fq 'Advanced Micro Devices X86-64' \
    && readelf -h ./EIFGENs/convex_example/F_code/convex | grep -Fq 'Advanced Micro Devices X86-64'
RUN strip ./EIFGENs/convex_adapter/F_code/convex ./EIFGENs/convex_example/F_code/convex \
    && mkdir -p /out \
    && cp ./EIFGENs/convex_adapter/F_code/convex /out/convex-adapter \
    && cp ./EIFGENs/convex_example/F_code/convex /out/convex-example

FROM build AS test
# The plaintext check proves the adapter's NDJSON framing and clean-close
# path; port 9 refuses the connection immediately, so the mismatched
# `demo:count' path never actually resolves against a real deployment and
# this alone is not TLS or Live evidence. `./run verify-example' and
# `./run verify' exercise both against the real approved deployments.
RUN set -eu; \
    actual="$(printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:9 /out/convex-adapter)"; \
    printf '%s\n' "$actual" | grep -Fq '"id":"hello","type":"ready"'; \
    printf '%s\n' "$actual" | grep -Fqx '{"id":"close","type":"closed"}'
CMD ["/bin/sh", "-c", "true"]

# Begin with a pinned, non-scratch Debian image and prune it in place down
# to the runtime library closure `ldd' actually reports for the two
# finalized binaries (EiffelStudio's own runtime is statically linked in
# -finalize mode, so that closure is just libc, libm, and OpenSSL), CA
# certificates, and a small POSIX toolset the shared example verifier
# requires.
FROM --platform=linux/amd64 ${RUNTIME_BASE_IMAGE} AS runtime-base
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
       ca-certificates=20230311+deb12u1 \
       libssl3=3.0.20-1~deb12u2 \
       openssl=3.0.20-1~deb12u2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/convex-adapter /out/convex-example /tmp/
RUN set -eu; \
    for command_path in /usr/bin/mawk /usr/bin/basename /usr/bin/cat /usr/bin/cut \
        /usr/bin/dash /usr/bin/dirname /usr/bin/env /usr/bin/find /usr/bin/grep \
        /usr/bin/head /usr/bin/id /usr/bin/sed /usr/bin/sort /usr/bin/tail \
        /usr/bin/tr /usr/bin/true /usr/bin/uname /usr/bin/uniq /usr/bin/wc; do \
      test -e "$command_path" || { echo "missing expected command: $command_path" >&2; exit 1; }; \
    done; \
    runtime_libs=/usr/lib/x86_64-linux-gnu.runtime; \
    mkdir -p "$runtime_libs"; \
    for executable in /tmp/convex-adapter /tmp/convex-example \
        /usr/bin/mawk /usr/bin/basename /usr/bin/cat /usr/bin/cut /usr/bin/dash \
        /usr/bin/dirname /usr/bin/env /usr/bin/find /usr/bin/grep /usr/bin/head \
        /usr/bin/id /usr/bin/sed /usr/bin/sort /usr/bin/tail /usr/bin/tr \
        /usr/bin/true /usr/bin/uname /usr/bin/uniq /usr/bin/wc; do \
      ldd "$executable" | awk '{ for (field = 1; field <= NF; field++) if ($field ~ /^\//) print $field }'; \
    done | sort -u > /tmp/runtime-library-paths; \
    while IFS= read -r library; do \
      cp -L "$library" "$runtime_libs/$(basename "$library")"; \
    done < /tmp/runtime-library-paths; \
    for library in libnss_dns.so.2 libnss_files.so.2; do \
      if test -e "/usr/lib/x86_64-linux-gnu/$library"; then \
        cp -L "/usr/lib/x86_64-linux-gnu/$library" "$runtime_libs/$library"; \
      fi; \
    done; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$runtime_libs/ossl-modules"; \
    rm -rf /usr/lib/x86_64-linux-gnu; \
    mv "$runtime_libs" /usr/lib/x86_64-linux-gnu
RUN set -eu; \
    rm -f /usr/bin/awk; ln -s mawk /usr/bin/awk; \
    find /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -print > /tmp/runtime-commands; \
    while IFS= read -r path; do \
      case "$path" in \
        /usr/bin/awk|/usr/bin/mawk|/usr/bin/basename|/usr/bin/cat|/usr/bin/cut|/usr/bin/dash|/usr/bin/dirname|/usr/bin/env|/usr/bin/find|/usr/bin/grep|/usr/bin/head|/usr/bin/id|/usr/bin/sed|/usr/bin/sh|/usr/bin/sort|/usr/bin/tail|/usr/bin/tr|/usr/bin/true|/usr/bin/uname|/usr/bin/uniq|/usr/bin/wc) ;; \
        *) rm -rf "$path" ;; \
      esac; \
    done < /tmp/runtime-commands; \
    rm -rf /etc/alternatives /etc/apt /etc/cron.d /etc/cron.daily /etc/cron.hourly \
      /etc/cron.monthly /etc/cron.weekly /etc/crontab /etc/debconf.conf /etc/dpkg \
      /etc/init.d /etc/logrotate.conf /etc/logrotate.d /etc/rc0.d /etc/rc1.d \
      /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/rcS.d \
      /etc/systemd /usr/games /usr/include /usr/lib/apt /usr/lib/dpkg \
      /usr/lib/systemd /usr/libexec /usr/share /usr/src /usr/local/man \
      /usr/local/share /var/backups /var/cache /var/lib /var/local /var/mail \
      /var/opt /var/spool /var/tmp /var/log/* /tmp/convex-adapter \
      /tmp/convex-example /tmp/runtime-commands /tmp/runtime-library-paths; \
    for command_name in ec estudio gcc cc clang make ld as apt apt-get dpkg \
        curl wget nc netcat openssl node python python3 ruby perl java php go \
        rustc cargo npm pip convex busybox rm mv cp chmod chown; do \
      ! command -v "$command_name" >/dev/null 2>&1 || { echo "forbidden runtime command: $command_name" >&2; exit 1; }; \
    done
RUN mkdir -p /usr/local/bin
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64

FROM runtime-base AS example-runtime
COPY --from=build /out/convex-example /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example && test ! -e /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out/convex-adapter /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:9 /usr/local/bin/convex-adapter \
       | grep -Fqx '{"id":"close","type":"closed"}'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
