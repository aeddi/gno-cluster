#!/usr/bin/env bash
# internal/scripts/create-run.sh — Create a fresh run folder and start the cluster.
#
# Usage: create-run.sh <project_root> <gno_repo> <gno_version> <num_nodes> \
#            <topology> <rpc_port_base> <p2p_port_base> <grafana_port> \
#            <victoria_metrics_port> <loki_port>
set -euo pipefail

PROJECT_ROOT="$1"
GNO_REPO="$2"
GNO_VERSION="$3"
NUM_NODES="$4"
TOPOLOGY="$5"
RPC_PORT_BASE="$6"
P2P_PORT_BASE="$7"
GRAFANA_PORT="$8"
VICTORIA_METRICS_PORT="$9"
LOKI_PORT="${10}"

SCRIPTS_DIR="${PROJECT_ROOT}/internal/scripts"
TEMPLATES_DIR="${PROJECT_ROOT}/internal/templates"
SECRETS_DIR="${PROJECT_ROOT}/internal/secrets"

source "${SCRIPTS_DIR}/parse-genesis.sh"

# ---- Validate port ranges
RPC_END=$((RPC_PORT_BASE + NUM_NODES - 1))
if ((RPC_END >= P2P_PORT_BASE)); then
  echo "Error: RPC port range (${RPC_PORT_BASE}-${RPC_END}) overlaps with P2P base (${P2P_PORT_BASE})."
  echo "  Increase GNOLAND_P2P_PORT_BASE to at least $((RPC_PORT_BASE + NUM_NODES))."
  exit 1
fi

# ---- Parse genesis for folder name metadata
echo "==> Parsing genesis.json..."
eval "$(parse_genesis "${PROJECT_ROOT}/genesis.json")"

# ---- Build folder name
# Slugify repo and version: '/' in refs like "feature/foo" would create nested
# paths under runs/, breaking `make list` and `runs/current` semantics.
REPO_SLUG=$(echo "$GNO_REPO" | tr '/' '-')
VERSION_SLUG=$(echo "$GNO_VERSION" | tr '/' '-')
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RUN_NAME="${TIMESTAMP}_${REPO_SLUG}_${VERSION_SLUG}_${NUM_NODES}-nodes_${validators_count}-vals_${balances_count}-bals_${txs_count}-txs"
RUN_DIR="${PROJECT_ROOT}/runs/${RUN_NAME}"

echo "==> Creating run: ${RUN_NAME}"
mkdir -p "$RUN_DIR"

# ---- Snapshot configs
echo "  Copying configs..."
cp "${PROJECT_ROOT}/genesis.json" "${RUN_DIR}/genesis.json"
cp "${PROJECT_ROOT}/cluster.env" "${RUN_DIR}/cluster.env"
if [[ -f "${PROJECT_ROOT}/config.overrides" ]]; then
  cp "${PROJECT_ROOT}/config.overrides" "${RUN_DIR}/config.overrides"
else
  touch "${RUN_DIR}/config.overrides"
fi

# ---- Copy secrets and set up node data dirs
echo "  Setting up node data directories..."
for i in $(seq 1 "$NUM_NODES"); do
  NODE_DATA="${RUN_DIR}/gnoland-data-${i}"
  mkdir -p "${NODE_DATA}/secrets"

  if [[ ! -d "${SECRETS_DIR}/node-${i}" ]]; then
    echo "Error: internal/secrets/node-${i} not found. Run 'make create' first." >&2
    exit 1
  fi

  cp "${SECRETS_DIR}/node-${i}"/* "${NODE_DATA}/secrets/"

  # Reset validator state to genesis
  printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' \
    >"${NODE_DATA}/secrets/priv_validator_state.json"

  echo "    Prepared gnoland-data-${i}"
done

# ---- Extract watchtower deploy/ configs (loki, grafana) into the run
# Single source of truth: gno-watchtower's deploy/ tree, baked into the
# config-export image at build time. See internal/scripts/extract-configs.sh.
echo "  Extracting watchtower configs..."
WT_EXTRACT_DIR="${RUN_DIR}/.wt-extracted"
bash "${SCRIPTS_DIR}/extract-configs.sh" "$WT_EXTRACT_DIR"

cp "${WT_EXTRACT_DIR}/deploy/loki/loki-config.yml" "${RUN_DIR}/loki-config.yml"
mkdir -p "${RUN_DIR}/grafana-provisioning"
cp -r "${WT_EXTRACT_DIR}/deploy/grafana/datasources" "${RUN_DIR}/grafana-provisioning/datasources"
cp -r "${WT_EXTRACT_DIR}/deploy/grafana/dashboards" "${RUN_DIR}/grafana-provisioning/dashboards"

# ---- Create empty data dirs
mkdir -p "${RUN_DIR}/victoria-data" "${RUN_DIR}/loki-data" "${RUN_DIR}/grafana-data"

# ---- Generate watchtower + sentinel configs from watchtower defaults + cluster overlay
echo "==> Generating configs..."
bash "${SCRIPTS_DIR}/generate-configs.sh" "$RUN_DIR" "$NUM_NODES" "$WT_EXTRACT_DIR"

# Extract dir has served its purpose now.
rm -rf "$WT_EXTRACT_DIR"

# ---- Generate docker-compose.yml
echo "==> Generating docker-compose.yml..."
bash "${SCRIPTS_DIR}/generate-compose.sh" \
  "$RUN_DIR" "$NUM_NODES" "$TOPOLOGY" \
  "$RPC_PORT_BASE" "$P2P_PORT_BASE" "$GRAFANA_PORT" \
  "$VICTORIA_METRICS_PORT" "$LOKI_PORT" \
  "$TEMPLATES_DIR"

# ---- Update current symlink
ln -sfn "$RUN_DIR" "${PROJECT_ROOT}/runs/current"
echo "==> Symlinked runs/current -> ${RUN_NAME}"
