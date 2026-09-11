#!/bin/bash
set -euo pipefail
TASK_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_REPO_DIR="$(cd "$TASK_TEST_DIR/../../../.." && pwd)"
TASK_TEST_BIN="$(mktemp -d /tmp/murmator-coordinator-tests.XXXXXX)"
cp "$TASK_TEST_DIR/engine-stub.swift.fixture" "$TASK_TEST_BIN/engine-stub.swift"
xcrun swiftc -emit-library -emit-module -module-name MurmurCore "$TASK_REPO_DIR/Engine/Core/Sources/MurmurCore/LanguagePair.swift" "$TASK_REPO_DIR/Engine/Core/Sources/MurmurCore/PageTranslation.swift" "$TASK_REPO_DIR/Engine/Core/Sources/MurmurCore/TextTranslation.swift" -o "$TASK_TEST_BIN/libMurmurCore.dylib" -emit-module-path "$TASK_TEST_BIN/MurmurCore.swiftmodule"
xcrun swiftc -emit-library -emit-module -module-name MurmurTranslation -I "$TASK_TEST_BIN" -L "$TASK_TEST_BIN" -lMurmurCore "$TASK_TEST_BIN/engine-stub.swift" -o "$TASK_TEST_BIN/libMurmurTranslation.dylib" -emit-module-path "$TASK_TEST_BIN/MurmurTranslation.swiftmodule"
xcrun swiftc -I "$TASK_TEST_BIN" -L "$TASK_TEST_BIN" -lMurmurCore -lMurmurTranslation "$TASK_TEST_DIR/../SafariWebExtensionHandler.swift" "$TASK_TEST_DIR/coordinator-tests.swift" -o "$TASK_TEST_BIN/coordinator-tests"
DYLD_LIBRARY_PATH="$TASK_TEST_BIN" "$TASK_TEST_BIN/coordinator-tests"
