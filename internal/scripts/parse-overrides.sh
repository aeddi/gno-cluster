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

apply_config_overrides() {
    local node_name="$1" config_file="$2" callback="$3"
    local current_section=""

    while IFS= read -r line; do
        # Strip inline comments (but not inside quotes — good enough for config keys)
        line="${line%%#*}"
        # Trim leading/trailing whitespace
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        [[ -z "$line" ]] && continue

        # Section header: [node-1] or [node-1, node-2]
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # Key = value
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            local key value
            key="$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            value="$(echo "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//')"

            if [[ -z "$current_section" ]]; then
                # Global section: applies to all nodes
                "$callback" "$key" "$value"
            else
                # Check if node_name is in the comma-separated section list
                IFS=',' read -ra targets <<< "$current_section"
                for target in "${targets[@]}"; do
                    target="$(echo "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                    if [[ "$target" == "$node_name" ]]; then
                        "$callback" "$key" "$value"
                        break
                    fi
                done
            fi
        fi
    done < "$config_file"
}
