# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG GO_IMAGE=golang:1.25.6-bookworm@sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e

FROM ${GO_IMAGE} AS dependencies
WORKDIR /src
COPY client/go.mod client/go.sum ./
RUN go mod download

FROM dependencies AS test
# Assemble a conventional Go module only inside the container. The repository
# keeps client and example ownership obvious for people reading the project.
COPY client/*.go ./
COPY client/tests ./tests
COPY examples ./examples
RUN test -z "$(gofmt -l .)"
RUN go test -race ./...
RUN go test -race -tags convexadapter ./...

FROM test AS build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -tags convexadapter -trimpath \
    -ldflags="-s -w -buildid=" \
    -o /out/convex-go-adapter ./tests/conformance

FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS runtime
RUN apk add --no-cache ca-certificates=20260611-r0
COPY --from=build /out/convex-go-adapter /usr/local/bin/convex-go-adapter
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/convex-go-adapter"]
