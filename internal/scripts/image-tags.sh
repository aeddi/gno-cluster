#!/usr/bin/env bash
# internal/scripts/image-tags.sh — Content-addressable Docker image tags.
#
# Source this file to use:
#   compute_build_hash_for <path>...
#       — echo an 8-char hash of the contents of the given files/dirs.
#         Deterministic: same inputs → same hash. Input-sensitive: any file
#         change, addition, or rename produces a different hash.
#   compute_build_hash
#       — wraps compute_build_hash_for with the project's image-build inputs
#         (Dockerfile, internal/docker/**, parse-overrides.sh). Requires
#         PROJECT_ROOT to be set.
#   compute_image_tag <target> <gno_commit> <wt_commit>
#       — echo the full tag for a target: "<commit12>-<content-hash>".
#         target ∈ {gnoland, watchtower, sentinel}.
#         gnoland uses gno_commit; watchtower/sentinel use wt_commit.
#
# Rationale: BUILD_DATE is deliberately excluded — it only appears in LABELs
# and changes per invocation, which would defeat the idempotency check.
set -euo pipefail

_IMAGE_TAGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_IMAGE_TAGS_DIR}/common.sh"

compute_file_hashes_for() {
  # Enumerate regular files under the given paths in stable order and emit
  # per-file sha256 lines ("<hash>  <path>"). Paths are always relative to
  # PROJECT_ROOT so the aggregate hash (and the .build-state snapshot) stay
  # stable if the project moves on disk. Callers pass paths relative to
  # PROJECT_ROOT (e.g. "internal/Dockerfile"), not absolute.
  #
  # xargs can't invoke bash functions, so pick the external sha256 tool once
  # and pass it directly. sha_cmd is deliberately unquoted in the xargs call
  # so "shasum -a 256" splits into command + flag.
  local sha_cmd
  if command -v sha256sum >/dev/null 2>&1; then
    sha_cmd="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    sha_cmd="shasum -a 256"
  else
    echo "Error: neither sha256sum nor shasum is installed." >&2
    return 1
  fi
  # shellcheck disable=SC2086
  (
    cd "$PROJECT_ROOT" &&
      find "$@" -type f -print0 |
      LC_ALL=C sort -z |
        xargs -0 $sha_cmd
  )
}

compute_build_hash_for() {
  # Short summary hash over the per-file hashes.
  compute_file_hashes_for "$@" |
    sha256_stdin |
    cut -c1-8
}

compute_build_hash() {
  compute_build_hash_for \
    "internal/Dockerfile" \
    "internal/docker" \
    "internal/scripts/parse-overrides.sh"
}

compute_image_tag() {
  local target="$1" gno_commit="$2" wt_commit="$3"
  local commit
  case "$target" in
  gnoland) commit="$gno_commit" ;;
  watchtower | sentinel) commit="$wt_commit" ;;
  *)
    echo "Error: unknown target '$target'" >&2
    return 1
    ;;
  esac
  local content
  content=$(compute_build_hash)
  echo "${commit:0:12}-${content}"
}
