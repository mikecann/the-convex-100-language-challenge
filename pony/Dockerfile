# syntax=docker/dockerfile:1.7
#
# Pony client build and hardened runtime images.
#
# Two things shape this file. Pony links its runtime into the executable, so a
# statically linked musl build produces a single self-contained binary with no
# language runtime to ship. The only third party Pony package is `net_ssl`,
# which is fetched at the version pinned in `client/corral.json`. OpenSSL also
# supplies TLS and operating-system entropy for RFC 6455 masking keys.
#
ARG PONYC_IMAGE=ponylang/ponyc:0.58.0-alpine@sha256:d4e91cecca428e39f5e97e2acc4fdef07e00ffb97b2905c71dd97591ce7430c3
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23
ARG NET_SSL_VERSION=1.3.2
ARG NET_SSL_COMMIT=16ce265bbd3cfa6a6d30341ea0291ea8afd65c01

FROM --platform=linux/amd64 ${BUSYBOX_IMAGE} AS busybox

# A stock BusyBox is a complete command surface: removing symlinks would not
# remove the applets, which can still be reached through the multicall binary
# or a forged argv[0]. Building a restricted one is the only way to make the
# absence of a package manager or downloader real.
FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS busybox-builder
RUN apk add --no-cache build-base linux-headers
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
      'CONFIG_AWK=y' \
      'CONFIG_CAT=y' \
      'CONFIG_CUT=y' \
      'CONFIG_ID=y' \
      'CONFIG_GREP=y' \
      'CONFIG_HEAD=y' \
      'CONFIG_SED=y' \
      'CONFIG_SORT=y' \
      'CONFIG_TAIL=y' \
      'CONFIG_TR=y' \
      'CONFIG_UNAME=y' \
      'CONFIG_UNIQ=y' \
      'CONFIG_WC=y' \
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
    test "$(./busybox --list)" = "$(printf '%s\n' '[' '[[' ash awk cat cut grep head id sed sh sort tail test tr uname uniq wc)" && \
    for tool in apk apt apt-get curl nc wget; do \
      test "$(./busybox "$tool" 2>/dev/null; printf '%s' "$?")" = 127; \
    done

FROM --platform=linux/amd64 ${PONYC_IMAGE} AS dependencies
ARG NET_SSL_VERSION
ARG NET_SSL_COMMIT
USER 0:0
RUN apk add --no-cache file git openssl-dev openssl-libs-static
WORKDIR /deps
COPY client/corral.json /tmp/corral.json
# The Docker build fetches the dependency directly instead of running corral,
# but the version it fetches must be the one the checked-in manifest declares.
RUN grep -F "\"version\": \"${NET_SSL_VERSION}\"" /tmp/corral.json && \
    grep -F "github.com/ponylang/net_ssl.git" /tmp/corral.json && \
    git clone --depth 1 --branch "${NET_SSL_VERSION}" \
      https://github.com/ponylang/net_ssl.git /deps/net_ssl && \
    test "$(git -C /deps/net_ssl rev-parse HEAD)" = "${NET_SSL_COMMIT}" && \
    test -d /deps/net_ssl/net_ssl

FROM dependencies AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
RUN test "$(uname -m)" = x86_64

# Pony has no official formatter, so the check is the project's own style
# rules: no tabs, no trailing whitespace, and no line wider than eighty
# columns, which is what the standard library follows.
RUN set -eu; \
    find client examples -name '*.pony' -type f -print | sort | while read -r source; do \
      if grep -qP '\t' "$source"; then echo "tab in $source" >&2; exit 1; fi; \
      if grep -qE ' +$' "$source"; then echo "trailing space in $source" >&2; exit 1; fi; \
      if grep -qE '.{81,}' "$source"; then echo "line over 80 columns in $source" >&2; exit 1; fi; \
    done

