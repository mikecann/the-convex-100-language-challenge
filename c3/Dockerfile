# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
FROM ${DEBIAN_IMAGE} AS build
ARG C3_VERSION=0.8.2
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libcurl4-openssl-dev gcc libc6-dev && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:dda062e791359d01549c5d1aefbac5ac88dcd9c6f84e0b2d3309e92f8f6600aa \
  https://github.com/c3lang/c3c/releases/download/v${C3_VERSION}/c3-linux-static.tar.gz /tmp/c3.tar.gz
RUN tar -xzf /tmp/c3.tar.gz -C /opt && test "$(/opt/c3/c3c --version | awk '/C3 Compiler Version/ {print $4}')" = "$C3_VERSION"
WORKDIR /src
COPY client ./client
COPY examples ./examples
RUN gcc -std=c17 -Wall -Wextra -Werror -c client/platform.c -o /out-platform.o && \
    C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -l curl -o /out-adapter client/adapter.c3 client/http.c3 client/values.c3 client/response.c3 /out-platform.o && \
    C3C_LIB=/opt/c3/lib /opt/c3/c3c compile -o /out-example examples/basics/main.c3 && \
    readelf -h /out-adapter | grep 'Advanced Micro Devices X86-64'
FROM build AS test
RUN test "$(uname -m)" = x86_64 && test "$(/out-adapter)" = 'c3 adapter seed' && test "$(/out-example)" = 'c3 example seed'
