#!/usr/bin/env bash
# internal/scripts/extract-configs.sh — Pull watchtower's deploy/ configs out of
# the gno-cluster-config-export:latest image and drop them into <output_dir>.
#
# Usage: extract-configs.sh <output_dir>
#
# Output layout mirrors watchtower's deploy/ tree:
#   <output_dir>/loki/loki-config.yml
#   <output_dir>/grafana/datasources/datasources.yaml
#   <output_dir>/grafana/dashboards/*.yaml *.json
set -euo pipefail

OUT_DIR="${1:?Usage: extract-configs.sh <output_dir>}"
IMAGE="${EXTRACT_IMAGE:-gno-cluster-config-export:latest}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Error: image $IMAGE not found — run 'make build' first." >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

id=$(docker create "$IMAGE")
trap 'docker rm -f "$id" >/dev/null 2>&1 || true' EXIT
docker cp "$id:/export/." "$OUT_DIR/"
