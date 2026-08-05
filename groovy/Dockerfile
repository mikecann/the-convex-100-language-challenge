# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GROOVY_IMAGE=groovy:4.0.27@sha256:3cff445b673a31b22ecc7217b41499208a15848303ac311617993a6123b685af
ARG JRE_IMAGE=eclipse-temurin:21.0.8_9-jre-jammy@sha256:db1689535962d757a5adabf57387584ed543d38c0b9d1fe870123ea362ad73b0

FROM --platform=linux/amd64 ${GROOVY_IMAGE} AS test
WORKDIR /src
COPY client ./client
COPY examples ./examples
# The checked-in layout stays educational; compilation creates the conventional tree only in Docker.
RUN mkdir -p out/classes \
 && groovyc -d out/classes client/ConvexClient.groovy client/LiveClient.groovy client/tests/conformance/Adapter.groovy examples/basics/Main.groovy client/tests/ClientTests.groovy \
 && java --add-modules jdk.httpserver -ea -cp 'out/classes:/opt/groovy/lib/*' convex.tests.ClientTests
ENTRYPOINT ["java", "--add-modules", "jdk.httpserver", "-ea", "-cp", "/src/out/classes:/opt/groovy/lib/*", "convex.tests.ClientTests"]

FROM test AS example-build
RUN printf '%s\n' '#!/bin/sh' 'exec java -cp "/opt/convex/lib/classes:/opt/convex/lib/*" examples.basics.Main "$@"' > out/convex-example && chmod 0555 out/convex-example

FROM test AS build
RUN printf '%s\n' '#!/bin/sh' 'exec java -cp "/opt/convex/lib/classes:/opt/convex/lib/*" convex.adapter.Adapter "$@"' > out/convex-adapter && chmod 0555 out/convex-adapter

FROM --platform=linux/amd64 ${JRE_IMAGE} AS runtime-base
RUN rm -f /opt/java/openjdk/bin/javac /opt/java/openjdk/bin/javadoc /opt/java/openjdk/bin/jlink /opt/java/openjdk/bin/jmod /opt/java/openjdk/bin/jshell /usr/bin/curl \
 && groupadd --gid 65532 nonroot && useradd --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin nonroot
COPY --from=test /src/out/classes /opt/convex/lib/classes
# Compiled Groovy bytecode needs the core runtime; JSON parsing needs this one
# small companion module. Deliberately do not copy Groovy's CLI/compiler modules.
COPY --from=test /opt/groovy/lib/groovy-4.0.27.jar /opt/groovy/lib/groovy-json-4.0.27.jar /opt/convex/lib/
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=example-build /src/out/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /src/out/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
