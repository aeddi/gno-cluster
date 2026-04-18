#!/usr/bin/env bash
# internal/scripts/parse-overrides.sh — Parse config.overrides with per-node targeting.
#
# Source this file to use:
#   apply_config_overrides <node_name> <config_file> <callback>
#
# Calls <callback> <key> <value> for each matching override.
# Global section (before any [header]) applies to all nodes.
# Targeted sections apply only if node_name is listed in the header.
# Last-match wins for duplicate keys on the same node.
set -euo pipefail

# Pure-bash whitespace trim: no subprocess, no sed dialect concerns.
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

apply_config_overrides() {
  local node_name="$1" config_file="$2" callback="$3"
  local current_section=""

  while IFS= read -r line; do
    # Strip inline comments (but not inside quotes — good enough for config keys)
    line="${line%%#*}"
    line=$(_trim "$line")

    [[ -z "$line" ]] && continue

    # Section header: [node-1] or [node-1, node-2]
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      current_section="${BASH_REMATCH[1]}"
      continue
    fi

    # Key = value
    if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
      local key value
      key=$(_trim "${BASH_REMATCH[1]}")
      value=$(_trim "${BASH_REMATCH[2]}")
      # Strip a single pair of surrounding quotes, if present.
      value="${value#\"}"
      value="${value%\"}"

      if [[ -z "$current_section" ]]; then
        # Global section: applies to all nodes
        "$callback" "$key" "$value"
      else
        # Check if node_name is in the comma-separated section list
        IFS=',' read -ra targets <<<"$current_section"
        for target in "${targets[@]}"; do
          target=$(_trim "$target")
          if [[ "$target" == "$node_name" ]]; then
            "$callback" "$key" "$value"
            break
          fi
        done
      fi
    fi
  done <"$config_file"
}
