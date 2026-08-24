#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly USAGE='usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT'
readonly ARTIFACT="${1:?$USAGE}"
readonly NOTES="${2:?$USAGE}"
readonly SHORT_VERSION="${3:?$USAGE}"
readonly BUILD_NUMBER="${4:?$USAGE}"
CHANNEL="$(printf '%s' "${5:?$USAGE}" | tr '[:upper:]' '[:lower:]')"
readonly CHANNEL
readonly PUBLISH_MODE="${6:?$USAGE}"
readonly OUTPUT="${7:?$USAGE}"

case "$PUBLISH_MODE" in
    0|1) ;;
    *) printf 'PUBLISH must be 0 or 1, got: %s\n' "$PUBLISH_MODE" >&2; exit 2 ;;
esac
[[ -f "$ARTIFACT" ]] || { printf 'Artifact is missing: %s\n' "$ARTIFACT" >&2; exit 1; }
[[ -f "$NOTES" ]] || { printf 'Notes are missing: %s\n' "$NOTES" >&2; exit 1; }

artifact_sha="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
notes_sha="$(shasum -a 256 "$NOTES" | cut -d' ' -f1)"

cat > "$OUTPUT" <<MANIFEST
commit=$(git -C "$ROOT" rev-parse HEAD)
version=$SHORT_VERSION
build=$BUILD_NUMBER
channel=$CHANNEL
publish=$PUBLISH_MODE
artifact=$(basename "$ARTIFACT")
artifact_sha256=$artifact_sha
notes_sha256=$notes_sha
MANIFEST
