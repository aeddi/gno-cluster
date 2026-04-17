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

# shellcheck source=image-tags.sh
source "${SCRIPT_DIR}/image-tags.sh"
# shellcheck source=build-state.sh
source "${SCRIPT_DIR}/build-state.sh"
# shellcheck source=preflight.sh
source "${SCRIPT_DIR}/preflight.sh"
# shellcheck source=parse-genesis.sh
source "${SCRIPT_DIR}/parse-genesis.sh"

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

# Builds one image target, or skips if a matching content-addressed tag already
# exists. Always re-points :latest to the current tag so compose references
# (which use :latest) pick up the freshest image.
# Args: target tag force build_args...
_build_image() {
    local target="$1" tag="$2" force="$3"
    shift 3
    local image="gno-cluster-${target}:${tag}"
    if [[ -z "$force" ]] && docker image inspect "$image" >/dev/null 2>&1; then
        echo "==> ${target}: up to date (${tag})"
        docker tag "$image" "gno-cluster-${target}:latest"
        echo ""
        return
    fi
    echo "==> Building ${target} image (${tag})..."
    docker build -f internal/Dockerfile \
        --target "$target" \
        "$@" \
        -t "$image" \
        -t "gno-cluster-${target}:latest" \
        .
    echo ""
}

# Resolves GNO_COMMIT and WATCHTOWER_COMMIT from the current GNO_VERSION / WATCHTOWER_VERSION
# refs, unless they're already set in the env. Called by cmd_build, cmd_create, cmd_start;
# the second+ caller in one invocation pays no extra network cost.
resolve_commits() {
    if [[ -n "${GNO_COMMIT:-}" && -n "${WATCHTOWER_COMMIT:-}" ]]; then
        return
    fi
    echo "==> Resolving versions to commit hashes..."
    if [[ -z "${GNO_COMMIT:-}" ]]; then
        GNO_COMMIT=$(git ls-remote "https://github.com/${GNO_REPO}.git" "${GNO_VERSION}" | head -1 | cut -f1)
        if [[ -z "$GNO_COMMIT" ]]; then
            echo "Error: could not resolve GNO_VERSION='${GNO_VERSION}' from ${GNO_REPO}"
            exit 1
        fi
    fi
    if [[ -z "${WATCHTOWER_COMMIT:-}" ]]; then
        WATCHTOWER_COMMIT=$(git ls-remote "https://github.com/${WATCHTOWER_REPO}.git" "${WATCHTOWER_VERSION}" | head -1 | cut -f1)
        if [[ -z "$WATCHTOWER_COMMIT" ]]; then
            echo "Error: could not resolve WATCHTOWER_VERSION='${WATCHTOWER_VERSION}' from ${WATCHTOWER_REPO}"
            exit 1
        fi
    fi
    export GNO_COMMIT WATCHTOWER_COMMIT
}

cmd_build() {
    local force="${1:-}"
    resolve_commits

    local build_date
    build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local gnoland_tag watchtower_tag sentinel_tag
    gnoland_tag=$(compute_image_tag gnoland "$GNO_COMMIT" "$WATCHTOWER_COMMIT")
    watchtower_tag=$(compute_image_tag watchtower "$GNO_COMMIT" "$WATCHTOWER_COMMIT")
    sentinel_tag=$(compute_image_tag sentinel "$GNO_COMMIT" "$WATCHTOWER_COMMIT")

    echo "  gno:        ${GNO_REPO}@${GNO_VERSION} -> ${GNO_COMMIT:0:12}"
    echo "  watchtower: ${WATCHTOWER_REPO}@${WATCHTOWER_VERSION} -> ${WATCHTOWER_COMMIT:0:12}"
    echo ""

    _build_image gnoland "$gnoland_tag" "$force" \
        --build-arg "GNO_REPO=${GNO_REPO}" \
        --build-arg "GNO_COMMIT_HASH=${GNO_COMMIT}" \
        --build-arg "GNO_VERSION=${GNO_VERSION}" \
        --build-arg "BUILD_DATE=${build_date}"

    _build_image watchtower "$watchtower_tag" "$force" \
        --build-arg "WATCHTOWER_REPO=${WATCHTOWER_REPO}" \
        --build-arg "WATCHTOWER_COMMIT_HASH=${WATCHTOWER_COMMIT}" \
        --build-arg "WATCHTOWER_VERSION=${WATCHTOWER_VERSION}" \
        --build-arg "BUILD_DATE=${build_date}"

    _build_image sentinel "$sentinel_tag" "$force" \
        --build-arg "WATCHTOWER_REPO=${WATCHTOWER_REPO}" \
        --build-arg "WATCHTOWER_COMMIT_HASH=${WATCHTOWER_COMMIT}" \
        --build-arg "WATCHTOWER_VERSION=${WATCHTOWER_VERSION}" \
        --build-arg "BUILD_DATE=${build_date}"

    echo "==> Build complete."
}

