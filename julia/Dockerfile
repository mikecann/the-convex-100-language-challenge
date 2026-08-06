# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG JULIA_IMAGE=julia:1.11.6-bookworm@sha256:1623eb4161dc20ee57bcf694e48cb16cfc2aed71507e79b2ff170a206ccd7803
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG CLANG_IMAGE=silkeh/clang:18-bookworm@sha256:3914c93a02e866795aafc80737488e515b96390eff3d2787cf8c5095997baea9

FROM ${CLANG_IMAGE} AS c-format
WORKDIR /work
COPY client/runtime/fixed_launcher.c ./fixed_launcher.c
RUN clang-format --dry-run --Werror fixed_launcher.c && touch /c-format.ok

FROM ${JULIA_IMAGE} AS deps
WORKDIR /work
COPY client ./client
COPY examples ./examples

# Dependencies are restricted to these exact direct versions in Project.toml.
# They provide ordinary HTTP/TLS/JSON/WebSocket transport only; all Convex
# request, transition, reconnect, and adapter behaviour remains Julia source.
RUN julia --project=client -e 'using Pkg; Pkg.instantiate(; update_registry=false); Pkg.precompile()'
RUN julia --project=client/formatter -e 'using Pkg; Pkg.instantiate(; update_registry=false); Pkg.precompile()'

FROM deps AS test
COPY --from=c-format /c-format.ok /tmp/c-format.ok
RUN test "$(uname -m)" = x86_64 && julia -e '@assert Sys.ARCH === :x86_64'
RUN julia --project=client/formatter -e 'using JuliaFormatter; for path in ARGS; source = read(path, String); source == format_text(source) || error("not formatted: " * path); end' \
    client/Convex.jl client/tests/runtests.jl client/tests/conformance/adapter.jl \
    client/runtime/ConvexRuntime.jl client/runtime/precompile_adapter.jl \
    client/runtime/precompile_statements.jl examples/basics/main.jl
RUN julia --project=client -e 'for path in ARGS; Meta.parseall(read(path, String); filename=path); end' \
    client/Convex.jl client/tests/runtests.jl client/tests/conformance/adapter.jl \
    client/runtime/ConvexRuntime.jl client/runtime/precompile_adapter.jl \
    client/runtime/precompile_statements.jl examples/basics/main.jl
RUN julia --project=client -e 'include("examples/basics/main.jl"); @assert hasmethod(run_example, Tuple{String})'
RUN julia --project=client -e 'using Test; include("client/tests/runtests.jl")'
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | \
    julia --project=client client/tests/conformance/adapter.jl >/tmp/adapter.ndjson && \
    grep -Fq '"language":"julia"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["julia", "--project=client", "-e", "exit(0)"]

