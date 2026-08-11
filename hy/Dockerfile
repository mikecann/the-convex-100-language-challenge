# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG PYTHON_IMAGE=python:3.13.5-slim-bookworm@sha256:4c2cf9917bd1cbacc5e9b07320025bdb7cdf2df7b0ceaccb55e9dd7e30987419
ARG RUNTIME_BASE=gcr.io/distroless/base-debian12:nonroot@sha256:b12529fbbd0bb15eea8905f69d83148679e0b4d7d434c8808100792029b1caae

FROM --platform=linux/amd64 ${PYTHON_IMAGE} AS test
WORKDIR /work
COPY client ./client
COPY examples ./examples
# Hy is the language frontend and websockets supplies only RFC 6455 transport.
RUN pip install --no-cache-dir hy==1.3.1 funcparserlib==1.0.1 websockets==17.0.1
# hy2py emits an unused `import hy` even when generated code uses no Hy runtime
# objects. Remove that import so the final Python image exposes no Hy compiler.
RUN mkdir -p /transpiled/client /transpiled/examples && \
    hy2py client/convex.hy --output /transpiled/client/convex.py && \
    hy2py client/tests/test.hy --output /transpiled/test.py && \
    hy2py client/tests/example.hy --output /transpiled/example-test.py && \
    hy2py client/tests/conformance/adapter.hy --output /transpiled/adapter.py && \
    hy2py examples/basics/main.hy --output /transpiled/examples/main.py && \
    sed -i '/^import hy$/d' /transpiled/client/convex.py /transpiled/test.py /transpiled/example-test.py /transpiled/adapter.py /transpiled/examples/main.py && \
    sed -i '1i#!/usr/local/bin/python3' /transpiled/adapter.py /transpiled/examples/main.py && \
    cp /transpiled/adapter.py /transpiled/client/adapter.py && \
    python3 -m py_compile /transpiled/client/convex.py /transpiled/test.py /transpiled/example-test.py /transpiled/adapter.py /transpiled/examples/main.py
RUN PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/work/client python3 -m hy client/tests/test.hy
RUN PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/work/client python3 -m hy client/tests/example.hy
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | CONVEX_CLIENT_PATH=/work/client python3 -m hy client/tests/conformance/adapter.hy > /tmp/source-adapter.ndjson && grep -Fq '"language":"hy"' /tmp/source-adapter.ndjson
RUN PYTHONDONTWRITEBYTECODE=1 CONVEX_CLIENT_PATH=/transpiled/client CONVEX_ADAPTER_PATH=/transpiled/adapter.py python3 /transpiled/test.py
RUN PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/transpiled/client CONVEX_EXAMPLE_PATH=/transpiled/examples python3 /transpiled/example-test.py
RUN printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' '{"id":"close","op":"close"}' | CONVEX_CLIENT_PATH=/transpiled/client python3 /transpiled/adapter.py > /tmp/transpiled-adapter.ndjson && grep -Fq '"language":"hy"' /tmp/transpiled-adapter.ndjson
RUN test "$(python3 -c 'import platform; print(platform.machine())')" = x86_64

FROM --platform=linux/amd64 ${PYTHON_IMAGE} AS runtime-rootfs
RUN pip install --no-cache-dir websockets==17.0.1 && set -eu; root=/runtime-root; mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/local/bin" "$root/usr/local/lib" "$root/usr/lib" "$root/etc"; \
    cp /usr/local/bin/python3 "$root/usr/local/bin/python3"; cp /bin/dash "$root/bin/dash"; ln -s dash "$root/bin/sh"; \
    for tool in id grep sed awk cat head tail tr wc; do cp "/usr/bin/$tool" "$root/usr/bin/$tool"; done; \
    cp -a /usr/local/lib/python3.13 "$root/usr/local/lib/python3.13"; rm -rf "$root/usr/local/lib/python3.13/ensurepip" "$root/usr/local/lib/python3.13/site-packages/pip" "$root/usr/local/lib/python3.13/site-packages/pip-"*; \
    { ldd /usr/local/bin/python3 /bin/dash /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/awk /usr/bin/cat /usr/bin/head /usr/bin/tail /usr/bin/tr /usr/bin/wc; find /usr/local/lib/python3.13 -type f -name '*.so' -exec ldd '{}' ';'; } | awk '$3 ~ /^\// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | while IFS= read -r library; do cp --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do test ! -e "$library" || cp --parents "$library" "$root"; done; \
    cp --parents /lib/x86_64-linux-gnu/libgcc_s.so.1 "$root"; \
    cp -a /etc/ssl "$root/etc/ssl"; mkdir -p "$root/usr/lib/ssl"; ln -s /etc/ssl/certs/ca-certificates.crt "$root/usr/lib/ssl/cert.pem"; ln -s /etc/ssl/certs "$root/usr/lib/ssl/certs"; ln -s /etc/ssl/openssl.cnf "$root/usr/lib/ssl/openssl.cnf"; for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do test ! -e "$config" || cp --parents "$config" "$root"; done

FROM --platform=linux/amd64 ${RUNTIME_BASE} AS runtime-base
ENV PYTHONDONTWRITEBYTECODE=1
ENV CONVEX_CLIENT_PATH=/usr/local/lib/python3.13/site-packages
COPY --from=runtime-rootfs /runtime-root /
COPY --from=test --chmod=0444 /transpiled/client/convex.py /usr/local/lib/python3.13/site-packages/convex.py
RUN ["/bin/sh", "-ec", "for name in node npm curl convex hy hy2py pip pip3 apt apt-get dpkg gcc cc make; do ! command -v $name >/dev/null 2>&1 || exit 1; done; /usr/local/bin/python3 -c 'import importlib.util, websockets, os, platform, ssl, urllib.request; assert importlib.util.find_spec(\"hy\") is None; assert platform.machine() == \"x86_64\"; paths = ssl.get_default_verify_paths(); assert paths.cafile and os.path.isfile(paths.cafile); response = urllib.request.urlopen(\"https://www.python.org/\", timeout=15); assert 200 <= response.status < 400; response.close()' "]
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=test --chmod=0555 /transpiled/examples/main.py /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=test --chmod=0555 /transpiled/adapter.py /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
