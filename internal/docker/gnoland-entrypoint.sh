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

CONFIG_PATH="/gnoland-data/config/config.toml"

# ---- Config Initialization
echo "[${NODE_NAME}] Initializing config..."
gnoland config init -force -config-path "$CONFIG_PATH"

# ---- User Overrides
if [[ -f /config.overrides ]]; then
  echo "[${NODE_NAME}] Applying user config overrides..."
  config_set_cmd() { gnoland config set "$1" "$2" -config-path "$CONFIG_PATH"; }
  apply_config_overrides "${NODE_NAME}" /config.overrides config_set_cmd
fi

# ---- Hardcoded Overrides
echo "[${NODE_NAME}] Applying hardcoded overrides..."
gnoland config set p2p.laddr "tcp://0.0.0.0:26656" -config-path "$CONFIG_PATH"
gnoland config set rpc.laddr "tcp://0.0.0.0:26657" -config-path "$CONFIG_PATH"

# Route gnoland's OTLP export to the paired sentinel's relay (:4317 gRPC).
# The bare host:port form lands metrics init in its grpc exporter branch
# which accepts endpoint strings in this form. Traces stay disabled: gnoland's
# traces init only accepts http/https schemes, whereas the sentinel relay is
# gRPC-only — mixing them would crash gnoland at startup with "unsupported
# scheme". Re-enable traces once the sentinel grows an HTTP traces endpoint.
NODE_INDEX="${NODE_NAME#node-}"
gnoland config set telemetry.metrics_enabled true -config-path "$CONFIG_PATH"
gnoland config set telemetry.traces_enabled false -config-path "$CONFIG_PATH"
gnoland config set telemetry.exporter_endpoint "sentinel-${NODE_INDEX}:4317" -config-path "$CONFIG_PATH"
gnoland config set telemetry.service_name "gno-cluster" -config-path "$CONFIG_PATH"
gnoland config set telemetry.service_instance_id "${NODE_NAME}" -config-path "$CONFIG_PATH"

if [[ -n "${PERSISTENT_PEERS:-}" ]]; then
  gnoland config set p2p.persistent_peers "${PERSISTENT_PEERS}" -config-path "$CONFIG_PATH"
fi

# ---- Start
echo "[${NODE_NAME}] Starting gnoland..."
exec gnoland start \
  -skip-genesis-sig-verification \
  -log-level debug \
  -log-format json \
  -data-dir /gnoland-data \
  -genesis /genesis.json
