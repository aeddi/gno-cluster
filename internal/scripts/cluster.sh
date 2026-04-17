#!/usr/bin/env bash
# internal/scripts/cluster.sh — Main entry point for gno-cluster operations.
#
# Usage: cluster.sh <command> [args]
# Commands: build, init, start, stop, clone, status, logs, infos, update
#
# Expects environment variables (set by Makefile or cluster.env):
#   PROJECT_ROOT, GNO_VERSION, GNO_REPO, WATCHTOWER_VERSION, WATCHTOWER_REPO,
#   NUM_NODES, TOPOLOGY, GNOLAND_RPC_PORT_BASE, GNOLAND_P2P_PORT_BASE, GRAFANA_PORT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT_LINK="${PROJECT_ROOT}/runs/current"
GNOLAND_IMAGE="gno-cluster-gnoland:latest"

# shellcheck source=preflight.sh
source "${SCRIPT_DIR}/preflight.sh"

# Fix the docker compose project name so networks have stable names across runs.
# Only one run can be active at a time (host ports collide), so reusing network
# slots is safe and prevents cross-run leakage when stop/start uses different
# run folders. Without this, compose derives the project name from the compose
# file's parent directory (the timestamped run folder), creating a fresh set of
# networks for every run.
export COMPOSE_PROJECT_NAME=gno-cluster

# ---- Helpers

gnoland_run() {
    docker run --rm --entrypoint gnoland "$@"
}

# Extracts a JSON string value by key from stdin. Handles "key":"val" and "key": "val".
# Usage: echo "$json" | json_val <key>
json_val() {
    local key="$1"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
        | sed "s/\"${key}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"
}

# HTTP GET with curl→wget fallback.
http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 2 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=2 "$url" 2>/dev/null
    else
        echo "Error: neither curl nor wget is installed." >&2
        echo "  Install one of them to use 'make status'." >&2
        return 1
    fi
}

# Generates 32 bytes of random hex. Uses /dev/urandom (POSIX).
rand_hex() {
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
}

require_current_run() {
    if [[ ! -L "$CURRENT_LINK" ]]; then
        echo "Error: no active run (runs/current does not exist)."
        exit 1
    fi
    readlink "$CURRENT_LINK"
}

is_running() {
    local compose_file="$1"
    docker compose -f "$compose_file" ps --status running -q 2>/dev/null | grep -q .
}

# Retrieves address, pubkey, and node_id for a given node index using gnoland secrets get -raw.
# Sets variables: _addr, _pubkey, _node_id
get_node_info() {
    local idx="$1"
    _addr=$(gnoland_run \
        -v "${PROJECT_ROOT}/secrets/node-${idx}:/gnoland-data" \
        "$GNOLAND_IMAGE" \
        secrets get validator_key.address -raw --data-dir /gnoland-data 2>/dev/null)
    _pubkey=$(gnoland_run \
        -v "${PROJECT_ROOT}/secrets/node-${idx}:/gnoland-data" \
        "$GNOLAND_IMAGE" \
        secrets get validator_key.pub_key -raw --data-dir /gnoland-data 2>/dev/null)
    _node_id=$(cat "secrets/node-${idx}/node_id" 2>/dev/null || echo "unknown")
}

validate_port_ranges() {
    local rpc_base="$1" p2p_base="$2" nodes="$3"
    local rpc_end=$((rpc_base + nodes - 1))
    if ((rpc_end >= p2p_base)); then
        echo "Error: RPC port range (${rpc_base}-${rpc_end}) overlaps with P2P base (${p2p_base})."
        echo "  Increase GNOLAND_P2P_PORT_BASE to at least $((rpc_base + nodes))."
        exit 1
    fi
}

# ---- Build

