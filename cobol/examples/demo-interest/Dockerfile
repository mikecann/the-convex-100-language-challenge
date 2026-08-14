# Video-demo image for COBOL's English-like ADD statement. Build with the
# cobol/ directory as context:
#   docker build -t cobol-interest-demo \
#     -f cobol/examples/demo-interest/Dockerfile cobol
FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       gnucobol4=4.0~early~20200606-6+b1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY examples/demo-interest/main.cbl ./main.cbl
RUN cobc -free -Wall -x -o /usr/local/bin/add-interest main.cbl

ENTRYPOINT ["/usr/local/bin/add-interest"]
