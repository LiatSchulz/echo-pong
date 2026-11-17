# syntax=docker/dockerfile:1

# Build on the builder's native CPU; Go cross-compiles without QEMU.
ARG GO_VERSION=1.27.4
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS build
WORKDIR /src

ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0 GOTOOLCHAIN=local

COPY . .
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -mod=readonly -trimpath -buildvcs=false \
      -ldflags="-s -w" -o /out/ping-pong .

# Static binary; no runtime shell or writable storage required.
FROM scratch AS runtime
COPY --from=build --chmod=0555 /out/ping-pong /ping-pong
USER 65532:65532
ENV PORT=8080 \
    SECRET_FILE_PATH=/var/run/secrets/echo-pong/token
EXPOSE 8080
ENTRYPOINT ["/ping-pong"]
CMD ["--mode=server"]
