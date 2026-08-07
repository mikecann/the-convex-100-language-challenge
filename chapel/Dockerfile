# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG CHAPEL_IMAGE=chapel/chapel:2.8.0@sha256:15679a34419ef19fc9d97ffdb0da6d2b2a07763dcc0c08871992595f7d6d7739
ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
ARG DEBIAN_SNAPSHOT=20260806T000000Z

FROM --platform=linux/amd64 ${CHAPEL_IMAGE} AS build
ARG DEBIAN_SNAPSHOT
WORKDIR /work
RUN --mount=type=tmpfs,target=/var/cache/apt \
    sed -i \
      -e "s|https://deb.debian.org/debian-security|https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|g" \
      -e "s|http://deb.debian.org/debian-security|https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|g" \
      -e "s|https://deb.debian.org/debian|https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|g" \
      -e "s|http://deb.debian.org/debian|https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|g" \
      /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install --yes --no-install-recommends \
      binutils file libcurl4-openssl-dev libjson-c-dev openssl python3 \
    && mkdir -p /out \
    && dpkg-query -W -f='${Package}=${Version}\n' \
      binutils libcurl4-openssl-dev libjson-c-dev libssl3t64 openssl python3 \
      | sort | tee /out/material-versions \
    && rm -rf /var/lib/apt/lists/*
COPY client/*.chpl client/*.c client/*.h ./client/
COPY client/tests/*.chpl ./client/tests/
COPY client/tests/conformance/*.chpl ./client/tests/conformance/
COPY examples ./examples
RUN test "$(uname -m)" = x86_64 \
    && chpl --version | grep -F 'chpl version 2.8.0'
RUN chpl -M client client/Transport.chpl client/Convex.chpl \
      client/tests/TransportTest.chpl client/tests/ClientTest.chpl \
      --ccflags=-DCHAPEL_TRANSPORT_TEST \
      --main-module ChapelConvexClientTest \
      -o /out/client-test \
    && chpl -M client client/Transport.chpl client/Convex.chpl \
      client/tests/conformance/Adapter.chpl \
      --main-module ChapelConvexAdapter -o /out/convex-adapter \
    && chpl -M client client/Transport.chpl client/Convex.chpl \
      examples/basics/main.chpl --main-module ChapelConvexBasics \
      -o /out/convex-example \
    && chpl -M client client/Transport.chpl client/Convex.chpl \
      client/tests/FixtureTest.chpl \
      --main-module ChapelConvexFixtureTest -o /out/fixture-test \
    && chpl -M client client/Transport.chpl client/Convex.chpl \
      client/tests/conformance/Adapter.chpl \
      --main-module ChapelConvexAdapter -sadapterGenerationSelfTest=true \
      -o /out/adapter-generation-test \
    && chpl -M client client/Transport.chpl client/Convex.chpl \
      client/tests/TransportTest.chpl \
      client/tests/conformance/Adapter.chpl \
      client/tests/conformance/AdapterCloseBudgetTest.chpl \
      --ccflags=-DCHAPEL_TRANSPORT_TEST \
      --main-module ChapelConvexAdapterCloseBudgetTest \
      -sadapterCloseBudgetSelfTest=true \
      -o /out/adapter-close-budget-test
RUN chplcheck client/Transport.chpl client/Convex.chpl \
      client/tests/TransportTest.chpl client/tests/ClientTest.chpl \
      client/tests/FixtureTest.chpl client/tests/conformance/Adapter.chpl \
      client/tests/conformance/AdapterCloseBudgetTest.chpl \
      examples/basics/main.chpl
RUN file /out/client-test /out/convex-adapter /out/convex-example \
      /out/fixture-test /out/adapter-generation-test \
      /out/adapter-close-budget-test \
      | grep -c 'ELF 64-bit LSB.*x86-64' | grep -qx 6
RUN for binary in /out/convex-adapter /out/convex-example /out/fixture-test \
      /out/adapter-generation-test; do \
      ! nm -g "$binary" | grep -E \
        'ct_ws_send_sequence_selftest|ct_adapter_(close|stalled)_test'; \
    done \
    && nm -g /out/client-test | grep -F ct_ws_send_sequence_selftest \
    && nm -g /out/adapter-close-budget-test \
      | grep -E 'ct_adapter_(close|stalled)_test'
COPY client/tests/fixtures ./client/tests/fixtures

FROM build AS test
RUN /out/client-test
RUN set -eu; \
    actual="$(printf '%s\n' \
      '{malformed' \
      '{"id":"hello","protocolVersion":1,"op":"hello"}' \
      '{"id":"unknown","op":"notAnOperation"}' \
      '{"id":"close","op":"close"}' | /out/convex-adapter)"; \
    printf '%s\n' "$actual" | grep -F '"type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready"'; \
    printf '%s\n' "$actual" | grep -F '"id":"unknown","type":"error"'; \
    printf '%s\n' "$actual" | grep -F '"id":"close","type":"closed"'
RUN utf8_recovery="$(printf '\377\nbad\000line\n%s\n%s\n' \
      '{"id":"hello-after-utf8","protocolVersion":1,"op":"hello"}' \
      '{"id":"close-after-utf8","op":"close"}' | /out/convex-adapter)" \
    && test "$(printf '%s\n' "$utf8_recovery" | grep -Fc 'adapter command is not exact UTF-8 text')" -eq 2 \
    && printf '%s\n' "$utf8_recovery" | grep -F '"id":"hello-after-utf8","type":"ready"' \
    && printf '%s\n' "$utf8_recovery" | grep -F '"id":"close-after-utf8","type":"closed"'
RUN environment_auth="$(printf '%s\n%s\n' \
      '{"id":"query","op":"query","path":"demo:state","args":{}}' \
      '{"id":"close","op":"close"}' \
      | CONVEX_URL=http://127.0.0.1:1 \
        CONVEX_AUTH_TOKEN="$(printf 'bad\ntoken')" /out/convex-adapter)" \
    && printf '%s\n' "$environment_auth" | grep -F 'authentication token is not a valid HTTP field value' \
    && printf '%s\n' "$environment_auth" | grep -F '"id":"query","type":"error"'
RUN bash -ec 'ADAPTER_LISTEN=127.0.0.1:18080 /out/convex-adapter & pid=$!; sleep 0.2; exec 3<>/dev/tcp/127.0.0.1/18080; printf "%s\n" "{\"id\":\"hello\",\"protocolVersion\":1,\"op\":\"hello\"}" "{\"id\":\"close\",\"op\":\"close\"}" >&3; IFS= read -r ready <&3; IFS= read -r closed <&3; wait "$pid"; grep -Fq "\"type\":\"ready\"" <<<"$ready"; grep -Fq "\"type\":\"closed\"" <<<"$closed"'
RUN python3 client/tests/fixtures/hostile_peer.py /out/fixture-test
RUN generation_events="$(/out/adapter-generation-test)" \
    && printf '%s\n' "$generation_events" | grep -Fq '"marker":"before"' \
    && printf '%s\n' "$generation_events" | grep -Fq '"marker":"fresh"' \
    && printf '%s\n' "$generation_events" | grep -Fq '"marker":"invalidation-ack"' \
    && ! printf '%s\n' "$generation_events" | grep -Fq '"paused":true' \
    && ! printf '%s\n' "$generation_events" | grep -Fq '"marker":"stale"'
RUN python3 client/tests/fixtures/stopped_reader.py /out/convex-adapter \
      /out/adapter-close-budget-test
CMD ["/bin/sh", "-c", "true"]

# Build a tiny glibc root filesystem containing the complete Chapel/libcurl
# runtime closure plus the verifier's shell and POSIX text tools. No compiler,
# Chapel frontend, package manager, curl command, or delegated runtime crosses.
FROM build AS runtime-rootfs
RUN set -eu; \
    root=/rootfs; \
    mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" "$root/etc"; \
    cp /bin/dash "$root/bin/sh"; \
    cp /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/mawk "$root/usr/bin/"; \
    ln -s mawk "$root/usr/bin/awk"; \
    cp /out/convex-example "$root/usr/local/bin/convex-example"; \
    cp /out/convex-adapter "$root/usr/local/bin/convex-adapter"; \
    mkdir -p "$root/usr/lib/locale"; \
    cp /usr/lib/locale/locale-archive "$root/usr/lib/locale/"; \
    for artifact in /bin/dash /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/mawk /out/convex-example /out/convex-adapter; do \
      ldd "$artifact"; \
    done | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\/.*ld-linux.*\.so/ {print $1}' | sort -u > /tmp/runtime-libraries; \
    while IFS= read -r library; do cp --parents -L "$library" "$root"; done < /tmp/runtime-libraries; \
    for nss_library in /usr/lib/*/libnss_dns.so.2 /usr/lib/*/libnss_files.so.2; do \
      if test -f "$nss_library"; then cp --parents -L "$nss_library" "$root"; fi; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp /etc/nsswitch.conf /etc/hosts /etc/resolv.conf "$root/etc/"; \
    for directory in /usr/lib/*/engines-3 /usr/lib/*/ossl-modules; do \
      if test -d "$directory"; then mkdir -p "$root/$directory"; cp -a "$directory/." "$root/$directory/"; fi; \
    done

# Build a self-contained closure for the toolchain the TLS probe below
# (hostile_peer.py, which shells out to the openssl CLI to mint its
# self-signed certificate) needs: python3 plus its stdlib, and openssl.
# This never feeds runtime-base, so it never reaches the
# runtime/example-runtime images or trips their "no python3"/"no openssl"
# audit -- it lands only in final-runtime-tls-test, a build-time-only
# verification stage neither final image derives from. Computed the same
# way runtime-rootfs computes the client binaries' closure above: ldd
# names every shared library each binary -- and, for python3, every
# stdlib extension module hostile_peer.py can import (socket, ssl,
# hashlib, json, struct) -- actually needs, rather than hand-listing
# them, so a Debian point release can't silently drop one out from under
# the probe the way libexpat did here. The openssl CLI additionally reads
# a config file at its compiled-in OPENSSLDIR (asked for directly via
# `openssl version -d` rather than hard-coded, for the same reason) --
# without it, `openssl req` cannot mint the probe's self-signed cert.
FROM build AS tls-probe-rootfs
RUN set -eu; \
    root=/pyrootfs; \
    python_binary=$(readlink -f /usr/bin/python3); \
    openssl_binary=$(readlink -f /usr/bin/openssl); \
    stdlib=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])'); \
    mkdir -p "$root/usr/bin"; \
    cp -L "$python_binary" "$root/usr/bin/python3"; \
    cp -L "$openssl_binary" "$root/usr/bin/openssl"; \
    { ldd "$python_binary"; \
      ldd "$openssl_binary"; \
      for extension in "$stdlib"/lib-dynload/*.so; do \
        if test -f "$extension"; then ldd "$extension"; fi; \
      done; \
    } | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\/.*ld-linux.*\.so/ {print $1}' \
      | sort -u > /tmp/python-libraries; \
    while IFS= read -r library; do cp --parents -L "$library" "$root"; done < /tmp/python-libraries; \
    mkdir -p "$root$stdlib"; \
    cp -a "$stdlib/." "$root$stdlib/"; \
    opensslconfdir=$(openssl version -d | sed -e 's/^OPENSSLDIR: "//' -e 's/"$//'); \
    if test -d "$opensslconfdir"; then \
      mkdir -p "$root$opensslconfdir"; \
      cp -a "$opensslconfdir/." "$root$opensslconfdir/"; \
    fi

FROM --platform=linux/amd64 ${ALPINE_IMAGE} AS runtime-base
# An earlier revision pinned CHPL_RT_NUM_THREADS_PER_LOCALE=2 here as
# "defense in depth" for the adapter's reader/writer starvation risk.
# That pin is unnecessary: ct_read_line's bounded poll(2)-plus-yield loop
# does not depend on thread count at all, and the exact read/response
# round trip this comment used to worry about was measured completing in
# ~0.13s even forced down to a single qthreads worker. (An initial
# attempt to also credit removing the pin with a large, reproducible
# speedup elsewhere did not hold up under a same-conditions control run
# -- this shared host's load varies enough on its own to produce that
# swing with the pin held constant, so no causal claim beyond
# "unnecessary" is made here.)
RUN for f in $(/bin/busybox find / -xdev -type f -perm /111); do \
         case "$f" in \
           /bin/busybox|/bin/sh|/usr/bin/id|/usr/bin/grep|/usr/bin/sed|/usr/bin/mawk|/lib/*|/lib64/*|/usr/lib/*) ;; \
           *) /bin/busybox rm -f "$f" ;; \
         esac; \
       done \
    && /bin/busybox find /bin /sbin /usr/bin /usr/sbin -type l -delete \
    && /bin/busybox rm -rf /etc/apk /lib/apk /var/cache/apk /var/lib/apk /usr/share/apk
COPY --from=runtime-rootfs /rootfs /
RUN for candidate in $(/bin/busybox find / -xdev -type f -perm /111); do \
         case "$candidate" in \
           /bin/busybox|/bin/sh|/usr/bin/id|/usr/bin/grep|/usr/bin/sed|/usr/bin/mawk|/usr/local/bin/convex-adapter|/usr/local/bin/convex-example|/lib/*|/lib64/*|/usr/lib/*) ;; \
           *) printf '%s\n' "unexpected runtime executable: $candidate" >&2; exit 1 ;; \
         esac; \
       done \
    && /bin/busybox rm -f /bin/busybox
RUN for required in sh id grep sed awk; do command -v "$required"; done \
    && test ! -e /bin/busybox \
    && test ! -e /sbin/apk \
    && test -r /etc/nsswitch.conf \
    && test -r /etc/hosts \
    && test -r /etc/resolv.conf \
    && test -r /etc/ssl/certs/ca-certificates.crt \
    && for candidate in /bin/* /sbin/* /usr/bin/* /usr/sbin/* /usr/local/bin/*; do \
         if test -f "$candidate" && test ! -L "$candidate" && test -x "$candidate"; then \
           case "$candidate" in \
             /bin/sh|/usr/bin/id|/usr/bin/grep|/usr/bin/sed|/usr/bin/mawk|/usr/local/bin/convex-adapter|/usr/local/bin/convex-example) ;; \
             *) printf '%s\n' "unexpected runtime executable: $candidate" >&2; exit 1 ;; \
           esac; \
         fi; \
       done \
    && for forbidden in busybox apk apt apt-get dpkg chpl chplcheck gcc g++ clang make cmake mason node python python3 perl ruby php java javac cargo rustc go curl openssl convex; do ! command -v "$forbidden"; done \
    && events="$(printf '%s\n' '{"id":"hello","protocolVersion":1,"op":"hello"}' '{"id":"close","op":"close"}' | /usr/local/bin/convex-adapter)" \
    && printf '%s\n' "$events" | grep -F '"language":"chapel"' \
    && printf '%s\n' "$events" | grep -F '"type":"closed"' \
    && if example_failure="$(CONVEX_URL=http://127.0.0.1:1 /usr/local/bin/convex-example 2>&1)"; then exit 1; fi \
    && printf '%s\n' "$example_failure" | grep -F 'current query failed:'
USER 65532:65532

FROM runtime-base AS final-runtime-tls-test
USER 0:0
COPY --from=build /out/fixture-test /tmp/fixture-test
COPY --from=build /work/client/tests/fixtures/hostile_peer.py /tmp/hostile_peer.py
# Lands python3, its ldd-derived library closure, and its stdlib at their
# normal absolute paths (mirroring runtime-base's own
# `COPY --from=runtime-rootfs /rootfs /` a few stages up), so the loader
# finds everything via its ordinary default search path with no
# LD_LIBRARY_PATH juggling required.
COPY --from=tls-probe-rootfs /pyrootfs /
RUN PATH=/usr/bin PYTHONHOME=/usr \
      /usr/bin/python3 /tmp/hostile_peer.py /tmp/fixture-test \
        /usr/local/bin/convex-adapter /usr/local/bin/convex-example \
    && : > /tls-probe-passed

FROM runtime-base AS example-runtime
COPY --from=final-runtime-tls-test /tls-probe-passed /usr/local/share/tls-probe-passed
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=final-runtime-tls-test /tls-probe-passed /usr/local/share/tls-probe-passed
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
