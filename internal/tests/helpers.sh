#!/usr/bin/env bash
# internal/tests/helpers.sh — Minimal test assertion helpers.
set -euo pipefail

_PASS=0
_FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $name"
    ((_PASS++)) || true
  else
    echo "  FAIL: $name"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    ((_FAIL++)) || true
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $name"
    ((_PASS++)) || true
  else
    echo "  FAIL: $name"
    echo "    Expected to contain: $needle"
    echo "    In: $haystack"
    ((_FAIL++)) || true
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $name"
    ((_PASS++)) || true
  else
    echo "  FAIL: $name"
    echo "    Expected NOT to contain: $needle"
    echo "    In: $haystack"
    ((_FAIL++)) || true
  fi
}

assert_line_count() {
  local name="$1" expected="$2" actual_text="$3"
  local count
  if [[ -z "$actual_text" ]]; then
    count=0
  else
    count=$(echo "$actual_text" | wc -l | tr -d ' ')
  fi
  assert_eq "$name" "$expected" "$count"
}

summary() {
  echo "---"
  echo "$_PASS passed, $_FAIL failed"
  [[ $_FAIL -eq 0 ]]
}