cmd_build() {
    echo "==> Resolving versions to commit hashes..."

    local gno_commit wt_commit build_date
    gno_commit=$(git ls-remote "https://github.com/${GNO_REPO}.git" "${GNO_VERSION}" | head -1 | cut -f1)
    if [[ -z "$gno_commit" ]]; then
        echo "Error: could not resolve GNO_VERSION='${GNO_VERSION}' from ${GNO_REPO}"
        exit 1
    fi

    wt_commit=$(git ls-remote "https://github.com/${WATCHTOWER_REPO}.git" "${WATCHTOWER_VERSION}" | head -1 | cut -f1)
    if [[ -z "$wt_commit" ]]; then
        echo "Error: could not resolve WATCHTOWER_VERSION='${WATCHTOWER_VERSION}' from ${WATCHTOWER_REPO}"
        exit 1
    fi

    build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "  gno:        ${GNO_REPO}@${GNO_VERSION} -> ${gno_commit:0:12}"
    echo "  watchtower: ${WATCHTOWER_REPO}@${WATCHTOWER_VERSION} -> ${wt_commit:0:12}"
    echo ""

    echo "==> Building gnoland image..."
    docker build -f internal/Dockerfile \
        --target gnoland \
        --build-arg GNO_REPO="${GNO_REPO}" \
        --build-arg GNO_COMMIT_HASH="${gno_commit}" \
        --build-arg GNO_VERSION="${GNO_VERSION}" \
        --build-arg BUILD_DATE="${build_date}" \
        -t gno-cluster-gnoland:latest .
    echo ""

    echo "==> Building watchtower image..."
    docker build -f internal/Dockerfile \
        --target watchtower \
        --build-arg WATCHTOWER_REPO="${WATCHTOWER_REPO}" \
        --build-arg WATCHTOWER_COMMIT_HASH="${wt_commit}" \
        --build-arg WATCHTOWER_VERSION="${WATCHTOWER_VERSION}" \
        --build-arg BUILD_DATE="${build_date}" \
        -t gno-cluster-watchtower:latest .
    echo ""

    echo "==> Building sentinel image..."
    docker build -f internal/Dockerfile \
        --target sentinel \
        --build-arg WATCHTOWER_REPO="${WATCHTOWER_REPO}" \
        --build-arg WATCHTOWER_COMMIT_HASH="${wt_commit}" \
        --build-arg WATCHTOWER_VERSION="${WATCHTOWER_VERSION}" \
        --build-arg BUILD_DATE="${build_date}" \
        -t gno-cluster-sentinel:latest .
    echo ""

    echo "==> Build complete."
}

# ---- Init

cmd_init() {
    echo "==> Initializing secrets for ${NUM_NODES} nodes..."
    mkdir -p secrets

    for i in $(seq 1 "$NUM_NODES"); do
        if [[ -d "secrets/node-${i}" ]]; then
            echo "  node-${i}: secrets exist, skipping"
            continue
        fi

        echo "  node-${i}: generating secrets..."
        mkdir -p "secrets/node-${i}"
        gnoland_run \
            -v "${PROJECT_ROOT}/secrets/node-${i}:/gnoland-data" \
            "$GNOLAND_IMAGE" \
            secrets init --data-dir /gnoland-data

        echo "  node-${i}: extracting node ID..."
        local node_id
        node_id=$(gnoland_run \
            -v "${PROJECT_ROOT}/secrets/node-${i}:/gnoland-data" \
            "$GNOLAND_IMAGE" \
            secrets get node_id.id -raw --data-dir /gnoland-data 2>/dev/null)
        echo "$node_id" > "secrets/node-${i}/node_id"
    done

    echo ""
    echo "==> Node information:"
    printf "  %-12s %-44s %-96s %s\n" "Moniker" "Address" "PubKey" "Node ID"
    printf "  %-12s %-44s %-96s %s\n" "-------" "-------" "------" "-------"
    for i in $(seq 1 "$NUM_NODES"); do
        get_node_info "$i"
        printf "  %-12s %-44s %-96s %s\n" "node-${i}" "$_addr" "$_pubkey" "$_node_id"
    done
    echo ""
    echo "==> Provide your genesis.json, then run 'make start'"
}

