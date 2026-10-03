#!/bin/bash
# Rebuild just the CT2 half, preserving Bergamot and platform-specific objects.
# Requires prebuilt CT2 dependencies from the original artifact build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SHIM="$ROOT/MurmurKit/Sources/CBergamot"
CT2_SOURCE="${CT2_SOURCE:-/Volumes/DATA/ctranslate2-arm64}"
BERG_SOURCE="${BERG_SOURCE:-/Volumes/DATA/bergamot-arm64/src}"
IOS_BUILD="${IOS_BUILD:-$ROOT/Prototypes/iOS/build}"
PATCH_HASH="$(shasum -a 256 "$ROOT/Engine/Translation/Patches/ct2-mapped-weights.patch" | cut -c 1-12)"
ARTIFACT="$ROOT/Engine/Translation/Artifacts/MurmurMT.xcframework"
WORK="$(mktemp -d)"
for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  case "$slice" in
    macos-arm64) sdk=macosx; target=arm64-apple-macos15.0; platform=macos; minimum=15.0; build="${CT2_MAC_BUILD:-$CT2_SOURCE/build}";;
    ios-arm64) sdk=iphoneos; target=arm64-apple-ios18.0; platform=ios; minimum=18.0; build="${CT2_IOS_BUILD:-$IOS_BUILD/ct2-device-$PATCH_HASH}";;
    ios-arm64-simulator) sdk=iphonesimulator; target=arm64-apple-ios18.0-simulator; platform=ios-simulator; minimum=18.0; build="${CT2_SIM_BUILD:-$IOS_BUILD/ct2-full-simulator-$PATCH_HASH}";;
  esac
  # Reject stale, unpatched caches before replacing any published slice. The
  # shim's CT2_MMAP_WEIGHTS string alone does not prove the loader supports it.
  if [[ "$platform" != macos ]] && ! strings "$build/libctranslate2.a" | grep -F 'Mapped weights require a file-backed CPU INT8 model' >/dev/null; then
    echo "Missing mapped-weight loader in $build. Rebuild the patched iOS CT2 dependencies first." >&2
    exit 1
  fi
  mkdir -p "$WORK/$slice"
  xcrun --sdk "$sdk" clang++ -std=c++17 -O2 -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -w -c \
    "$SHIM/murmur_ct2.cpp" -o "$WORK/$slice/murmur_ct2.o" \
    -D_USE_INTERNAL_STRING_VIEW -I"$SHIM/include" -I"$CT2_SOURCE/include" \
    -I"$BERG_SOURCE/3rd_party/marian-dev/src/3rd_party/sentencepiece/src" \
    -I"$BERG_SOURCE/3rd_party/marian-dev/src/3rd_party/sentencepiece"
  cat > "$WORK/exports.txt" <<'EXPORTS'
_murmur_ct2_open
_murmur_ct2_open_with_options
_murmur_ct2_translate
_murmur_ct2_translate_with_options
_murmur_ct2_close
_murmur_ct2_string_free
EXPORTS
  libs=()
  while IFS= read -r file; do libs+=("$file"); done < <(find "$build/third_party" -name '*.a')
  xcrun ld -r -arch arm64 -platform_version "$platform" "$minimum" \
    "$(xcrun --sdk "$sdk" --show-sdk-version)" -all_load \
    -exported_symbols_list "$WORK/exports.txt" -o "$WORK/$slice/ct2_all.o" \
    "$WORK/$slice/murmur_ct2.o" "$build/libctranslate2.a" "${libs[@]}"
  if nm -gU "$WORK/$slice/ct2_all.o" | grep spdlog; then exit 1; fi
  cp "$ARTIFACT/$slice/libmurmurmt.a" "$WORK/$slice/libmurmurmt.a"
  ar -r "$WORK/$slice/libmurmurmt.a" "$WORK/$slice/ct2_all.o"
  ranlib "$WORK/$slice/libmurmurmt.a"
done
# Install only once all three platform builds succeeded.
for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  cp "$WORK/$slice/libmurmurmt.a" "$ARTIFACT/$slice/libmurmurmt.a"
  cp "$SHIM/include/murmur_ct2.h" "$ARTIFACT/$slice/Headers/murmur_ct2.h"
done
printf 'Native shim rebuilt for all slices. Build evidence: %s\n' "$WORK"
