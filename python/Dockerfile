# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG PYTHON_IMAGE=python:3.13.5-slim-bookworm@sha256:4c2cf9917bd1cbacc5e9b07320025bdb7cdf2df7b0ceaccb55e9dd7e30987419

FROM --platform=linux/amd64 ${PYTHON_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
# Compile and test every checked-in Python source in Docker, including the
# adapter and canonical example, before publishing either runtime target.
RUN python3 -m compileall -q client examples && python3 -m unittest discover -s client -p 'test_*.py' && python3 -m unittest discover -s examples/basics -p 'test_*.py'
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | PYTHONPATH=client python3 client/tests/conformance/adapter.py | grep -Fq '"language":"python"'
RUN test "$(python3 -c 'import platform; print(platform.machine())')" = x86_64
CMD ["python3", "-c", "pass"]

FROM --platform=linux/amd64 ${PYTHON_IMAGE} AS runtime-rootfs
# Make a narrowly copied root filesystem. The official Python image's pip and
# Debian package tools never cross this stage boundary into the runtime image.
RUN set -eu; root=/runtime-root; mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" "$root/usr/local/lib" "$root/usr/lib" "$root/etc"; \
    cp /usr/local/bin/python3 "$root/usr/local/bin/python3"; cp /bin/dash "$root/bin/dash"; ln -s dash "$root/bin/sh"; cp /usr/bin/id "$root/usr/bin/id"; cp /usr/bin/grep "$root/usr/bin/grep"; \
    cp -a /usr/local/lib/python3.13 "$root/usr/local/lib/python3.13"; rm -rf "$root/usr/local/lib/python3.13/ensurepip" "$root/usr/local/lib/python3.13/site-packages/pip" "$root/usr/local/lib/python3.13/site-packages/pip-"*; \
    { ldd /usr/local/bin/python3 /bin/dash /usr/bin/id /usr/bin/grep; find /usr/local/lib/python3.13 -type f -name '*.so' -exec ldd '{}' ';'; } | awk '$3 ~ /^\// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do test ! -e "$library" || cp --parents "$library" "$root"; done; \
    cp -a /etc/ssl "$root/etc/ssl"; mkdir -p "$root/usr/lib/ssl"; ln -s /etc/ssl/certs/ca-certificates.crt "$root/usr/lib/ssl/cert.pem"; ln -s /etc/ssl/certs "$root/usr/lib/ssl/certs"; ln -s /etc/ssl/openssl.cnf "$root/usr/lib/ssl/openssl.cnf"; for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done

FROM scratch AS runtime-base
ENV PYTHONDONTWRITEBYTECODE=1
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV PYTHONPATH=/opt/convex/client
COPY --from=runtime-rootfs /runtime-root /
COPY client/convex.py /opt/convex/client/convex.py
# The final image keeps only Python's runtime. This guards against accidental
# delegation to Python package tooling or another language client.
RUN ["/bin/sh", "-ec", "for name in node npm curl convex pip pip3 apt apt-get dpkg gcc cc make; do ! command -v $name >/dev/null 2>&1 || exit 1; done; /usr/local/bin/python3 -c 'import convex, os, platform, ssl, urllib.request; assert platform.machine() == \"x86_64\"; paths = ssl.get_default_verify_paths(); assert paths.cafile and os.path.isfile(paths.cafile); response = urllib.request.urlopen(\"https://www.python.org/\", timeout=15); assert 200 <= response.status < 400; response.close()' "]
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.py /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/python3", "/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --chmod=0444 client/tests/conformance/adapter.py /opt/convex/adapter.py
COPY --chmod=0555 client/tests/conformance/entrypoint.sh /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
