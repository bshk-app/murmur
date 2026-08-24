#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
[[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == "false" ]] || {
    printf 'Release build numbers require a full git history; this clone is shallow.\n' >&2
    exit 1
}
base="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER_BASE")"
count="$(git -C "$ROOT" rev-list --count HEAD)"
[[ "$base" =~ ^[0-9]+$ ]] \
    || { printf 'BUILD_NUMBER_BASE must be an integer.\n' >&2; exit 1; }
printf '%s\n' "$((base + count))"
