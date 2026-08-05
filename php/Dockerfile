# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG PHP_IMAGE=php:8.4.8-cli-alpine3.22@sha256:c9b1ab69749902c0e8ccd4424ca81e4154f0b7cf055e53f5a9b2b0056dc647d4
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

FROM --platform=linux/amd64 ${PHP_IMAGE} AS runtime-base
# The official CLI image supplies PHP's required runtime libraries. Remove apk
# and its database after copying source so the final image cannot install code.
RUN find /usr/local/bin -mindepth 1 -maxdepth 1 ! -name php -delete && \
    rm -f /sbin/apk /usr/sbin/apk /usr/bin/curl && \
    rm -rf /etc/apk /lib/apk /usr/lib/libapk* /usr/local/include/php /usr/local/lib/php/build /usr/local/lib/php/.registry /usr/local/share/pear /usr/local/etc/pear.conf && \
    for command in composer curl node npm python python3 gcc cc make phpize php-config pecl pear phar phpdbg php-cgi docker-php-ext-install docker-php-ext-enable docker-php-source; do ! command -v "$command" >/dev/null 2>&1 || exit 1; done && \
    set -- /usr/local/bin/*; test "$#" = 1; test "$1" = /usr/local/bin/php && \
    php -m | grep -qx json && test "$(php -r 'echo PHP_INT_SIZE * 8;')" = 64
ENV CONVEX_CLIENT_PATH=/opt/convex/client/convex.php
COPY client/convex.php /opt/convex/client/convex.php
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.php /usr/local/bin/convex-example
RUN ["/bin/sh", "-ec", "for name in composer curl apk phpize php-config pecl pear phar phpdbg php-cgi docker-php-ext-install docker-php-ext-enable docker-php-source; do ! command -v \"$name\" || exit 1; done"]
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0555 client/tests/conformance/adapter.php /usr/local/bin/convex-adapter
RUN ["/bin/sh", "-ec", "for name in composer curl apk phpize php-config pecl pear phar phpdbg php-cgi docker-php-ext-install docker-php-ext-enable docker-php-source; do ! command -v \"$name\" || exit 1; done"]
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
