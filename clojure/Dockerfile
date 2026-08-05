# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG JAVA_IMAGE=maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${JAVA_IMAGE} AS test
ADD --checksum=sha256:e864cafd01f4cfb428c79245196bb885a70688bbc15662501efc342b6b0c300c \
    https://github.com/weavejester/cljfmt/releases/download/0.16.4/cljfmt-0.16.4-standalone.jar \
    /opt/cljfmt.jar
WORKDIR /work
COPY client ./client
COPY examples ./examples

# Maven only resolves the two pinned runtime libraries. Compilation, tests,
# formatting verification, and entrypoint compilation all stay in this stage.
RUN cd client \
    && mvn -q dependency:build-classpath -Dmdep.outputFile=/work/classpath \
    && mvn -q dependency:copy-dependencies -DincludeScope=runtime -DoutputDirectory=/work/deps
RUN test "$(uname -m)" = x86_64 \
    && test "$(java -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64
RUN CP="$(cat /work/classpath):/work/client:/work/client/tests:/work/client/tests/conformance:/work/examples/basics" \
    && java -jar /opt/cljfmt.jar check client examples \
    && java --add-modules jdk.httpserver -cp "$CP" clojure.main -m run-tests \
    && mkdir -p /work/adapter-classes /work/example-classes \
    && java -cp "$CP" clojure.main -e \
      '(binding [*compile-path* "/work/adapter-classes"] (compile (quote convex.client)) (compile (quote adapter)))' \
    && java -cp "$CP" clojure.main -e \
      '(binding [*compile-path* "/work/example-classes"] (compile (quote convex.client)) (compile (quote main)))' \
    && printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' \
      | java -cp "/work/deps/*:/work/adapter-classes" adapter >/tmp/adapter.ndjson \
    && grep -Fq '"language":"clojure"' /tmp/adapter.ndjson \
    && grep -Fq '"type":"closed"' /tmp/adapter.ndjson
CMD ["/bin/sh", "-c", "test \"$(uname -m)\" = x86_64"]

FROM test AS runtime-rootfs
RUN set -eu; \
    "$JAVA_HOME/bin/jlink" \
        --add-modules java.base,java.logging,java.management,java.net.http,java.sql,jdk.crypto.ec \
        --compress=zip-6 \
        --no-header-files \
        --no-man-pages \
        --strip-debug \
        --output /runtime/opt/clojure-jre; \
    rm -f /runtime/opt/clojure-jre/bin/keytool; \
    mkdir -p /runtime/etc/ssl/certs /runtime/usr/local/lib /runtime/opt/convex/lib /launchers; \
    { \
        ldd /runtime/opt/clojure-jre/bin/java; \
        find /runtime/opt/clojure-jre -type f -name '*.so' -exec ldd '{}' ';'; \
    } | awk \
        '/=> \/(lib|usr\/lib)/ { print $3 } $1 ~ /^\/(lib|usr\/lib)/ && $1 !~ /:$/ { print $1 }' \
      | sort -u \
      | while IFS= read -r library; do cp --parents "$library" /runtime; done; \
    for library in \
        /lib/x86_64-linux-gnu/libnss_dns.so.2 \
        /lib/x86_64-linux-gnu/libnss_files.so.2 \
        /lib/x86_64-linux-gnu/libresolv.so.2; do \
        cp --parents "$library" /runtime; \
    done; \
    cp /etc/ssl/certs/ca-certificates.crt /runtime/etc/ssl/certs/; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
        test ! -e "$config" || cp --parents "$config" /runtime; \
    done; \
    printf '%s\n' '#!/bin/sh' \
      'exec /opt/clojure-jre/bin/java -XX:+PerfDisableSharedMem -cp /opt/convex/lib/*:/opt/convex/adapter-classes adapter "$@"' \
      > /launchers/convex-adapter; \
    printf '%s\n' '#!/bin/sh' \
      'exec /opt/clojure-jre/bin/java -XX:+PerfDisableSharedMem -cp /opt/convex/lib/*:/opt/convex/example-classes main "$@"' \
      > /launchers/convex-example; \
    chmod 0555 /launchers/convex-adapter /launchers/convex-example

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
# Retain only the POSIX tools used by shared policy. Removing /bin/busybox
# prevents the multicall binary from becoming a package/tooling escape hatch.
RUN set -eu; \
    /bin/busybox find /bin -mindepth 1 ! -name busybox -delete; \
    /bin/busybox find /usr/bin -mindepth 1 -delete; \
    /bin/busybox cp /bin/busybox /bin/sh; \
    for tool in awk basename cat cmp cut find grep head id ls sed sort tail tr uniq uname wc; do \
        /bin/busybox ln /bin/sh "/bin/$tool"; \
    done; \
    /bin/busybox unlink /bin/busybox
COPY --from=runtime-rootfs /runtime /
COPY --from=test /work/deps/ /opt/convex/lib/
ENV PATH=/opt/clojure-jre/bin:/usr/local/bin:/usr/bin:/bin
RUN test -x /bin/sh \
    && test "$(java -XX:+PerfDisableSharedMem -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64 \
    && test ! -e /bin/busybox \
    && ! command -v javac \
    && ! command -v jar \
    && ! command -v clojure \
    && ! command -v mvn \
    && ! command -v wget
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /work/example-classes/ /opt/convex/example-classes/
COPY --from=runtime-rootfs /launchers/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /work/adapter-classes/ /opt/convex/adapter-classes/
COPY --from=runtime-rootfs /launchers/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