# Ensures images are ready for starting a run. Reads run's .build-state (if any),
# compares against current env state, prompts on drift, then either rebuilds
# (updating .build-state) or re-tags the pinned images as :latest.
# Expects: GNO_COMMIT and WATCHTOWER_COMMIT already resolved in env.
# Args: run_dir [upgrade_flag]
ensure_images_for_run() {
    local run_dir="$1" upgrade="${2:-}"
    local state_file="${run_dir}/.build-state"

    # Load previous build state into PREV_* vars (empty if no prior state).
    local prev_output has_prev=0
    if prev_output=$(read_build_state_as_prev "$state_file"); then
        eval "$prev_output"
        has_prev=1
    fi

    local drift_summary="" has_drift=0
    if ((has_prev)); then
        set +e
        drift_summary=$(build_state_drift_summary)
        has_drift=$?
        set -e
    fi

    local action="rebuild"
    if ((has_drift)); then
        echo "==> Build state changed since last build (${PREV_BUILD_DATE})."
        echo ""
        echo "$drift_summary"
        echo ""
        echo "    To preserve this run and try the new build separately:"
        echo "      make clone     # new run from this one"
        echo "      make start     # starts the clone with the new build"
        echo ""
        if [[ -n "$upgrade" ]]; then
            action="rebuild"
            echo "    upgrade=1 → rebuilding with new state."
        elif [[ -t 0 ]]; then
            local ans
            read -r -p "    Rebuild this run with the new state? [r/K] " ans
            case "$ans" in
                r|R|rebuild|y|Y|yes) action="rebuild" ;;
                *) action="keep" ;;
            esac
        else
            action="keep"
            echo "    (non-TTY: keeping previously-built images. Set upgrade=1 to rebuild.)"
        fi
        echo ""
    fi

    if [[ "$action" == "keep" ]]; then
        echo "==> Keeping previously-built images from ${PREV_BUILD_DATE}."
        if ! docker image inspect "$PREV_GNOLAND_IMAGE" >/dev/null 2>&1; then
            echo "Error: previously-pinned image ${PREV_GNOLAND_IMAGE} is not present."
            echo "  It may have been removed via 'make clean-imgs' or 'docker image prune'."
            echo "  Options:"
            echo "    - 'make start upgrade=1' to rebuild with the current state"
            echo "    - 'make clone' first if you want to keep this run intact"
            exit 1
        fi
        docker tag "$PREV_GNOLAND_IMAGE"    gno-cluster-gnoland:latest
        docker tag "$PREV_WATCHTOWER_IMAGE" gno-cluster-watchtower:latest
        docker tag "$PREV_SENTINEL_IMAGE"   gno-cluster-sentinel:latest
        # Override the resolved commits with the pinned ones so any downstream
        # user of GNO_COMMIT sees what's actually running.
        export GNO_COMMIT="$PREV_GNO_COMMIT"
        export WATCHTOWER_COMMIT="$PREV_WATCHTOWER_COMMIT"
        echo ""
        return
    fi

    # Rebuild (or first build). cmd_build is idempotent so no-ops when tags exist.
    cmd_build
    write_build_state "$state_file"
}

