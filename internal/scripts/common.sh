#!/usr/bin/env bash
# internal/scripts/common.sh — Cross-platform shell utilities.
#
# Source this before any module that needs portable sha256 hashing or
# silent HTTP fetching. Prefers the Linux-standard tools (sha256sum, curl)
# and falls back to macOS defaults (shasum, wget). Loud failure when no
# tool is available for sha256 (can't proceed); silent for http_get_silent
# (caller handles degradation).
set -euo pipefail

# sha256 of a file. Output: 64-char hex hash, no path.
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "Error: neither sha256sum nor shasum is installed." >&2
        return 1
    fi
}

# sha256 of stdin. Output: 64-char hex hash.
sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        echo "Error: neither sha256sum nor shasum is installed." >&2
        return 1
    fi
}

# sha256 of one or more files. Output: standard "<hash>  <path>" lines.
sha256_files() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        echo "Error: neither sha256sum nor shasum is installed." >&2
        return 1
    fi
}

# HTTP GET with silent failure (curl → wget → nothing). Designed for optional
# auto-fetches (like GitHub compare API) where we want to gracefully skip on
# any error: missing tool, network down, non-2xx response.
http_get_silent() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 5 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=5 "$url" 2>/dev/null
    else
        return 1
    fi
}

# Enforces a hard dependency on a command. Prints an install hint and returns
# non-zero when the tool is missing. Callers that can't proceed without the
# tool should propagate the return code.
require_tool() {
    local tool="$1" hint="${2:-}"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '${tool}' is required but not installed." >&2
        [[ -n "$hint" ]] && echo "  ${hint}" >&2
        return 1
    fi
}
