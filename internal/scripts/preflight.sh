#!/usr/bin/env bash
# internal/scripts/preflight.sh — Docker pre-flight checks for cluster startup.
#
# Source this file to use:
#   compute_required_networks <topology> <n>
#       — echo the total number of networks needed for a cluster of <n> nodes
#         with the given topology (topology nets + sidecars + watchtower).
#   compute_pool_capacity
#       — read `docker system info` output from stdin and echo the sum of
#         declared subnets across all Default Address Pools.
#   count_bridge_networks
#       — echo the number of bridge networks currently on the host.
#   count_project_bridges <project_name>
#       — echo the number of bridge networks belonging to a given compose project.
#   check_network_capacity <topology> <n> [<project_name>]
#       — run the full preflight: print a summary, and if declared capacity is
#         insufficient, print actionable options and exit 1.
set -euo pipefail

_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=topology.sh
source "${_PREFLIGHT_DIR}/topology.sh"

compute_required_networks() {
  local topology="$1" n="$2"
  local topo
  topo=$(get_networks "$topology" "$n" | grep -c . || true)
  echo $((topo + n + 1))
}

# Parses `docker system info` output from stdin. Recognises lines of the form
# "Base: A.B.C.D/M, Size: S" and accumulates 2^(S-M) subnets per pool.
compute_pool_capacity() {
  local total=0
  local base_mask size diff subnets
  while IFS= read -r line; do
    if [[ "$line" =~ Base:[[:space:]]+[0-9.]+/([0-9]+),[[:space:]]+Size:[[:space:]]+([0-9]+) ]]; then
      base_mask="${BASH_REMATCH[1]}"
      size="${BASH_REMATCH[2]}"
      diff=$((size - base_mask))
      if ((diff >= 0 && diff < 31)); then
        subnets=$((1 << diff))
        total=$((total + subnets))
      fi
    fi
  done
  echo "$total"
}

count_bridge_networks() {
  docker network ls --filter driver=bridge -q 2>/dev/null | grep -c . || true
}

count_project_bridges() {
  local project="$1"
  docker network ls --filter driver=bridge \
    --filter "label=com.docker.compose.project=${project}" -q 2>/dev/null |
    grep -c . || true
}

# Emits the "here are your options" block to stderr.
_print_pool_options() {
  local topology="$1" n="$2"
  local count
  {
    echo ""
    echo "Options to resolve this:"
    echo ""
    echo "  1. Reduce cluster size or switch topology in cluster.env:"
    echo "       Current:  NUM_NODES=${n}  TOPOLOGY=${topology}"
    for alt in mesh star ring; do
      [[ "$alt" == "$topology" ]] && continue
      count=$(compute_required_networks "$alt" "$n")
      printf "       Try:      NUM_NODES=%-3d TOPOLOGY=%-5s (%d networks)\n" "$n" "$alt" "$count"
    done
    echo "       Smaller NUM_NODES also reduces the count (mesh grows O(1), star/ring O(N))."
    echo ""
    echo "  2. Free unused Docker networks:"
    echo "       List all bridge networks:"
    echo "         docker network ls --filter driver=bridge"
    echo "       Remove unused ones (safe — skips in-use):"
    echo "         docker network prune"
    echo "       Stop a specific past run:"
    echo "         docker compose -p gno-cluster -f runs/<folder>/docker-compose.yml down"
    echo ""
    echo "  3. Increase Docker's address pools (requires a Docker restart):"
    echo "       Edit ~/.docker/daemon.json and add or enlarge default-address-pools:"
    echo '         {'
    echo '           "default-address-pools": ['
    echo '             {"base": "10.0.0.0/8", "size": 24}'
    echo '           ]'
    echo '         }'
    echo "       Then restart Docker Desktop (or: sudo systemctl restart docker)."
  } >&2
}

# Prints a summary banner and, if declared capacity is insufficient, options + exit 1.
check_network_capacity() {
  local topology="$1" n="$2" project="${3:-gno-cluster}"
  local required current capacity project_bridges topo_count

  required=$(compute_required_networks "$topology" "$n")
  topo_count=$((required - n - 1))
  current=$(count_bridge_networks)
  capacity=$(docker system info 2>/dev/null | compute_pool_capacity)
  project_bridges=$(count_project_bridges "$project")

  echo "==> Pre-flight: Docker network capacity"
  echo "    Cluster:  ${n} nodes, ${topology} topology"
  echo "    Required: ${required} networks  (${topo_count} topology + ${n} sidecar + 1 watchtower)"
  if ((capacity > 0)); then
    echo "    Docker:   ${current} bridges in use (${project_bridges} owned by '${project}'), declared pool = ${capacity} subnets"
  else
    echo "    Docker:   ${current} bridges in use  (pool capacity: unknown)"
  fi

  if ((capacity > 0)); then
    local non_project needed
    non_project=$((current - project_bridges))
    needed=$((required + non_project))
    if ((needed > capacity)); then
      echo "    Status:   INSUFFICIENT — would need ${needed} subnets, have ${capacity}"
      _print_pool_options "$topology" "$n"
      exit 1
    fi
    echo "    Status:   OK"
  fi
  echo ""
}