FROM ${JULIA_IMAGE} AS app-build
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc g++ libc6-dev && \
    rm -rf /var/lib/apt/lists/*
RUN gcc -fsyntax-only -Wall -Wextra -Werror \
      -DJULIA_MAIN='"ConvexRuntime.adapter_main"' \
      -I/usr/local/julia/include/julia client/runtime/fixed_launcher.c
RUN julia --project=client/compiler -e 'using Pkg; Pkg.instantiate(; update_registry=false); Pkg.precompile()'
RUN mkdir -p /opt/runtime/src /opt/runtime/client/tests/conformance \
      /opt/runtime/examples/basics && \
    cp client/runtime/Project.toml /opt/runtime/Project.toml && \
    cp client/runtime/Manifest.toml /opt/runtime/Manifest.toml && \
    cp client/runtime/ConvexRuntime.jl /opt/runtime/src/ConvexRuntime.jl && \
    cp client/Convex.jl /opt/runtime/client/Convex.jl && \
    cp client/tests/conformance/adapter.jl /opt/runtime/client/tests/conformance/adapter.jl && \
    cp examples/basics/main.jl /opt/runtime/examples/basics/main.jl
RUN JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=1 JULIA_PKG_CONCURRENT_DOWNLOADS=1 \
    julia --project=/opt/runtime -e 'using Pkg; Pkg.instantiate(; update_registry=false); Pkg.precompile()'
RUN julia --project=client/compiler -e 'using PackageCompiler; create_app( \
        "/opt/runtime", "/opt/convex-app"; \
        executables=["convex-adapter" => "adapter_main", "convex-example" => "example_main"], \
        precompile_execution_file="/work/client/runtime/precompile_adapter.jl", \
        precompile_statements_file="/work/client/runtime/precompile_statements.jl", \
        incremental=false, filter_stdlibs=true, include_lazy_artifacts=true, \
        include_transitive_dependencies=false, \
        c_driver_program="/work/client/runtime/fixed_launcher.c", \
        cpu_target="x86-64", \
        sysimage_build_args=`-O0 --strip-ir`, force=true)'
RUN readelf -h /opt/convex-app/bin/convex-adapter | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' && \
    readelf -h /opt/convex-app/bin/convex-example | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'

FROM ${DEBIAN_IMAGE} AS runtime-base
COPY --from=app-build /opt/convex-app /opt/convex-app
COPY --from=app-build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=app-build /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
RUN set -eu; \
    rm -f /opt/convex-app/bin/julia; \
    find /opt/convex-app -type f \( \
      -name openssl -o -name 7z -o -name lld -o -name ld.lld -o \
      -name clang -o -name clang++ -o -name julia \) -delete; \
    if test -d /opt/convex-app/share/julia/artifacts; then \
      find /opt/convex-app/share/julia/artifacts -type f -path '*/bin/*' -delete; \
      find /opt/convex-app/share/julia/artifacts -type d \( \
        -name include -o -name cmake -o -name pkgconfig -o -name licenses \
      \) -prune -exec rm -rf '{}' +; \
    fi; \
    rm -rf /etc/apt /var/cache/apt /var/lib/apt /var/lib/dpkg \
      /usr/lib/apt /usr/lib/dpkg /usr/lib/*/perl-base /usr/share/bash-completion \
      /usr/share/bug /usr/share/doc /usr/share/man /usr/share/perl*; \
    rm -f /etc/logrotate.d/apt /etc/logrotate.d/dpkg /etc/cron.daily/dpkg; \
    runtime_bin_dir=/runtime-bin; \
    mkdir "$runtime_bin_dir"; \
    for command_name in '[' arch awk basename cat cksum cmp comm cp cut dash \
      date dd dirname env expr false find fold grep head id join ln ls mawk \
      mkdir mkfifo mktemp mv nawk nice nl od paste printf pwd readlink realpath \
      rm rmdir sed sha256sum sh sleep sort split stat tail tee test timeout touch \
      tr true tsort uname uniq wc xargs; do \
      if test -e "/usr/bin/$command_name" || test -L "/usr/bin/$command_name"; then \
        cp -a "/usr/bin/$command_name" "$runtime_bin_dir/"; \
      fi; \
    done; \
    find /usr/bin -mindepth 1 -maxdepth 1 -exec rm -rf '{}' +; \
    "$runtime_bin_dir/cp" -a "$runtime_bin_dir/." /usr/bin/; \
    rm -rf "$runtime_bin_dir"; \
    find /usr/sbin -mindepth 1 -maxdepth 1 -exec rm -rf '{}' +; \
    for command_name in busybox toybox node nodejs npm npx python python3 ruby \
      perl php lua java dotnet mono R curl wget ftp nc netcat ssh scp sftp git \
      svn hg pip pip3 gem bundle cargo rustc gcc g++ cc c++ make cmake clang \
      clang++ ld lld ar as strip apt apt-get dpkg dpkg-deb julia juliaup \
      openssl c_rehash 7z; do \
      ! command -v "$command_name" >/dev/null 2>&1 || exit 1; \
      test -z "$(find / -xdev \( -type f -o -type l \) -name "$command_name" -print -quit 2>/dev/null)" || exit 1; \
    done; \
    test -z "$(find / -xdev -type f -perm /111 \( \
      -name '*-gcc' -o -name '*-g++' -o -name '*-cc' -o -name '*-c++' -o \
      -name '*-clang' -o -name '*-ld' -o -name '*-lld' -o -name '*-ar' -o \
      -name '*-as' -o -name '*-strip' -o -name 'gcc-[0-9]*' -o \
      -name 'g++-[0-9]*' -o -name 'clang-[0-9]*' -o -name 'python[0-9]*' -o \
      -name 'perl[0-9]*' -o -name 'node[0-9]*' \
    \) -print -quit 2>/dev/null)" || exit 1; \
    test -x /bin/sh; test -x /usr/bin/id; test -x /usr/bin/grep; \
    test -x /opt/convex-app/bin/convex-adapter; \
    test -x /opt/convex-app/bin/convex-example; \
    test "$(find /opt/convex-app/bin -type f -perm /111 | wc -l)" -eq 2; \
    probe_output=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' | \
      /opt/convex-app/bin/convex-adapter --julia-args --version 2>/tmp/adapter-probe.err); \
    test ! -s /tmp/adapter-probe.err; \
    test "$(printf '%s\n' "$probe_output" | wc -l)" -eq 2; \
    printf '%s\n' "$probe_output" | grep -Fq '"type":"ready"'; \
    printf '%s\n' "$probe_output" | grep -Fq '"type":"closed"'; \
    find /usr/bin -mindepth 1 -maxdepth 1 -printf 'runtime tool: %f\n' | sort; \
    find /opt/convex-app/bin -type f -perm /111 -printf 'runtime launcher: %f\n' | sort
ENV HOME=/nonexistent \
    JULIA_DEPOT_PATH=/nonexistent \
    JULIA_NUM_GC_THREADS=1 \
    JULIA_NUM_THREADS=1 \
    JULIA_SSL_CA_ROOTS_PATH=/etc/ssl/certs/ca-certificates.crt \
    MALLOC_ARENA_MAX=2 \
    OPENBLAS_NUM_THREADS=1 \
    OPENSSL_CONF=/etc/ssl/openssl.cnf \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    UV_THREADPOOL_SIZE=2
USER 65532:65532

FROM runtime-base AS example-runtime
USER root
RUN rm -f /opt/convex-app/bin/convex-adapter && \
    ln -s /opt/convex-app/bin/convex-example /usr/local/bin/convex-example
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the conformance adapter as the Dockerfile's final/default target.
FROM runtime-base AS runtime
USER root
RUN rm -f /opt/convex-app/bin/convex-example && \
    ln -s /opt/convex-app/bin/convex-adapter /usr/local/bin/convex-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
