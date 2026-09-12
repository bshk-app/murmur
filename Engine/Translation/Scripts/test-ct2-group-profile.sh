#!/bin/bash
# Supply converted eng-zle group weights with source/target SentencePiece files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
xcrun clang++ -std=c++17 -mmacosx-version-min=15.0 \
  -I "$ROOT/MurmurKit/Sources/CBergamot/include" \
  "$ROOT/Engine/Translation/Tests/ct2-group-profile-smoke.cpp" \
  "$ROOT/Engine/Translation/Artifacts/MurmurMT.xcframework/macos-arm64/libmurmurmt.a" \
  -framework Accelerate -liconv -L/opt/homebrew/lib -lpcre2-8 -o "$WORK/smoke"
"$WORK/smoke" "$@"
