# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GRADLE_IMAGE=gradle:8.14.3-jdk21-jammy@sha256:554981bbebcbe0fe9ad77f5d0d10729ef0e998f20248eb5d38221c1473532604
ARG JRE_IMAGE=eclipse-temurin:21-jre-jammy@sha256:3097cbbebb7d490494a98aed2301f284b38f79eba158eef098c6fc8c8af11c23

FROM ${GRADLE_IMAGE} AS test
WORKDIR /workspace
COPY client ./client
COPY examples ./examples
# All Kotlin tooling and dependency resolution remains in this build stage.
RUN gradle --no-daemon --project-dir client check adapterJar exampleJar \
    && test "$(uname -m)" = x86_64 \
    && test "$(java -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64

FROM ${JRE_IMAGE} AS runtime-base
# The verifier needs POSIX sh and text tools, but runtime images must not retain
# a package manager or compiler frontend after the jars have been built.
RUN useradd --system --uid 65532 --no-create-home nonroot \
    && rm -f /usr/bin/apt /usr/bin/apt-* /usr/bin/dpkg /usr/bin/dpkg-* /usr/bin/curl \
    && test -x /bin/sh \
    && test "$(java -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /workspace/client/build/libs/convex-kotlin-example.jar /usr/local/lib/convex-kotlin-example.jar
COPY --chmod=755 <<'EOF' /usr/local/bin/convex-example
#!/bin/sh
exec java -jar /usr/local/lib/convex-kotlin-example.jar "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /workspace/client/build/libs/convex-kotlin-adapter.jar /usr/local/lib/convex-kotlin-adapter.jar
COPY --chmod=755 <<'EOF' /usr/local/bin/convex-adapter
#!/bin/sh
exec java -jar /usr/local/lib/convex-kotlin-adapter.jar "$@"
EOF
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
