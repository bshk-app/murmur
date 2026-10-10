#!/bin/bash
# Checks that truncated or altered model downloads are caught before they load.
# Optional arguments: real .safetensors files to report as complete or INCOMPLETE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -parse-as-library -O -target arm64-apple-macos15.0 \
  "$ROOT/Engine/Speech/Sources/MurmurSpeech/PinnedAsset.swift" \
  "$ROOT/Engine/Speech/Vendor/mlx-audio-swift/Sources/MLXAudioCore/SafetensorsIntegrity.swift" \
  "$ROOT/Engine/Speech/Tests/ModelIntegrity/ModelIntegrityChecks.swift" \
  -o "$WORK/checks"
"$WORK/checks" "$@"
