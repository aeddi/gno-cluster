#!/usr/bin/env bash
# internal/scripts/generate-configs.sh — Generate watchtower.toml and sentinel configs
# by layering cluster-specific overrides on top of watchtower's own default configs.
#
# Usage: generate-configs.sh <run_dir> <num_nodes> <wt_extract_dir>
#
# <wt_extract_dir>/defaults/{sentinel,watchtower}.toml are the outputs of
# `sentinel generate-config` and `watchtower generate-config` — the schema-current
# defaults. gno-cluster layers the following overrides:
#
#   sentinel.toml (per-node):
#     - fill <watchtower-server-url>, <watchtower-auth-token>,
#       <gnoland-container-name>, <path-to-genesis-json>
#     - rpc_url      localhost -> node-N
#     - min_level    info -> debug
#     - listen_addr  localhost:4317 -> 0.0.0.0:4317 (OTLP)
#     - resources.source  host -> docker
#     - metadata: drop binary_path / config_path, add binary_version_cmd /
#       config_get_cmd using docker exec
#
#   watchtower.toml:
#     - security.*   relaxed defaults for dev (rps/burst/threshold/duration)
#     - <victoria-metrics-url>, <loki-url>
#     - remove the sample [validators.my-validator], append one
#       [validators.node-N] per node with its generated token
set -euo pipefail

RUN_DIR="$1"
NUM_NODES="$2"
WT_EXTRACT_DIR="$3"

SENTINEL_DEFAULT="${WT_EXTRACT_DIR}/defaults/sentinel.toml"
WATCHTOWER_DEFAULT="${WT_EXTRACT_DIR}/defaults/watchtower.toml"

for f in "$SENTINEL_DEFAULT" "$WATCHTOWER_DEFAULT"; do
  [[ -f "$f" ]] || { echo "Error: missing $f (did extract-configs.sh run?)" >&2; exit 1; }
done

# Tokens are shared secrets between watchtower and each sentinel; make sure
# they don't survive on disk even if the script fails between the two loops.
cleanup_tokens() { rm -f "${RUN_DIR}"/.token-*; }
trap cleanup_tokens EXIT

# ---- Watchtower config: defaults → drop sample validator → override security +
# fill URL placeholders → append per-node [validators.node-N] blocks.
echo "  Generating watchtower config..."

WT_OUT="${RUN_DIR}/watchtower.toml"

# Strip the [validators]/[validators.my-validator] section (and everything after
# it, since it's always emitted last). We add our own validator blocks below.
awk '
  /^\[validators(\.|$)/ { stop=1 }
  !stop { print }
' "$WATCHTOWER_DEFAULT" \
  | sed \
    -e "s|'<victoria-metrics-url>'|'http://victoria-metrics:8428'|" \
    -e "s|'<loki-url>'|'http://loki:3100'|" \
    -e "s|^rate_limit_rps = 10.0|rate_limit_rps = 100.0|" \
    -e "s|^rate_limit_burst = 10|rate_limit_burst = 50|" \
    -e "s|^ban_threshold = 5|ban_threshold = 50|" \
    -e "s|^ban_duration = '15m0s'|ban_duration = '1m'|" \
    > "$WT_OUT"

# Append a [validators.node-N] block per node.
for i in $(seq 1 "$NUM_NODES"); do
  TOKEN=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
  echo "$TOKEN" > "${RUN_DIR}/.token-${i}"

  cat >> "$WT_OUT" <<EOF

[validators.node-${i}]
token          = "${TOKEN}"
permissions    = ["rpc", "metrics", "logs", "otlp"]
logs_min_level = "debug"
EOF
  echo "    Added validator node-${i} to watchtower config"
done

# ---- Sentinel configs: one per node, placeholders filled + overrides applied.
for i in $(seq 1 "$NUM_NODES"); do
  TOKEN=$(cat "${RUN_DIR}/.token-${i}")
  NODE="node-${i}"
  OUT="${RUN_DIR}/sentinel-${i}-config.toml"

  sed \
    -e "s|'<watchtower-server-url>'|'http://watchtower:8080'|" \
    -e "s|'<watchtower-auth-token>'|'${TOKEN}'|" \
    -e "s|'<gnoland-container-name>'|'${NODE}'|g" \
    -e "s|'<path-to-genesis-json>'|'/genesis.json'|" \
    -e "s|^rpc_url = 'http://localhost:26657'|rpc_url = 'http://${NODE}:26657'|" \
    -e "s|^min_level = 'info'|min_level = 'debug'|" \
    -e "s|^listen_addr = 'localhost:4317'|listen_addr = '0.0.0.0:4317'|" \
    -e "s|^source = 'host'|source = 'docker'|" \
    -e "s|^binary_path = .*|binary_version_cmd = 'docker exec ${NODE} gnoland version'|" \
    -e "s|^config_path = .*|config_get_cmd = 'docker exec ${NODE} gnoland config get %s -config-path /gnoland-data/config/config.toml'|" \
    "$SENTINEL_DEFAULT" > "$OUT"

  echo "    Generated sentinel-${i}-config.toml"
done

echo "  Config generation complete."
