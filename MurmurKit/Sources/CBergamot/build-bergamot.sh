#!/usr/bin/env bash
# Build the bergamot-translator engine plus the C shim into one static library
# and wrap it as an XCFramework that SwiftPM can consume as a binary target.
#
# Vendoring the 36 static libraries individually would put 36 link-order
# constraints into Package.swift; merging them once here keeps that knowledge in
# the place that already understands the C++ build.
#
# Requires a configured bergamot build tree (see BERGAMOT_BUILD below). Rerun
# after changing murmur_mt.cpp or updating the engine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BERGAMOT_SRC="${BERGAMOT_SRC:-/Volumes/DATA/bergamot-arm64/src}"
# Must be a tree configured with -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0. Setting
# the minimum only on the shim below is not enough: the merged archives keep
# whatever target their own build used, and objects built for a newer macOS
# than the package declares may fail to load on the oldest supported OS.
BERGAMOT_BUILD="${BERGAMOT_BUILD:-/Volumes/DATA/bergamot-arm64/build15}"
OUT="${OUT:-$HERE/../../Vendor}"

if [[ ! -f "$BERGAMOT_BUILD/src/translator/libbergamot-translator.a" ]]; then
  echo "no bergamot build at $BERGAMOT_BUILD" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> compiling the C shim"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 -c \
  "$HERE/murmur_mt.cpp" -o "$work/murmur_mt.o" \
  -DARM -DBLAS_FOUND=1 -DCOMPILE_CPU=1 -DCPUINFO_SUPPORTED_PLATFORM=1 \
  -DFMA -DNDEBUG -DSSE -DUSE_PTHREADS -DUSE_SENTENCEPIECE \
  -D_USE_INTERNAL_STRING_VIEW \
  -I"$HERE" \
  -I"$BERGAMOT_SRC" \
  -I"$BERGAMOT_SRC/src" \
  -I"$BERGAMOT_SRC/3rd_party/marian-dev/src" \
  -I"$BERGAMOT_SRC/3rd_party/marian-dev/src/3rd_party" \
  -I"$BERGAMOT_SRC/3rd_party/marian-dev/src/3rd_party/spdlog/include" \
  -I"$BERGAMOT_SRC/3rd_party/marian-dev/src/3rd_party/sentencepiece" \
  -I"$BERGAMOT_SRC/3rd_party/ssplit-cpp/src/ssplit" \
  -I"$BERGAMOT_SRC/3rd_party/ssplit-cpp/src/3rd-party/CLI11" \
  -I"$BERGAMOT_BUILD/3rd_party/marian-dev/src/3rd_party" \
  -I"$BERGAMOT_BUILD/local/include" \
  -I/opt/homebrew/include

echo "==> merging $(find "$BERGAMOT_BUILD" -name '*.a' | wc -l | tr -d ' ') archives + shim"
# libtool warns loudly about duplicate member names across archives; they are
# separate translation units with the same basename, which is harmless.
#
# sentencepiece_train is included even though nothing here trains anything:
# marian's SentencePieceVocab::create references the trainer, so dropping the
# archive leaves an undefined symbol at link time.
libtool -static -o "$work/libmurmurmt.a" \
  "$work/murmur_mt.o" \
  $(find "$BERGAMOT_BUILD" -name '*.a') \
  2>/dev/null

mkdir -p "$work/Headers"
# The module map ships alongside the header: without it the XCFramework is a
# header search path, not something Swift can `import`.
cp "$HERE/include/murmur_mt.h" "$HERE/include/module.modulemap" "$work/Headers/"

echo "==> packaging the XCFramework"
rm -rf "$OUT/MurmurMT.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library "$work/libmurmurmt.a" -headers "$work/Headers" \
  -output "$OUT/MurmurMT.xcframework" >/dev/null

echo "==> $(du -sh "$OUT/MurmurMT.xcframework" | cut -f1)  $OUT/MurmurMT.xcframework"
