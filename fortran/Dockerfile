# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM gcc:14.2.0-bookworm@sha256:b99b86a28812b1e6453a231a947dc43d76fe192788a12f344a9b568bf9f5d24c AS build
RUN apt-get update && \
    apt-get install --no-install-recommends -y libc-ares-dev=1.18.1-3 libcurl4-openssl-dev=7.88.1-10+deb12u15 libssl-dev=3.0.20-1~deb12u2 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN mkdir -p /build && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread -c client/curl_transport.c -o /build-curl_transport.o && \
    gfortran -cpp -std=f2018 -O2 -Wall -Wextra -Werror -ffree-line-length-none -J /build -c client/convex.f90 -o /build-convex.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-curl_transport.o examples/basics/main.f90 -lcares -lcurl -lssl -lcrypto -o /out-example && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -J /build -I /build -c client/tests/conformance/transport.f90 -o /build-adapter-transport.o && \
    gfortran -cpp -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-adapter-transport.o /build-curl_transport.o client/tests/conformance/main.f90 -lcares -lcurl -lssl -lcrypto -o /out-adapter && \
    gfortran -cpp -DFORTRAN_ADAPTER_TESTING -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-adapter-transport.o /build-curl_transport.o client/tests/conformance/main.f90 -lcares -lcurl -lssl -lcrypto -o /out-adapter-test && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread -c client/tests/live_owner_fixture.c -o /build-live-owner-fixture.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex.o /build-curl_transport.o /build-live-owner-fixture.o client/tests/test_live_owner.f90 -lcares -lcurl -lssl -lcrypto -o /out-live-owner-test && \
    mkdir -p /build-relay && \
    gfortran -cpp -DFORTRAN_ADAPTER_TESTING -DFORTRAN_ADAPTER_MODULE_ONLY -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -J /build-relay -I /build -c client/tests/conformance/main.f90 -o /build-adapter-state-test.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build-relay -I /build /build-convex.o /build-adapter-transport.o /build-curl_transport.o /build-adapter-state-test.o client/tests/conformance/test_relay_barrier.f90 -lcares -lcurl -lssl -lcrypto -o /out-relay-barrier-test && \
    gfortran -cpp -DFORTRAN_TESTING -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -g -fcheck=all -J /build -c client/convex.f90 -o /build-convex-test.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex-test.o /build-curl_transport.o client/tests/test_client.f90 -lcares -lcurl -lssl -lcrypto -o /out-test && \
    gcc -DFORTRAN_TRANSPORT_TESTING -std=c17 -Wall -Wextra -Werror -pthread -c client/curl_transport.c -o /build-curl-transport-stall.o && \
    gfortran -std=f2018 -Wall -Wextra -Werror -ffree-line-length-none -pthread -I /build /build-convex-test.o /build-curl-transport-stall.o client/tests/test_close_dns.f90 -lcares -lcurl -lssl -lcrypto -o /out-close-dns-test && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread client/tests/transport_socket_test.c /build-curl_transport.o -lcares -lcurl -lssl -lcrypto -o /out-transport-test && \
    gcc -std=c17 -Wall -Wextra -Werror -pthread client/tests/conformance/adapter_process_test.c -o /out-adapter-process-test && \
    file /out-adapter | grep -F 'x86-64' && \
    strip /out-example /out-adapter

FROM build AS test
RUN test "$(uname -m)" = x86_64 && /out-test && /out-transport-test && /out-live-owner-test && /out-close-dns-test && /out-relay-barrier-test && /out-adapter-process-test && \
    actual=$(printf '%s\n' \
      '{"id":"hello","protocolVersion":1,"op":"hello"}' \
      '{"id":"close","op":"close"}' | /out-adapter) && \
    printf '%s\n' "$actual" | grep -F '"id":"hello","type":"ready"' && \
    printf '%s\n' "$actual" | grep -Fx '{"id":"close","type":"closed"}'
CMD ["/bin/sh", "-c", "true"]

FROM debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef AS runtime-base
RUN apt-get update && \
    apt-get install --no-install-recommends -y libc-ares2=1.18.1-3 libcurl4=7.88.1-10+deb12u15 libssl3=3.0.20-1~deb12u2 \
      openssl=3.0.20-1~deb12u2 ca-certificates=20230311+deb12u1 libgfortran5=12.2.0-14+deb12u1 && \
    rm -rf /var/lib/apt /var/lib/dpkg /var/log/apt /var/log/dpkg.log /etc/apt /etc/dpkg /usr/lib/apt /usr/share/dpkg \
      /usr/bin/apt* /usr/bin/dpkg* /usr/bin/debconf* /usr/bin/update-alternatives /usr/sbin/update-alternatives \
      /usr/bin/perl* /usr/bin/wget /usr/bin/openssl && \
    find /usr/bin -mindepth 1 -maxdepth 1 \
      ! -name '[' ! -name awk ! -name basename ! -name cat ! -name chmod ! -name chown \
      ! -name cksum ! -name cmp ! -name comm ! -name cp ! -name cut ! -name dash \
      ! -name date ! -name dd ! -name diff ! -name dirname ! -name echo ! -name env \
      ! -name expr ! -name false ! -name find ! -name grep ! -name head ! -name id \
      ! -name join ! -name ln ! -name ls ! -name mawk ! -name mkdir ! -name mkfifo \
      ! -name mktemp ! -name mv ! -name od ! -name paste ! -name printf ! -name pwd \
      ! -name readlink ! -name realpath ! -name rm ! -name rmdir ! -name sed ! -name sh \
      ! -name sha256sum ! -name sleep ! -name sort ! -name tail ! -name tee ! -name test \
      ! -name touch ! -name tr ! -name true ! -name uname ! -name uniq ! -name wc \
      ! -name xargs -delete && \
    find /usr/sbin -mindepth 1 -maxdepth 1 -delete
USER 65532:65532

FROM runtime-base AS example-runtime
COPY --from=build /out-example /usr/local/bin/convex-example
ENTRYPOINT ["/usr/local/bin/convex-example"]

FROM runtime-base AS runtime
COPY --from=build /out-adapter /usr/local/bin/convex-adapter
ENTRYPOINT ["/usr/local/bin/convex-adapter"]
