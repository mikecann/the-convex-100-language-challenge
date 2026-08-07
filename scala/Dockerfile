# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG JAVA_IMAGE=maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM --platform=linux/amd64 ${JAVA_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
COPY README.md ./README.md

# Maven resolves Scala and Jackson only in this build stage.
RUN cd client && mvn -q -DskipTests package
RUN cd client && \
    mvn -q dependency:build-classpath -Dmdep.outputFile=/tmp/scalafmt-classpath && \
    format_status=0 && \
    java -cp "$(cat /tmp/scalafmt-classpath)" org.scalafmt.cli.Cli --test scala tests ../examples/basics > /tmp/scalafmt-output 2>&1 || format_status=$?; \
    sed -n '1,240p' /tmp/scalafmt-output; \
    test "$format_status" -eq 0; \
    ! grep -Eq 'error:|ParseError' /tmp/scalafmt-output
RUN java -cp client/target/classes:client/target/scala-client-0.1.0-all.jar convex.LiveAcceptanceTests && \
    mkdir -p /work/out/adapter /work/out/example && \
    cp examples/basics/Main.scala /work/out/canonical-example.scala && \
    sed -n '/^```scala$/,/^```$/p' README.md | sed '1d;$d' > /tmp/readme-example.scala && \
    cmp examples/basics/Main.scala /tmp/readme-example.scala && \
    cd client/target/classes && \
    find convex -maxdepth 1 -type f -name 'Adapter*.class' -exec cp --parents '{}' /work/out/adapter ';' && \
    find convex/example -maxdepth 1 -type f -name 'Main*.class' -exec cp --parents '{}' /work/out/example ';' && \
    jar cfe /work/out/adapter.jar convex.Adapter -C /work/out/adapter . && \
    jar cfe /work/out/example.jar convex.example.Main -C /work/out/example .
CMD ["/bin/sh", "-c", "uname -m | grep -qx x86_64 && test \"$(java -XshowSettings:properties -version 2>&1 | sed -n 's/.*os.arch = //p')\" = amd64"]

FROM test AS runtime-rootfs
RUN set -eu; \
    "$JAVA_HOME/bin/jlink" --add-modules java.base,java.net.http,java.logging,java.naming,java.security.jgss,jdk.crypto.ec --strip-debug --no-header-files --no-man-pages --compress=zip-6 --output /runtime/opt/java; \
    mkdir -p /runtime/bin /runtime/usr/bin /runtime/usr/local/bin /runtime/opt/convex /runtime/etc /runtime/usr/share /launchers; \
    for tool in dash mawk basename cat cmp cut env grep head id sed sort tail tr uname wc; do cp "/usr/bin/$tool" "/runtime/usr/bin/$tool"; done; \
    ln -s /usr/bin/dash /runtime/bin/sh; ln -s mawk /runtime/usr/bin/awk; \
    { ldd /runtime/opt/java/bin/java; find /runtime/opt/java -type f -name '*.so' -exec ldd '{}' ';'; for tool in /runtime/usr/bin/*; do ldd "$tool"; done; } | awk '/=> \// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | while IFS= read -r library; do cp --parents "$library" /runtime; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do test ! -e "$library" || cp --parents "$library" /runtime; done; \
    cp -a /etc/ssl /runtime/etc/ssl; cp -a /usr/share/ca-certificates /runtime/usr/share/ca-certificates; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" /runtime; done; \
    printf '%s\n' '#!/bin/sh' 'exec /opt/java/bin/java -cp /opt/convex/convex-client.jar:/opt/convex/adapter.jar convex.Adapter "$@"' > /launchers/convex-adapter; \
    printf '%s\n' '#!/bin/sh' 'exec /opt/java/bin/java -cp /opt/convex/convex-client.jar:/opt/convex/example.jar convex.example.Main "$@"' > /launchers/convex-example; chmod 0555 /launchers/convex-adapter /launchers/convex-example

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
# BusyBox supplies the pinned non-scratch filesystem. Its multicall binary also
# exposes dpkg, so replace its applets with only the POSIX tools the verifier uses.
RUN ["/bin/busybox", "sh", "-ec", "/bin/busybox rm -f /bin/* /usr/bin/* /usr/sbin/*"]
COPY --from=runtime-rootfs /runtime /
COPY --from=test /work/client/target/scala-client-0.1.0-all.jar /opt/convex/convex-client.jar
ENV PATH=/usr/local/bin:/usr/bin:/bin
RUN ["/bin/sh", "-ec", "for name in javac jar javadoc jshell jlink jmod jpackage keytool mvn apt apt-get dpkg gcc cc make node npm python python3 curl convex; do ! command -v \"$name\" >/dev/null 2>&1 || exit 1; done; /opt/java/bin/java -version"]
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /work/out/example.jar /opt/convex/example.jar
COPY --from=runtime-rootfs /launchers/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /work/out/adapter.jar /opt/convex/adapter.jar
COPY --from=runtime-rootfs /launchers/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
