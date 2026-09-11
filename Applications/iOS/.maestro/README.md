# MurMur UI tests

Run from the repository root:

```sh
bash Applications/iOS/scripts/test-maestro.sh
```

The runner generates the workspace, builds `MurMurUITestHost`, boots a dedicated **MurMur Maestro** iPhone 17 Pro simulator, installs the host, and runs the flows. Maestro 2.10.0 and the iOS 26.5 simulator runtime were used. Override the device with `MURMUR_SIMULATOR_ID`; reuse a built host with `MURMUR_SKIP_BUILD=1`.

```sh
MURMUR_SKIP_BUILD=1 bash Applications/iOS/scripts/test-maestro.sh .maestro/flows/03_add_languages.yaml
```

Results: `Applications/iOS/results/maestro/report.html`, with per-run screenshots, logs and command records nearby. This generated directory is ignored by Git.

## Coverage

- Skip onboarding without microphone permission or models.
- Complete all five steps without preparation.
- Add a speech language and a translation pair; leave after a preparation error.
- Russian localization of onboarding and notes.

All four flows passed on 2026-09-06. Captures for a designer live in `.maestro/capture/` and are run explicitly, separately from the acceptance suite.

## What is tested

The host compiles the **same SwiftUI view files** as the production app, plus the real `LanguageLibrary`, localization resources, and note format. It has a separate bundle ID and a small test adapter without inference dependencies. Download/record actions report that inference requires a physical device; the host never simulates successful model preparation. The optional `uiFixture` launch argument provides synthetic notes for screenshots in this host only.

This checks navigation, optional onboarding, language selection, errors and localization. It does not check ASR, ANE/GPU concurrency, model files, physical microphone behavior, or extension execution. Those require the main application on an iPhone and the device tests. The previous device onboarding test successfully downloaded and warmed speech models; the current device UI test checks the updated optional flow and stable mascot bounds.

The production translation archive currently has macOS-arm64 and iOS-arm64 slices, without an iOS Simulator slice. The UI host avoids rebuilding or faking those native inference libraries.

## simslim

Installed version: 0.8.0. It optimizes simulator background services; it is not a replacement for Maestro or device ASR tests.

Only the dedicated MurMur Maestro simulator was changed. The tested profile preserves **widgets, Siri/speech, and iCloud**:

```sh
simslim on "$MURMUR_SIMULATOR_ID" --except widgets,siri,icloud
simslim verify "$MURMUR_SIMULATOR_ID" --except widgets,siri,icloud
simslim doctor "$MURMUR_SIMULATOR_ID" --requires widgets,siri,icloud
simslim measure "$MURMUR_SIMULATOR_ID" --json
# Restore this simulator to its stock services:
simslim off "$MURMUR_SIMULATOR_ID"
```

The normal runner does not change simulator service profiles. Do not apply the tool's full default profile to widget/Live Activity tests: it disables those services. Measurements are summed simulator process footprints, not the MurMur app's inference memory.

Upstream references: https://docs.maestro.dev/getting-started/build-and-install-your-app/ios and https://github.com/MobAI-App/simslim.

Observed simulator totals (not a controlled benchmark): stock after the acceptance suite, 277 processes / 4.68 GB; slim after the same four flows, 160 processes / 2.94 GB. The idle pre-test slim snapshot was 1.70 GB. All four acceptance flows passed again with the selected slim profile. Simulator footprint includes system/test processes and must not be reported as mobile ASR memory.

## Sharing and correction presentation

The suite now has seven flows. Added checks cover a single Share action, language preparation from Settings without engine names, and a controlled draft-to-correction transition using the real `CorrectionDisplay` and SwiftUI renderer. The `correctionFixture` input is limited to the simulator host; it is not ASR output and is never enabled in the production app. Seven flows passed on 2026-09-06. Core word-diff tests also cover stale callbacks, whitespace, repeated words, Unicode, deletion and preservation of the final highlight.

## Design v2

The acceptance suite now has eight flows, including editing and saving note text. All eight passed on 2026-09-06 (run 2026-09-06_180845, 4m 33s). Language sheets are exercised from the ordinary onboarding navigation route; the screens are no longer nested under a fullscreen presentation. Capture-only dark Russian review: `.maestro/capture/v2-dark-ru.yaml`. Current review images: `design-handoff/ios/implemented-v2/`.

## Navigation and modal confirmation (2026-09-08)

Flow 17 verifies native edge-back navigation for settings, languages, note details and onboarding. Flow 18 verifies modal cancellation and deletion from the note-detail menu. The shared cancellation partial requires a visible Cancel button and rejects `PopoverDismissRegion`. Native navigation replaces custom back identifiers in the existing edit/storage tests.
