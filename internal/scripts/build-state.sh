#!/usr/bin/env bash
# internal/scripts/build-state.sh — Record and compare image-build state per run.
#
# Source this file (after image-tags.sh) to use:
#   write_build_state <file>
#       — Write a sourceable snapshot of the current build state to <file>.
#         Pulls refs/repos/commits from env (GNO_*, WATCHTOWER_*) and content
#         file hashes from the project source tree.
#   read_build_state_as_prev <file>
#       — Read <file> in a subshell and emit eval-able lines that populate
#         PREV_* variables in the caller's scope. Use as:
#           eval "$(read_build_state_as_prev .build-state)"
#         Returns non-zero if <file> doesn't exist.
#   build_state_drift_summary
#       — Compare PREV_* vars against the current env state. Emits a human-
#         readable summary of differences to stdout. Returns 0 if no drift,
#         1 if drift detected. Uses fetch_commit_titles to enrich commit-only
#         drifts with commit messages (silent on failure).
#   fetch_commit_titles <repo> <from_commit> <to_commit>
#       — Print "  <short_sha>  <title>" lines for commits between from and to
#         via the GitHub compare API. Silently fails (returns 1, no output) on
#         network errors, API errors, rate limits, force-push / fork divergence.
set -euo pipefail

_BUILD_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=image-tags.sh
source "${_BUILD_STATE_DIR}/image-tags.sh"

# Writes current build state. Expects these env vars: GNO_REPO, GNO_VERSION,
# GNO_COMMIT, WATCHTOWER_REPO, WATCHTOWER_VERSION, WATCHTOWER_COMMIT, PROJECT_ROOT.
# Writes atomically: builds the content in a sibling temp file, then renames.
# That way a killed process leaves either the old state or no change, never a
# truncated file that would confuse read_build_state_as_prev.
write_build_state() {
    local out_file="$1"
    local build_date content_hash gnoland_tag watchtower_tag sentinel_tag file_lines
    build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    content_hash=$(compute_build_hash)
    gnoland_tag=$(compute_image_tag gnoland "$GNO_COMMIT" "$WATCHTOWER_COMMIT")
    watchtower_tag=$(compute_image_tag watchtower "$GNO_COMMIT" "$WATCHTOWER_COMMIT")
    sentinel_tag=$(compute_image_tag sentinel "$GNO_COMMIT" "$WATCHTOWER_COMMIT")
    file_lines=$(compute_file_hashes_for \
        "${PROJECT_ROOT}/internal/Dockerfile" \
        "${PROJECT_ROOT}/internal/docker" \
        "${PROJECT_ROOT}/internal/scripts/parse-overrides.sh")

    local tmp
    tmp=$(mktemp "${out_file}.tmp.XXXXXX")
    # Clean up the temp file on any non-local exit from this function.
    trap 'rm -f "$tmp"' RETURN

    {
        echo "# Build state snapshot — inputs used when this run's images were last built."
        echo "# Compared by make start to detect drift. Do not edit by hand."
        echo ""
        echo "BUILD_DATE=\"${build_date}\""
        echo ""
        echo "GNO_REPO=\"${GNO_REPO}\""
        echo "GNO_VERSION=\"${GNO_VERSION}\""
        echo "GNO_COMMIT=\"${GNO_COMMIT}\""
        echo "GNOLAND_IMAGE=\"gno-cluster-gnoland:${gnoland_tag}\""
        echo ""
        echo "WATCHTOWER_REPO=\"${WATCHTOWER_REPO}\""
        echo "WATCHTOWER_VERSION=\"${WATCHTOWER_VERSION}\""
        echo "WATCHTOWER_COMMIT=\"${WATCHTOWER_COMMIT}\""
        echo "WATCHTOWER_IMAGE=\"gno-cluster-watchtower:${watchtower_tag}\""
        echo "SENTINEL_IMAGE=\"gno-cluster-sentinel:${sentinel_tag}\""
        echo ""
        echo "CONTENT_HASH=\"${content_hash}\""
        echo "CONTENT_FILES=("
        # Each line of file_lines is "<hash>  <path>"; quote as a bash array element.
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf '    "%s"\n' "$line"
        done <<< "$file_lines"
        echo ")"
    } > "$tmp"

    mv -f "$tmp" "$out_file"
}

