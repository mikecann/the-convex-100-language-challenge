# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# Pharo publishes immutable, build-numbered artefacts. Both are pinned by URL
# and by content hash, so this build cannot silently move to another Pharo.
ARG PHARO_IMAGE_URL=https://files.pharo.org/image/120/Pharo12-SNAPSHOT.build.1258.sha.1645336.arch.64bit.zip
ARG PHARO_IMAGE_SHA256=8f3b9f1514160cdef13313701d15e60b96f3c1eac6cc9afde5fbe826885ce236
ARG PHARO_VM_URL=https://files.pharo.org/vm/pharo-spur64-headless/Linux-x86_64/PharoVM-v12.0.3-beta+33.23e5a5a-Linux-x86_64-bin.zip
ARG PHARO_VM_SHA256=328a7b55717d7b6a24e2bc6557c940975dac1800c99a06e694e21d4351996cd8

FROM --platform=linux/amd64 ${BUILD_IMAGE} AS test
ARG PHARO_IMAGE_URL
ARG PHARO_IMAGE_SHA256
ARG PHARO_VM_URL
ARG PHARO_VM_SHA256
WORKDIR /project
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       ca-certificates=20230311+deb12u1 \
       unzip=6.0-28 \
       busybox-static=1:1.35.0-4+deb12u1+b1 \
       file=1:5.44-3 \
       libuuid1=2.38.1-5+deb12u3 \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:${PHARO_VM_SHA256} ${PHARO_VM_URL} /tmp/pharo-vm.zip
ADD --checksum=sha256:${PHARO_IMAGE_SHA256} ${PHARO_IMAGE_URL} /tmp/pharo-image.zip
RUN mkdir -p /opt/pharo /build /out \
    && unzip -q /tmp/pharo-vm.zip -d /opt/pharo \
    && unzip -q /tmp/pharo-image.zip -d /build \
    && mv /build/Pharo12-SNAPSHOT-64bit-1645336.image /build/pharo.image \
    && mv /build/Pharo12-SNAPSHOT-64bit-1645336.changes /build/pharo.changes \
    && rm -f /tmp/pharo-vm.zip /tmp/pharo-image.zip

# The VM is dynamically linked against libraries that ship alongside it in
# /opt/pharo/lib rather than the system loader path, so this has to be set
# before the very first invocation below - not after it.
ENV SQUEAK_PLUGINS=/opt/pharo/lib \
    LD_LIBRARY_PATH=/opt/pharo/lib \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs

# The VM is a genuine amd64 ELF and the downloaded image itself reports Pharo
# 12. The archive does not contain a pharo.version sidecar, so ask the image
# instead of testing a file that cannot exist.
RUN test "$(uname -m)" = x86_64 \
    && file /opt/pharo/lib/pharo | grep -Eq 'ELF 64-bit.*x86-64' \
    && timeout 60 /opt/pharo/lib/pharo --headless /build/pharo.image eval \
       "(SystemVersion current dottedMajorMinorPatch beginsWith: '12.') ifFalse: [ Smalltalk exit: 2 ]. Smalltalk exitSuccess" </dev/null

COPY client ./client
COPY examples ./examples

# Layer one: load every checked-in source file into a scratch image and run the
# whole SUnit suite. A load failure, a test failure or fewer tests than expected
# exits non-zero, so this stage cannot pass on compilation alone.
RUN cp /build/pharo.image /build/tests.image \
    && cp /build/pharo.changes /build/tests.changes \
    && timeout 1800 /opt/pharo/lib/pharo --headless /build/tests.image eval \
       "CodeImporter evaluateFileNamed: '/project/client/build-support.st'. CodeImporter evaluateFileNamed: '/project/client/build-test.st'" </dev/null \
    && test -s /out/tests-passed.txt \
    && cat /out/tests-passed.txt

# Layer two: one saved image per entry point. Each build removes the entire
# interactive command surface before it snapshots, so the shipped image cannot
# be used as a general Smalltalk evaluator.
RUN cp /build/pharo.image /build/adapter-work.image \
    && cp /build/pharo.changes /build/adapter-work.changes \
    && timeout 900 /opt/pharo/lib/pharo --headless /build/adapter-work.image eval \
       "CodeImporter evaluateFileNamed: '/project/client/build-support.st'. CodeImporter evaluateFileNamed: '/project/client/build-adapter.st'" </dev/null \
    && test -s /out/convex-adapter.image
