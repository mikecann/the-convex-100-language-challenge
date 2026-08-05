# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GRADLE_IMAGE=gradle:8.14.3-jdk21-jammy@sha256:554981bbebcbe0fe9ad77f5d0d10729ef0e998f20248eb5d38221c1473532604
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23

FROM ${GRADLE_IMAGE} AS test
WORKDIR /workspace
COPY client ./client
COPY examples ./examples
# All Kotlin tooling and dependency resolution remains in this build stage.
RUN gradle --no-daemon --project-dir client ktlintCheck check adapterJar exampleJar \
    && test "$(uname -m)" = x86_64 \
    && test "$(java -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64
CMD ["gradle", "--no-daemon", "--project-dir", "client", "check"]

FROM test AS runtime-rootfs
# Project only the JRE modules and native libraries the client actually loads.
# The CA bundle and glibc resolver pieces are copied explicitly so TLS and DNS
# do not depend on carrying the complete build-distribution root filesystem.
RUN set -eu; \
    "$JAVA_HOME/bin/jlink" \
        --add-modules java.base,java.logging,java.net.http,jdk.crypto.ec \
        --compress=zip-6 \
        --no-header-files \
        --no-man-pages \
        --strip-debug \
        --output /runtime/opt/kotlin-jre; \
    rm -f /runtime/opt/kotlin-jre/bin/keytool; \
    mkdir -p /runtime/etc/ssl/certs /runtime/usr/local/lib /launchers; \
    { \
        ldd /runtime/opt/kotlin-jre/bin/java; \
        find /runtime/opt/kotlin-jre -type f -name '*.so' -exec ldd '{}' ';'; \
    } | awk \
        '/=> \/(lib|usr\/lib)/ { print $3 } $1 ~ /^\/(lib|usr\/lib)/ && $1 !~ /:$/ { print $1 }' | \
        sort -u | \
        while IFS= read -r library; do cp --parents "$library" /runtime; done; \
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
    printf '%s\n' '#!/bin/sh' 'exec /opt/kotlin-jre/bin/java -jar /usr/local/lib/convex-kotlin-adapter.jar "$@"' > /launchers/convex-adapter; \
    printf '%s\n' '#!/bin/sh' 'exec /opt/kotlin-jre/bin/java -jar /usr/local/lib/convex-kotlin-example.jar "$@"' > /launchers/convex-example; \
    chmod 0555 /launchers/convex-adapter /launchers/convex-example

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS runtime-base
# BusyBox supplies the required non-scratch base. Remove its broad applet
# surface, then expose only the shell and text tools used by runtime policy.
RUN set -eu; \
    /bin/busybox find /bin -mindepth 1 ! -name busybox -delete; \
    /bin/busybox find /usr/bin -mindepth 1 -delete; \
    /bin/busybox cp /bin/busybox /bin/sh; \
    for tool in awk basename cat cmp cut find grep head id ls sed sort tail tr uniq uname wc; do \
        /bin/busybox ln /bin/sh "/bin/$tool"; \
    done; \
    /bin/busybox rm -f \
        /etc/localtime /etc/mtab /etc/shadow; \
    for directory in \
        /etc/network/if-down.d \
        /etc/network/if-post-down.d \
        /etc/network/if-pre-up.d \
        /etc/network/if-up.d \
        /etc/network \
        /home \
        /opt \
        /runtime \
        /usr/sbin \
        /var/spool/mail \
        /var/spool \
        /var/www \
        /var; do \
        test ! -d "$directory" || /bin/busybox rmdir "$directory"; \
    done; \
    /bin/busybox unlink /bin/busybox
COPY --from=runtime-rootfs /runtime /
ENV PATH=/opt/kotlin-jre/bin:/usr/local/bin:/usr/bin:/bin
RUN test -x /bin/sh \
    && test "$(java -XX:+PerfDisableSharedMem -XshowSettings:properties -version 2>&1 | awk '/os.arch =/ { print $3 }')" = amd64 \
    && test ! -e /bin/busybox \
    && ! command -v javac \
    && ! command -v gradle \
    && ! command -v wget
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test /workspace/client/build/libs/convex-kotlin-example.jar /usr/local/lib/convex-kotlin-example.jar
COPY --from=runtime-rootfs /launchers/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test /workspace/client/build/libs/convex-kotlin-adapter.jar /usr/local/lib/convex-kotlin-adapter.jar
COPY --from=runtime-rootfs /launchers/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
