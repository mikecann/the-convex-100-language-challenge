# Video-demo image: builds the unmodified Fortran client plus the watch-mode
# demo. Deliberately simple and single-stage; this is filming kit, not the
# hermetic verified image. Build with the fortran/ directory as context:
#   docker build -t convex-fortran-watch -f fortran/examples/demo-live/Dockerfile fortran
FROM gcc:14.2.0-bookworm
RUN apt-get update && \
    apt-get install --no-install-recommends -y libc-ares-dev libcurl4-openssl-dev libssl-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY client ./client
COPY examples/demo-live ./examples/demo-live
RUN mkdir -p /build && \
    gcc -std=c17 -Wall -pthread -c client/curl_transport.c -o /build/curl_transport.o && \
    gfortran -cpp -std=f2018 -O2 -Wall -ffree-line-length-none -J /build -c client/convex.f90 -o /build/convex.o && \
    gfortran -std=f2018 -Wall -ffree-line-length-none -pthread -I /build /build/convex.o /build/curl_transport.o \
      examples/demo-live/watch.f90 -lcares -lcurl -lssl -lcrypto -o /usr/local/bin/convex-watch
ENTRYPOINT ["/usr/local/bin/convex-watch"]
