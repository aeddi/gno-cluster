#!/usr/bin/env bash
# internal/scripts/parse-genesis.sh — Extract metadata from genesis.json.
#
# Source this file to use:
#   parse_genesis <path>
#       — outputs bash-assignable KEY=VALUE lines for:
#         chain_id, genesis_time, sha256, validators_count, total_voting_power,
#         balances_count, txs_count
#   parse_genesis_validators <path>
#       — outputs one line per validator: address|pubkey|power|name
set -euo pipefail

_PARSE_GENESIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_PARSE_GENESIS_DIR}/common.sh"

parse_genesis() {
    local genesis="$1"
    if [[ ! -f "$genesis" ]]; then
        echo "Error: genesis.json not found at $genesis" >&2
        return 1
    fi
    require_tool jq "Install with: brew install jq (macOS) | apt install jq (Debian)" || return 1

    local chain_id genesis_time sha256 vals bals txs power
    chain_id=$(jq -r '.chain_id // ""' "$genesis")
    genesis_time=$(jq -r '.genesis_time // ""' "$genesis")
    sha256=$(sha256_file "$genesis")
    vals=$(jq '.validators | length' "$genesis")
    power=$(jq '[.validators[].power | (tonumber? // 0)] | add // 0' "$genesis")
    bals=$(jq '(.app_state.balances // []) | length' "$genesis")
    txs=$(jq '(.app_state.txs // []) | length' "$genesis")

    echo "chain_id=${chain_id}"
    echo "genesis_time=${genesis_time}"
    echo "sha256=${sha256}"
    echo "validators_count=${vals}"
    echo "total_voting_power=${power}"
    echo "balances_count=${bals}"
    echo "txs_count=${txs}"
}

parse_genesis_validators() {
    local genesis="$1"
    if [[ ! -f "$genesis" ]]; then
        echo "Error: genesis.json not found at $genesis" >&2
        return 1
    fi
    require_tool jq "Install with: brew install jq (macOS) | apt install jq (Debian)" || return 1
    jq -r '.validators[] | [.address, .pub_key.value, .power, (.name // "")] | join("|")' "$genesis"
}
