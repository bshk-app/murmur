#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
xcrun swiftc -parse-as-library -O -target arm64-apple-macos15.0 \
  "$ROOT"/Engine/Speech/Sources/MurmurSpeech/CanaryQualification/*.swift \
  "$ROOT/Engine/Speech/Tests/CanaryQualification/QualificationChecks.swift" \
  -o "$WORK/checks"
"$WORK/checks" "$@"
