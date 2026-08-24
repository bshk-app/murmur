#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly USAGE='usage: publish-cask.sh DMG SHORT_VERSION TAG'
readonly DMG="${1:?$USAGE}"
readonly SHORT_VERSION="${2:?$USAGE}"
readonly TAG="${3:?$USAGE}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/murmur}"
readonly TAP="${HOMEBREW_TAP:-bshk-app/homebrew-tap}"
readonly METADATA="${CASK_METADATA:-$ROOT/Distribution/cask-murmur.json}"

require_semver SHORT_VERSION "$SHORT_VERSION"
expected_tag="$(release_tag "$SHORT_VERSION" stable)"
[[ "$TAG" == "$expected_tag" ]] \
    || die "stable cask requires tag $expected_tag, got: $TAG"
require_zamokctl
[[ -f "$DMG" ]] || die "no DMG at $DMG"
[[ -f "$METADATA" ]] || die "no cask metadata at $METADATA"
[[ -n "${TAP_GITHUB_TOKEN:-}" ]] || die "TAP_GITHUB_TOKEN is required to write $TAP"
reject_unresolved TAP_GITHUB_TOKEN
if [[ "${TAP_WRITE_VERIFIED_REPOSITORY:-}" != "$TAP" ]]; then
    verify_github_repo_write "$TAP_GITHUB_TOKEN" "$TAP"
fi

manifest="$(find "$(dirname "$DMG")" -maxdepth 1 -type f -name manifest.json -print -quit)"
[[ -n "$manifest" ]] || die "no manifest.json beside $DMG; zamokctl package writes one"

env -u GH_TOKEN GITHUB_TOKEN="$TAP_GITHUB_TOKEN" zamokctl cask \
    --manifest "$manifest" \
    --store url \
    --url "https://github.com/${REPOSITORY}/releases/download/${TAG}/$(basename "$DMG")" \
    --tap "$TAP" \
    --metadata "$METADATA"

printf 'Cask: %s murmur %s\n' "$TAP" "$SHORT_VERSION"
