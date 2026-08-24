#!/usr/bin/env bash
set -euo pipefail

# Export the configured Sparkle private key to one caller-owned 0600 file and
# prove its public half matches SUPublicEDKey before any release mutation.

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly OUTPUT="${1:?usage: export-sparkle-key.sh OUTPUT}"
# Sparkle stores the key under the account chosen at generate_keys time
# ("ed25519" by default). Only override when the key was made with --account.
readonly KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-}"

require_env SPARKLE_PUBLIC_ED_KEY
reject_unresolved SPARKLE_PRIVATE_ED_KEY
rm -f "$OUTPUT"

if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    (umask 077; printf '%s' "$SPARKLE_PRIVATE_ED_KEY" > "$OUTPUT")
else
    generate_keys="$(
        for caskroom in /opt/homebrew/Caskroom/sparkle /usr/local/Caskroom/sparkle; do
            [[ -d "$caskroom" ]] || continue
            find "$caskroom" -maxdepth 3 -name generate_keys -type f -print
        done | sort -V | tail -1
    )"
    [[ -n "$generate_keys" ]] \
        || die "no SPARKLE_PRIVATE_ED_KEY and no generate_keys; install the Sparkle tools"
    account_args=()
    [[ -n "$KEYCHAIN_ACCOUNT" ]] && account_args=(--account "$KEYCHAIN_ACCOUNT")
    (umask 077; "$generate_keys" "${account_args[@]}" -x "$OUTPUT" >/dev/null) \
        || die "could not export the Sparkle key${KEYCHAIN_ACCOUNT:+ for account $KEYCHAIN_ACCOUNT}"
fi

[[ -s "$OUTPUT" ]] || die "the Sparkle private key is empty"
chmod 600 "$OUTPUT"
derived_public="$("${ROOT}/scripts/sparkle-public-key.swift" "$OUTPUT")" \
    || die "could not derive the Sparkle public key"
[[ "$derived_public" == "$SPARKLE_PUBLIC_ED_KEY" ]] \
    || die "Sparkle private key does not match Murmur.app SUPublicEDKey"
