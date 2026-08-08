# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG BALLERINA_IMAGE=ballerina/ballerina:2201.13.5@sha256:5520b275863571240db0e6f82995aa4f84de7ac5af9d5cb9716a906b08d305b9
ARG JRE_IMAGE=eclipse-temurin:21.0.8_9-jre-jammy@sha256:db1689535962d757a5adabf57387584ed543d38c0b9d1fe870123ea362ad73b0
ARG RUNTIME_OS=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${BALLERINA_IMAGE} AS test
USER root
WORKDIR /project
COPY client ./client
COPY examples ./examples

# `bal format --dry-run` always exits 0, whether or not it found anything to
# reformat (see LESSONS.md's "safety check that could not fail" entry) - the
# gate has to read its output, not its exit status, to actually fail on
# drift. Matching on the "files to be modified" marker (rather than
# requiring the whole output to equal a fixed banner-free string) tolerates
# whatever compiler progress output `bal` prints ahead of it.
RUN set -eu; \
    client_fmt=$(bal format --dry-run client 2>&1); \
    if printf '%s' "$client_fmt" | grep -q 'files to be modified'; then echo "$client_fmt" >&2; exit 1; fi; \
    example_fmt=$(bal format --dry-run examples/basics/main.bal 2>&1); \
    if printf '%s' "$example_fmt" | grep -q 'files to be modified'; then echo "$example_fmt" >&2; exit 1; fi

RUN bal test client

# Ballerina has no cross-module local dependency mechanism that does not
# round-trip through the local Ballerina Central cache - and this repository
# has already hit that publish step drop a symbol it had just packed
# correctly (LESSONS.md section 15). The adapter and the example are instead
# each composed, inside this build stage only, as a throwaway package that
# copies the checked-in library files next to that target's own entrypoint;
# the repository itself keeps exactly one copy of the library.
RUN set -eu; \
    mkdir -p /build/adapter /build/example; \
    cp client/Ballerina.toml /build/adapter/; \
    sed -i 's/^name = .*/name = "adapter"/' /build/adapter/Ballerina.toml; \
    cp client/*.bal /build/adapter/; \
    cp client/tests/conformance/adapter_main.bal /build/adapter/; \
    cp client/Ballerina.toml /build/example/; \
    sed -i 's/^name = .*/name = "example"/' /build/example/Ballerina.toml; \
    cp client/*.bal /build/example/; \
    cp examples/basics/main.bal /build/example/; \
    cd /build/adapter && bal build; \
    cd /build/example && bal build

RUN set -eu; \
    test "$(uname -m)" = x86_64; \
    arch=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/.*os\.arch = //p'); \
    test "$arch" = amd64
CMD ["/bin/sh", "-ec", "test \"$(uname -m)\" = x86_64 && java -jar /build/adapter/target/bin/adapter.jar <<'EOF'\n{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\nEOF"]

FROM --platform=linux/amd64 ${JRE_IMAGE} AS jre

FROM --platform=linux/amd64 ${RUNTIME_OS} AS runtime-os
COPY --from=jre /opt/java/openjdk /opt/java/openjdk
COPY --from=jre /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=/opt/java/openjdk/bin:/usr/local/bin:/usr/bin:/bin
# Ballerina's generated jar bundles Netty's TLS stack for both `ballerina/http`
# and this client's hand-rolled `ballerina/tcp` transport, so it inherits the
# same JVM-under-128-MiB risk this repository already diagnosed and fixed for
# Groovy: a fully tiered JIT's own transient compilation working set (not its
# compiled output) is what blows the budget under a real TLS handshake, and
# fully interpreted execution trades that for missing the harness's response
# deadline. C1-only compilation with raised invocation thresholds keeps only
# genuinely hot loops (the TLS handshake's own crypto) compiled while the long
# tail of one-shot Ballerina runtime bootstrap methods stays interpreted -
# the same fix, for the same reason, as ../groovy/Dockerfile.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAM=120m -Xms8m -Xmx24m -Xss256k -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:MaxMetaspaceSize=88m -XX:CompressedClassSpaceSize=40m -XX:MaxDirectMemorySize=12m -XX:ReservedCodeCacheSize=16m -XX:TieredStopAtLevel=1 -XX:CICompilerCount=1 -XX:Tier3InvocationThreshold=8000 -XX:Tier3MinInvocationThreshold=4000 -XX:Tier3CompileThreshold=8000 -XX:Tier3BackEdgeThreshold=8000"
# Runtime images expose no package manager, compiler, or build frontend
# (AGENTS.md). debian:bookworm-slim still ships apt/apt-get/dpkg on PATH, so
# replace /usr/bin, /usr/sbin, /usr/local/bin, and /usr/local/sbin outright
# with a minimal allowlisted toolset rather than deleting distro tooling
# piecemeal, which would leave anything the allowlist forgot to name intact.
RUN set -eu; \
    mkdir /restricted-tools; \
    for tool in dash mawk basename cat cmp cut env grep head id sed sort tail tr uname wc; do \
      cp "/usr/bin/$tool" "/restricted-tools/$tool"; \
    done; \
    cp /usr/bin/rm /restricted-tools/.rm; \
    cp /usr/bin/mv /restricted-tools/.mv; \
    cp /usr/bin/ln /restricted-tools/.ln; \
    /restricted-tools/.rm -rf /usr/bin/* /usr/sbin/* \
      /usr/local/bin/* /usr/local/sbin/*; \
    /restricted-tools/.mv /restricted-tools/[!.]* /usr/bin/; \
    /restricted-tools/.ln -s dash /usr/bin/sh; \
    /restricted-tools/.ln -s mawk /usr/bin/awk; \
    /restricted-tools/.rm -rf \
      /usr/lib/apt /usr/lib/dpkg /usr/lib/x86_64-linux-gnu/perl-base \
      /usr/share/debconf /usr/share/perl /var/lib/apt /var/lib/dpkg \
      /var/cache/apt /etc/apt /etc/perl; \
    /restricted-tools/.rm -f /opt/java/openjdk/bin/jfr \
      /opt/java/openjdk/bin/jrunscript /opt/java/openjdk/bin/jwebserver \
      /opt/java/openjdk/bin/keytool /opt/java/openjdk/bin/rmiregistry \
      /opt/java/openjdk/bin/jshell /opt/java/openjdk/bin/jdb; \
    /restricted-tools/.rm -rf /restricted-tools
# Every name below must genuinely fail the lookup, not merely be evaluated
# and discarded: a `for` loop's exit status is only its last iteration's, and
# `set -e` does not apply to a pipeline starting with `!` (LESSONS.md's "the
# safety check that could not fail" - thirty-three merged languages carried
# the vacuous form of exactly this loop). `|| exit 1` after each check is what
# actually makes a present command fail the build.
RUN set -eu; \
    for forbidden in bal javac jar jshell jdb jfr jrunscript jwebserver \
      keytool rmiregistry apt apt-get apt-cache dpkg gcc cc make node npm \
      python python3 pip convex; do \
      ! command -v "$forbidden" >/dev/null 2>&1 || exit 1; \
    done; \
    java -version
USER 65532:65532

FROM runtime-os AS example-runtime
COPY --from=test /build/example/target/bin/example.jar /opt/convex/example.jar
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-example
#!/bin/sh
exec java -jar /opt/convex/example.jar "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-os AS runtime
COPY --from=test /build/adapter/target/bin/adapter.jar /opt/convex/adapter.jar
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec java -jar /opt/convex/adapter.jar "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
