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

# Compute build version the same way as gnoland's upstream Dockerfile
# (gnolang/gno@391938e8): prefer an exact tag, fall back to
# "<branch>.<commit-count>+<short-sha>". Written to /build_version so every
# build target below can bake it into the binary via -ldflags.
RUN { git describe --tags --exact-match 2>/dev/null \
      || echo "$(git rev-parse --abbrev-ref HEAD).$(git rev-list --count HEAD)+$(git rev-parse --short HEAD)"; \
    } > /build_version

RUN cd gno.land && go build \
  -ldflags "-w -s -X github.com/gnolang/gno/tm2/pkg/version.Version=$(cat /build_version)" \
  -o /build/gnoland ./cmd/gnoland

# ---- Gnoland
FROM alpine:3 AS gnoland
ENV GNOROOT="/gnoroot"

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
COPY --from=gno-builder /src/gnovm/stdlibs /gnoroot/gnovm/stdlibs
COPY --from=gno-builder /src/gnovm/tests/stdlibs /gnoroot/gnovm/tests/stdlibs
COPY internal/scripts/parse-overrides.sh /scripts/parse-overrides.sh
COPY internal/docker/gnoland-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /scripts/parse-overrides.sh

ENTRYPOINT ["/entrypoint.sh"]

# ---- Watchtower Builder (Debian for systemd/journald headers)
FROM golang:1.25 AS watchtower-builder

ARG WATCHTOWER_REPO=aeddi/gno-watchtower
ARG WATCHTOWER_COMMIT_HASH
ARG WATCHTOWER_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
  git libsystemd-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone "https://github.com/${WATCHTOWER_REPO}.git" . \
  && git checkout "${WATCHTOWER_COMMIT_HASH:-${WATCHTOWER_VERSION}}"
RUN go build -o /build/watchtower ./cmd/watchtower \
  && go build -o /build/sentinel ./cmd/sentinel

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

RUN apk add --no-cache ca-certificates gcompat libgcc

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

RUN apk add --no-cache ca-certificates docker-cli gcompat libgcc

COPY --from=watchtower-builder /build/sentinel /usr/local/bin/sentinel

ENTRYPOINT ["sentinel"]

# ---- Config Export
# Exposes watchtower's deploy/ tree and the default sentinel/watchtower configs
# (produced by `generate-config`) so gno-cluster can extract them at run-creation
# time instead of duplicating them. /export/defaults/ files are the schema-current
# TOML defaults; gno-cluster layers cluster-specific overrides on top via sed.
FROM alpine:3 AS config-export

ARG WATCHTOWER_COMMIT_HASH
ARG WATCHTOWER_VERSION
ARG WATCHTOWER_REPO

LABEL watchtower.commit="${WATCHTOWER_COMMIT_HASH}" \
  watchtower.version="${WATCHTOWER_VERSION}" \
  watchtower.repo="${WATCHTOWER_REPO}"

# gcompat/libgcc are needed for the glibc-linked binaries from the Debian builder.
RUN apk add --no-cache gcompat libgcc

COPY --from=watchtower-builder /src/deploy         /export/deploy
COPY --from=watchtower-builder /build/sentinel    /tmp/sentinel
COPY --from=watchtower-builder /build/watchtower  /tmp/watchtower

RUN mkdir -p /export/defaults \
  && /tmp/sentinel   generate-config /export/defaults/sentinel.toml \
  && /tmp/watchtower generate-config /export/defaults/watchtower.toml \
  && rm -f /tmp/sentinel /tmp/watchtower