# Reads <file> in a subshell (so sourcing doesn't clobber the caller's env) and
# emits bash assignments for PREV_* variables. Eval the output in the caller.
read_build_state_as_prev() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$file"
        echo "PREV_BUILD_DATE=\"${BUILD_DATE:-}\""
        echo "PREV_GNO_REPO=\"${GNO_REPO:-}\""
        echo "PREV_GNO_VERSION=\"${GNO_VERSION:-}\""
        echo "PREV_GNO_COMMIT=\"${GNO_COMMIT:-}\""
        echo "PREV_GNOLAND_IMAGE=\"${GNOLAND_IMAGE:-}\""
        echo "PREV_WATCHTOWER_REPO=\"${WATCHTOWER_REPO:-}\""
        echo "PREV_WATCHTOWER_VERSION=\"${WATCHTOWER_VERSION:-}\""
        echo "PREV_WATCHTOWER_COMMIT=\"${WATCHTOWER_COMMIT:-}\""
        echo "PREV_WATCHTOWER_IMAGE=\"${WATCHTOWER_IMAGE:-}\""
        echo "PREV_SENTINEL_IMAGE=\"${SENTINEL_IMAGE:-}\""
        echo "PREV_CONTENT_HASH=\"${CONTENT_HASH:-}\""
        printf 'PREV_CONTENT_FILES=('
        local f
        for f in "${CONTENT_FILES[@]:-}"; do
            [[ -n "$f" ]] && printf ' %q' "$f"
        done
        printf ')\n'
    )
}

# Fetches commit titles between from_commit and to_commit via GitHub compare API.
# Prints "  <short_sha>  <first_line_of_message>" for each commit. Silent on
# failure (returns 1, prints nothing).
fetch_commit_titles() {
    local repo="$1" from_commit="$2" to_commit="$3"
    local api_url="https://api.github.com/repos/${repo}/compare/${from_commit}...${to_commit}"
    local json
    json=$(http_get_silent "$api_url") || return 1
    local out
    out=$(echo "$json" | jq -r '.commits[]? | "  \(.sha[0:7])  \(.commit.message | split("\n")[0])"' 2>/dev/null) || return 1
    [[ -z "$out" ]] && return 1
    echo "$out"
}

