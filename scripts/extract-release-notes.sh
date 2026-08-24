#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="${1:?usage: extract-release-notes.sh VERSION [CHANGELOG]}"
readonly CHANGELOG="${2:-CHANGELOG.md}"

awk -v ver="$VERSION" '
    $0 ~ "^## \\[" ver "\\]" { grab = 1; next }
    grab && /^## /                  { exit }
    grab && /^\[[^]]+\]:/          { exit }
    grab                            { print }
' "$CHANGELOG" | sed -e '/./,$!d'
