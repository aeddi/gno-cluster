#!/usr/bin/env bash
# internal/scripts/generate-compose.sh — Generate docker-compose.yml from templates.
#
# Usage: generate-compose.sh <run_dir> <num_nodes> <topology> <rpc_port_base> \
#            <p2p_port_base> <grafana_port> <templates_dir> <secrets_dir>
#
# Reads node IDs from <secrets_dir>/node-N/node_id to build peer addresses.
# Sources topology.sh for network computation.
set -euo pipefail

RUN_DIR="$1"
NUM_NODES="$2"
TOPOLOGY="$3"
RPC_PORT_BASE="$4"
P2P_PORT_BASE="$5"
GRAFANA_PORT="$6"
TEMPLATES_DIR="$7"
SECRETS_DIR="$8"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/topology.sh"

COMPOSE_FILE="${RUN_DIR}/docker-compose.yml"

echo "  Generating docker-compose.yml (${NUM_NODES} nodes, ${TOPOLOGY} topology)..."

# ---- Collect node IDs for peer address generation (indexed array, bash 3.2 compatible)
NODE_IDS=()
for i in $(seq 1 "$NUM_NODES"); do
    NODE_KEY_FILE="${RUN_DIR}/gnoland-data-${i}/secrets/node_key.json"
    if [[ ! -f "$NODE_KEY_FILE" ]]; then
        echo "Error: ${NODE_KEY_FILE} not found. Run 'make init' first." >&2
        exit 1
    fi
    NODE_ID_FILE="${SECRETS_DIR}/node-${i}/node_id"
    if [[ -f "$NODE_ID_FILE" ]]; then
        NODE_IDS[$i]=$(cat "$NODE_ID_FILE")
    else
        echo "Error: ${NODE_ID_FILE} not found. Run 'make init' first." >&2
        exit 1
    fi
done

# ---- Build peer strings per node
build_peer_string() {
    local node="$1"
    local peers_str=""
    for peer_idx in $(get_peers "$TOPOLOGY" "$NUM_NODES" "$node"); do
        if [[ -n "$peers_str" ]]; then peers_str+=","; fi
        peers_str+="${NODE_IDS[$peer_idx]}@node-${peer_idx}:26656"
    done
    echo "$peers_str"
}

# ---- Header (shared services)
sed "s/__GRAFANA_PORT__/${GRAFANA_PORT}/g" \
    "${TEMPLATES_DIR}/docker-compose-header.yml.tmpl" > "$COMPOSE_FILE"

# ---- Per-node services
for i in $(seq 1 "$NUM_NODES"); do
    RPC_PORT=$((RPC_PORT_BASE + i - 1))
    P2P_PORT=$((P2P_PORT_BASE + i - 1))
    PEERS=$(build_peer_string "$i")

    # Build network list for this node's topology connections
    NODE_NETS=""
    for net in $(get_node_networks "$TOPOLOGY" "$NUM_NODES" "$i"); do
        NODE_NETS+="      - ${net}"$'\n'
    done

    # Substitute placeholders — use a temp file for multi-line __NODE_NETWORKS__
    TMPNODE=$(mktemp)
    sed -e "s/__N__/${i}/g" \
        -e "s/__RPC_PORT__/${RPC_PORT}/g" \
        -e "s/__P2P_PORT__/${P2P_PORT}/g" \
        -e "s|__PEERS__|${PEERS}|g" \
        "${TEMPLATES_DIR}/docker-compose-node.yml.tmpl" > "$TMPNODE"

    # Replace __NODE_NETWORKS__ with actual network lines using awk
    awk -v nets="$NODE_NETS" '{gsub(/__NODE_NETWORKS__/, nets); print}' \
        "$TMPNODE" >> "$COMPOSE_FILE"
    rm -f "$TMPNODE"

    echo "    Added node-${i} + sentinel-${i}"
done

# ---- Networks section
SIDECAR_NETS=""
for i in $(seq 1 "$NUM_NODES"); do
    SIDECAR_NETS+="  sidecar-${i}:"$'\n'"    driver: bridge"$'\n'
done

TOPO_NETS=""
while IFS=' ' read -r net _a _b; do
    TOPO_NETS+="  ${net}:"$'\n'"    driver: bridge"$'\n'
done < <(get_networks "$TOPOLOGY" "$NUM_NODES")

# Replace network placeholders using awk (sed can't handle multi-line on macOS)
awk -v sidecars="$SIDECAR_NETS" -v topos="$TOPO_NETS" \
    '{gsub(/__SIDECAR_NETWORKS__/, sidecars); gsub(/__TOPOLOGY_NETWORKS__/, topos); print}' \
    "${TEMPLATES_DIR}/docker-compose-networks.yml.tmpl" >> "$COMPOSE_FILE"

echo "  docker-compose.yml generated."