# ---- Start

cmd_start() {
    local run_arg="${1:-}"

    # Resume a specific run by name
    if [[ -n "$run_arg" ]]; then
        local run_dir="${PROJECT_ROOT}/runs/${run_arg}"
        if [[ ! -d "$run_dir" ]]; then
            echo "Error: runs/${run_arg} not found."
            exit 1
        fi
        # Align preflight with the run's actual topology/N
        if [[ -f "${run_dir}/cluster.env" ]]; then
            # shellcheck disable=SC1091
            source "${run_dir}/cluster.env"
        fi
        if [[ -L "$CURRENT_LINK" ]]; then
            local current
            current=$(readlink "$CURRENT_LINK")
            if is_running "${current}/docker-compose.yml"; then
                echo "==> Stopping current run $(basename "$current") first..."
                docker compose -f "${current}/docker-compose.yml" down
            fi
        fi
        check_network_capacity "$TOPOLOGY" "$NUM_NODES"
        echo "==> Resuming run: ${run_arg}"
        ln -sfn "$run_dir" "$CURRENT_LINK"
        docker compose -f "${CURRENT_LINK}/docker-compose.yml" up -d
        echo "==> Run resumed."
        return
    fi

    # Check prerequisites
    if [[ ! -f cluster.env ]]; then
        echo "Error: cluster.env not found."
        echo "  Copy cluster.env.example to cluster.env and adjust settings."
        exit 1
    fi
    if [[ ! -f genesis.json ]]; then
        echo "Error: genesis.json not found."
        echo "  Run 'make init' to generate secrets, then provide genesis.json."
        exit 1
    fi
    if [[ ! -d secrets ]]; then
        echo "Error: secrets/ not found. Run 'make init' first."
        exit 1
    fi
    validate_port_ranges "$GNOLAND_RPC_PORT_BASE" "$GNOLAND_P2P_PORT_BASE" "$NUM_NODES"

    # Resume current run if it exists
    if [[ -L "$CURRENT_LINK" ]]; then
        local current
        current=$(readlink "$CURRENT_LINK")
        if is_running "${current}/docker-compose.yml"; then
            echo "Cluster is already running ($(basename "$current"))."
            echo "  Run 'make stop' first, or 'make start run=<folder>' to switch."
            return
        fi
        # Align preflight with the run's actual topology/N
        if [[ -f "${current}/cluster.env" ]]; then
            # shellcheck disable=SC1091
            source "${current}/cluster.env"
        fi
        check_network_capacity "$TOPOLOGY" "$NUM_NODES"
        echo "==> Resuming stopped run: $(basename "$current")"
        docker compose -f "${current}/docker-compose.yml" up -d
        echo "==> Run resumed."
        return
    fi

    # Create fresh run
    check_network_capacity "$TOPOLOGY" "$NUM_NODES"
    bash "${SCRIPT_DIR}/create-run.sh" \
        "$PROJECT_ROOT" "$GNO_REPO" "$GNO_VERSION" \
        "$NUM_NODES" "$TOPOLOGY" \
        "$GNOLAND_RPC_PORT_BASE" "$GNOLAND_P2P_PORT_BASE" "$GRAFANA_PORT"
}

# ---- Stop

cmd_stop() {
    local current
    current=$(require_current_run)
    echo "==> Stopping run: $(basename "$current")"
    docker compose -f "${current}/docker-compose.yml" down
    echo "==> Stopped. Data preserved in $(basename "$current")/"
}

# ---- Clone

