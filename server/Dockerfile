# The Collection Keeper sync server: a static Go binary on distroless.
#   docker build -t collection-keeper-server --build-arg VERSION=$(git rev-parse --short HEAD) server/
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/ckserver ./cmd/ckserver

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ckserver /ckserver
USER 65532:65532
EXPOSE 8080
ENV LISTEN_ADDR=:8080 BLOB_DIR=/data/blobs
ENTRYPOINT ["/ckserver"]
