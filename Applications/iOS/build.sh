#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../Tuist
if [[ "${MURMUR_QUALIFICATION_BUILD:-0}" == "1" ]]; then
  node ../../Engine/Speech/Qualification/capture-build-source.mjs
fi
tuist generate --no-open
mkdir -p MurMurMobile.xcworkspace/xcshareddata/swiftpm
cp Package.resolved MurMurMobile.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -resolvePackageDependencies -workspace MurMurMobile.xcworkspace -scheme MurMurMobile -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile
mkdir -p build
cp MurMurMobile.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved
xcodebuild -workspace MurMurMobile.xcworkspace -scheme MurMurMobile -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile "$@" build