cmd_clone() {
    local run_arg="${1:-}"
    local source_dir

    if [[ -n "$run_arg" ]]; then
        source_dir="${PROJECT_ROOT}/runs/${run_arg}"
    elif [[ -L "$CURRENT_LINK" ]]; then
        source_dir=$(readlink "$CURRENT_LINK")
    else
        echo "Error: no active run to clone."
        exit 1
    fi

    if [[ ! -d "$source_dir" ]]; then
        echo "Error: source run not found."
        exit 1
    fi

    # Stop source if running
    if is_running "${source_dir}/docker-compose.yml"; then
        echo "==> Stopping source run first..."
        docker compose -f "${source_dir}/docker-compose.yml" down
    fi

    echo "==> Cloning from: $(basename "$source_dir")"

    # Read metadata from source env (in a subshell to avoid polluting our env)
    local repo_slug version nodes timestamp new_name new_dir
    eval "$(
        source "${SCRIPT_DIR}/parse-genesis.sh"
        . "${source_dir}/cluster.env" 2>/dev/null || true
        eval "$(parse_genesis "${source_dir}/genesis.json")"
        echo "repo_slug=$(echo "${GNO_REPO}" | tr '/' '-')"
        echo "version=${GNO_VERSION}"
        echo "nodes=${NUM_NODES}"
        echo "validators_count=${validators_count}"
        echo "balances_count=${balances_count}"
        echo "txs_count=${txs_count}"
    )"
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    new_name="${timestamp}_${repo_slug}_${version}_${nodes}-nodes_${validators_count}-vals_${balances_count}-bals_${txs_count}-txs"
    new_dir="${PROJECT_ROOT}/runs/${new_name}"

    echo "  Creating: ${new_name}"
    mkdir -p "$new_dir"

    # Copy configs
    echo "  Copying configs..."
    for f in genesis.json cluster.env config.overrides docker-compose.yml watchtower.toml loki-config.yml; do
        if [[ -f "${source_dir}/${f}" ]]; then cp "${source_dir}/${f}" "${new_dir}/${f}"; fi
    done
    cp "${source_dir}"/sentinel-*-config.toml "${new_dir}/" 2>/dev/null || true
    if [[ -d "${source_dir}/grafana-provisioning" ]]; then
        cp -r "${source_dir}/grafana-provisioning" "${new_dir}/grafana-provisioning"
    fi

    # Copy secrets, reset chain state
    echo "  Copying secrets, resetting chain state..."
    for i in $(seq 1 "$nodes"); do
        mkdir -p "${new_dir}/gnoland-data-${i}/secrets"
        cp "${source_dir}/gnoland-data-${i}/secrets/priv_validator_key.json" "${new_dir}/gnoland-data-${i}/secrets/"
        cp "${source_dir}/gnoland-data-${i}/secrets/node_key.json" "${new_dir}/gnoland-data-${i}/secrets/"
        printf '{\n  "height": "0",\n  "round": "0",\n  "step": 0\n}\n' \
            > "${new_dir}/gnoland-data-${i}/secrets/priv_validator_state.json"
    done
    mkdir -p "${new_dir}/victoria-data" "${new_dir}/loki-data" "${new_dir}/grafana-data"

    ln -sfn "$new_dir" "$CURRENT_LINK"
    echo "==> Cloned. Run 'make start' to start."
}

# ---- Status

# Renders the status table once. In watch mode, appends \033[K (clear to EOL)
# to each line so shorter values don't leave stale characters.
render_status() {
    local nodes="$1" rpc_base="$2" eol="${3:-}"
    printf "%-10s %-12s %-8s %-24s %s${eol}\n" "Node" "Status" "Height" "Latest Block" "Peers"
    printf "%-10s %-12s %-8s %-24s %s${eol}\n" "----" "------" "------" "------------" "-----"

    for i in $(seq 1 "$nodes"); do
        local port=$((rpc_base + i - 1))
        local result
        result=$(http_get "http://localhost:${port}/status") || true

        if [[ -z "$result" ]]; then
            printf "%-10s %-12s %-8s %-24s %s${eol}\n" "node-${i}" "unreachable" "-" "-" "-"
        else
            local height block_time num_peers net_info
            height=$(echo "$result" | json_val "latest_block_height")
            block_time=$(echo "$result" | json_val "latest_block_time" | cut -c1-19)
            net_info=$(http_get "http://localhost:${port}/net_info") || true
            num_peers=$(echo "$net_info" | json_val "n_peers")
            printf "%-10s %-12s %-8s %-24s %s${eol}\n" "node-${i}" "running" "${height:-?}" "${block_time:-?}" "${num_peers:-?}"
        fi
    done
}

