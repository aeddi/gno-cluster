#!/usr/bin/env bash
# internal/scripts/generate-configs.sh — Generate watchtower.toml and sentinel configs.
#
# Usage: generate-configs.sh <run_dir> <num_nodes> <templates_dir>
#
# Generates:
#   <run_dir>/watchtower.toml
#   <run_dir>/sentinel-N-config.toml  (one per node)
set -euo pipefail

RUN_DIR="$1"
NUM_NODES="$2"
TEMPLATES_DIR="$3"

echo "  Generating watchtower config..."

# ---- Watchtower config: start from template, append per-node validator blocks
cp "${TEMPLATES_DIR}/watchtower-config.toml.tmpl" "${RUN_DIR}/watchtower.toml"

for i in $(seq 1 "$NUM_NODES"); do
    TOKEN=$(openssl rand -hex 32)
    # Store token for sentinel config generation
    echo "$TOKEN" > "${RUN_DIR}/.token-${i}"

    cat >> "${RUN_DIR}/watchtower.toml" <<EOF

[validators.node-${i}]
token          = "${TOKEN}"
permissions    = ["rpc", "metrics", "logs", "otlp"]
logs_min_level = "debug"
EOF
    echo "    Added validator node-${i} to watchtower config"
done

# ---- Sentinel configs: substitute placeholders in template
for i in $(seq 1 "$NUM_NODES"); do
    TOKEN=$(cat "${RUN_DIR}/.token-${i}")
    SENTINEL_CONFIG="${RUN_DIR}/sentinel-${i}-config.toml"

    sed -e "s/__N__/${i}/g" \
        -e "s/__TOKEN__/${TOKEN}/g" \
        "${TEMPLATES_DIR}/sentinel-config.toml.tmpl" > "$SENTINEL_CONFIG"

    echo "    Generated sentinel-${i}-config.toml"
done

# Clean up token files
rm -f "${RUN_DIR}"/.token-*

echo "  Config generation complete."
