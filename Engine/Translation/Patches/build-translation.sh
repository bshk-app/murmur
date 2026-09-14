#!/bin/bash
set -euo pipefail
PATCHES="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$PATCHES/../../.." && pwd)"
# The cached CMake trees run to tens of gigabytes, so the build area stays outside the repository.
ROOT="${MURMUR_TRANSLATION_BUILD:-$REPO/Prototypes/iOS}"
BERG_SOURCE="${BERG_SOURCE:-/Volumes/DATA/bergamot-arm64/src}"
CT2_SOURCE="${CT2_SOURCE:-/Volumes/DATA/ctranslate2-arm64}"
SHIM="$REPO/MurmurKit/Sources/CBergamot"
mkdir -p "$ROOT/build"
cd "$ROOT"
ROOT="$PWD"  # Absolute, so an override given as a relative path still resolves once cwd moves.
CT2_PATCH="$PATCHES/ct2-mapped-weights.patch"
CT2_PATCH_HASH="$(shasum -a 256 "$CT2_PATCH" | cut -c 1-12)"
CT2_PATCHED="$ROOT/build/ct2-mapped-$CT2_PATCH_HASH"
if [[ ! -f "$CT2_PATCHED/.murmur-source-ready" ]]; then
    mkdir -p "$CT2_PATCHED"
    rsync -a --exclude='/.git/' --exclude='/build/' --exclude='/build-*/' --exclude='/.venv/' --exclude='/.env' "$CT2_SOURCE/" "$CT2_PATCHED/"
    (
        cd "$CT2_PATCHED"
        patch --batch -p1 < "$CT2_PATCH"
    )
    touch "$CT2_PATCHED/.murmur-source-ready"
fi
CT2_SOURCE="$CT2_PATCHED"
# Patch an isolated copy, preserving the desktop source/build trees.
if [[ ! -d build/bergamot-source ]]; then cp -cR "$BERG_SOURCE" build/bergamot-source; fi
ARCH_FILE="$ROOT/build/bergamot-source/3rd_party/marian-dev/cmake/TargetArch.cmake"
if ! rg -q 'CMAKE_SYSTEM_NAME STREQUAL "iOS"' "$ARCH_FILE"; then
    patch "$ARCH_FILE" < "$PATCHES/target-arch-ios.patch"
fi
COMMON=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DIOS=ON -DIOS_ARCH=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_MACOSX_BUNDLE=OFF -DBUILD_SHARED_LIBS=OFF)
if [[ ! -d build/pcre2-source ]]; then
    git clone --depth 1 --branch pcre2-10.48 https://github.com/PCRE2Project/pcre2.git build/pcre2-source
fi
cmake -S build/pcre2-source -B build/pcre2-ios "${COMMON[@]}" \
    -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=OFF
cmake --build build/pcre2-ios -j 6
cmake -S "$CT2_SOURCE" -B build/ct2-ios "${COMMON[@]}" \
    -DBUILD_CLI=OFF -DBUILD_TESTS=OFF -DWITH_ACCELERATE=ON -DWITH_RUY=ON \
    -DWITH_MKL=OFF -DWITH_CUDA=OFF -DOPENMP_RUNTIME=NONE -DCPUINFO_BUILD_TOOLS=OFF
cmake --build build/ct2-ios -j 6
cmake -S build/bergamot-source -B build/bergamot-device "${COMMON[@]}" \
    -DCOMPILE_CPU=ON -DCOMPILE_CUDA=OFF -DCOMPILE_TESTS=OFF -DCOMPILE_EXAMPLES=OFF \
    -DCOMPILE_LIBRARY_ONLY=ON -DUSE_APPLE_ACCELERATE=ON -DUSE_RUY=ON \
    -DUSE_INTGEMM=OFF -DUSE_FBGEMM=OFF -DUSE_MKL=OFF -DUSE_SENTENCEPIECE=ON \
    -DUSE_STATIC_LIBS=ON -DUSE_DOXYGEN=OFF -DCPUINFO_BUILD_TOOLS=OFF \
    -DSSPLIT_COMPILE_LIBRARY_ONLY=ON -DPCRE2_FOUND=TRUE \
    -DPCRE2_INCLUDE_DIRS="$ROOT/build/pcre2-ios/interface" \
    -DPCRE2_LIBRARIES="$ROOT/build/pcre2-ios/libpcre2-8.a" \
    -DBUILD_ARCH=armv8-a -DCMAKE_C_FLAGS=-Wno-error -DCMAKE_CXX_FLAGS=-Wno-error
