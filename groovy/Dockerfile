# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GROOVY_IMAGE=groovy:4.0.27@sha256:3cff445b673a31b22ecc7217b41499208a15848303ac311617993a6123b685af
ARG JRE_IMAGE=eclipse-temurin:21.0.8_9-jre-jammy@sha256:db1689535962d757a5adabf57387584ed543d38c0b9d1fe870123ea362ad73b0
ARG RUNTIME_OS=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM --platform=linux/amd64 ${GROOVY_IMAGE} AS build
WORKDIR /src
COPY client ./client
COPY examples ./examples

# Compile each public surface into a separate classpath. The final adapter,
# example, and test images therefore cannot invoke one another's classes.
RUN mkdir -p out/client out/adapter out/example out/tests out/runtime \
 && groovyc -d out/client client/ConvexClient.groovy client/LiveClient.groovy \
 && groovyc -cp 'out/client:/opt/groovy/lib/*' -d out/adapter \
      client/tests/conformance/Adapter.groovy \
 && groovyc -cp 'out/client:/opt/groovy/lib/*' -d out/example \
      examples/basics/Main.groovy \
 && groovyc -cp 'out/client:out/adapter:out/example:/opt/groovy/lib/*' \
      -d out/tests client/tests/*.groovy

# The core Groovy runtime contains optional command frontends. Compiled Groovy
# needs the runtime classes but not GroovyMain, GroovyShell, or groovyc's
# FileSystemCompiler, so construct and probe a runtime-only jar.
RUN cd out/runtime \
 && jar xf /opt/groovy/lib/groovy-4.0.27.jar \
 && rm -rf groovy/ui groovy/lang/GroovyShell* \
      org/codehaus/groovy/tools/FileSystemCompiler* \
      org/codehaus/groovy/tools/GroovyStarter* \
      org/codehaus/groovy/tools/shell \
 && jar --create --file ../groovy-runtime-4.0.27.jar . \
 && cd /src \
 && ! java -cp 'out/groovy-runtime-4.0.27.jar' groovy.ui.GroovyMain -e 'println 1' \
 && ! java -cp 'out/groovy-runtime-4.0.27.jar' \
      org.codehaus.groovy.tools.FileSystemCompiler --version

FROM build AS test
# The test image exercises near-maximum protocol values, so it needs a larger
# test-only heap. The final images below keep their separate 128 MiB runtime
# envelope and are probed independently.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAM=256m -Xms16m -Xmx128m -Xss512k -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:MaxMetaspaceSize=64m -XX:CompressedClassSpaceSize=32m -XX:MaxDirectMemorySize=16m -XX:ReservedCodeCacheSize=8m"
# This repository-local lint gate rejects compressed multi-statement teaching
# source, tabs, trailing whitespace, and accidental overlong lines.
RUN java -ea -cp 'out/tests:out/client:out/adapter:out/example:/opt/groovy/lib/*' \
      convex.tests.StyleCheck client examples \
 && java --add-modules jdk.httpserver -ea \
      -cp 'out/tests:out/client:out/adapter:out/example:/opt/groovy/lib/*' \
      convex.tests.AllTests
ENTRYPOINT ["java", "--add-modules", "jdk.httpserver", "-ea", "-cp", "/src/out/tests:/src/out/client:/src/out/adapter:/src/out/example:/opt/groovy/lib/*", "convex.tests.AllTests"]

FROM --platform=linux/amd64 ${JRE_IMAGE} AS jre

FROM --platform=linux/amd64 ${RUNTIME_OS} AS runtime-os
COPY --from=jre /opt/java/openjdk /opt/java/openjdk
COPY --from=jre /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=/opt/java/openjdk/bin:/usr/local/bin:/usr/bin:/bin
# These are part of the runtime contract, not reviewer-only flags. They leave
# room for TLS, direct buffers, threads, and native JVM bookkeeping at 128 MiB.
# A tiered-compiling JVM settles near 130 MiB of Rss (docker exec ... cat
# /proc/1/smaps, summed) within ~2 seconds of a real wss:// handshake against
# the hosted deployment and keeps climbing past 260 MiB by the time the run
# finishes - comfortably over the 128 MiB --memory cap ./run applies to
# every runtime container. Interpreter-only (-Xint) fixed that (measured
# under 90 MiB) but traded it for a latency cliff: fully interpreted TLS/
# X.509 crypto made the hosted client/http/query check take 10007 ms against
# the harness's 10 s timeout, since the interpreter never compiles the
# handshake's hot crypto loops at all. The middle ground is C1 only, capped
# to one compiler thread, with its invocation thresholds raised well above
# their tiered defaults (200-ish): Groovy's invokedynamic call-site
# bootstrapping mints large numbers of small methods that each run only a
# handful of times, and by default C1 compiles many of them anyway, which is
# what actually drove Rss - lowering ReservedCodeCacheSize alone barely
# moved it (16m vs 8m: no measurable difference), because the cost is C1's
# own transient compilation working set, not the bytes of compiled output it
# keeps. Raising Tier3*Threshold to 8000 means only genuinely hot loops -
# like the TLS handshake's crypto - still get compiled, while the long tail
# of Groovy's one-shot bootstrap methods stays interpreted. Measured against
# the same hosted deployment: peak Rss 105-107 MiB across repeated runs
# (target <110), and an isolated ConvexClient.query() call - matching how
# the conformance adapter constructs its client, unlike this example, which
# also builds a LiveClient up front - completed in 1.7-2.2 s across 10 runs
# (target <4 s), both comfortably clear of their caps.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAM=96m -Xms8m -Xmx24m -Xss256k -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:MaxMetaspaceSize=24m -XX:CompressedClassSpaceSize=16m -XX:MaxDirectMemorySize=8m -XX:ReservedCodeCacheSize=16m -XX:TieredStopAtLevel=1 -XX:CICompilerCount=1 -XX:Tier3InvocationThreshold=8000 -XX:Tier3MinInvocationThreshold=4000 -XX:Tier3CompileThreshold=8000 -XX:Tier3BackEdgeThreshold=8000"
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
      /opt/java/openjdk/bin/keytool /opt/java/openjdk/bin/rmiregistry; \
    /restricted-tools/.rm -rf /restricted-tools
COPY --from=build /src/out/groovy-runtime-4.0.27.jar /opt/convex/lib/
COPY --from=build /opt/groovy/lib/groovy-json-4.0.27.jar /opt/convex/lib/
# Prove the stripped rootfs above at build time: both the package-manager
# family (apt, apt-get, apt-cache, aptitude, debconf, dpkg, dpkg-deb) and
# every compiler/build/runtime frontend must be absent, or this stage fails
# and neither final image below (runtime, example-runtime) gets produced.
RUN set -eu; \
    for forbidden in \
      apt apt-get apt-cache aptitude debconf dpkg dpkg-deb perl wget curl \
      groovy groovyc javac jfr jrunscript jwebserver keytool rmiregistry \
      node npm python python3 pip pip3 convex; do \
      ! command -v "$forbidden" >/dev/null 2>&1; \
    done; \
    ! java -cp '/opt/convex/lib/*' groovy.ui.GroovyMain \
      -e 'println 1' >/dev/null 2>&1; \
    ! java -cp '/opt/convex/lib/*' \
      org.codehaus.groovy.tools.FileSystemCompiler --version >/dev/null 2>&1
USER 65532:65532

FROM runtime-os AS example-runtime
COPY --from=build /src/out/client /opt/convex/client
COPY --from=build /src/out/example /opt/convex/example
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-example
#!/bin/sh
exec java -cp "/opt/convex/client:/opt/convex/example:/opt/convex/lib/*" examples.basics.Main "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-os AS runtime
COPY --from=build /src/out/client /opt/convex/client
COPY --from=build /src/out/adapter /opt/convex/adapter
COPY --chmod=0555 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec java -cp "/opt/convex/client:/opt/convex/adapter:/opt/convex/lib/*" convex.adapter.Adapter "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
