#!/usr/bin/env bash
# internal/scripts/cluster.sh — Main entry point for gno-cluster operations.
#
# Usage: cluster.sh <command> [args]
# Commands: build, create, list, start, stop, restart, clone, status, logs,
#           infos, update, clean, clean-runs, clean-imgs
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

# Silent resolution: echoes the current run dir on success, returns non-zero
# when runs/current is missing or dangling. Use this when the caller has a
# fallback behavior (e.g. skip a conditional stop-if-running step).
resolve_current_run() {
    [[ -L "$CURRENT_LINK" ]] || return 1
    local d
    d=$(readlink "$CURRENT_LINK")
    [[ -d "$d" ]] || return 1
    echo "$d"
}

# Strict resolution: prints an actionable error on failure and returns non-zero.
# Uses `return` (not `exit`) so callers can collect via
#   current=$(require_current_run) || exit 1
# (exit from a subshell does not propagate to the parent).
require_current_run() {
    local d
    if d=$(resolve_current_run); then
        echo "$d"
        return 0
    fi
    if [[ -L "$CURRENT_LINK" ]]; then
        echo "Error: runs/current points to a missing folder: '$(readlink "$CURRENT_LINK")'." >&2
        echo "  Remove the dangling symlink: rm runs/current" >&2
    else
        echo "Error: no active run (runs/current does not exist)." >&2
        echo "  Run 'make create' to create one, or 'make start run=<folder>' to resume a past run." >&2
    fi
    return 1
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

# Ensures images are ready for starting a run.
#
# Reads the run's .build-state, compares it against current env state, prints a
# drift summary (with a suggestion to run `make clone` and/or `make update`) if
# anything differs, then re-tags the pinned images as :latest so compose picks
# them up. Never rebuilds — drift resolution belongs to `make update`.
#
# Backward compat: if .build-state is missing (legacy runs), cmd_build is
# invoked to ensure images exist for the current env, then the state is written.
# Expects: GNO_COMMIT and WATCHTOWER_COMMIT already resolved in env.
ensure_images_for_run() {
    local run_dir="$1"
    local state_file="${run_dir}/.build-state"

    if [[ ! -f "$state_file" ]]; then
        echo "==> No pinned build state for this run — building and pinning now."
        cmd_build
        write_build_state "$state_file"
        return
    fi

    local prev_output
    prev_output=$(read_build_state_as_prev "$state_file")
    eval "$prev_output"

    local drift_summary="" has_drift=0
    set +e
    drift_summary=$(build_state_drift_summary)
    has_drift=$?
    set -e

    if ((has_drift)); then
        echo "==> Build state drifted since last build (${PREV_BUILD_DATE})."
        echo ""
        echo "$drift_summary"
        echo ""
        echo "    This run will start with its pinned images. To act on the drift:"
        echo "      make clone     # fork this run, then 'make update' the clone"
        echo "      make update    # rebuild and restart this run in place"
        echo ""
    fi

    if ! docker image inspect "$PREV_GNOLAND_IMAGE" >/dev/null 2>&1; then
        echo "Error: pinned image ${PREV_GNOLAND_IMAGE} is not present."
        echo "  It may have been removed via 'make clean-imgs' or 'docker image prune'."
        echo "  Run 'make update' to rebuild this run's images."
        exit 1
    fi
    docker tag "$PREV_GNOLAND_IMAGE"    gno-cluster-gnoland:latest
    docker tag "$PREV_WATCHTOWER_IMAGE" gno-cluster-watchtower:latest
    docker tag "$PREV_SENTINEL_IMAGE"   gno-cluster-sentinel:latest
    # Override the resolved commits with the pinned ones so any downstream
    # user of GNO_COMMIT sees what's actually running.
    export GNO_COMMIT="$PREV_GNO_COMMIT"
    export WATCHTOWER_COMMIT="$PREV_WATCHTOWER_COMMIT"
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

    # If a cluster is currently running, prepare the new run without flipping
    # runs/current away from it — observability tools (status/infos/list) stay
    # correct, and the user can explicitly switch with `make start run=<name>`
    # once they stop the running cluster.
    local preserve_current=""
    local current
    if current=$(resolve_current_run) && is_running "${current}/docker-compose.yml"; then
        preserve_current="$current"
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
    new_run=$(require_current_run) || exit 1
    write_build_state "${new_run}/.build-state"

    echo ""
    if [[ -n "$preserve_current" ]]; then
        # Restore runs/current to the still-running cluster — the new run is
        # prepared but not adopted.
        ln -sfn "$preserve_current" "$CURRENT_LINK"
        echo "==> Run created at runs/$(basename "$new_run")"
        echo "    A cluster is still running on $(basename "$preserve_current"); runs/current stays pointed at it."
        echo "    To switch to the new run:"
        echo "      make stop"
        echo "      make start run=$(basename "$new_run")"
    else
        echo "==> Run created. Run 'make start' to start the cluster."
    fi
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
        # Source the run's cluster.env so downstream steps use the run's own
        # topology, node count, and image versions (not the project-root ones).
        if [[ -f "${run_dir}/cluster.env" ]]; then
            # shellcheck disable=SC1091
            source "${run_dir}/cluster.env"
        fi
        local current
        if current=$(resolve_current_run) && is_running "${current}/docker-compose.yml"; then
            echo "==> Stopping current run $(basename "$current") first..."
            docker compose -f "${current}/docker-compose.yml" down
        fi
        resolve_commits
        ensure_images_for_run "$run_dir"
        check_network_capacity "$TOPOLOGY" "$NUM_NODES"
        echo "==> Resuming run: ${run_arg}"
        ln -sfn "$run_dir" "$CURRENT_LINK"
        docker compose -f "${CURRENT_LINK}/docker-compose.yml" up -d
        echo "==> Run resumed."
        return
    fi

    # Start the current run (must already exist)
    local current
    current=$(require_current_run) || exit 1
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
    ensure_images_for_run "$current"
    check_network_capacity "$TOPOLOGY" "$NUM_NODES"
    echo "==> Starting run: $(basename "$current")"
    docker compose -f "${current}/docker-compose.yml" up -d
    echo "==> Run started."
}

# ---- Stop

cmd_stop() {
    local current
    current=$(require_current_run) || exit 1
    echo "==> Stopping run: $(basename "$current")"
    docker compose -f "${current}/docker-compose.yml" down
    echo "==> Stopped. Data preserved in $(basename "$current")/"
}

# ---- Restart

cmd_restart() {
    local run_arg="${1:-}"
    # Stop the current run if it's running. If run= is given, cmd_start handles
    # switching to that folder; if not given, cmd_start resumes current.
    local current
    if current=$(resolve_current_run) && is_running "${current}/docker-compose.yml"; then
        echo "==> Stopping run: $(basename "$current")"
        docker compose -f "${current}/docker-compose.yml" down
        echo ""
    fi
    cmd_start "$run_arg"
}

# ---- Clone

cmd_clone() {
    local run_arg="${1:-}"
    local source_dir

    if [[ -n "$run_arg" ]]; then
        source_dir="${PROJECT_ROOT}/runs/${run_arg}"
        if [[ ! -d "$source_dir" ]]; then
            echo "Error: runs/${run_arg} not found." >&2
            exit 1
        fi
    else
        source_dir=$(require_current_run) || exit 1
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
    for f in genesis.json cluster.env config.overrides docker-compose.yml watchtower.toml loki-config.yml .build-state; do
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
    local nodes="$1" rpc_base="$2" run_name="$3" eol="${4:-}"
    printf "Run: %s${eol}\n" "$run_name"
    printf "${eol}\n"
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
            height=$(echo "$result" | jq -r '.result.sync_info.latest_block_height // "-"' 2>/dev/null || echo "-")
            block_time=$(echo "$result" | jq -r '.result.sync_info.latest_block_time // "-"' 2>/dev/null | cut -c1-19)
            net_info=$(http_get "http://localhost:${port}/net_info") || true
            num_peers=$(echo "$net_info" | jq -r '.result.n_peers // "-"' 2>/dev/null || echo "-")
            printf "%-10s %-12s %-8s %-24s %s${eol}\n" "node-${i}" "running" "${height:-?}" "${block_time:-?}" "${num_peers:-?}"
        fi
    done
}

cmd_status() {
    local current
    if ! current=$(resolve_current_run); then
        echo "No active run."
        return
    fi
    # shellcheck disable=SC1091
    . "${current}/cluster.env" 2>/dev/null || true

    local nodes="${NUM_NODES}" rpc_base="${GNOLAND_RPC_PORT_BASE}"
    local run_name
    run_name=$(basename "$current")
    local watch_interval="${1:-}"

    # Non-mandatory info — warn once if jq is missing; height/block/peers will
    # render as "-" but node reachability is still reported.
    if ! command -v jq >/dev/null 2>&1; then
        echo "Warning: jq not installed; height/block/peers will be unavailable." >&2
        echo "" >&2
    fi

    if [[ -n "$watch_interval" ]]; then
        local eol=$'\033[K'
        printf '\033[?25l'
        trap 'printf "\033[?25h\n"' EXIT INT TERM
        printf '\033[2J'

        while true; do
            printf '\033[H'
            printf "Refreshing every %ss (Ctrl+C to stop)${eol}\n\n" "$watch_interval"
            render_status "$nodes" "$rpc_base" "$run_name" "$eol"
            sleep "$watch_interval"
        done
    else
        render_status "$nodes" "$rpc_base" "$run_name"
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

# ANSI color wrapper; outputs plain text when stdout isn't a TTY so piped output
# stays clean.
_color() {
    local code="$1" text="$2"
    if [[ -t 1 ]]; then
        printf '\033[%sm%s\033[0m' "$code" "$text"
    else
        printf '%s' "$text"
    fi
}

# Parses the "YYYY-MM-DD_HH-MM-SS" prefix of a run folder name into a readable
# timestamp. Folder-name-based so it doesn't depend on filesystem mtime.
_run_creation_date() {
    local name="$1"
    if [[ "$name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
    else
        echo "unknown"
    fi
}

# Human-readable directory size, or "-" if missing.
_dir_size() {
    local d="$1"
    if [[ -d "$d" ]]; then
        du -sh "$d" 2>/dev/null | awk '{print $1}'
    else
        echo "-"
    fi
}

# Reads the height from priv_validator_state.json, or "-" if unavailable.
_last_block_height() {
    local f="$1"
    [[ -f "$f" ]] || { echo "-"; return; }
    jq -r '.height // "-"' "$f" 2>/dev/null || echo "-"
}

# Total size of all per-node gnoland data directories under a run, or "-" when
# the run has no data dirs yet.
_gnoland_data_size() {
    local run_dir="$1"
    local dirs=("${run_dir}"/gnoland-data-*)
    [[ -d "${dirs[0]}" ]] || { echo "-"; return; }
    du -sch "${dirs[@]}" 2>/dev/null | tail -1 | awk '{print $1}'
}

# Reads a single KEY from a run's cluster.env without sourcing the whole file
# (so we don't clobber the caller's env). Prints "-" if the key isn't set.
_run_env_get() {
    local run_dir="$1" key="$2" value
    value=$(grep -E "^${key}=" "${run_dir}/cluster.env" 2>/dev/null | head -1 | cut -d= -f2-)
    echo "${value:--}"
}

_infos_header() {
    local run_dir="$1"
    local name date_str state height loki_sz vm_sz
    name=$(basename "$run_dir")
    date_str=$(_run_creation_date "$name")
    # Only the current run can be running (all runs share the same compose
    # project name; is_running on a non-current run's compose file would give
    # a false positive when another run's containers are up).
    local current_dir=""
    current_dir=$(resolve_current_run 2>/dev/null || true)
    if [[ "$run_dir" == "$current_dir" ]] && is_running "${run_dir}/docker-compose.yml"; then
        state=$(_color 32 "running")
    else
        state=$(_color 31 "stopped")
    fi
    height=$(_last_block_height "${run_dir}/gnoland-data-1/secrets/priv_validator_state.json")
    loki_sz=$(_dir_size "${run_dir}/loki-data")
    vm_sz=$(_dir_size "${run_dir}/victoria-data")

    echo "==> Run: ${name}"
    printf "    Created:          %s\n" "$date_str"
    printf "    State:            %b\n" "$state"
    printf "    Height (node-1):  %s\n" "$height"
    printf "    Loki data:        %s\n" "$loki_sz"
    printf "    VictoriaMetrics:  %s\n" "$vm_sz"
}

_infos_cluster_config() {
    local run_dir="$1"
    # Pull resolved commits from the run's .build-state if present.
    local PREV_BUILD_DATE="" PREV_GNO_REPO="" PREV_GNO_VERSION="" PREV_GNO_COMMIT="" \
          PREV_GNOLAND_IMAGE="" PREV_WATCHTOWER_REPO="" PREV_WATCHTOWER_VERSION="" \
          PREV_WATCHTOWER_COMMIT="" PREV_WATCHTOWER_IMAGE="" PREV_SENTINEL_IMAGE="" \
          PREV_CONTENT_HASH=""
    local PREV_CONTENT_FILES=()
    local prev_output
    if prev_output=$(read_build_state_as_prev "${run_dir}/.build-state" 2>/dev/null); then
        eval "$prev_output"
    fi

    local gno_commit_str wt_commit_str
    gno_commit_str="${PREV_GNO_COMMIT:-<not yet built>}"
    [[ -n "${PREV_GNO_COMMIT:-}" ]] && gno_commit_str="${PREV_GNO_COMMIT:0:12}"
    wt_commit_str="${PREV_WATCHTOWER_COMMIT:-<not yet built>}"
    [[ -n "${PREV_WATCHTOWER_COMMIT:-}" ]] && wt_commit_str="${PREV_WATCHTOWER_COMMIT:0:12}"

    echo "==> Cluster config"
    printf "    Nodes:       %s\n" "$NUM_NODES"
    printf "    Topology:    %s\n" "$TOPOLOGY"
    printf "    Gno:         %s@%s (%s)\n" "$GNO_REPO" "$GNO_VERSION" "$gno_commit_str"
    printf "    Watchtower:  %s@%s (%s)\n" "$WATCHTOWER_REPO" "$WATCHTOWER_VERSION" "$wt_commit_str"
}

_infos_genesis() {
    local run_dir="$1"
    local genesis="${run_dir}/genesis.json"
    echo "==> Genesis"
    if [[ ! -f "$genesis" ]]; then
        printf "    (missing)\n"
        return
    fi
    local info chain_id genesis_time sha256 validators_count total_voting_power balances_count txs_count
    info=$(parse_genesis "$genesis")
    eval "$info"
    printf "    sha256:      %s\n" "$sha256"
    printf "    time:        %s\n" "$genesis_time"
    printf "    validators:  %s\n" "$validators_count"
    printf "    balances:    %s\n" "$balances_count"
    printf "    txs:         %s\n" "$txs_count"
}

_infos_node_identities() {
    local run_dir="$1"
    local genesis="${run_dir}/genesis.json"
    local valset_addrs=""
    if [[ -f "$genesis" ]]; then
        valset_addrs=$(parse_genesis_validators "$genesis" | cut -d'|' -f1)
    fi

    echo "==> Node identities"
    printf "    %-8s  %-44s  %-96s  %s\n" "Moniker" "Address" "PubKey" "In valset"
    printf "    %-8s  %-44s  %-96s  %s\n" "-------" "-------" "------" "---------"
    local i in_valset
    for i in $(seq 1 "$NUM_NODES"); do
        get_node_info "$i"
        if [[ -n "$valset_addrs" ]] && grep -qFx "$_addr" <<< "$valset_addrs"; then
            in_valset="yes"
        else
            in_valset="no"
        fi
        printf "    %-8s  %-44s  %-96s  %s\n" \
            "node-${i}" "$_addr" "$_pubkey" "$in_valset"
    done
}

_infos_node_network() {
    echo "==> Node network (host-accessible; localhost ports are Docker port-forwards)"
    printf "    %-8s  %-70s  %s\n" "Moniker" "P2P" "RPC"
    printf "    %-8s  %-70s  %s\n" "-------" "---" "---"
    local i rpc_port p2p_port node_id
    for i in $(seq 1 "$NUM_NODES"); do
        rpc_port=$((GNOLAND_RPC_PORT_BASE + i - 1))
        p2p_port=$((GNOLAND_P2P_PORT_BASE + i - 1))
        node_id=$(cat "secrets/node-${i}/node_id" 2>/dev/null || echo "?")
        printf "    %-8s  %-70s  http://localhost:%s\n" \
            "node-${i}" "${node_id}@localhost:${p2p_port}" "$rpc_port"
    done
}

cmd_list() {
    if [[ ! -d runs ]]; then
        echo "No runs yet. Run 'make create' to create one."
        return
    fi

    # Collect run folders, excluding the 'current' symlink.
    local runs=() entry
    for entry in runs/*; do
        [[ -d "$entry" && ! -L "$entry" ]] && runs+=("$entry")
    done
    if ((${#runs[@]} == 0)); then
        echo "No runs yet. Run 'make create' to create one."
        return
    fi

    # Newest first: folder names start with an ISO timestamp.
    IFS=$'\n' read -r -d '' -a runs < <(printf '%s\n' "${runs[@]}" | sort -r && printf '\0')

    local current_name="" current_dir=""
    if current_dir=$(resolve_current_run 2>/dev/null); then
        current_name=$(basename "$current_dir")
    fi

    echo "==> Runs (${#runs[@]} total)"
    echo ""

    # Only one run can be "running" at a time — host ports collide and all runs
    # share the same compose project name. is_running compared across compose
    # files under the same project label can't distinguish run folders, so we
    # gate on the run being the current one.
    local current_running=0
    if [[ -n "$current_dir" ]] && is_running "${current_dir}/docker-compose.yml"; then
        current_running=1
    fi

    local run name state_label marker nodes topology height gno_sz loki_sz vm_sz total_sz
    for run in "${runs[@]}"; do
        name=$(basename "$run")
        if [[ "$name" == "$current_name" && "$current_running" == "1" ]]; then
            state_label=$(_color 32 "running")
        else
            state_label=$(_color 31 "stopped")
        fi
        if [[ "$name" == "$current_name" ]]; then
            marker=" $(_color 33 "(current)")"
        else
            marker=""
        fi
        nodes=$(_run_env_get "$run" NUM_NODES)
        topology=$(_run_env_get "$run" TOPOLOGY)
        height=$(_last_block_height "${run}/gnoland-data-1/secrets/priv_validator_state.json")
        gno_sz=$(_gnoland_data_size "$run")
        loki_sz=$(_dir_size "${run}/loki-data")
        vm_sz=$(_dir_size "${run}/victoria-data")
        total_sz=$(du -sh "$run" 2>/dev/null | awk '{print $1}')
        total_sz="${total_sz:--}"

        printf "%s%b\n" "$name" "$marker"
        printf "    State:    %b\n" "$state_label"
        printf "    Config:   %s nodes, %s topology\n" "$nodes" "$topology"
        printf "    Height:   %s  (node-1)\n" "$height"
        printf "    Sizes:    gnoland %s, loki %s, victoria %s  (run total %s)\n" \
            "$gno_sz" "$loki_sz" "$vm_sz" "$total_sz"
        echo ""
    done
}

cmd_infos() {
    local run_arg="${1:-}"
    local run_dir

    if [[ -n "$run_arg" ]]; then
        run_dir="${PROJECT_ROOT}/runs/${run_arg}"
        if [[ ! -d "$run_dir" ]]; then
            echo "Error: runs/${run_arg} not found."
            exit 1
        fi
    else
        run_dir=$(require_current_run) || exit 1
    fi

    if [[ -f "${run_dir}/cluster.env" ]]; then
        # shellcheck disable=SC1091
        source "${run_dir}/cluster.env"
    fi

    if [[ ! -d secrets ]]; then
        echo "Error: secrets/ not found. Run 'make create' first."
        exit 1
    fi

    _infos_header "$run_dir"
    echo ""
    _infos_cluster_config "$run_dir"
    echo ""
    _infos_genesis "$run_dir"
    echo ""
    _infos_node_identities "$run_dir"
    echo ""
    _infos_node_network
}

# ---- Update

# Rebuilds a run's images (and restarts it) only when its pinned build state
# drifts from the current env. If nothing has changed, it's a no-op. If a run
# arg is given, targets that run (switching current to it, like cmd_start).
cmd_update() {
    local run_arg="${1:-}"
    local run_dir

    if [[ -n "$run_arg" ]]; then
        run_dir="${PROJECT_ROOT}/runs/${run_arg}"
        if [[ ! -d "$run_dir" ]]; then
            echo "Error: runs/${run_arg} not found."
            exit 1
        fi
    else
        run_dir=$(require_current_run)
    fi

    if [[ -f "${run_dir}/cluster.env" ]]; then
        # shellcheck disable=SC1091
        source "${run_dir}/cluster.env"
    fi

    local state_file="${run_dir}/.build-state"
    local has_prev=0
    if [[ -f "$state_file" ]]; then
        local prev_output
        prev_output=$(read_build_state_as_prev "$state_file")
        eval "$prev_output"
        has_prev=1
    fi

    resolve_commits

    local drift_summary="" has_drift=1
    if ((has_prev)); then
        set +e
        drift_summary=$(build_state_drift_summary)
        has_drift=$?
        set -e
    fi

    if ((has_drift == 0)); then
        echo "==> Nothing to update (build state unchanged since ${PREV_BUILD_DATE})."
        echo "    To force a rebuild, remove ${state_file} and run 'make update' again."
        return
    fi

    if ((has_prev)); then
        echo "==> Build state drifted since last build (${PREV_BUILD_DATE})."
        echo ""
        echo "$drift_summary"
        echo ""
    else
        echo "==> No pinned build state for this run — rebuilding."
        echo ""
    fi

    cmd_build
    write_build_state "$state_file"

    # Switch current to this run if needed (mirrors cmd_start's run= behavior).
    local current
    if current=$(resolve_current_run) \
            && [[ "$current" != "$run_dir" ]] \
            && is_running "${current}/docker-compose.yml"; then
        echo "==> Stopping current run $(basename "$current") first..."
        docker compose -f "${current}/docker-compose.yml" down
    fi
    ln -sfn "$run_dir" "$CURRENT_LINK"

    check_network_capacity "$TOPOLOGY" "$NUM_NODES"
    echo "==> Restarting run: $(basename "$run_dir")"
    docker compose -f "${run_dir}/docker-compose.yml" up -d --force-recreate
    echo "==> Updated and restarted."
}

# ---- Clean

cmd_clean_imgs() {
    local yes="${1:-}"

    local images
    images=$(docker images --filter "reference=gno-cluster-*" -q 2>/dev/null | sort -u)
    if [[ -z "$images" ]]; then
        echo "==> No gno-cluster images to remove."
        return
    fi
    local count
    count=$(echo "$images" | grep -c . || true)

    if [[ -z "$yes" ]]; then
        if [[ ! -t 0 ]]; then
            echo "Error: clean-imgs requires yes=1 in non-interactive mode (${count} image(s) would be removed)." >&2
            return 1
        fi
        echo "About to remove ${count} gno-cluster image(s)."
        local ans
        read -r -p "Proceed? [y/N] " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Aborted."
            return
        fi
    fi

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

    local current
    if current=$(resolve_current_run) && is_running "${current}/docker-compose.yml"; then
        echo "==> Stopping current run..."
        docker compose -f "${current}/docker-compose.yml" down
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
    cmd_clean_imgs "$yes"
}

# ---- Dispatch

command="${1:?Usage: cluster.sh <command> (build|create|list|start|stop|restart|clone|status|logs|infos|update|clean|clean-runs|clean-imgs)}"
shift || true

case "$command" in
    build)        cmd_build "$@" ;;
    create)       cmd_create "$@" ;;
    start)        cmd_start "$@" ;;
    stop)         cmd_stop ;;
    restart)      cmd_restart "$@" ;;
    clone)        cmd_clone "$@" ;;
    status)       cmd_status "$@" ;;
    logs)         cmd_logs "$@" ;;
    infos)        cmd_infos "$@" ;;
    list)         cmd_list ;;
    update)       cmd_update ;;
    clean)        cmd_clean "$@" ;;
    clean-runs)   cmd_clean_runs "$@" ;;
    clean-imgs) cmd_clean_imgs "$@" ;;
    *)
        echo "Unknown command: ${command}"
        echo "Run 'make help' for usage."
        exit 1
        ;;
esac
