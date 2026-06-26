#!/usr/bin/env bash
#
# Murmur — local de-risk of Developer ID signing + notarization (plan §8 step 1).
#
# Mirrors what the CI reusable workflow (zamok/ci) will do — build unsigned, then
# zamokctl signs (Developer ID + Hardened Runtime + entitlements), notarizes, staples,
# and zips — but on THIS machine, so an MLX-under-Hardened-Runtime / library-validation
# failure surfaces BEFORE any Gitea org / secrets / runner plumbing exists.
#
# If this passes, nothing downstream is blocked. If it fails, fix entitlements here.
#
# ── One-time prerequisite ────────────────────────────────────────────────────────────
# Store App Store Connect API creds in the keychain as a notarytool profile (interactive
# — it prompts for anything you omit):
#
#   xcrun notarytool store-credentials murmur-notary \
#     --key   ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
#     --key-id <KEYID> \
#     --issuer <ISSUER-UUID>
#
#   • <KEYID>      = the AuthKey_<KEYID>.p8 filename (you have AuthKey_38V7FDZ48J.p8 and
#                    AuthKey_W8TB6AATXS.p8 — use whichever belongs to team Q8H6GWJ658).
#   • <ISSUER-UUID>= App Store Connect → Users and Access → Integrations →
#                    App Store Connect API → Issuer ID (the same one the Zamok pipeline uses).
#
# Then just: Distribution/derisk-sign-notarize.sh
# Override the profile name with: NOTARY_PROFILE=other-name Distribution/derisk-sign-notarize.sh
# ──────────────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

NOTARY_PROFILE="${NOTARY_PROFILE:-murmur-notary}"
SCHEME="Murmur"
WORKSPACE="Murmur.xcworkspace"
DD="$PWD/build/derisk-dd"      # dedicated DerivedData — does NOT clobber your `make run` build
OUT="$PWD/build/derisk-dist"

# 1. Developer ID Application identity (Team Q8H6GWJ658).
SHA1="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
[ -n "$SHA1" ] || { echo "✗ no 'Developer ID Application' identity in the keychain" >&2; exit 1; }
echo "→ Developer ID Application: $SHA1"

# 2. notarytool profile must exist (fail early with a helpful message).
#    NB: notarytool's flag is --keychain-profile; zamokctl's is --notary-profile (below).
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool profile '$NOTARY_PROFILE' not found — run the store-credentials command in this file's header first." >&2
  exit 1
fi

# 3. Generate the Xcode project/workspace from the Tuist SSOT.
echo "→ tuist generate"
tuist generate --no-open

# 4. Build Release UNSIGNED (CODE_SIGNING_ALLOWED=NO) so zamokctl re-signs the whole tree
#    with Developer ID — same flags as `make build` (arm64-only, no explicit modules).
echo "→ build Release (unsigned — mirrors CI; this is the heavy MLX build)"
rm -rf "$DD"
tuist xcodebuild build -workspace "$WORKSPACE" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  CODE_SIGNING_ALLOWED=NO

APP="$DD/Build/Products/Release/$SCHEME.app"
[ -d "$APP" ] || { echo "✗ build produced no $APP" >&2; exit 1; }

# 5. Sign (Developer ID + Hardened Runtime + entitlements) → notarize → staple → zip.
echo "→ zamokctl package: sign + notarize + staple + zip (notarization uploads to Apple — may take minutes)"
rm -rf "$OUT"; mkdir -p "$OUT"
zamokctl package --input "$APP" --output-dir "$OUT" --format zip \
  --signing-identity-sha1 "$SHA1" \
  --entitlements Murmur.entitlements \
  --notary-profile "$NOTARY_PROFILE"

# 6. Verify the ACTUAL packaged artifact (what a user downloads), not the in-place build.
echo "→ verify the packaged zip"
ZIP="$(find "$OUT" -name '*.zip' | head -1)"
[ -n "$ZIP" ] || { echo "✗ no zip produced in $OUT" >&2; exit 1; }
VDIR="$OUT/verify"; rm -rf "$VDIR"; mkdir -p "$VDIR"
ditto -x -k "$ZIP" "$VDIR"
VAPP="$(find "$VDIR" -maxdepth 2 -name '*.app' | head -1)"
[ -n "$VAPP" ] || { echo "✗ no .app inside $ZIP" >&2; exit 1; }

echo "─── codesign ───"
codesign -dv --verbose=4 "$VAPP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature|Runtime|flags" || true
echo "─── codesign --verify (deep, strict) ───"
codesign --verify --deep --strict --verbose=2 "$VAPP" 2>&1 || echo "  ↑ FAILED — inspect which nested binary"
echo "─── spctl (Gatekeeper assessment) ───"
spctl -a -vvv "$VAPP" 2>&1 || true
echo "─── stapler ───"
xcrun stapler validate "$VAPP" 2>&1 || true

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
✓ de-risk finished. PASS criteria (read the blocks above):
  • spctl:   "accepted" + "source=Notarized Developer ID"
  • codesign: Authority chain ends at "Apple Root CA", TeamIdentifier=Q8H6GWJ658,
              flags include "runtime"
  • stapler: "The validate action worked!"

If codesign --verify or notarization FAILED on library validation (a Cmlx /
mlx-swift dylib), add this to Murmur.entitlements (plan §5.1) and rerun:
  <key>com.apple.security.cs.disable-library-validation</key><true/>
────────────────────────────────────────────────────────────────────────────
EOF
