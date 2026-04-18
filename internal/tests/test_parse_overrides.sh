#!/usr/bin/env bash
# internal/tests/test_parse_overrides.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

source "$SCRIPT_DIR/../scripts/parse-overrides.sh"

echo "=== parse-overrides.sh ==="

# Mock: record calls instead of running gnoland config set
RECORDED=()
mock_config_set() { RECORDED+=("$1=$2"); }

# ---- Global section applies to all nodes
echo "-- global section --"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
consensus.timeout_commit = "3s"
mempool.size = 10000
EOF
RECORDED=()
apply_config_overrides "node-1" "$TMP" mock_config_set
assert_eq "global: 2 calls" "2" "${#RECORDED[@]}"
assert_eq "global: key 1" "consensus.timeout_commit=3s" "${RECORDED[0]}"
assert_eq "global: key 2" "mempool.size=10000" "${RECORDED[1]}"
rm -f "$TMP"

# ---- Targeted section: matching node
echo "-- targeted section (match) --"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
consensus.timeout_commit = "3s"

[node-1]
consensus.timeout_commit = "5s"

[node-2]
mempool.size = 5000
EOF
RECORDED=()
apply_config_overrides "node-1" "$TMP" mock_config_set
assert_eq "targeted match: 2 calls" "2" "${#RECORDED[@]}"
assert_eq "targeted match: global" "consensus.timeout_commit=3s" "${RECORDED[0]}"
assert_eq "targeted match: node-1 override" "consensus.timeout_commit=5s" "${RECORDED[1]}"
rm -f "$TMP"

# ---- Targeted section: non-matching node
echo "-- targeted section (no match) --"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
[node-2]
mempool.size = 5000
EOF
RECORDED=()
apply_config_overrides "node-1" "$TMP" mock_config_set
assert_eq "no match: 0 calls" "0" "${#RECORDED[@]}"
rm -f "$TMP"

# ---- Multi-target section
echo "-- multi-target section --"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
[node-1, node-3]
mempool.size = 7000
EOF
RECORDED=()
apply_config_overrides "node-3" "$TMP" mock_config_set
assert_eq "multi-target: 1 call" "1" "${#RECORDED[@]}"
assert_eq "multi-target: value" "mempool.size=7000" "${RECORDED[0]}"
rm -f "$TMP"

# ---- Comments and blank lines
echo "-- comments and blanks --"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
# This is a comment
consensus.timeout_commit = "3s"

   # Indented comment
mempool.size = 10000
EOF
RECORDED=()
apply_config_overrides "node-1" "$TMP" mock_config_set
assert_eq "comments: 2 calls" "2" "${#RECORDED[@]}"
rm -f "$TMP"

# ---- Last-match wins
echo "-- last-match wins --"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
consensus.timeout_commit = "3s"

[node-1]
consensus.timeout_commit = "5s"

[node-1, node-2]
consensus.timeout_commit = "2s"
EOF
RECORDED=()
apply_config_overrides "node-1" "$TMP" mock_config_set
assert_eq "last-match: 3 calls" "3" "${#RECORDED[@]}"
assert_eq "last-match: global" "consensus.timeout_commit=3s" "${RECORDED[0]}"
assert_eq "last-match: first override" "consensus.timeout_commit=5s" "${RECORDED[1]}"
assert_eq "last-match: final override" "consensus.timeout_commit=2s" "${RECORDED[2]}"
rm -f "$TMP"

summary
