#!/usr/bin/env bash
# internal/scripts/topology.sh — Pure functions for computing network topology.
#
# Source this file to use:
#   get_networks <topology> <num_nodes>     — outputs one network entry per line
#   get_peers <topology> <num_nodes> <node> — outputs space-separated peer indices
#   get_node_networks <topology> <num_nodes> <node> — outputs space-separated network names
#
# Network entry format:
#   "<network-name> <a> <b>"  — edge network (connects exactly two nodes)
#   "<network-name> ALL"      — shared network (all nodes join)
#
# Mesh uses a single shared network since every pair is allowed; per-edge isolation
# would waste Docker address-pool slots (O(N²)). Star and ring keep per-edge networks
# so Docker enforces the topology at the network layer.
set -euo pipefail

get_networks() {
    local topology="$1" n="$2"
    case "$topology" in
        mesh)
            if ((n >= 2)); then
                echo "net-mesh ALL"
            fi
            ;;
        star)
            for ((i = 2; i <= n; i++)); do
                echo "net-1-${i} 1 ${i}"
            done
            ;;
        ring)
            for ((i = 1; i < n; i++)); do
                echo "net-${i}-$((i + 1)) ${i} $((i + 1))"
            done
            if ((n >= 3)); then
                echo "net-1-${n} 1 ${n}"
            fi
            ;;
        *)
            echo "Error: unknown topology '$topology'" >&2
            return 1
            ;;
    esac
}

get_peers() {
    local topology="$1" n="$2" node="$3"
    local peers=()
    while IFS=' ' read -r _net a b; do
        if [[ "$a" == "ALL" ]]; then
            for ((i = 1; i <= n; i++)); do
                if ((i != node)); then peers+=("$i"); fi
            done
        else
            if ((a == node)); then peers+=("$b"); fi
            if ((b == node)); then peers+=("$a"); fi
        fi
    done < <(get_networks "$topology" "$n")
    echo "${peers[*]}"
}

get_node_networks() {
    local topology="$1" n="$2" node="$3"
    local nets=()
    while IFS=' ' read -r net a b; do
        if [[ "$a" == "ALL" ]]; then
            nets+=("$net")
        else
            if ((a == node || b == node)); then nets+=("$net"); fi
        fi
    done < <(get_networks "$topology" "$n")
    echo "${nets[*]}"
}