# The client's own tests. `convex_adapter` is defined so the adapter-only
# `debugDisconnect` hook is compiled in and the five-reconnect test can prove
# it; an ordinary client build leaves it out.
RUN ponyc --define convex_adapter --define openssl_3.0.x \
      --path /deps/net_ssl \
      --output /tmp/build --bin-name convex-client-test client && \
    /tmp/build/convex-client-test --sequential

# The conformance adapter's own tests, which cover the exact serialised shape
# of every event before the shared controller ever sees one.
RUN ponyc --define convex_adapter --define openssl_3.0.x \
      --path /deps/net_ssl \
      --output /tmp/build --bin-name convex-adapter-test \
      client/tests/conformance/core && \
    /tmp/build/convex-adapter-test --sequential

RUN ponyc --define convex_adapter --define openssl_3.0.x \
      --static --path /deps/net_ssl \
      --output /tmp/build --bin-name convex-adapter \
      client/tests/conformance && \
    ponyc --define openssl_3.0.x --static --path /deps/net_ssl \
      --output /tmp/build --bin-name convex-example examples/basics && \
    file /tmp/build/convex-adapter | grep -F 'x86-64' && \
    file /tmp/build/convex-example | grep -F 'x86-64'

# A strictness probe against the real adapter binary, with no deployment
# configured: an unparseable line, a missing id, an over-long id, an unknown
# operation, and a wrong protocol version must each produce a structured error
# rather than a guess, and `close` must still shut down cleanly.
RUN set -eu; \
    long_id=$(printf '%129s' '' | tr ' ' x); \
    actual=$({ \
      printf '%s\n' \
        '{"protocolVersion":1,"id":"hello","op":"hello"}' \
        'not json at all' \
        '{"protocolVersion":1,"op":"hello"}' \
        '{"id":"bad","op":"hello","protocolVersion":2}' \
        '{"id":"unknown","op":"nope"}' \
        '{"id":"extra","op":"close","surprise":1}'; \
      printf '{"id":"%s","op":"close"}\n' "$long_id"; \
      printf '%s\n' '{"id":"close","op":"close"}'; \
    } | /tmp/build/convex-adapter); \
    printf '%s\n' "$actual" | grep -F '"id":"hello"' | grep -F '"type":"ready"'; \
    printf '%s\n' "$actual" | grep -F '"language":"pony"'; \
    ! printf '%s\n' "$actual" | grep -F 'null'; \
    printf '%s\n' "$actual" | grep -F '"id":"unknown"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"extra"' | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"bad"' | grep -F '"type":"error"'; \
    test "$(printf '%s\n' "$actual" | grep -cF 'adapter command id must be')" -eq 2; \
    printf '%s\n' "$actual" | grep -F '"id":"close","type":"closed"'

# The same stream over the TCP transport the shared harness uses.
RUN set -eu; \
    ADAPTER_LISTEN=127.0.0.1:18080 /tmp/build/convex-adapter & adapter_pid=$!; \
    sleep 1; \
    actual=$(printf '%s\n' \
      '{"protocolVersion":1,"id":"tcp","op":"hello"}' \
      '{"id":"close","op":"close"}' | \
      nc 127.0.0.1 18080); \
    wait "$adapter_pid"; \
    printf '%s\n' "$actual" | grep -F '"id":"tcp"' | grep -F '"type":"ready"'; \
    printf '%s\n' "$actual" | grep -F '"id":"close","type":"closed"'
ENTRYPOINT []
# Running the test image re-runs the deterministic client tests, so `./run test
# pony` is a real test run rather than a replay of build cache.
CMD ["/tmp/build/convex-client-test", "--sequential"]

FROM test AS artifacts
RUN mkdir -p /common/etc/ssl/certs /adapter /example && \
    cp /tmp/build/convex-example /example/convex-example && \
    cp /tmp/build/convex-adapter /adapter/convex-adapter && \
    cp /etc/ssl/certs/ca-certificates.crt /common/etc/ssl/certs/ca-certificates.crt && \
    cp /etc/ssl/openssl.cnf /common/etc/ssl/openssl.cnf && \
    chmod 0755 /example/convex-example /adapter/convex-adapter

