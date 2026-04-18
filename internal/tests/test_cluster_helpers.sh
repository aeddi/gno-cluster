#!/usr/bin/env bash
# internal/tests/test_cluster_helpers.sh — Unit tests for pure helpers in cluster.sh.
#
# cluster.sh is designed to be run, not sourced; sourcing it top-to-bottom would
# invoke the dispatch block. Instead, extract just the helpers we want to test
# by sourcing a filtered view that stops before the dispatch section.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

CLUSTER_SH="$SCRIPT_DIR/../scripts/cluster.sh"

# Filter cluster.sh to make it sourceable in tests:
#   1. stop before the dispatch block (which would eagerly parse argv)
#   2. strip `set -euo pipefail` (tests manage their own options)
#   3. strip the SCRIPT_DIR reassignment (cluster.sh uses $0 since it's an
#      entry-point script; in a sourced context $0 is the test file's path,
#      which breaks the subsequent `source "${SCRIPT_DIR}/..."` lines)
FILTERED=$(mktemp)

# cluster.sh sources sibling modules by path and cd's to PROJECT_ROOT. Mirror
# the layout in a temp dir so those source lines succeed.
PROJECT_ROOT_TMP=$(mktemp -d)
FAKE_HEIGHT_RUN=""
EMPTY_RUN=""
_cleanup() { rm -rf "$PROJECT_ROOT_TMP" "$FILTERED" "${FAKE_HEIGHT_RUN:-}" "${EMPTY_RUN:-}"; }
trap _cleanup EXIT
mkdir -p "$PROJECT_ROOT_TMP/internal/scripts"
# Sanity check: `*.sh` glob must match at least one file.
shopt -s nullglob
scripts=( "$SCRIPT_DIR/../scripts/"*.sh )
shopt -u nullglob
if ((${#scripts[@]} == 0)); then
    echo "FAIL: no .sh files found in $SCRIPT_DIR/../scripts/" >&2
    exit 1
fi
cp "${scripts[@]}" "$PROJECT_ROOT_TMP/internal/scripts/"
export PROJECT_ROOT="$PROJECT_ROOT_TMP"
cd "$PROJECT_ROOT"

# Guard: the filter relies on the `# ---- Dispatch` marker to stop sourcing
# before cluster.sh's argv parser. If that marker is renamed or removed the
# awk becomes a no-op and sourcing would execute dispatch at load time.
if ! grep -qx '# ---- Dispatch' "$CLUSTER_SH"; then
    echo "FAIL: expected '# ---- Dispatch' marker in cluster.sh — filter in this test would break." >&2
    exit 1
fi

awk '/^# ---- Dispatch$/{exit} {print}' "$CLUSTER_SH" \
    | grep -Ev '^set -euo pipefail$|^SCRIPT_DIR=' > "$FILTERED"

# Point SCRIPT_DIR at the copied scripts so relative source lines resolve.
SCRIPT_DIR_SAVE="$SCRIPT_DIR"
SCRIPT_DIR="${PROJECT_ROOT}/internal/scripts"
# shellcheck disable=SC1090
source "$FILTERED"
SCRIPT_DIR="$SCRIPT_DIR_SAVE"

echo "=== cluster.sh helpers ==="

# ---- _node_secrets_path
echo "-- _node_secrets_path --"

# With empty run_dir: uses project-root secrets layout.
result=$(_node_secrets_path 1 "")
assert_eq "project layout: node-1" "${PROJECT_ROOT}/internal/secrets/node-1" "$result"

result=$(_node_secrets_path 3 "")
assert_eq "project layout: node-3" "${PROJECT_ROOT}/internal/secrets/node-3" "$result"

# With run_dir: uses the run's pinned secrets layout.
FAKE_RUN="/some/runs/2026-01-01_12-00-00_foo"
result=$(_node_secrets_path 1 "$FAKE_RUN")
assert_eq "run layout: node-1" "${FAKE_RUN}/gnoland-data-1/secrets" "$result"

result=$(_node_secrets_path 4 "$FAKE_RUN")
assert_eq "run layout: node-4" "${FAKE_RUN}/gnoland-data-4/secrets" "$result"

# Default arg (no second arg) == empty string.
result=$(_node_secrets_path 2)
assert_eq "no run_dir arg: defaults to project layout" \
    "${PROJECT_ROOT}/internal/secrets/node-2" "$result"

# ---- resolve_run_arg
echo "-- resolve_run_arg --"

# Canonicalize PROJECT_ROOT to match resolve_run_arg's `pwd -P` output
# (macOS /var/folders -> /private/var/folders symlink).
CANONICAL_ROOT=$(cd "$PROJECT_ROOT" && pwd -P)

# Bare name under $PROJECT_ROOT/runs/.
mkdir -p "${PROJECT_ROOT}/runs/some-run"
result=$(resolve_run_arg "some-run")
assert_eq "bare name resolves under runs/" "${CANONICAL_ROOT}/runs/some-run" "$result"

# Relative path with /.
result=$(resolve_run_arg "runs/some-run")
assert_eq "relative path resolves from PROJECT_ROOT" "${CANONICAL_ROOT}/runs/some-run" "$result"

# Absolute path.
result=$(resolve_run_arg "${PROJECT_ROOT}/runs/some-run")
assert_eq "absolute path used as-is" "${CANONICAL_ROOT}/runs/some-run" "$result"

# Missing: returns non-zero, prints error to stderr.
set +e
err=$(resolve_run_arg "nonexistent-run" 2>&1 >/dev/null)
code=$?
set -e
assert_eq "missing run returns 1" "1" "$code"
assert_contains "missing run error mentions name" "nonexistent-run" "$err"

# ---- _last_block_height
echo "-- _last_block_height --"

# Build a fake run dir with two nodes at different heights.
FAKE_HEIGHT_RUN=$(mktemp -d)

mkdir -p "${FAKE_HEIGHT_RUN}/gnoland-data-1/secrets"
mkdir -p "${FAKE_HEIGHT_RUN}/gnoland-data-2/secrets"
printf '{"height": "0",  "round": "0", "step": 0}\n' \
    > "${FAKE_HEIGHT_RUN}/gnoland-data-1/secrets/priv_validator_state.json"
printf '{"height": "500","round": "0", "step": 0}\n' \
    > "${FAKE_HEIGHT_RUN}/gnoland-data-2/secrets/priv_validator_state.json"

result=$(_last_block_height "$FAKE_HEIGHT_RUN")
assert_eq "returns max height across nodes" "500" "$result"

# Node-1 advances; node-2 stays — max should follow.
printf '{"height": "999","round": "0", "step": 0}\n' \
    > "${FAKE_HEIGHT_RUN}/gnoland-data-1/secrets/priv_validator_state.json"
result=$(_last_block_height "$FAKE_HEIGHT_RUN")
assert_eq "returns new max when node-1 advances" "999" "$result"

# Run dir with no state files returns "-".
EMPTY_RUN=$(mktemp -d)
result=$(_last_block_height "$EMPTY_RUN")
assert_eq "empty run dir returns -" "-" "$result"

summary