RUN cp /build/pharo.image /build/example-work.image \
    && cp /build/pharo.changes /build/example-work.changes \
    && timeout 900 /opt/pharo/lib/pharo --headless /build/example-work.image eval \
       "CodeImporter evaluateFileNamed: '/project/client/build-support.st'. CodeImporter evaluateFileNamed: '/project/client/build-example.st'" </dev/null \
    && test -s /out/convex-example.image

# The VM looks for its `.sources` file next to whatever `.image` it is asked
# to run; without it here it prints a "cannot locate the sources file"
# warning to stdout on every single startup, which is indistinguishable from
# real output to anything reading that stream.
RUN cp /build/*.sources /out/

# Prove the hardening actually landed: the saved images must refuse to evaluate
# arbitrary Smalltalk, and must still answer their own entry point.
# A removed handler must leave no other way in, and an unknown command must not
# leave the image sitting in a read-eval loop either, so the probe is bounded.
RUN set -eu; \
    for saved in /out/convex-adapter.image /out/convex-example.image; do \
      timeout 60 /opt/pharo/lib/pharo --headless "$saved" eval "1 + 1" \
        </dev/null >/tmp/eval.out 2>/tmp/eval.err || true; \
      if grep -Fxq '2' /tmp/eval.out; then \
        echo "FAIL $saved still evaluates arbitrary Smalltalk" >&2; exit 1; \
      fi; \
    done
RUN printf '%s\n' \
      '{"protocolVersion":1,"id":"hello","op":"hello"}' \
      '{"id":"close","op":"close"}' \
    | CONVEX_URL=http://127.0.0.1:3210 \
      timeout 120 /opt/pharo/lib/pharo --headless /out/convex-adapter.image convex-adapter \
    | tee /tmp/adapter-probe.out \
    && grep -Fq '"type":"ready"' /tmp/adapter-probe.out \
    && grep -Fq '"language":"smalltalk"' /tmp/adapter-probe.out \
    && grep -Fq '"type":"closed"' /tmp/adapter-probe.out
# The example must fail loudly, on stderr and with a non-zero status, when the
# deployment URL is missing. Silent success here would hide a broken entry point.
RUN code=0; \
    timeout 120 /opt/pharo/lib/pharo --headless /out/convex-example.image convex-example \
      </dev/null >/tmp/example.out 2>/tmp/example.err || code=$?; \
    test "$code" -ne 0 \
    && test ! -s /tmp/example.out \
    && grep -Fq 'CONVEX_URL is required' /tmp/example.err

# Start from the pinned non-scratch Debian image the shared policy requires,
# remove its visible filesystem with a temporary static helper that never enters
# a final layer, then copy back only the declared runtime closure.
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS runtime-base
RUN --mount=type=bind,from=test,source=/bin/busybox,target=/busybox,readonly \
    set -eu; \
    pruner=/busybox; \
    for path in /bin /boot /home /lib /lib64 /media /mnt /opt /root \
                /run /sbin /srv /usr /var; do \
      "$pruner" rm -rf "$path"; \
    done; \
    for path in /etc/*; do \
      case "$path" in \
        /etc/hosts|/etc/resolv.conf) ;; \
        *) "$pruner" rm -rf "$path" ;; \
      esac; \
    done; \
    "$pruner" rm -rf /etc/.pwd.lock; \
    "$pruner" mkdir -p \
      /bin /etc/ssl/certs /lib/x86_64-linux-gnu /lib64 /usr/bin \
      /opt/pharo/lib /usr/local/bin; \
    exec "$pruner" rm -rf /tmp
COPY --from=test /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=test /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6
COPY --from=test /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6
COPY --from=test /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/libdl.so.2
COPY --from=test /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/libpthread.so.0
COPY --from=test /lib/x86_64-linux-gnu/libuuid.so.1 /lib/x86_64-linux-gnu/libuuid.so.1
# Glibc resolves the hosted deployment through NSS at runtime. These modules are
# loaded dynamically, so they never appear in a link-time closure.
COPY --from=test /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=test /lib/x86_64-linux-gnu/libnss_files.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2
COPY --from=test /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2
COPY --from=test /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=test /etc/nsswitch.conf /etc/nsswitch.conf
# The Pharo virtual machine and only the plugins this client actually reaches.
# TLS comes from the OpenSSL 1.0.2 pair the Pharo VM bundles for SqueakSSL, so
# no system OpenSSL is installed and no openssl command exists.
COPY --from=test /opt/pharo/lib/pharo /opt/pharo/lib/pharo
COPY --from=test /opt/pharo/lib/libPharoVMCore.so /opt/pharo/lib/libPharoVMCore.so
COPY --from=test /opt/pharo/lib/libffi.so /opt/pharo/lib/libffi.so
COPY --from=test /opt/pharo/lib/libSocketPlugin.so /opt/pharo/lib/libSocketPlugin.so
COPY --from=test /opt/pharo/lib/libFilePlugin.so /opt/pharo/lib/libFilePlugin.so
COPY --from=test /opt/pharo/lib/libNewFilePlugin.so /opt/pharo/lib/libNewFilePlugin.so
COPY --from=test /opt/pharo/lib/libFileAttributesPlugin.so /opt/pharo/lib/libFileAttributesPlugin.so
COPY --from=test /opt/pharo/lib/libSqueakSSL.so /opt/pharo/lib/libSqueakSSL.so
COPY --from=test /opt/pharo/lib/libssl.so.1.0.0 /opt/pharo/lib/libssl.so.1.0.0
COPY --from=test /opt/pharo/lib/libcrypto.so.1.0.0 /opt/pharo/lib/libcrypto.so.1.0.0
COPY --from=test /opt/pharo/lib/libDSAPrims.so /opt/pharo/lib/libDSAPrims.so
COPY --from=test /opt/pharo/lib/libLargeIntegers.so /opt/pharo/lib/libLargeIntegers.so
COPY --from=test /opt/pharo/lib/libMiscPrimitivePlugin.so /opt/pharo/lib/libMiscPrimitivePlugin.so
COPY --from=test /opt/pharo/lib/libUUIDPlugin.so /opt/pharo/lib/libUUIDPlugin.so
COPY --from=test /opt/pharo/lib/libLocalePlugin.so /opt/pharo/lib/libLocalePlugin.so
COPY --from=test /opt/pharo/lib/libBitBltPlugin.so /opt/pharo/lib/libBitBltPlugin.so
COPY --from=test /opt/pharo/lib/libSurfacePlugin.so /opt/pharo/lib/libSurfacePlugin.so
COPY --from=test /opt/pharo/lib/libtty.so /opt/pharo/lib/libtty.so
COPY --from=test /bin/dash /bin/sh
COPY --from=test /usr/bin/id /usr/bin/id
COPY --from=test /usr/bin/cat /usr/bin/cat
COPY --from=test /usr/bin/cut /usr/bin/cut
COPY --from=test /usr/bin/head /usr/bin/head
COPY --from=test /usr/bin/tail /usr/bin/tail
COPY --from=test /usr/bin/tr /usr/bin/tr
COPY --from=test /usr/bin/sort /usr/bin/sort
COPY --from=test /usr/bin/uniq /usr/bin/uniq
COPY --from=test /usr/bin/wc /usr/bin/wc
COPY --from=test /usr/bin/uname /usr/bin/uname
COPY --from=test /usr/bin/grep /usr/bin/grep
COPY --from=test /usr/bin/sed /usr/bin/sed
COPY --from=test /usr/bin/mawk /usr/bin/awk
COPY --from=test /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libselinux.so.1
COPY --from=test /lib/x86_64-linux-gnu/libpcre2-8.so.0 /lib/x86_64-linux-gnu/libpcre2-8.so.0
COPY --from=test /lib/x86_64-linux-gnu/libacl.so.1 /lib/x86_64-linux-gnu/libacl.so.1
ENV SQUEAK_PLUGINS=/opt/pharo/lib \
    LD_LIBRARY_PATH=/opt/pharo/lib \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    PATH=/usr/local/bin:/usr/bin:/bin
USER 65532:65532
# Guard the exported runtime shape, not merely its PATH. The Pharo virtual
# machine deliberately stays outside PATH: it is a runtime, and the only
# executables a user of these images can name are the two entry points.
RUN test "$(id -u):$(id -g)" = 65532:65532 \
    && test -s "$SSL_CERT_FILE" \
    && test "$(printf 'ok\n' | cat)" = ok \
    && test "$(printf 'a:b\n' | cut -d: -f2)" = b \
    && test "$(printf 'first\nsecond\n' | head -n 1)" = first \
    && test "$(printf 'first\nsecond\n' | tail -n 1)" = second \
    && test "$(printf 'a\n' | tr a A)" = A \
    && test "$(printf 'b\na\n' | sort | head -n 1)" = a \
    && test "$(printf 'a\na\n' | uniq | wc -l | tr -d ' ')" = 1 \
    && test "$(uname -m)" = x86_64 \
    && printf 'needle\n' | grep -Fqx needle \
    && test "$(printf 'before\n' | sed 's/before/after/')" = after \
    && test "$(printf 'value\n' | awk '{print $1}')" = value \
    && test ! -e /etc/dpkg \
    && test ! -e /etc/.pwd.lock \
    && test ! -e /etc/update-motd.d \
    && test ! -e /busybox \
    && test ! -e /var \
    && test ! -e /usr/share \
    && test ! -e /usr/lib \
    && test ! -e /usr/include \
    && test ! -e /usr/src \
    && test ! -e /build \
    && test ! -e /project \
    && set -- /bin/* \
    && test "$#" -eq 1 \
    && test "$1" = /bin/sh \
    && set -- /usr/bin/* \
    && test "$#" -eq 13 \
    && set -- /lib64/* \
    && test "$#" -eq 1 \
    && set -- /opt/pharo/lib/* \
    && test "$#" -eq 18 \
    && for command_name in pharo pharo-vm smalltalk gst squeak gcc cc clang make \
         cmake apt apt-get dpkg curl wget nc netcat openssl node python python3 \
         ruby perl java php go rustc cargo npm pip metacello convex; do \
         ! command -v "$command_name" >/dev/null 2>&1; \
       done

FROM runtime-base AS example-runtime
COPY --from=test --chmod=0444 /out/convex-example.image /opt/convex-example.image
# The VM looks up its sources file by the name embedded in the image at save
# time, not by the image's own filename, so this keeps that original name
# rather than being renamed alongside convex-example.image.
COPY --from=test --chmod=0444 /out/*.sources /opt/
# A three-line launcher is all that stands between the entry point path the
# shared policy requires and the virtual machine that runs the saved image.
COPY --from=test --chmod=0555 /project/client/convex-example.sh /usr/local/bin/convex-example
RUN test -x /usr/local/bin/convex-example \
    && test ! -e /usr/local/bin/convex-adapter \
    && test ! -e /opt/convex-adapter.image
ENTRYPOINT ["/usr/local/bin/convex-example"]

# Keep the adapter last because `./run build smalltalk` uses the default target.
FROM runtime-base AS runtime
COPY --from=test --chmod=0444 /out/convex-adapter.image /opt/convex-adapter.image
# See the matching comment in the example-runtime stage above.
COPY --from=test --chmod=0444 /out/*.sources /opt/
COPY --from=test --chmod=0555 /project/client/convex-adapter.sh /usr/local/bin/convex-adapter
RUN test -x /usr/local/bin/convex-adapter \
    && test ! -e /usr/local/bin/convex-example \
    && test ! -e /opt/convex-example.image \
    && printf '%s\n' \
         '{"protocolVersion":1,"id":"hello","op":"hello"}' \
         '{"id":"close","op":"close"}' \
       | CONVEX_URL=http://127.0.0.1:3210 /usr/local/bin/convex-adapter \
       | grep -Fq '"type":"closed"'
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
