#!/usr/bin/env bash
# internal/scripts/parse-genesis.sh — Extract metadata from genesis.json.
#
# Source this file to use:
#   parse_genesis <path>  — outputs validators_count=N, balances_count=N, txs_count=N
set -euo pipefail

parse_genesis() {
    local genesis="$1"
    if [[ ! -f "$genesis" ]]; then
        echo "Error: genesis.json not found at $genesis" >&2
        return 1
    fi

    local vals bals txs
    vals=$(jq '.validators | length' "$genesis")
    bals=$(jq '(.app_state.balances // []) | length' "$genesis")
    txs=$(jq '(.app_state.txs // []) | length' "$genesis")

    echo "validators_count=${vals}"
    echo "balances_count=${bals}"
    echo "txs_count=${txs}"
}
