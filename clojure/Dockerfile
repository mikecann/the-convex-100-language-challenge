# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG JAVA_IMAGE=maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS busybox

FROM --platform=linux/amd64 ${JAVA_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples

# Maven is only a deterministic dependency fetcher in this build stage. The
# final image contains the JRE, Clojure jars, source, and no build frontend.
RUN cd client && mvn -q dependency:build-classpath -Dmdep.outputFile=/work/classpath && mvn -q dependency:copy-dependencies -DoutputDirectory=/work/deps
RUN test "$(uname -m)" = x86_64 && test "$(java -XshowSettings:properties -version 2>&1 | sed -n 's/.*os.arch = //p')" = amd64
RUN CP="$(cat /work/classpath):/work/client:/work/client/tests:/work/client/tests/conformance:/work/examples/basics" && \
    java -cp "$CP" clojure.main -m run-tests && \
    printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | java -cp "$CP" clojure.main -m adapter >/tmp/adapter.ndjson && \
    grep -Fq '"language":"clojure"' /tmp/adapter.ndjson && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["/bin/sh", "-c", "test \"$(uname -m)\" = x86_64"]

FROM test AS runtime-rootfs
COPY --from=busybox /bin/busybox /runtime/bin/sh
COPY --from=busybox /bin/busybox /runtime/usr/bin/id
COPY --from=busybox /bin/busybox /runtime/usr/bin/grep
RUN set -eu; \
    "$JAVA_HOME/bin/jlink" --add-modules java.base,java.logging,java.naming,java.net.http,java.security.jgss,jdk.crypto.ec --strip-debug --no-header-files --no-man-pages --compress=zip-6 --output /runtime/opt/java; \
    mkdir -p /runtime/usr/local/bin /runtime/opt/convex/lib /runtime/etc /runtime/usr/share /launchers; \
    { ldd /runtime/opt/java/bin/java; find /runtime/opt/java -type f -name '*.so' -exec ldd '{}' ';'; } | awk '/=> \// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | while IFS= read -r library; do cp --parents "$library" /runtime; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do test ! -e "$library" || cp --parents "$library" /runtime; done; \
    cp -a /etc/ssl /runtime/etc/ssl; cp -a /usr/share/ca-certificates /runtime/usr/share/ca-certificates; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" /runtime; done; \
    printf '%s\n' '#!/bin/sh' 'exec /opt/java/bin/java -cp /opt/convex/lib/*:/opt/convex/client:/opt/convex/conformance clojure.main -m adapter "$@"' > /launchers/convex-adapter; \
    printf '%s\n' '#!/bin/sh' 'exec /opt/java/bin/java -cp /opt/convex/lib/*:/opt/convex/client:/opt/convex/example clojure.main -m convex.example.main "$@"' > /launchers/convex-example; \
    chmod 0555 /launchers/convex-adapter /launchers/convex-example

FROM scratch AS runtime-base
COPY --from=runtime-rootfs /runtime /
COPY --from=test /work/deps/ /opt/convex/lib/
COPY --from=test /work/client/convex /opt/convex/client/convex
RUN ["/bin/sh", "-ec", "for name in javac jar javadoc jshell jlink jmod jpackage keytool mvn apt apt-get dpkg gcc cc make node npm python python3 curl convex clojure; do ! command -v \"$name\" >/dev/null 2>&1 || exit 1; done; /opt/java/bin/java -version"]
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /work/examples/basics/main.clj /opt/convex/example/convex/example/main.clj
COPY --from=runtime-rootfs /launchers/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /work/client/tests/conformance/adapter.clj /opt/convex/conformance/adapter.clj
COPY --from=runtime-rootfs /launchers/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