cmd_status() {
    if [[ ! -L "$CURRENT_LINK" ]]; then
        echo "No active run."
        return
    fi

    local current
    current=$(readlink "$CURRENT_LINK")
    # shellcheck disable=SC1091
    . "${current}/cluster.env" 2>/dev/null || true

    local nodes="${NUM_NODES}" rpc_base="${GNOLAND_RPC_PORT_BASE}"
    local watch_interval="${1:-}"

    if [[ -n "$watch_interval" ]]; then
        local eol=$'\033[K'
        printf '\033[?25l'
        trap 'printf "\033[?25h\n"' EXIT INT TERM
        printf '\033[2J'

        while true; do
            printf '\033[H'
            printf "Refreshing every %ss (Ctrl+C to stop)${eol}\n\n" "$watch_interval"
            render_status "$nodes" "$rpc_base" "$eol"
            sleep "$watch_interval"
        done
    else
        render_status "$nodes" "$rpc_base"
    fi
}

# ---- Logs

cmd_logs() {
    local svc="${1:-}"
    if [[ -z "$svc" ]]; then
        echo "Usage: make logs svc=<service>"
        echo "  Services: node-1..node-N, sentinel-1..sentinel-N, watchtower, victoria-metrics, loki, grafana"
        exit 1
    fi
    local current
    current=$(require_current_run)
    docker compose -f "${current}/docker-compose.yml" logs -f "$svc"
}

# ---- Infos

cmd_infos() {
    if [[ ! -d secrets ]]; then
        echo "Error: secrets/ not found. Run 'make init' first."
        exit 1
    fi

    echo "==> Node information (${NUM_NODES} nodes, ${TOPOLOGY} topology):"
    echo ""
    printf "  %-12s %-44s %-96s %-26s %-8s %s\n" \
        "Moniker" "Address" "PubKey" "RPC" "P2P" "Node ID"
    printf "  %-12s %-44s %-96s %-26s %-8s %s\n" \
        "-------" "-------" "------" "---" "---" "-------"

    for i in $(seq 1 "$NUM_NODES"); do
        get_node_info "$i"
        local rpc_port=$((GNOLAND_RPC_PORT_BASE + i - 1))
        local p2p_port=$((GNOLAND_P2P_PORT_BASE + i - 1))
        printf "  %-12s %-44s %-96s http://localhost:%-8s %-8s %s\n" \
            "node-${i}" "$_addr" "$_pubkey" "$rpc_port" "$p2p_port" "$_node_id"
    done
}

# ---- Update

cmd_update() {
    local current
    current=$(require_current_run)
    echo "==> Restarting run: $(basename "$current")"
    docker compose -f "${current}/docker-compose.yml" up -d --force-recreate
    echo "==> Updated and restarted."
}

# ---- Dispatch

command="${1:?Usage: cluster.sh <command> (build|init|start|stop|clone|status|logs|infos|update)}"
shift || true

case "$command" in
    build)   cmd_build ;;
    init)    cmd_init ;;
    start)   cmd_start "$@" ;;
    stop)    cmd_stop ;;
    clone)   cmd_clone "$@" ;;
    status)  cmd_status "$@" ;;
    logs)    cmd_logs "$@" ;;
    infos)   cmd_infos ;;
    update)  cmd_update ;;
    *)
        echo "Unknown command: ${command}"
        echo "Run 'make help' for usage."
        exit 1
        ;;
esac
