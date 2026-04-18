#!/usr/bin/env bash
# internal/tests/test_parse_genesis.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

source "$SCRIPT_DIR/../scripts/parse-genesis.sh"

echo "=== parse-genesis.sh ==="

FIXTURE="$SCRIPT_DIR/fixtures/test-genesis.json"

result=$(parse_genesis "$FIXTURE")
assert_contains "validators count" "validators_count=2" "$result"
assert_contains "balances count" "balances_count=3" "$result"
assert_contains "txs count" "txs_count=2" "$result"
assert_contains "chain_id" "chain_id=test-chain" "$result"
assert_contains "genesis_time" "genesis_time=2026-01-01T00:00:00Z" "$result"
assert_contains "total_voting_power" "total_voting_power=2" "$result"
# sha256 is a 64-char hex digest
[[ "$result" =~ sha256=[0-9a-f]{64} ]]
assert_eq "sha256 is 64-hex" "0" "$?"

# ---- parse_genesis_validators
echo "-- parse_genesis_validators --"
val_result=$(parse_genesis_validators "$FIXTURE")
assert_line_count "2 validators" "2" "$val_result"
assert_contains "val-1 in output" "g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|AAAA|1|val-1" "$val_result"
assert_contains "val-2 in output" "g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|BBBB|1|val-2" "$val_result"

# Missing file
if parse_genesis "/nonexistent/genesis.json" 2>/dev/null; then
    assert_eq "missing file returns error" "should fail" "did not fail"
else
    assert_eq "missing file returns error" "1" "$?"
fi

# Genesis without txs field
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
{
  "validators": [{"name": "v1"}],
  "app_state": {
    "balances": ["a=1", "b=2"]
  }
}
EOF
result=$(parse_genesis "$TMP")
assert_contains "no txs field" "txs_count=0" "$result"
assert_contains "no txs: 2 balances" "balances_count=2" "$result"
rm -f "$TMP"

summary
