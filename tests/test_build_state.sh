#!/usr/bin/env bash
# tests/test_build_state.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# build-state.sh sources image-tags.sh (for compute_*), which expects PROJECT_ROOT.
PROJECT_ROOT=$(mktemp -d)
trap 'rm -rf "$PROJECT_ROOT"' EXIT
mkdir -p "$PROJECT_ROOT/internal/docker" "$PROJECT_ROOT/internal/scripts"
echo "FROM alpine:3" > "$PROJECT_ROOT/internal/Dockerfile"
echo "#!/bin/sh" > "$PROJECT_ROOT/internal/docker/gnoland-entrypoint.sh"
echo "#!/bin/sh" > "$PROJECT_ROOT/internal/scripts/parse-overrides.sh"
export PROJECT_ROOT

source "$SCRIPT_DIR/../internal/scripts/build-state.sh"

echo "=== build-state.sh ==="

# ---- write_build_state + read_build_state_as_prev roundtrip
echo "-- write/read roundtrip --"

export GNO_REPO="gnolang/gno"
export GNO_VERSION="master"
export GNO_COMMIT="26dc377ab634abcdef1234567890abcdef"
export WATCHTOWER_REPO="aeddi/gno-watchtower"
export WATCHTOWER_VERSION="main"
export WATCHTOWER_COMMIT="d98609f4ecdaabcdef1234567890abcdef"

STATE=$(mktemp)
write_build_state "$STATE"

# File should be sourceable
[[ -s "$STATE" ]]
assert_eq "state file non-empty" "0" "$?"

grep -q "^GNO_REPO=" "$STATE"
assert_eq "contains GNO_REPO" "0" "$?"

grep -q "^CONTENT_HASH=" "$STATE"
assert_eq "contains CONTENT_HASH" "0" "$?"

grep -q "^CONTENT_FILES=(" "$STATE"
assert_eq "contains CONTENT_FILES array" "0" "$?"

# Read via read_build_state_as_prev + eval
out=$(read_build_state_as_prev "$STATE")
eval "$out"

assert_eq "PREV_GNO_REPO roundtrip" "gnolang/gno" "$PREV_GNO_REPO"
assert_eq "PREV_GNO_VERSION roundtrip" "master" "$PREV_GNO_VERSION"
assert_eq "PREV_GNO_COMMIT roundtrip" "26dc377ab634abcdef1234567890abcdef" "$PREV_GNO_COMMIT"
assert_eq "PREV_WATCHTOWER_COMMIT roundtrip" "d98609f4ecdaabcdef1234567890abcdef" "$PREV_WATCHTOWER_COMMIT"
[[ "${#PREV_CONTENT_FILES[@]}" -ge 3 ]]
assert_eq "PREV_CONTENT_FILES is array with content" "0" "$?"

rm -f "$STATE"

# Missing file
set +e
out=$(read_build_state_as_prev "/nonexistent/path")
code=$?
set -e
assert_eq "read missing file returns non-zero" "1" "$code"

# ---- build_state_drift_summary: no drift when PREV matches current
echo "-- drift detection --"

PREV_GNO_REPO="$GNO_REPO"
PREV_GNO_VERSION="$GNO_VERSION"
PREV_GNO_COMMIT="$GNO_COMMIT"
PREV_WATCHTOWER_REPO="$WATCHTOWER_REPO"
PREV_WATCHTOWER_VERSION="$WATCHTOWER_VERSION"
PREV_WATCHTOWER_COMMIT="$WATCHTOWER_COMMIT"
PREV_CONTENT_HASH=$(compute_build_hash)
PREV_CONTENT_FILES=()
while IFS= read -r l; do PREV_CONTENT_FILES+=("$l"); done < <(compute_file_hashes_for \
    "internal/Dockerfile" \
    "internal/docker" \
    "internal/scripts/parse-overrides.sh")

set +e
summary=$(build_state_drift_summary)
code=$?
set -e
assert_eq "no drift returns 0" "0" "$code"
assert_eq "no drift prints nothing" "" "$summary"

# ---- Drift: gno commit changed (same repo, same ref)
PREV_GNO_COMMIT="0000000000000000000000000000000000"  # different
set +e
summary=$(build_state_drift_summary 2>&1)
code=$?
set -e
assert_eq "commit drift returns 1" "1" "$code"
# The summary should mention gno and the two commit short hashes.
case "$summary" in
    *"gno"*"000000000000"*"26dc377ab634"*) ok=1 ;;
    *) ok=0 ;;
esac
assert_eq "commit drift summary mentions both SHAs" "1" "$ok"

# ---- Drift: gno ref changed
PREV_GNO_COMMIT="$GNO_COMMIT"
PREV_GNO_VERSION="v0.1.0"
set +e
summary=$(build_state_drift_summary 2>&1)
code=$?
set -e
assert_eq "ref drift returns 1" "1" "$code"
case "$summary" in
    *"v0.1.0"*"master"*) ok=1 ;;
    *) ok=0 ;;
esac
assert_eq "ref drift summary mentions old and new ref" "1" "$ok"

# ---- Drift: gno repo changed
PREV_GNO_VERSION="$GNO_VERSION"
PREV_GNO_REPO="some-fork/gno"
set +e
summary=$(build_state_drift_summary 2>&1)
code=$?
set -e
assert_eq "repo drift returns 1" "1" "$code"
case "$summary" in
    *"some-fork/gno"*"gnolang/gno"*) ok=1 ;;
    *) ok=0 ;;
esac
assert_eq "repo drift summary mentions old and new repo" "1" "$ok"

# ---- Drift: content files changed
PREV_GNO_REPO="$GNO_REPO"
PREV_CONTENT_HASH="00000000"
set +e
summary=$(build_state_drift_summary 2>&1)
code=$?
set -e
assert_eq "content drift returns 1" "1" "$code"
case "$summary" in
    *[Cc]"ontent"*) ok=1 ;;
    *) ok=0 ;;
esac
assert_eq "content drift summary mentions content" "1" "$ok"

summary
