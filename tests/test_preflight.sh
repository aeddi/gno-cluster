#!/usr/bin/env bash
# tests/test_preflight.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

source "$SCRIPT_DIR/../internal/scripts/preflight.sh"

echo "=== preflight.sh ==="

# ---- compute_required_networks
echo "-- compute_required_networks --"

# Formula: topology networks + N sidecars + 1 watchtower
# mesh: 1 shared network (after mesh optimization)
# star: N-1 edge networks
# ring: N edge networks (for N >= 3) or 1 (for N == 2)

assert_eq "mesh 4: 1+4+1 = 6"  "6"  "$(compute_required_networks mesh 4)"
assert_eq "mesh 10: 1+10+1 = 12" "12" "$(compute_required_networks mesh 10)"
assert_eq "mesh 20: 1+20+1 = 22" "22" "$(compute_required_networks mesh 20)"

assert_eq "star 4: 3+4+1 = 8"   "8"  "$(compute_required_networks star 4)"
assert_eq "star 10: 9+10+1 = 20" "20" "$(compute_required_networks star 10)"

assert_eq "ring 4: 4+4+1 = 9"   "9"  "$(compute_required_networks ring 4)"
assert_eq "ring 10: 10+10+1 = 21" "21" "$(compute_required_networks ring 10)"
assert_eq "ring 2: 1+2+1 = 4"   "4"  "$(compute_required_networks ring 2)"

# ---- compute_pool_capacity
echo "-- compute_pool_capacity --"

assert_eq "empty input: 0" "0" "$(printf '' | compute_pool_capacity)"

# One /24 base with /24 subnet size = 1 subnet
assert_eq "one /24->/24: 1" "1" \
    "$(printf ' Base: 192.168.97.0/24, Size: 24\n' | compute_pool_capacity)"

# One /16 base with /24 subnet size = 2^(24-16) = 256 subnets
assert_eq "one /16->/24: 256" "256" \
    "$(printf ' Base: 172.17.0.0/16, Size: 24\n' | compute_pool_capacity)"

# One /20 base with /24 subnet size = 2^(24-20) = 16 subnets
assert_eq "one /20->/24: 16" "16" \
    "$(printf ' Base: 10.0.0.0/20, Size: 24\n' | compute_pool_capacity)"

# One /8 base with /24 subnet size = 2^16 = 65536 subnets
assert_eq "one /8->/24: 65536" "65536" \
    "$(printf ' Base: 10.0.0.0/8, Size: 24\n' | compute_pool_capacity)"

# Multiple pools summed
input='Default Address Pools:
   Base: 192.168.97.0/24, Size: 24
   Base: 192.168.107.0/24, Size: 24
   Base: 172.17.0.0/16, Size: 24'
assert_eq "mixed pools: 258" "258" \
    "$(printf '%s\n' "$input" | compute_pool_capacity)"

# Ignore non-matching lines
input='some garbage
 Base: 192.168.97.0/24, Size: 24
other stuff
 Base: 192.168.107.0/24, Size: 24'
assert_eq "noise ignored: 2" "2" \
    "$(printf '%s\n' "$input" | compute_pool_capacity)"

summary
