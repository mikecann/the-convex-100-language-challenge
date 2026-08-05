# syntax=docker/dockerfile:1.7
ARG JAVA_IMAGE=maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e
FROM --platform=linux/amd64 ${JAVA_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
# Maven, javac, tests, and dependency resolution stay entirely in this build stage.
RUN cd client && mvn -q -DskipTests package
RUN java -cp client/target/java-client-0.1.0-all.jar:client/target/test-classes convex.ConvexClientTest
RUN mkdir -p /work/out/adapter /work/out/example && \
    javac -cp client/target/java-client-0.1.0-all.jar -d /work/out/adapter client/tests/conformance/Adapter.java && \
    javac -cp client/target/java-client-0.1.0-all.jar -d /work/out/example examples/basics/Main.java && \
    jar cfe /work/out/adapter.jar convex.adapter.Adapter -C /work/out/adapter . && \
    jar cfe /work/out/example.jar convex.example.Main -C /work/out/example . && \
    printf '%s\n%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | java -cp client/target/java-client-0.1.0-all.jar:/work/out/adapter.jar convex.adapter.Adapter | grep -F '"type":"closed"'
CMD ["/bin/sh", "-c", "uname -m | grep -qx x86_64 && java -version && test \"$(java -XshowSettings:properties -version 2>&1 | sed -n 's/.*os.arch = //p')\" = amd64"]

FROM --platform=linux/amd64 eclipse-temurin:21.0.8_9-jre-noble@sha256:20e7f7288e1c18eebe8f06a442c9f7183342d9b022d3b9a9677cae2b558ddddd AS runtime-base
# The final image keeps only the JVM and application jars. It intentionally has
# no compiler, Maven, or Convex tooling; runtime image policy is exercised by root.
RUN command -v javac >/dev/null 2>&1 && exit 1 || true
USER 65532:65532
FROM runtime-base AS example-runtime
COPY --from=test /work/client/target/java-client-0.1.0-all.jar /opt/convex/convex-client.jar
COPY --from=test /work/out/example.jar /opt/convex/example.jar
ENTRYPOINT ["java", "-cp", "/opt/convex/convex-client.jar:/opt/convex/example.jar", "convex.example.Main"]
FROM runtime-base AS runtime
COPY --from=test /work/client/target/java-client-0.1.0-all.jar /opt/convex/convex-client.jar
COPY --from=test /work/out/adapter.jar /opt/convex/adapter.jar
ENTRYPOINT ["java", "-cp", "/opt/convex/convex-client.jar:/opt/convex/adapter.jar", "convex.adapter.Adapter"]