# ---- Create

# Ensures secrets exist for nodes 1..NUM_NODES. Skips existing, creates missing.
_ensure_node_secrets() {
    echo "==> Ensuring secrets for ${NUM_NODES} nodes..."
    mkdir -p secrets

    local i node_id
    for i in $(seq 1 "$NUM_NODES"); do
        if [[ -d "secrets/node-${i}" ]]; then
            echo "  node-${i}: skipping, already exists"
            continue
        fi
        echo "  node-${i}: creating..."
        mkdir -p "secrets/node-${i}"
        gnoland_run \
            -v "${PROJECT_ROOT}/secrets/node-${i}:/gnoland-data" \
            "$GNOLAND_IMAGE" \
            secrets init --data-dir /gnoland-data
        node_id=$(gnoland_run \
            -v "${PROJECT_ROOT}/secrets/node-${i}:/gnoland-data" \
            "$GNOLAND_IMAGE" \
            secrets get node_id.id -raw --data-dir /gnoland-data 2>/dev/null)
        echo "$node_id" > "secrets/node-${i}/node_id"
    done
}

_print_node_info_table() {
    echo ""
    echo "==> Node information:"
    printf "  %-12s %-44s %-96s %s\n" "Moniker" "Address" "PubKey" "Node ID"
    printf "  %-12s %-44s %-96s %s\n" "-------" "-------" "------" "-------"
    local i
    for i in $(seq 1 "$NUM_NODES"); do
        get_node_info "$i"
        printf "  %-12s %-44s %-96s %s\n" "node-${i}" "$_addr" "$_pubkey" "$_node_id"
    done
}