cmake --build build/bergamot-device --target bergamot-translator -j 6

WORK="$(mktemp -d "$ROOT/build/mt-assembly.XXXXXX")"
BERG="$ROOT/build/bergamot-source"
BERG_BUILD="$ROOT/build/bergamot-device"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
FLAGS=(-std=c++17 -O2 -target arm64-apple-ios18.0 -isysroot "$SDK" -w)
xcrun --sdk iphoneos clang++ "${FLAGS[@]}" -c "$SHIM/murmur_mt.cpp" -o "$WORK/murmur_mt.o" \
    -DARM -DBLAS_FOUND=1 -DCOMPILE_CPU=1 -DCPUINFO_SUPPORTED_PLATFORM=1 \
    -DFMA -DNDEBUG -DSSE -DUSE_PTHREADS -DUSE_SENTENCEPIECE -D_USE_INTERNAL_STRING_VIEW \
    -I"$SHIM" -I"$BERG" -I"$BERG/src" -I"$BERG/3rd_party/marian-dev/src" \
    -I"$BERG/3rd_party/marian-dev/src/3rd_party" \
    -I"$BERG/3rd_party/marian-dev/src/3rd_party/spdlog/include" \
    -I"$BERG/3rd_party/marian-dev/src/3rd_party/sentencepiece" \
    -I"$BERG/3rd_party/ssplit-cpp/src/ssplit" -I"$BERG/3rd_party/ssplit-cpp/src/3rd-party/CLI11" \
    -I"$BERG_BUILD/3rd_party/marian-dev/src/3rd_party" -I"$ROOT/build/pcre2-ios/interface"
xcrun --sdk iphoneos clang++ "${FLAGS[@]}" -c "$SHIM/murmur_ct2.cpp" -o "$WORK/murmur_ct2.o" \
    -DARM -DBLAS_FOUND=1 -DCOMPILE_CPU=1 -DNDEBUG -DUSE_SENTENCEPIECE -D_USE_INTERNAL_STRING_VIEW \
    -I"$SHIM/include" -I"$CT2_SOURCE/include" \
    -I"$BERG/3rd_party/marian-dev/src/3rd_party/sentencepiece/src" \
    -I"$BERG/3rd_party/marian-dev/src/3rd_party/sentencepiece"
cat > "$WORK/exports.txt" <<'EXPORTS'
_murmur_ct2_open
_murmur_ct2_translate
_murmur_ct2_close
_murmur_ct2_string_free
EXPORTS
CT2_LIBS=()
while IFS= read -r file; do CT2_LIBS+=("$file"); done < <(rg --files --no-ignore build/ct2-ios/third_party -g '*.a')
xcrun ld -r -arch arm64 -platform_version ios 18.0 26.5 -all_load \
    -exported_symbols_list "$WORK/exports.txt" -o "$WORK/ct2_all.o" \
    "$WORK/murmur_ct2.o" build/ct2-ios/libctranslate2.a "${CT2_LIBS[@]}"
if nm -gU "$WORK/ct2_all.o" | rg spdlog; then echo 'CTranslate2 spdlog symbols leaked' >&2; exit 1; fi
BERG_LIBS=()
while IFS= read -r file; do BERG_LIBS+=("$file"); done < <(rg --files --no-ignore "$BERG_BUILD" -g '*.a')
xcrun libtool -static -o "$WORK/libmurmurmt.a" "$WORK/murmur_mt.o" "$WORK/ct2_all.o" \
    "${BERG_LIBS[@]}" build/pcre2-ios/libpcre2-8.a
mkdir -p "$WORK/Headers"
cp "$SHIM/include/murmur_mt.h" "$SHIM/include/murmur_ct2.h" "$SHIM/include/module.modulemap" "$WORK/Headers/"
xcodebuild -create-xcframework -library "$WORK/libmurmurmt.a" -headers "$WORK/Headers" \
    -output "$WORK/MurmurMT.xcframework"
ditto "$WORK/MurmurMT.xcframework" build/MurmurMT.xcframework
ditto build/MurmurMT.xcframework/ios-arm64 "$REPO/Engine/Translation/Artifacts/MurmurMT.xcframework/ios-arm64"