FROM busybox AS runtime-base
USER 0:0
COPY --from=busybox-builder /out/busybox /restricted-busybox
# BusyBox's multicall dispatcher only enters "top-level" mode (--list,
# explicit `busybox <applet>`) when argv[0]'s basename is literally
# "busybox"; invoked under any other name it looks that name up directly in
# the compiled applet table. The restricted binary is therefore verified
# through a copy at a path still named "busybox" that is deleted before this
# layer ends, then installed under the applet names it actually serves and
# never again written to a path literally named busybox: a from-source
# rebuild that still ends up at /bin/busybox only proves the applet table
# changed, not that the image stopped being "a copy of BusyBox with a longer
# denylist" the way this stage's own FROM busybox starts out.
RUN /bin/busybox sh -c 'set -eu; \
    /bin/busybox mkdir /policy /verify; \
    /bin/busybox cp /bin/busybox /policy/busybox; \
    /bin/busybox cp /restricted-busybox /verify/busybox; \
    test "$(/verify/busybox --list | /verify/busybox grep -c "^")" = 18; \
    for applet in "[" "[[" ash awk cat cut grep head id sed sh sort tail test tr uname uniq wc; do /verify/busybox --list | /verify/busybox grep -Fqx "$applet"; done; \
    for tool in apk apt apt-get curl nc wget; do \
      if /verify/busybox "$tool" >/dev/null 2>&1; then exit 1; else test "$?" = 127; fi; \
    done; \
    /policy/busybox rm -rf /verify; \
    /policy/busybox rm -rf /etc/group /etc/localtime /etc/mtab /etc/network /etc/passwd /etc/shadow /.cache /home /root /sbin /tmp /usr /var /lib; \
    /policy/busybox find /bin -mindepth 1 -maxdepth 1 -delete; \
    /policy/busybox mkdir -p /usr/bin /usr/local/bin; \
    /policy/busybox mv /restricted-busybox /bin/sh; \
    for applet in awk cat cut grep head id sed sort tail tr uname uniq wc; do \
      /policy/busybox ln /bin/sh "/usr/bin/$applet"; \
    done; \
    test -x /bin/sh; \
    test -x /usr/bin/grep; \
    for name in apk apt apt-get curl nc wget; do \
      implicit="$(/bin/sh -c "exec -a $name /bin/sh" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$implicit" = 127; \
      explicit="$(/bin/sh -c "exec -a busybox /bin/sh $name" >/dev/null 2>&1; printf "%s" "$?")"; \
      test "$explicit" = 127; \
    done; \
    forbidden="$(/policy/busybox find / -xdev -path /policy -prune -o \( -type f -o -type l \) \( -name apk -o -name apt -o -name apt-get -o -name busybox -o -name curl -o -name nc -o -name wget -o -name ponyc -o -name corral \) -print)"; \
    test -z "$forbidden"; \
    /policy/busybox rm -rf /policy; \
    test ! -e /policy'
COPY --from=artifacts /common /
# The runtime version is not exposed to a Pony program, so the image that pins
# the toolchain stamps it here and the adapter reports exactly this value.
ENV PONY_RUNTIME_VERSION=0.58.0
RUN set -eu; \
    test -x /bin/sh && test -x /usr/bin/id && test -x /usr/bin/grep; \
    test ! -e /bin/busybox; \
    for tool in apk apt apt-get curl wget nc gcc cc make ld ponyc corral node npm python python3 convex; do \
      ! command -v "$tool" >/dev/null 2>&1 || exit 1; \
    done; \
    test -r /etc/ssl/certs/ca-certificates.crt; \
    for entry in /usr/local/bin/*; do \
      test "$entry" = "/usr/local/bin/*" || { printf 'unexpected entry: %s\n' "$entry" >&2; exit 1; }; \
    done
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=artifacts --chown=65532:65532 /example/convex-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=artifacts --chown=65532:65532 /adapter/convex-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
