#!/usr/bin/env bash
# internal/docker/gpao-entrypoint.sh — import the approver key, then run gpao.
#
# Expected environment:
#   GPAO_KEY_NAME   — key name to create in the container keystore
#   GPAO_REMOTE     — RPC address of the node to watch
#
# Expected mounts:
#   /approver.mnemonic — bip39 mnemonic for the approver key
#   /genesis.json      — chain genesis, read for the chain id
set -euo pipefail

: "${GPAO_KEY_NAME:?GPAO_KEY_NAME is required}"
: "${GPAO_REMOTE:?GPAO_REMOTE is required}"

if [[ ! -f /approver.mnemonic ]]; then
  echo "[gpao] Error: /approver.mnemonic is not mounted." >&2
  exit 1
fi

# Taken from the genesis rather than configured, so the id used to sign
# approvals cannot disagree with the chain that must accept them.
GPAO_CHAIN_ID=$(jq -r '.chain_id' /genesis.json)
if [[ -z "$GPAO_CHAIN_ID" || "$GPAO_CHAIN_ID" == "null" ]]; then
  echo "[gpao] Error: could not read .chain_id from /genesis.json." >&2
  exit 1
fi
echo "[gpao] chain-id: ${GPAO_CHAIN_ID}"

readonly GNO_HOME=/tmp/gpao-keystore

# The keystore is rebuilt on every start: it holds one derived key and no state
# worth persisting.
#
# The passphrase is fixed and local to this container. It cannot be empty:
# gpao falls back to an interactive prompt when GPAO_PASSWORD is unset or
# empty, and there is no terminal here to answer it.
readonly KEY_PASSWORD=gpao-local

echo "[gpao] Importing approver key..."
rm -rf "$GNO_HOME"
# gnokey -recover reads three lines: the mnemonic, the passphrase, and the
# passphrase again.
# \r as well as \n: a mnemonic file saved with CRLF would otherwise reach
# gnokey with a stray carriage return and fail as an invalid phrase.
printf '%s\n%s\n%s\n' \
  "$(tr -d '\n\r' </approver.mnemonic)" "$KEY_PASSWORD" "$KEY_PASSWORD" |
  gnokey add -recover -insecure-password-stdin -home "$GNO_HOME" "$GPAO_KEY_NAME" >/dev/null

gnokey list -home "$GNO_HOME"

# Compose starts gpao and the node together, and gpao exits if its first poll
# cannot reach the node.
#
# Bounded: waiting forever leaves a container that looks started while
# approving nothing, and make status reports only nodes. Exiting lets the
# restart policy retry and puts the reason in the logs.
readonly NODE_WAIT_SECONDS=120

echo "[gpao] Waiting for ${GPAO_REMOTE}..."
waited=0
until wget -qO- --timeout=2 "${GPAO_REMOTE}/status" >/dev/null 2>&1; do
  if ((waited >= NODE_WAIT_SECONDS)); then
    echo "[gpao] Error: ${GPAO_REMOTE} unreachable after ${NODE_WAIT_SECONDS}s." >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done

echo "[gpao] Starting..."
export GPAO_PASSWORD="$KEY_PASSWORD"
exec gpao \
  --remote "$GPAO_REMOTE" \
  --chain-id "$GPAO_CHAIN_ID" \
  --home "$GNO_HOME" \
  --key "$GPAO_KEY_NAME" \
  --gno-root /gnoroot \
  --status-listen 0.0.0.0:8546
