# internal/Dockerfile — Multi-stage build for gnoland, watchtower, and sentinel.
# Build targets: gnoland, watchtower, sentinel
# Usage: docker build -f internal/Dockerfile --target <target> .

# ---- Gno Builder
FROM golang:1.24-alpine AS gno-builder

ARG GNO_REPO=gnolang/gno
ARG GNO_COMMIT_HASH
ARG GNO_VERSION

RUN apk add --no-cache git

WORKDIR /src
RUN git clone "https://github.com/${GNO_REPO}.git" . \
    && git checkout "${GNO_COMMIT_HASH:-${GNO_VERSION}}"
RUN cd gno.land && go build -o /build/gnoland ./cmd/gnoland

# ---- Gnoland
FROM alpine:3 AS gnoland

ARG GNO_COMMIT_HASH
ARG GNO_VERSION
ARG GNO_REPO
ARG BUILD_DATE

LABEL gno.commit="${GNO_COMMIT_HASH}" \
      gno.version="${GNO_VERSION}" \
      gno.repo="${GNO_REPO}" \
      build.date="${BUILD_DATE}"

RUN apk add --no-cache bash jq

COPY --from=gno-builder /build/gnoland /usr/local/bin/gnoland
COPY --from=gno-builder /src/gnovm/stdlibs /gnovm/stdlibs
COPY internal/scripts/parse-overrides.sh /scripts/parse-overrides.sh
COPY internal/docker/gnoland-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /scripts/parse-overrides.sh

ENTRYPOINT ["/entrypoint.sh"]

# ---- Watchtower Builder
FROM golang:1.25-alpine AS watchtower-builder

ARG WATCHTOWER_REPO=aeddi/gno-watchtower
ARG WATCHTOWER_COMMIT_HASH
ARG WATCHTOWER_VERSION

RUN apk add --no-cache git gcc musl-dev

WORKDIR /src
RUN git clone "https://github.com/${WATCHTOWER_REPO}.git" . \
    && git checkout "${WATCHTOWER_COMMIT_HASH:-${WATCHTOWER_VERSION}}"
RUN CGO_ENABLED=0 go build -o /build/watchtower ./cmd/watchtower \
    && CGO_ENABLED=1 go build -o /build/sentinel ./cmd/sentinel

# ---- Watchtower
FROM alpine:3 AS watchtower

ARG WATCHTOWER_COMMIT_HASH
ARG WATCHTOWER_VERSION
ARG WATCHTOWER_REPO
ARG BUILD_DATE

LABEL watchtower.commit="${WATCHTOWER_COMMIT_HASH}" \
      watchtower.version="${WATCHTOWER_VERSION}" \
      watchtower.repo="${WATCHTOWER_REPO}" \
      build.date="${BUILD_DATE}"

RUN apk add --no-cache ca-certificates

COPY --from=watchtower-builder /build/watchtower /usr/local/bin/watchtower

ENTRYPOINT ["watchtower"]

# ---- Sentinel
FROM alpine:3 AS sentinel

ARG WATCHTOWER_COMMIT_HASH
ARG WATCHTOWER_VERSION
ARG WATCHTOWER_REPO
ARG BUILD_DATE

LABEL sentinel.commit="${WATCHTOWER_COMMIT_HASH}" \
      sentinel.version="${WATCHTOWER_VERSION}" \
      sentinel.repo="${WATCHTOWER_REPO}" \
      build.date="${BUILD_DATE}"

RUN apk add --no-cache ca-certificates docker-cli

COPY --from=watchtower-builder /build/sentinel /usr/local/bin/sentinel

ENTRYPOINT ["sentinel"]
