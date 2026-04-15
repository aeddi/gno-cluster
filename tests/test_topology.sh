#!/usr/bin/env bash
# tests/test_topology.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

source "$SCRIPT_DIR/../internal/scripts/topology.sh"

echo "=== topology.sh ==="

# ---- get_networks
echo "-- get_networks --"

result=$(get_networks mesh 3)
assert_line_count "mesh 3: 3 networks" "3" "$result"
assert_contains "mesh 3: net-1-2" "net-1-2 1 2" "$result"
assert_contains "mesh 3: net-1-3" "net-1-3 1 3" "$result"
assert_contains "mesh 3: net-2-3" "net-2-3 2 3" "$result"

result=$(get_networks mesh 4)
assert_line_count "mesh 4: 6 networks" "6" "$result"

result=$(get_networks star 4)
assert_line_count "star 4: 3 networks" "3" "$result"
assert_contains "star 4: net-1-2" "net-1-2 1 2" "$result"
assert_contains "star 4: net-1-3" "net-1-3 1 3" "$result"
assert_contains "star 4: net-1-4" "net-1-4 1 4" "$result"

result=$(get_networks ring 4)
assert_line_count "ring 4: 4 networks" "4" "$result"
assert_contains "ring 4: net-1-2" "net-1-2 1 2" "$result"
assert_contains "ring 4: net-2-3" "net-2-3 2 3" "$result"
assert_contains "ring 4: net-3-4" "net-3-4 3 4" "$result"
assert_contains "ring 4: net-1-4" "net-1-4 1 4" "$result"

# Ring with 2 nodes: single link, no wrap
result=$(get_networks ring 2)
assert_line_count "ring 2: 1 network" "1" "$result"

# Ring with 1 node: no networks
result=$(get_networks ring 1)
assert_eq "ring 1: empty" "" "$result"

# ---- get_peers
echo "-- get_peers --"

result=$(get_peers mesh 4 1)
assert_eq "mesh 4: node-1 peers" "2 3 4" "$result"

result=$(get_peers mesh 4 3)
assert_eq "mesh 4: node-3 peers" "1 2 4" "$result"

result=$(get_peers star 4 1)
assert_eq "star 4: node-1 peers" "2 3 4" "$result"

result=$(get_peers star 4 3)
assert_eq "star 4: node-3 peers" "1" "$result"

result=$(get_peers ring 4 1)
assert_eq "ring 4: node-1 peers" "2 4" "$result"

result=$(get_peers ring 4 2)
assert_eq "ring 4: node-2 peers" "1 3" "$result"

result=$(get_peers ring 4 4)
assert_eq "ring 4: node-4 peers" "3 1" "$result"

# ---- get_node_networks
echo "-- get_node_networks --"

result=$(get_node_networks mesh 3 2)
assert_contains "mesh 3 node-2: net-1-2" "net-1-2" "$result"
assert_contains "mesh 3 node-2: net-2-3" "net-2-3" "$result"
assert_not_contains "mesh 3 node-2: not net-1-3" "net-1-3" "$result"

result=$(get_node_networks star 4 1)
assert_contains "star 4 node-1: net-1-2" "net-1-2" "$result"
assert_contains "star 4 node-1: net-1-3" "net-1-3" "$result"
assert_contains "star 4 node-1: net-1-4" "net-1-4" "$result"

result=$(get_node_networks star 4 3)
assert_eq "star 4 node-3: only net-1-3" "net-1-3" "$result"

summary
