#!/bin/bash
# The iOS provider has a 230 MiB budget. Both iOS slices must include the
# patched CT2 loader, not just the shim that sets/reads CT2_MMAP_WEIGHTS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
status=0
for slice in ios-arm64 ios-arm64-simulator; do
  library="$ROOT/Engine/Translation/Artifacts/MurmurMT.xcframework/$slice/libmurmurmt.a"
  if ! strings "$library" | grep -F 'Mapped weights require a file-backed CPU INT8 model' >/dev/null; then
    echo "FAIL: $slice is missing the extension's mapped-weight loader" >&2
    status=1
  else
    echo "PASS: $slice contains the mapped-weight loader"
  fi
done
exit "$status"
