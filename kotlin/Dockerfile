# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GRADLE_IMAGE=gradle:8.14.3-jdk21-jammy@sha256:554981bbebcbe0fe9ad77f5d0d10729ef0e998f20248eb5d38221c1473532604
ARG JDK_ALPINE_IMAGE=eclipse-temurin:21-jdk-alpine@sha256:1ff763083f2993d57d0bf374ab10bb3e2cb873af6c13a04458ebbd3e0337dc76
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

FROM ${GRADLE_IMAGE} AS test
WORKDIR /workspace
COPY client ./client
COPY examples ./examples
# All Kotlin tooling and dependency resolution remains in this build stage.
RUN gradle --no-daemon --project-dir client ktlintCheck check adapterJar exampleJar \
    && test "$(uname -m)" = x86_64 \
    && test "$(java -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64
CMD ["gradle", "--no-daemon", "--project-dir", "client", "check"]

FROM ${JDK_ALPINE_IMAGE} AS runtime-link
RUN jlink \
    --add-modules java.base,java.logging,java.net.http,jdk.crypto.ec \
    --compress=zip-6 \
    --no-header-files \
    --no-man-pages \
    --strip-debug \
    --output /opt/kotlin-jre

FROM ${ALPINE_IMAGE} AS runtime-base
# The final image contains only a jlink-tailored runtime, CA roots, and BusyBox
# sh/text tools required by the shared policy. apk is removed after installing
# certificates so no package manager or JDK frontend remains.
RUN apk add --no-cache ca-certificates=20260611-r0 \
    && rm -f /sbin/apk \
        /usr/bin/ftpget \
        /usr/bin/ftpput \
        /usr/bin/nc \
        /usr/bin/telnet \
        /usr/bin/wget
COPY --from=runtime-link /opt/kotlin-jre /opt/kotlin-jre
ENV PATH=/opt/kotlin-jre/bin:/usr/local/bin:/usr/bin:/bin
RUN rm -f /opt/kotlin-jre/bin/keytool \
    && test -x /bin/sh \
    && test "$(java -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64 \
    && ! command -v javac \
    && ! command -v apk
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
