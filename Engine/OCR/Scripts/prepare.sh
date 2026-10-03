#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
artifacts="$root/Artifacts"
work="$root/Scripts/.dependencies"
mkdir -p "$artifacts" "$work"
if [[ ! -d "$artifacts/opencv2.xcframework" ]]; then
  curl -fL 'https://github.com/nihui/opencv-mobile/releases/download/v35/opencv-mobile-4.13.0-ios.zip' -o "$work/device.zip"
  curl -fL 'https://github.com/nihui/opencv-mobile/releases/download/v35/opencv-mobile-4.13.0-ios-simulator.zip' -o "$work/simulator.zip"
  [[ "$(shasum -a 256 "$work/device.zip" | cut -d ' ' -f1)" == b16cf8ec2f3de04dcd24f426c85cea6ae120c91b36f961a45984fe7ccdb05ee1 ]]
  [[ "$(shasum -a 256 "$work/simulator.zip" | cut -d ' ' -f1)" == cceaed5a83cfff8d4dbe5952d99ec4e0586af6e092c8fadf7d6c9b1d9fff003f ]]
  unzip -qo "$work/device.zip" -d "$work/device"
  unzip -qo "$work/simulator.zip" -d "$work/simulator"
  # Upstream static frameworks use macOS-style versioned folders; iOS requires a shallow bundle.
  for platform in device simulator; do
    mkdir -p "$work/flat-$platform/opencv2.framework"
    cp -RL "$work/$platform/opencv2.framework/Headers" "$work/flat-$platform/opencv2.framework/"
    cp "$work/$platform/opencv2.framework/opencv2" "$work/flat-$platform/opencv2.framework/"
    cp "$work/$platform/opencv2.framework/Resources/Info.plist" "$work/flat-$platform/opencv2.framework/Info.plist"
    plutil -insert CFBundleExecutable -string opencv2 "$work/flat-$platform/opencv2.framework/Info.plist"
  done
  xcodebuild -create-xcframework -framework "$work/flat-device/opencv2.framework" -framework "$work/flat-simulator/opencv2.framework" -output "$artifacts/opencv2.xcframework"
fi
# The upstream static framework omits this field. Xcode exports a framework
# stub, and App Store Connect requires a deployment target on that bundle too.
for plist in "$artifacts"/opencv2.xcframework/*/opencv2.framework/Info.plist; do
  /usr/libexec/PlistBuddy -c 'Set :MinimumOSVersion 18.0' "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c 'Add :MinimumOSVersion string 18.0' "$plist"
done
if [[ ! -d "$artifacts/onnxruntime_objc.xcframework" || ! -d "$artifacts/onnxruntime.xcframework" ]]; then
  cd "$work"
  ruby -e 'require "xcodeproj";p=Xcodeproj::Project.new("OCRDependencies.xcodeproj");p.new_target(:framework,"OCRDependencies",:ios,"18.0");p.save'
  cat > Podfile <<'POD'
platform :ios, '18.0'
use_frameworks! :linkage => :static
target 'OCRDependencies' do
 pod 'onnxruntime-objc', '1.30.0'
end
POD
  pod install
  for sdk in iphoneos iphonesimulator; do
    xcodebuild -project Pods/Pods.xcodeproj -scheme onnxruntime-objc -configuration Release -sdk "$sdk" -derivedDataPath "build-$sdk" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=18.0 build
  done
  if [[ ! -d "$artifacts/onnxruntime_objc.xcframework" ]]; then
    xcodebuild -create-xcframework -framework "$work/build-iphoneos/Build/Products/Release-iphoneos/onnxruntime-objc/onnxruntime_objc.framework" -framework "$work/build-iphonesimulator/Build/Products/Release-iphonesimulator/onnxruntime-objc/onnxruntime_objc.framework" -output "$artifacts/onnxruntime_objc.xcframework"
  fi
  if [[ ! -d "$artifacts/onnxruntime.xcframework" ]]; then cp -R Pods/onnxruntime-c/onnxruntime.xcframework "$artifacts/"; fi
  cd "$root"
fi
# Xcode embeds a generated iOS 18.0 dylib stub for this static framework.
# Its upstream plist says 15.1; that mismatch is rejected as ITMS-90208 even
# though the application's own deployment target is 18.0.
for plist in "$artifacts"/onnxruntime.xcframework/*/onnxruntime.framework/Info.plist; do
  /usr/libexec/PlistBuddy -c 'Set :MinimumOSVersion 18.0' "$plist"
done
if [[ ! -f Sources/MurmurOCR/Resources/dictionaries.json || ! -f Sources/MurmurOCR/Resources/detector-portrait.onnx ]]; then
  uv run --python 3.12 --with onnx==1.22.0 --with onnxruntime==1.30.0 --with onnxconverter-common==1.16.0 Scripts/prepare_models.py
fi