# Computes drift between PREV_* and current env state. Prints human-readable
# summary. Returns 1 if drift detected, 0 if identical.
build_state_drift_summary() {
    local drift=0

    # Gno
    if [[ "${PREV_GNO_REPO:-}" != "${GNO_REPO:-}" ]]; then
        echo "  gno repo changed: ${PREV_GNO_REPO:-<none>} → ${GNO_REPO:-<none>}"
        _fetch_and_indent_titles "${GNO_REPO:-}" "${PREV_GNO_COMMIT:-}" "${GNO_COMMIT:-}"
        drift=1
    elif [[ "${PREV_GNO_VERSION:-}" != "${GNO_VERSION:-}" ]]; then
        echo "  gno ref changed: ${PREV_GNO_VERSION:-<none>} → ${GNO_VERSION:-<none>}"
        _fetch_and_indent_titles "${GNO_REPO:-}" "${PREV_GNO_COMMIT:-}" "${GNO_COMMIT:-}"
        drift=1
    elif [[ "${PREV_GNO_COMMIT:-}" != "${GNO_COMMIT:-}" ]]; then
        echo "  gno commit advanced on ${GNO_VERSION}: ${PREV_GNO_COMMIT:0:12} → ${GNO_COMMIT:0:12}"
        _fetch_and_indent_titles "${GNO_REPO:-}" "${PREV_GNO_COMMIT:-}" "${GNO_COMMIT:-}"
        drift=1
    fi

    # Watchtower (used by both watchtower and sentinel images)
    if [[ "${PREV_WATCHTOWER_REPO:-}" != "${WATCHTOWER_REPO:-}" ]]; then
        echo "  watchtower repo changed: ${PREV_WATCHTOWER_REPO:-<none>} → ${WATCHTOWER_REPO:-<none>}"
        _fetch_and_indent_titles "${WATCHTOWER_REPO:-}" "${PREV_WATCHTOWER_COMMIT:-}" "${WATCHTOWER_COMMIT:-}"
        drift=1
    elif [[ "${PREV_WATCHTOWER_VERSION:-}" != "${WATCHTOWER_VERSION:-}" ]]; then
        echo "  watchtower ref changed: ${PREV_WATCHTOWER_VERSION:-<none>} → ${WATCHTOWER_VERSION:-<none>}"
        _fetch_and_indent_titles "${WATCHTOWER_REPO:-}" "${PREV_WATCHTOWER_COMMIT:-}" "${WATCHTOWER_COMMIT:-}"
        drift=1
    elif [[ "${PREV_WATCHTOWER_COMMIT:-}" != "${WATCHTOWER_COMMIT:-}" ]]; then
        echo "  watchtower commit advanced on ${WATCHTOWER_VERSION}: ${PREV_WATCHTOWER_COMMIT:0:12} → ${WATCHTOWER_COMMIT:0:12}"
        _fetch_and_indent_titles "${WATCHTOWER_REPO:-}" "${PREV_WATCHTOWER_COMMIT:-}" "${WATCHTOWER_COMMIT:-}"
        drift=1
    fi

    # Content (files baked into images). Self-compute — no network needed.
    local current_content_hash
    current_content_hash=$(compute_build_hash)
    if [[ -n "${PREV_CONTENT_HASH:-}" && "${PREV_CONTENT_HASH}" != "${current_content_hash}" ]]; then
        echo "  content: image source files changed"
        _summarize_content_drift
        drift=1
    fi

    return $drift
}

# Helper: fetch commit titles and indent them, or nothing on failure.
_fetch_and_indent_titles() {
    local repo="$1" from="$2" to="$3"
    [[ -z "$repo" || -z "$from" || -z "$to" ]] && return 0
    local titles
    if titles=$(fetch_commit_titles "$repo" "$from" "$to" 2>/dev/null); then
        echo "$titles" | sed 's/^/    /'
    fi
}

# Helper: diff PREV_CONTENT_FILES against current file hashes, list changed paths.
_summarize_content_drift() {
    local current_lines prev_paths=() prev_hashes=() path hash
    current_lines=$(compute_file_hashes_for \
        "${PROJECT_ROOT}/internal/Dockerfile" \
        "${PROJECT_ROOT}/internal/docker" \
        "${PROJECT_ROOT}/internal/scripts/parse-overrides.sh" 2>/dev/null) || return 0

    # Parse prev into parallel arrays
    local entry rest
    for entry in "${PREV_CONTENT_FILES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        # Format: "<hash>  <path>"
        hash="${entry%% *}"
        rest="${entry#* }"
        rest="${rest# }"  # strip leading space
        path="$rest"
        prev_hashes+=("$hash")
        prev_paths+=("$path")
    done

    # For each current file, compare against prev by path.
    local cur_hash cur_path idx match
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        cur_hash="${line%% *}"
        cur_path="${line#* }"
        cur_path="${cur_path# }"
        match=""
        idx=0
        for path in "${prev_paths[@]:-}"; do
            if [[ "$path" == "$cur_path" ]]; then
                match="${prev_hashes[$idx]}"
                break
            fi
            idx=$((idx + 1))
        done
        if [[ -z "$match" ]]; then
            echo "      + ${cur_path}"
        elif [[ "$match" != "$cur_hash" ]]; then
            echo "      ~ ${cur_path}"
        fi
    done <<< "$current_lines"

    # Removed files (in prev but not in current)
    local cur_paths_joined
    cur_paths_joined=$'\n'"$(echo "$current_lines" | awk '{$1=""; sub(/^ +/, ""); print}')"$'\n'
    idx=0
    for path in "${prev_paths[@]:-}"; do
        if ! grep -Fxq "$path" <<< "${cur_paths_joined}"; then
            echo "      - ${path}"
        fi
        idx=$((idx + 1))
    done
}
