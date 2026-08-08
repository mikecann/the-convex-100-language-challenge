# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG PHP_IMAGE=php:8.4.8-cli-alpine3.22@sha256:c9b1ab69749902c0e8ccd4424ca81e4154f0b7cf055e53f5a9b2b0056dc647d4
ARG ALPINE_BUILDER_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
FROM --platform=linux/amd64 ${PHP_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
# PHP itself parses every runnable source, including the adapter and example.
RUN php -v && test "$(uname -m)" = x86_64 && find client examples -name '*.php' -exec php -l '{}' \;
RUN php client/tests.php
RUN php client/fixture_test.php
RUN php client/adapter_fixture.php
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | php client/tests/conformance/adapter.php | grep -q '"language":"php"'
CMD ["php", "-r", "exit(0);"]

# Alpine's own /bin/sh, and everything else in /bin, /sbin, /usr/bin and
# /usr/sbin, is BusyBox: one multicall binary that `busybox --install` turns
# into ~300 symlinks (including wget and nc, both compiled into Alpine's
# default BusyBox build) at image-build time. apk's package database owns
# only the busybox binary's own package entry, not those symlinks, so the
# apk/curl/pear/php-ext cleanup this image already did left every one of
# those applets fully reachable, /bin/sh included. This stage compiles a
# from-source BusyBox with only the applets the shared verifier's
# image_policy and this Dockerfile's own checks need.
FROM --platform=linux/amd64 ${ALPINE_BUILDER_IMAGE} AS busybox-builder
RUN apk add --no-cache \
      build-base=0.5-r3 \
      linux-headers=6.14.2-r0
ADD --checksum=sha256:3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 /tmp/busybox.tar.bz2
WORKDIR /src
RUN tar -xjf /tmp/busybox.tar.bz2 && \
    cd busybox-1.37.0 && \
    printf '%s\n' \
      'CONFIG_STATIC=y' \
      'CONFIG_BUSYBOX=y' \
      'CONFIG_ASH=y' \
      'CONFIG_ASH_TEST=y' \
      'CONFIG_ASH_CMDCMD=y' \
      'CONFIG_SH_IS_ASH=y' \
      'CONFIG_TEST=y' \
      'CONFIG_TEST1=y' \
      'CONFIG_TEST2=y' \
      'CONFIG_ID=y' \
      'CONFIG_GREP=y' \
      > /tmp/minimal.config && \
    make allnoconfig >/dev/null && \
    while IFS= read -r setting; do \
      name="${setting%%=*}"; \
      sed -i "s/^# $name is not set$/$setting/" .config; \
    done < /tmp/minimal.config && \
    make oldconfig </dev/null >/dev/null && \
    make -j2 busybox && \
    mkdir -p /out && \
    cp busybox /out/busybox
RUN cd busybox-1.37.0 && \
    file ./busybox | grep -q 'statically linked' && \
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash grep id sh test)" && \
    for tool in apk apt apt-get curl dpkg nc rpm wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

# The official CLI image supplies PHP's required runtime libraries under
# /usr/local/lib and /usr/lib, which stay untouched. Everything BusyBox owns
# in /bin, /sbin, /usr/bin and /usr/sbin — apk included, since it is one
# more BusyBox applet symlink on this image rather than a separate package —
# is deleted and replaced by the restricted BusyBox above, hard-linked under
# the applet names it serves and never written to a path literally named
# busybox: a from-source rebuild that still ends up at /bin/busybox only
# proves the applet table changed, not that the image stopped being "the
# official image with apk and the php-ext tooling removed".
FROM --platform=linux/amd64 ${PHP_IMAGE} AS runtime-base
RUN find /usr/local/bin -mindepth 1 -maxdepth 1 ! -name php -delete && \
    rm -f /sbin/apk /usr/sbin/apk /usr/bin/curl && \
    rm -rf /etc/apk /lib/apk /usr/lib/libapk* /usr/local/include/php /usr/local/lib/php/build /usr/local/lib/php/.registry /usr/local/share/pear /usr/local/etc/pear.conf && \
    for command in composer curl node npm python python3 gcc cc make phpize php-config pecl pear phar phpdbg php-cgi docker-php-ext-install docker-php-ext-enable docker-php-source; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done && \
    set -- /usr/local/bin/*; test "$#" = 1; test "$1" = /usr/local/bin/php && \
    php -m | grep -qx json && test "$(php -r 'echo PHP_INT_SIZE * 8;')" = 64
COPY --from=busybox-builder /out/busybox /restricted-busybox
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox mkdir /policy /verify; \
    /bin/busybox cp /bin/busybox /policy/busybox; \
    /bin/busybox cp /restricted-busybox /verify/busybox; \
    test "$(/verify/busybox --list)" = "$(printf "%s\n" "[" "[[" ash grep id sh test)"; \
    for tool in apk apt apt-get curl dpkg nc rpm wget; do \
      test "$(/verify/busybox "$tool" 2>/dev/null; printf "%s" "$?")" = 127; \
    done; \
    /policy/busybox rm -rf /verify; \
    /policy/busybox rm -rf /etc/busybox-paths.d; \
    /policy/busybox find /bin /sbin /usr/bin /usr/sbin -mindepth 1 -maxdepth 1 -delete; \
    /policy/busybox mkdir -p /bin /usr/bin /usr/local/bin; \
    /policy/busybox mv /restricted-busybox /bin/sh; \
    /policy/busybox ln /bin/sh /usr/bin/id; \
    /policy/busybox ln /bin/sh /usr/bin/grep; \
    test -x /bin/sh; \
    test -x /usr/bin/id; \
    test -x /usr/bin/grep; \
    for name in apk apt apt-get curl dpkg nc rpm wget; do \
      implicit="$(/bin/sh -c "exec -a $name /bin/sh" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$implicit" = 127; \
      explicit="$(/bin/sh -c "exec -a busybox /bin/sh $name" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$explicit" = 127; \
    done; \
    forbidden="$(/policy/busybox find / -xdev -path /policy -prune -o \( -type f -o -type l \) \( -name apk -o -name apt -o -name apt-get -o -name busybox -o -name curl -o -name dpkg -o -name nc -o -name rpm -o -name wget \) -print)"; \
    test -z "$forbidden"; \
    /policy/busybox rm -rf /policy; \
    test ! -e /policy'
RUN set -eu; \
    set -- /usr/local/bin/*; \
    test "$#" = 1; \
    test "$1" = /usr/local/bin/php; \
    php -m | grep -qx json; \
    test "$(php -r 'echo PHP_INT_SIZE * 8;')" = 64
ENV CONVEX_CLIENT_PATH=/opt/convex/client/convex.php
COPY client/convex.php /opt/convex/client/convex.php
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.php /usr/local/bin/convex-example
RUN ["/bin/sh", "-ec", "for name in composer curl apk busybox wget nc phpize php-config pecl pear phar phpdbg php-cgi docker-php-ext-install docker-php-ext-enable docker-php-source; do ! command -v \"$name\" || exit 1; done"]
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.php /usr/local/bin/convex-adapter
RUN ["/bin/sh", "-ec", "for name in composer curl apk busybox wget nc phpize php-config pecl pear phar phpdbg php-cgi docker-php-ext-install docker-php-ext-enable docker-php-source; do ! command -v \"$name\" || exit 1; done"]
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
