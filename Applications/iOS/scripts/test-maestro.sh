#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v maestro >/dev/null
if [[ -z "${MURMUR_SIMULATOR_ID:-}" ]]; then
    MURMUR_SIMULATOR_ID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; print(next((d["udid"] for group in json.load(sys.stdin)["devices"].values() for d in group if d["name"] == "MurMur Maestro"), ""))')"
fi
if [[ -z "$MURMUR_SIMULATOR_ID" ]]; then
    MURMUR_SIMULATOR_ID="$(xcrun simctl create 'MurMur Maestro' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
fi
if [[ "${MURMUR_SKIP_BUILD:-0}" != 1 ]]; then
    tuist generate --no-open
    xcodebuild -workspace MurMurMobile.xcworkspace -scheme MurMurUITestHost -configuration Debug \
      -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ui CODE_SIGNING_ALLOWED=NO build > /tmp/murmur-maestro-host-build.log 2>&1
fi
xcrun simctl boot "$MURMUR_SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$MURMUR_SIMULATOR_ID" -b
xcrun simctl install "$MURMUR_SIMULATOR_ID" build-ui/Build/Products/Debug-iphonesimulator/MurMurUITestHost.app
export MAESTRO_DRIVER_STARTUP_TIMEOUT=240000
mkdir -p results/maestro
if [[ $# == 0 ]]; then set -- .maestro/flows; fi
maestro test --device "$MURMUR_SIMULATOR_ID" --format HTML --output results/maestro/report.html \
  --test-output-dir results/maestro --no-ansi "$@"
