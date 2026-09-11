#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
swift build --package-path Engine/Core >/dev/null
core_bin=$(swift build --package-path Engine/Core --show-bin-path)
regression_bin=$(mktemp -d /tmp/murmur-import-check.XXXXXX)
trap 'rm -f "$regression_bin/check"; rmdir "$regression_bin"' EXIT
swiftc -I "$core_bin/Modules" "$core_bin"/MurmurCore.build/*.o Applications/iOS/Shared/AudioImportJob.swift Applications/iOS/Regression/CompletedImports.swift -o "$regression_bin/check"
"$regression_bin/check"
