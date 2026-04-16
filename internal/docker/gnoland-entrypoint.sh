#!/usr/bin/env bash
# internal/docker/gnoland-entrypoint.sh — Initialize config and start gnoland.
#
# Expected environment:
#   NODE_NAME         — e.g. "node-1" (used for config override targeting)
#   PERSISTENT_PEERS  — comma-separated peer list (set by compose)
#
# Expected mounts:
#   /gnoland-data       — node data directory
#   /genesis.json       — chain genesis file
#   /config.overrides   — user config overrides
set -euo pipefail

source /scripts/parse-overrides.sh

# ---- Config Initialization
echo "[${NODE_NAME}] Initializing config..."
gnoland config init --force --data-dir /gnoland-data

# ---- User Overrides
if [[ -f /config.overrides ]]; then
    echo "[${NODE_NAME}] Applying user config overrides..."
    config_set_cmd() { gnoland config set "$1" "$2" --data-dir /gnoland-data; }
    apply_config_overrides "${NODE_NAME}" /config.overrides config_set_cmd
fi

# ---- Hardcoded Overrides
echo "[${NODE_NAME}] Applying hardcoded overrides..."
gnoland config set p2p.laddr "tcp://0.0.0.0:26656" --data-dir /gnoland-data
gnoland config set rpc.laddr "tcp://0.0.0.0:26657" --data-dir /gnoland-data
gnoland config set telemetry.metrics_enabled true --data-dir /gnoland-data
gnoland config set telemetry.traces_enabled true --data-dir /gnoland-data

NODE_INDEX="${NODE_NAME#node-}"
gnoland config set telemetry.exporter_endpoint "sentinel-${NODE_INDEX}:4317" --data-dir /gnoland-data
gnoland config set telemetry.service_name "gno-cluster" --data-dir /gnoland-data
gnoland config set telemetry.service_instance_id "${NODE_NAME}" --data-dir /gnoland-data

if [[ -n "${PERSISTENT_PEERS:-}" ]]; then
    gnoland config set p2p.persistent_peers "${PERSISTENT_PEERS}" --data-dir /gnoland-data
fi

# ---- Start
echo "[${NODE_NAME}] Starting gnoland..."
exec gnoland start \
    --skip-genesis-sig-verification \
    -log-level debug \
    -log-format json \
    --data-dir /gnoland-data \
    --genesis /genesis.json \
    --gnoroot-dir /
