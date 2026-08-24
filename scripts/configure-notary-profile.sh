#!/usr/bin/env bash
set -euo pipefail

readonly PROFILE="${RELEASE_NOTARY_PROFILE:-Murmur}"

require_env() {
    [[ -n "${!1:-}" ]] || {
        printf '%s is not set. Run through AgentVault profile notarize.\n' "$1" >&2
        exit 1
    }
}

command -v xcrun >/dev/null 2>&1 || { printf 'xcrun is required.\n' >&2; exit 1; }
require_env NOTARY_APPLE_ID
require_env NOTARY_PASSWORD
require_env NOTARY_TEAM_ID

xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$NOTARY_TEAM_ID"

xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null
printf 'Notary profile %s is stored and accepted by Apple.\n' "$PROFILE"
