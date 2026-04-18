#!/usr/bin/env bash
# internal/scripts/generate-compose.sh — Generate docker-compose.yml from templates.
#
# Usage: generate-compose.sh <run_dir> <num_nodes> <topology> <rpc_port_base> \
#            <p2p_port_base> <grafana_port> <victoria_metrics_port> <loki_port> \
#            <templates_dir> <secrets_dir>
#
# Reads node IDs from <secrets_dir>/node-N/node_id to build peer addresses.
# Sources topology.sh for network computation.
set -euo pipefail

TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

RUN_DIR="$1"
NUM_NODES="$2"
TOPOLOGY="$3"
RPC_PORT_BASE="$4"
P2P_PORT_BASE="$5"
GRAFANA_PORT="$6"
VICTORIA_METRICS_PORT="$7"
LOKI_PORT="$8"
TEMPLATES_DIR="$9"
SECRETS_DIR="${10}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/topology.sh"

COMPOSE_FILE="${RUN_DIR}/docker-compose.yml"

echo "  Generating docker-compose.yml (${NUM_NODES} nodes, ${TOPOLOGY} topology)..."

# ---- Collect node IDs for peer address generation (indexed array, bash 3.2 compatible)
NODE_IDS=()
for i in $(seq 1 "$NUM_NODES"); do
  NODE_KEY_FILE="${RUN_DIR}/gnoland-data-${i}/secrets/node_key.json"
  if [[ ! -f "$NODE_KEY_FILE" ]]; then
    echo "Error: ${NODE_KEY_FILE} not found. Run 'make create' first." >&2
    exit 1
  fi
  NODE_ID_FILE="${SECRETS_DIR}/node-${i}/node_id"
  if [[ -f "$NODE_ID_FILE" ]]; then
    NODE_IDS[$i]=$(cat "$NODE_ID_FILE")
  else
    echo "Error: ${NODE_ID_FILE} not found. Run 'make create' first." >&2
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

# ---- replace_placeholder <file> <placeholder> <replacement_file>
# Replaces a line containing <placeholder> with the contents of <replacement_file>.
# Works on both macOS and Linux by avoiding multi-line sed/awk -v strings.
replace_placeholder() {
  local file="$1" placeholder="$2" replacement_file="$3"
  local tmp
  tmp=$(mktemp)
  while IFS= read -r line; do
    if [[ "$line" == *"$placeholder"* ]]; then
      cat "$replacement_file"
    else
      echo "$line"
    fi
  done <"$file" >"$tmp"
  mv "$tmp" "$file"
}

# ---- Header (shared services)
sed -e "s/__GRAFANA_PORT__/${GRAFANA_PORT}/g" \
  -e "s/__VICTORIA_METRICS_PORT__/${VICTORIA_METRICS_PORT}/g" \
  -e "s/__LOKI_PORT__/${LOKI_PORT}/g" \
  "${TEMPLATES_DIR}/docker-compose-header.yml.tmpl" >"$COMPOSE_FILE"

# ---- Per-node services
for i in $(seq 1 "$NUM_NODES"); do
  RPC_PORT=$((RPC_PORT_BASE + i - 1))
  P2P_PORT=$((P2P_PORT_BASE + i - 1))
  PEERS=$(build_peer_string "$i")

  # Build network list for this node's topology connections
  TMPNETS=$(mktemp)
  TMPFILES+=("$TMPNETS")
  for net in $(get_node_networks "$TOPOLOGY" "$NUM_NODES" "$i"); do
    echo "      - ${net}" >>"$TMPNETS"
  done

  # Substitute simple placeholders
  TMPNODE=$(mktemp)
  TMPFILES+=("$TMPNODE")
  sed -e "s/__N__/${i}/g" \
    -e "s/__RPC_PORT__/${RPC_PORT}/g" \
    -e "s/__P2P_PORT__/${P2P_PORT}/g" \
    -e "s|__PEERS__|${PEERS}|g" \
    "${TEMPLATES_DIR}/docker-compose-node.yml.tmpl" >"$TMPNODE"

  # Replace multi-line __NODE_NETWORKS__ placeholder
  replace_placeholder "$TMPNODE" "__NODE_NETWORKS__" "$TMPNETS"

  cat "$TMPNODE" >>"$COMPOSE_FILE"
  rm -f "$TMPNODE" "$TMPNETS"

  echo "    Added node-${i} + sentinel-${i}"
done

# ---- Networks section: build sidecar and topology network definitions
TMPSIDECAR=$(mktemp)
TMPFILES+=("$TMPSIDECAR")
for i in $(seq 1 "$NUM_NODES"); do
  echo "  sidecar-${i}:" >>"$TMPSIDECAR"
  echo "    driver: bridge" >>"$TMPSIDECAR"
done

TMPTOPO=$(mktemp)
TMPFILES+=("$TMPTOPO")
while IFS=' ' read -r net _a _b; do
  echo "  ${net}:" >>"$TMPTOPO"
  echo "    driver: bridge" >>"$TMPTOPO"
done < <(get_networks "$TOPOLOGY" "$NUM_NODES")

# Start from template, replace placeholders
cp "${TEMPLATES_DIR}/docker-compose-networks.yml.tmpl" "${COMPOSE_FILE}.nets"
replace_placeholder "${COMPOSE_FILE}.nets" "__SIDECAR_NETWORKS__" "$TMPSIDECAR"
replace_placeholder "${COMPOSE_FILE}.nets" "__TOPOLOGY_NETWORKS__" "$TMPTOPO"
cat "${COMPOSE_FILE}.nets" >>"$COMPOSE_FILE"
rm -f "${COMPOSE_FILE}.nets" "$TMPSIDECAR" "$TMPTOPO"

echo "  docker-compose.yml generated."