# Prints the genesis summary: chain_id, time, sha256, balances/txs counts,
# and a validator-set breakdown (which validators belong to this cluster).
_print_genesis_info() {
    local genesis="$1"
    local info
    info=$(parse_genesis "$genesis")
    local chain_id genesis_time sha256 validators_count total_voting_power balances_count txs_count
    eval "$info"

    echo "==> Genesis: $(basename "$genesis")"
    echo "    chain_id:       ${chain_id}"
    echo "    genesis_time:   ${genesis_time}"
    echo "    sha256:         ${sha256}"
    echo "    balances:       ${balances_count}"
    echo "    txs:            ${txs_count}"

    # Collect our addresses (parallel arrays; works in bash 3.2).
    # Address is the stable identifier — pubkey formats differ between gnoland's
    # `secrets get -raw` (bech32 gpub...) and genesis.pub_key.value (base64).
    local our_addrs=() our_nodes=() i
    for i in $(seq 1 "$NUM_NODES"); do
        [[ -d "secrets/node-${i}" ]] || continue
        get_node_info "$i"
        our_addrs+=("$_addr")
        our_nodes+=("node-${i}")
    done

    local ours=() externals=() addr _pubkey power _name
    while IFS='|' read -r addr _pubkey power _name; do
        local match="" idx=0 our_addr
        for our_addr in "${our_addrs[@]:-}"; do
            if [[ "$our_addr" == "$addr" ]]; then
                match="${our_nodes[$idx]}"
                break
            fi
            idx=$((idx + 1))
        done
        if [[ -n "$match" ]]; then
            ours+=("${match}|${addr}|${power}")
        else
            externals+=("${addr}|${power}")
        fi
    done < <(parse_genesis_validators "$genesis")

    echo "    Validator set:  ${validators_count} validators (voting_power sum = ${total_voting_power})"
    if ((${#ours[@]} > 0)); then
        echo "      ${#ours[@]} from this cluster:"
        local v n a p
        for v in "${ours[@]}"; do
            IFS='|' read -r n a p <<< "$v"
            printf "        %-10s %s  pow=%s\n" "$n" "$a" "$p"
        done
    fi
    if ((${#externals[@]} > 0)); then
        echo "      ${#externals[@]} external:"
        local v a p
        for v in "${externals[@]}"; do
            IFS='|' read -r a p <<< "$v"
            printf "        %-10s %s  pow=%s\n" "" "$a" "$p"
        done
    fi
}

cmd_create() {
    local yes="${1:-}"

    if [[ ! -f cluster.env ]]; then
        echo "Error: cluster.env not found."
        echo "  Copy cluster.env.example to cluster.env and adjust settings."
        exit 1
    fi
    validate_port_ranges "$GNOLAND_RPC_PORT_BASE" "$GNOLAND_P2P_PORT_BASE" "$NUM_NODES"

    if [[ -L "$CURRENT_LINK" ]]; then
        local current
        current=$(readlink "$CURRENT_LINK")
        if is_running "${current}/docker-compose.yml"; then
            echo "Error: a cluster is currently running ($(basename "$current"))."
            echo "  Run 'make stop' first."
            exit 1
        fi
    fi

    local interactive=1
    if [[ -n "$yes" || ! -t 0 ]]; then
        interactive=0
    fi

    # Resolve refs to commits and ensure images exist (idempotent). This pins the
    # run to the exact commits we built against, which goes into .build-state.
    resolve_commits
    cmd_build
    echo ""

    _ensure_node_secrets
    _print_node_info_table

    local genesis="${PROJECT_ROOT}/genesis.json"
    while true; do
        if [[ ! -f "$genesis" ]]; then
            if ((interactive == 0)); then
                echo "Error: genesis.json not found at ${genesis}." >&2
                echo "  Non-interactive mode requires a pre-existing genesis.json." >&2
                echo "  Provide it or re-run from a TTY without yes=1 to be prompted." >&2
                exit 1
            fi
            echo ""
            echo "No genesis.json found. Copy your genesis.json to ${genesis}, then press Enter."
            read -r _
            continue
        fi

        echo ""
        _print_genesis_info "$genesis"

        if ((interactive == 0)); then
            break
        fi

        echo ""
        local ans
        read -r -p "Proceed with this genesis? [Y/n/r(eplace)] " ans
        case "$ans" in
            ""|y|Y|yes)
                break
                ;;
            n|N|no)
                echo "Aborted."
                return
                ;;
            r|R|replace)
                echo "Copy your new genesis.json to ${genesis}, then press Enter."
                read -r _
                continue
                ;;
            *)
                echo "Please answer y, n, or r."
                ;;
        esac
    done

    echo ""
    bash "${SCRIPT_DIR}/create-run.sh" \
        "$PROJECT_ROOT" "$GNO_REPO" "$GNO_VERSION" \
        "$NUM_NODES" "$TOPOLOGY" \
        "$GNOLAND_RPC_PORT_BASE" "$GNOLAND_P2P_PORT_BASE" "$GRAFANA_PORT"

    # Pin this run's build state so future make start invocations can detect drift.
    local new_run
    new_run=$(readlink "$CURRENT_LINK")
    write_build_state "${new_run}/.build-state"

    echo ""
    echo "==> Run created. Run 'make start' to start the cluster."
}

# ---- Start

cmd_start() {
    local run_arg="${1:-}"
    local upgrade="${upgrade:-}"

    # Resume a specific run by name
    if [[ -n "$run_arg" ]]; then
        local run_dir="${PROJECT_ROOT}/runs/${run_arg}"
        if [[ ! -d "$run_dir" ]]; then
            echo "Error: runs/${run_arg} not found."
            exit 1
        fi
        # Source the run's cluster.env so downstream steps use the run's own
        # topology, node count, and image versions (not the project-root ones).
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
        resolve_commits
        ensure_images_for_run "$run_dir" "$upgrade"
        check_network_capacity "$TOPOLOGY" "$NUM_NODES"
        echo "==> Resuming run: ${run_arg}"
        ln -sfn "$run_dir" "$CURRENT_LINK"
        docker compose -f "${CURRENT_LINK}/docker-compose.yml" up -d
        echo "==> Run resumed."
        return
    fi

    # Start the current run (must already exist)
    if [[ ! -L "$CURRENT_LINK" ]]; then
        echo "Error: no current run to start."
        echo "  Run 'make create' to create a new cluster,"
        echo "  or 'make start run=<folder>' to start a specific past run."
        exit 1
    fi
    local current
    current=$(readlink "$CURRENT_LINK")
    if is_running "${current}/docker-compose.yml"; then
        echo "Cluster is already running ($(basename "$current"))."
        echo "  Run 'make stop' first, or 'make start run=<folder>' to switch."
        return
    fi
    if [[ -f "${current}/cluster.env" ]]; then
        # shellcheck disable=SC1091
        source "${current}/cluster.env"
    fi
    resolve_commits
    ensure_images_for_run "$current" "$upgrade"
    check_network_capacity "$TOPOLOGY" "$NUM_NODES"
    echo "==> Starting run: $(basename "$current")"
    docker compose -f "${current}/docker-compose.yml" up -d
    echo "==> Run started."
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

# ---- Clean

cmd_clean_imgs() {
    local images
    images=$(docker images --filter "reference=gno-cluster-*" -q 2>/dev/null | sort -u)
    if [[ -z "$images" ]]; then
        echo "==> No gno-cluster images to remove."
        return
    fi
    local count
    count=$(echo "$images" | grep -c . || true)
    echo "==> Removing ${count} gno-cluster image(s)..."
    echo "$images" | xargs docker rmi -f >/dev/null
    echo "==> Done."
}

cmd_clean_runs() {
    local yes="${1:-}"

    local runs=()
    if [[ -d runs ]]; then
        local entry
        for entry in runs/*; do
            [[ -d "$entry" && ! -L "$entry" ]] && runs+=("$entry")
        done
    fi

    local count=${#runs[@]}
    if ((count == 0)); then
        echo "==> No runs to remove."
        return
    fi

    if [[ -z "$yes" ]]; then
        if [[ ! -t 0 ]]; then
            echo "Error: clean-runs requires yes=1 in non-interactive mode (${count} run folder(s) would be removed)." >&2
            return 1
        fi
        echo "About to remove ${count} run folder(s):"
        local r
        for r in "${runs[@]}"; do echo "  $r"; done
        local ans
        read -r -p "Proceed? [y/N] " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Aborted."
            return
        fi
    fi

    if [[ -L "$CURRENT_LINK" ]]; then
        local current
        current=$(readlink "$CURRENT_LINK")
        if is_running "${current}/docker-compose.yml"; then
            echo "==> Stopping current run..."
            docker compose -f "${current}/docker-compose.yml" down
        fi
    fi

    echo "==> Removing ${count} run folder(s)..."
    rm -f "$CURRENT_LINK"
    local r
    for r in "${runs[@]}"; do
        rm -rf "$r"
        echo "    removed $r"
    done
    echo "==> Done."
}

cmd_clean() {
    local yes="${1:-}"
    cmd_clean_runs "$yes"
    cmd_clean_imgs
}

# ---- Dispatch

command="${1:?Usage: cluster.sh <command> (build|create|start|stop|clone|status|logs|infos|update|clean|clean-runs|clean-imgs)}"
shift || true

case "$command" in
    build)        cmd_build "$@" ;;
    create)       cmd_create "$@" ;;
    start)        cmd_start "$@" ;;
    stop)         cmd_stop ;;
    clone)        cmd_clone "$@" ;;
    status)       cmd_status "$@" ;;
    logs)         cmd_logs "$@" ;;
    infos)        cmd_infos ;;
    update)       cmd_update ;;
    clean)        cmd_clean "$@" ;;
    clean-runs)   cmd_clean_runs "$@" ;;
    clean-imgs) cmd_clean_imgs ;;
    *)
        echo "Unknown command: ${command}"
        echo "Run 'make help' for usage."
        exit 1
        ;;
esac
