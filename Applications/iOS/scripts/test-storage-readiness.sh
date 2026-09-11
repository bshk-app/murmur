#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
regression_dir=$(mktemp -d /tmp/murmator-readiness.XXXXXX)
trap 'rm -f "$regression_dir/check"; rmdir "$regression_dir"' EXIT
swiftc Applications/iOS/Shared/LanguageLibrary.swift Applications/iOS/Regression/StorageReadiness.swift -o "$regression_dir/check"
"$regression_dir/check"
