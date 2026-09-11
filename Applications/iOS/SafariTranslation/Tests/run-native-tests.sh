#!/bin/bash
set -euo pipefail
TASK_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_TEST_BIN="$(mktemp -d /tmp/murmator-native-tests.XXXXXX)"
trap 'rmdir "$TASK_TEST_BIN" 2>/dev/null || true' EXIT
xcrun swiftc "$TASK_TEST_DIR/../../Shared/SafariTranslationHandoff.swift" "$TASK_TEST_DIR/handoff-tests.swift" -o "$TASK_TEST_BIN/handoff-tests"
"$TASK_TEST_BIN/handoff-tests"
unlink "$TASK_TEST_BIN/handoff-tests"
