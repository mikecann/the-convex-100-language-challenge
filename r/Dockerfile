# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# R's interpreter is the declared target runtime. The four ordinary packages
# are pinned below and supply only TLS/HTTP, JSON, and WebSocket primitives.
ARG R_IMAGE=rocker/r-ver:4.5.1@sha256:03b023fbf7b1b24ac1bb8b2ac5fd7e15a767e67b40ff50c155e328110981c2aa
FROM ${R_IMAGE} AS packages
WORKDIR /work
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4-openssl-dev libssl-dev libz-dev make g++ ca-certificates && rm -rf /var/lib/apt/lists/*
RUN R -q -e 'install.packages(c("curl", "digest", "jsonlite", "later", "websocket"), repos="https://packagemanager.posit.co/cran/__linux__/noble/2026-08-01"); expected <- c(curl="7.1.0", digest="0.6.39", jsonlite="2.0.0", later="1.4.8", websocket="1.4.4"); actual <- vapply(names(expected), function(package) as.character(packageVersion(package)), character(1)); stopifnot(identical(actual, expected))'

FROM packages AS formatter
RUN R -q -e 'install.packages("styler", repos="https://packagemanager.posit.co/cran/__linux__/noble/2026-08-01"); stopifnot(as.character(packageVersion("styler")) == "1.11.0")'
COPY client ./client
COPY examples ./examples
RUN cp -a client /tmp/client-before && cp -a examples /tmp/examples-before && \
    Rscript -e 'styler::style_dir("client"); styler::style_dir("examples")' && \
    diff -ru /tmp/client-before client && diff -ru /tmp/examples-before examples

FROM formatter AS test
RUN test "$(uname -m)" = x86_64 && Rscript -e 'stopifnot(R.version$arch == "x86_64")'
RUN Rscript -e 'for (f in c(list.files("client", recursive=TRUE, full.names=TRUE, pattern="\\.R$"), list.files("examples", recursive=TRUE, full.names=TRUE, pattern="\\.R$"))) parse(f)'
RUN Rscript client/tests/client_test.R
RUN Rscript client/tests/live_test.R
RUN Rscript client/tests/web_socket_test.R
RUN Rscript client/tests/conformance/adapter_test.R
RUN Rscript examples/basics/main_test.R
RUN expected='{"protocolVersion":1,"id":"hello","op":"hello"}\n{"id":"close","op":"close"}\n'; \
    actual=$(printf "$expected" | CONVEX_CLIENT_PATH=/work/client Rscript client/tests/conformance/adapter.R); \
    printf '%s\n' "$actual" | grep -Fx '{"protocolVersion":1,"id":"hello","type":"ready","language":"r","implementation":"native-r-4.5.1","runtime":"R-4.5.1"}'; \
    printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
CMD ["Rscript", "-e", "quit(status=0)"]

FROM packages AS runtime-rootfs
# Build an explicit runtime closure. Rscript needs the R launcher and bytecode
# libraries, but none of the R CMD build frontends, headers, package installers,
# compilers, linkers, or OS package managers are copied into the final image.
RUN set -eu; \
    root=/runtime-root; \
    mkdir -p "$root/bin" "$root/lib" "$root/usr/bin" "$root/usr/local/bin" "$root/usr/local/lib" "$root/usr/lib/x86_64-linux-gnu" "$root/usr/share" "$root/etc"; \
    cp /bin/dash "$root/bin/dash"; \
    ln -s dash "$root/bin/sh"; \
    cp /bin/rm /bin/mkdir "$root/bin/"; \
    cp /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/uname /usr/bin/which "$root/usr/bin/"; \
    cp /usr/local/bin/Rscript "$root/usr/local/bin/Rscript"; \
    cp -a /usr/local/lib/R "$root/usr/local/lib/R"; \
    rm -rf "$root/usr/local/lib/R/site-library/digest" "$root/usr/local/lib/R/include" "$root/usr/local/lib/R/doc"; \
    find "$root/usr/local/lib/R/bin" -mindepth 1 -maxdepth 1 ! -name exec ! -name R ! -name Rscript -exec rm -rf {} +; \
    sed -i '1s|/bin/bash|/bin/sh|' "$root/usr/local/lib/R/bin/R"; \
    { \
      LD_LIBRARY_PATH=/usr/local/lib/R/lib ldd /usr/local/bin/Rscript /usr/local/lib/R/bin/exec/R /usr/local/lib/R/lib/libR.so /bin/dash /bin/rm /bin/mkdir /usr/bin/id /usr/bin/grep /usr/bin/sed /usr/bin/uname /usr/bin/which; \
      find /usr/local/lib/R -type f -name '*.so' -exec ldd '{}' ';'; \
    } | awk '/=> \/.* \(0x/ { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' | sort -u | \
      while IFS= read -r library; do cp -L --parents "$library" "$root"; done; \
    for library in /lib/x86_64-linux-gnu/libnss_*.so.2; do \
      test ! -e "$library" || cp --parents "$library" "$root"; \
    done; \
    for library in /lib/x86_64-linux-gnu/libcurl.so.4 /lib/x86_64-linux-gnu/liblapack.so.3 /lib/x86_64-linux-gnu/libblas.so.3 /lib/x86_64-linux-gnu/libopenblas.so.0 /lib/x86_64-linux-gnu/libgfortran.so.5 /lib/x86_64-linux-gnu/libgomp.so.1 /lib/x86_64-linux-gnu/libquadmath.so.0; do \
      test ! -e "$library" || cp -L --parents "$library" "$root"; \
    done; \
    cp -a /lib/x86_64-linux-gnu "$root/lib/"; \
    for library in /lib/x86_64-linux-gnu/libcurl.so.4 /lib/x86_64-linux-gnu/liblapack.so.3 /lib/x86_64-linux-gnu/libblas.so.3 /lib/x86_64-linux-gnu/libopenblas.so.0 /lib/x86_64-linux-gnu/libgfortran.so.5 /lib/x86_64-linux-gnu/libgomp.so.1 /lib/x86_64-linux-gnu/libquadmath.so.0; do \
      if test -e "$library"; then rm -f "$root$library"; cp -L "$library" "$root$library"; fi; \
    done; \
    cp -a /etc/ssl "$root/etc/ssl"; \
    cp -a /usr/lib/ssl "$root/usr/lib/ssl"; \
    cp -a /usr/lib/x86_64-linux-gnu/ossl-modules "$root/usr/lib/x86_64-linux-gnu/ossl-modules"; \
    cp -a /usr/share/ca-certificates "$root/usr/share/ca-certificates"; \
    test ! -d /usr/lib/locale/C.utf8 || cp -a --parents /usr/lib/locale/C.utf8 "$root"; \
    for config in /etc/nsswitch.conf /etc/host.conf /etc/gai.conf; do \
      test ! -e "$config" || cp --parents "$config" "$root"; \
    done

FROM scratch AS runtime-base
ENV CONVEX_CLIENT_PATH=/opt/convex/client
ENV TMPDIR=/dev/shm
ENV LANG=C.UTF-8
COPY --from=runtime-rootfs /runtime-root /
COPY client/convex.R client/live.R /opt/convex/client/
COPY --chmod=0555 client/tests/conformance/adapter.R /usr/local/bin/convex-adapter
USER 65532:65532
RUN expected='{"protocolVersion":1,"id":"hello","op":"hello"}\n{"id":"close","op":"close"}\n'; \
    actual=$(printf "$expected" | /usr/local/bin/convex-adapter); \
    printf '%s\n' "$actual" | grep -Fx '{"protocolVersion":1,"id":"hello","type":"ready","language":"r","implementation":"native-r-4.5.1","runtime":"R-4.5.1"}'; \
    printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'

FROM runtime-base AS example-runtime
COPY --chmod=0555 examples/basics/main.R /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
