#!/usr/bin/env bash
# tests/test_image_tags.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

source "$SCRIPT_DIR/../internal/scripts/image-tags.sh"

echo "=== image-tags.sh ==="

# ---- compute_build_hash_for
echo "-- compute_build_hash_for --"

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

mkdir -p "$FIX/a" "$FIX/b"
echo "alpha" > "$FIX/a/one.txt"
echo "beta" > "$FIX/a/two.txt"
echo "gamma" > "$FIX/b/three.txt"

hash1=$(compute_build_hash_for "$FIX/a" "$FIX/b")

# Same inputs → same hash
hash2=$(compute_build_hash_for "$FIX/a" "$FIX/b")
assert_eq "deterministic" "$hash1" "$hash2"

# Change a file → different hash
echo "changed" > "$FIX/a/one.txt"
hash3=$(compute_build_hash_for "$FIX/a" "$FIX/b")
[[ "$hash3" != "$hash1" ]]
assert_eq "sensitive to file content" "0" "$?"

# Revert → original hash
echo "alpha" > "$FIX/a/one.txt"
hash4=$(compute_build_hash_for "$FIX/a" "$FIX/b")
assert_eq "reverting restores hash" "$hash1" "$hash4"

# Add a file → different hash
echo "delta" > "$FIX/a/four.txt"
hash5=$(compute_build_hash_for "$FIX/a" "$FIX/b")
[[ "$hash5" != "$hash1" ]]
assert_eq "sensitive to new files" "0" "$?"
rm "$FIX/a/four.txt"

# Hash is 8 hex chars
hash_len=${#hash1}
assert_eq "hash length 8" "8" "$hash_len"
[[ "$hash1" =~ ^[0-9a-f]{8}$ ]]
assert_eq "hash is hex" "0" "$?"

# ---- compute_image_tag
echo "-- compute_image_tag --"

# Override PROJECT_ROOT so compute_image_tag's internal call to compute_build_hash is stable.
PROJECT_ROOT="$FIX"
mkdir -p "$FIX/internal/docker" "$FIX/internal/scripts"
echo "FROM alpine:3" > "$FIX/internal/Dockerfile"
echo "echo hi" > "$FIX/internal/docker/gnoland-entrypoint.sh"
echo "echo hi" > "$FIX/internal/scripts/parse-overrides.sh"

GNO_COMMIT="abc123def456789fedcba98765"
WT_COMMIT="deadbeef000000000000000000"

gnoland_tag=$(compute_image_tag gnoland "$GNO_COMMIT" "$WT_COMMIT")
watchtower_tag=$(compute_image_tag watchtower "$GNO_COMMIT" "$WT_COMMIT")
sentinel_tag=$(compute_image_tag sentinel "$GNO_COMMIT" "$WT_COMMIT")

# Tag format: <commit12>-<content8>
[[ "$gnoland_tag" =~ ^abc123def456-[0-9a-f]{8}$ ]]
assert_eq "gnoland tag format" "0" "$?"

# gnoland uses gno commit
[[ "$gnoland_tag" == abc123def456-* ]]
assert_eq "gnoland uses gno commit" "0" "$?"

# watchtower uses wt commit
[[ "$watchtower_tag" == deadbeef0000-* ]]
assert_eq "watchtower uses wt commit" "0" "$?"

# sentinel also uses wt commit (same builder stage)
[[ "$sentinel_tag" == deadbeef0000-* ]]
assert_eq "sentinel uses wt commit" "0" "$?"

# All three share the same content-hash suffix (same source tree)
assert_eq "gnoland/watchtower share content hash" \
    "${gnoland_tag##*-}" "${watchtower_tag##*-}"
assert_eq "watchtower/sentinel share content hash" \
    "${watchtower_tag##*-}" "${sentinel_tag##*-}"

# Unknown target errors
set +e
err_out=$(compute_image_tag unknown "$GNO_COMMIT" "$WT_COMMIT" 2>&1)
err_code=$?
set -e
assert_eq "unknown target exits non-zero" "1" "$err_code"

summary
