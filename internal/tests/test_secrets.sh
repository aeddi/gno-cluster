#!/usr/bin/env bash
# internal/tests/test_secrets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== secrets command ==="

# A wiring test, not a behaviour test. cmd_secrets is five lines of
# orchestration over resolve_commits, cmd_build and _ensure_node_secrets, and
# running it needs Docker and builds images, which no test here does. So these
# assertions cover the parts that silently disappear in a refactor -- the
# dispatch entry, the function, the target -- and would still pass if the body
# were emptied. The behaviour is covered by running the command.
CLUSTER_SH="$SCRIPT_DIR/../scripts/cluster.sh"
MAKEFILE="$SCRIPT_DIR/../../Makefile"

DISPATCH=$(grep -c '^secrets) cmd_secrets' "$CLUSTER_SH" || true)
assert_eq "dispatch handles 'secrets'" "1" "$DISPATCH"

DEFINED=$(grep -c '^cmd_secrets()' "$CLUSTER_SH" || true)
assert_eq "cmd_secrets is defined" "1" "$DEFINED"

USAGE=$(grep -c 'build|create|secrets' "$CLUSTER_SH" || true)
assert_eq "usage string lists secrets" "1" "$USAGE"

MAKE_TARGET=$(grep -c '^secrets:' "$MAKEFILE" || true)
assert_eq "Makefile exposes a secrets target" "1" "$MAKE_TARGET"

MAKE_PHONY=$(grep -c '^\.PHONY:.* secrets' "$MAKEFILE" || true)
assert_eq "secrets is .PHONY" "1" "$MAKE_PHONY"

summary
