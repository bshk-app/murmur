#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
tuist generate --no-open
xcodebuild -resolvePackageDependencies -workspace MurMurMobile.xcworkspace -scheme MurMurMobile -derivedDataPath build
mkdir -p build
cp MurMurMobile.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved
xcodebuild -workspace MurMurMobile.xcworkspace -scheme MurMurMobile -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -skipPackagePluginValidation "$@" build
