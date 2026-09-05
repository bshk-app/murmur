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
# CTranslate2 is the quality engine for the final paste. It must be configured
# with the same -DCMAKE_OSX_DEPLOYMENT_TARGET as bergamot, and with
# -DWITH_ACCELERATE=ON -DWITH_RUY=ON -DOPENMP_RUNTIME=NONE so it stays on the
# CPU and brings no runtime the app does not already have.
CT2_BUILD="${CT2_BUILD:-/Volumes/DATA/ctranslate2-arm64/build}"
CT2_SRC="${CT2_SRC:-/Volumes/DATA/ctranslate2-arm64}"
OUT="${OUT:-$HERE/../../Vendor}"

if [[ ! -f "$BERGAMOT_BUILD/src/translator/libbergamot-translator.a" ]]; then
  echo "no bergamot build at $BERGAMOT_BUILD" >&2
  exit 1
fi

if [[ ! -f "$CT2_BUILD/libctranslate2.a" ]]; then
  echo "no CTranslate2 build at $CT2_BUILD" >&2
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

# CTranslate2 does no tokenisation of its own, and this shim deliberately does
# not vendor a second SentencePiece: it compiles against marian's headers and
# resolves against marian's copy already inside the merged archive. Two copies
# would be a duplicate-symbol conflict at link time.
echo "==> compiling the CTranslate2 shim"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 -w -c \
  "$HERE/murmur_ct2.cpp" -o "$work/murmur_ct2.o" \
  -DARM -DBLAS_FOUND=1 -DCOMPILE_CPU=1 -DNDEBUG -DUSE_SENTENCEPIECE \
  -D_USE_INTERNAL_STRING_VIEW \
  -I"$HERE/include" \
  -I"$CT2_SRC/include" \
  -I"$BERGAMOT_SRC/3rd_party/marian-dev/src/3rd_party/sentencepiece/src" \
  -I"$BERGAMOT_SRC/3rd_party/marian-dev/src/3rd_party/sentencepiece"

# CTranslate2 and marian each vendor their own spdlog. Merged into one archive
# they collide, and which copy wins is decided by link order - not something
# this package controls. The symptom is not a link error: it is
# ctranslate2::init_logger() reaching marian's differently-built registry and
# taking SIGBUS at runtime. It reproduces in some link orders and not others,
# so it reads as a flaky test rather than as the ODR violation it is.
#
# CTranslate2 is therefore partially linked into one object first, with every
# symbol except this shim's four entry points made local. Its spdlog then
# cannot be reached from outside that object and marian's stays the only global
# copy. SentencePiece is deliberately not bundled in: those references stay
# undefined and resolve against marian's copy, which is the whole reason the
# shim compiles against marian's headers.
echo "==> privatising the CTranslate2 half"
cat > "$work/ct2-exports.txt" <<'EXPORTS'
_murmur_ct2_open
_murmur_ct2_translate
_murmur_ct2_close
_murmur_ct2_string_free
EXPORTS
ld -r -arch arm64 -all_load \
  -exported_symbols_list "$work/ct2-exports.txt" \
  -o "$work/ct2_all.o" \
  "$work/murmur_ct2.o" \
  "$CT2_BUILD/libctranslate2.a" \
  $(find "$CT2_BUILD/third_party" -name '*.a')

# A surviving global spdlog symbol means the privatisation did not take, and
# the crash would return at runtime instead of here.
leaked=$(nm -gU "$work/ct2_all.o" | grep -c spdlog || true)
if [[ "$leaked" -ne 0 ]]; then
  echo "CTranslate2 still exports $leaked spdlog symbols; they would collide" >&2
  exit 1
fi

echo "==> merging $(find "$BERGAMOT_BUILD" -name '*.a' | wc -l | tr -d ' ') archives + CTranslate2 + shims"
# libtool warns loudly about duplicate member names across archives; they are
# separate translation units with the same basename, which is harmless.
#
# sentencepiece_train is included even though nothing here trains anything:
# marian's SentencePieceVocab::create references the trainer, so dropping the
# archive leaves an undefined symbol at link time.
libtool -static -o "$work/libmurmurmt.a" \
  "$work/murmur_mt.o" \
  "$work/ct2_all.o" \
  $(find "$BERGAMOT_BUILD" -name '*.a') \
  2>/dev/null

mkdir -p "$work/Headers"
# The module map ships alongside the header: without it the XCFramework is a
# header search path, not something Swift can `import`.
cp "$HERE/include/murmur_mt.h" "$HERE/include/murmur_ct2.h" \
   "$HERE/include/module.modulemap" "$work/Headers/"

echo "==> packaging the XCFramework"
rm -rf "$OUT/MurmurMT.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library "$work/libmurmurmt.a" -headers "$work/Headers" \
  -output "$OUT/MurmurMT.xcframework" >/dev/null

echo "==> $(du -sh "$OUT/MurmurMT.xcframework" | cut -f1)  $OUT/MurmurMT.xcframework"
