# Murmator for iOS

Separate app (`app.bshk.murmur.ios`), built from the supplied MurMur iOS design. Murmur Lab remains a separate application and keeps its existing data.

The native SwiftUI interface provides onboarding, notes/search, recording, text and voice translation, note editing/copy/system sharing, language preparation, and light/dark appearance. Notes persist locally with atomic writes; a recovery draft preserves captured text on interruption. The keyboard offers hold-to-talk, language and translation selection, deletion and Send/Return. Its microphone and single Core ML recognizer run in the containing app, with local App Group commands. See Keyboard/README.md. Home Screen widgets provide dictation, translation, unloading and settings actions; the medium size also offers keyboard and language management. Actions open the containing app. The medium widget labels its last model-status snapshot with an update time. A Lock Screen widget and App Shortcut open the app for recording. Live Activities display recording status without transcript text.

Speech and translation use `../../Engine` packages. No example transcript or simulated model progress ships in Release. The UI test fixture exists only under `DEBUG` with `--ui-testing`.

## Build

Requires Xcode, Tuist, Apple Silicon and iOS 18+. The current native translation binary supports physical arm64 devices, not the simulator.

```sh
bash Applications/iOS/build.sh -allowProvisioningUpdates
# Compilation without signing:
bash Applications/iOS/build.sh CODE_SIGNING_ALLOWED=NO
```

For device installation, Xcode must have the development account for team `Q8H6GWJ658`. Provision the app and its `.widgets` / `.keyboard` extensions with App Group `group.app.bshk.murmur.ios.shared`; the app also requests Increased Memory Limit. Wildcard provisioning profiles do not cover these entitlements.

## Models

Basic speech models download on preparation. Advanced model folders can be selected in Settings → Import model folder: `ASRModels`, `CoreMLModels`, `TranslationModels`, or a parent containing these folders. They are stored under Application Support/MurMur/Models. Existing files are preserved by import. Do not select arbitrary partial checkpoints; use the tested exported model folders and retain their provenance.

The design's example download sizes and automatic Apple Notes delivery are not presented as real behavior. Apple Notes export uses the system share sheet. Keyboard dictation now uses an explicitly enabled background microphone session in the containing app. The extension itself never captures audio; the old saved-note insertion button has been removed.

## Validation remaining

Unsigned compilation does not validate signing, device installation, extension sharing, UI rendering, or real ASR. Run `MurMurMobileUITests` on an unlocked physical device after provisioning, then replay the existing FLEURS fixtures through the extracted speech package. This is a separate product app under development, not an App Store release claim.

## Verified 2026-09-06

Release builds with signing disabled passed for both MurMurMobile (including keyboard and widget extensions) and MurmurPhone after extraction. Core: 47 tests passed. The existing MurmurKit regression run executed 191 tests with 6 skips and no failures; checkpoint-loading and detector warmup tests were excluded from the command-line run. The initial command-line signing failure was resolved after Xcode generated explicit profiles for the app and extensions. A signed Release build was installed and launched on the iPhone. Device UI and model checks for the revised onboarding are tracked separately below.

## Onboarding and languages

The five setup stages cover welcome, microphone, language packs, warmup, and keyboard/Action Button help. Preparation and microphone access are optional during setup: Continue and Skip remain available. Language packs can be added from onboarding or Settings → Languages & offline. Speech languages and translation directions have separate download/warm actions. A completed translation pack includes Mozilla preview and strict OPUS warmup. Only downloadable or installed OPUS routes are offered. Preparation status remains visible on Notes after leaving setup.

UI localization covers English, Russian, German, Spanish, French and Finnish. See `Localization/README.md`. The design handoff in `../../design-handoff/ios` records missing screens and current visual deviations from the original user design; current screenshots are not a claim of final visual fidelity.

Maestro setup and coverage are documented in `.maestro/README.md`. Four flows passed against the same SwiftUI screens in a separate simulator host. Inference is validated separately on a physical iPhone.

## Finnish OPUS and memory controls (2026-09-07)

The production download registry includes verified OPUS INT8 packs for RU↔FI and EN↔FI in addition to RU↔EN. Preparation selects a published direct quality route before downloading its fast previews. Unsupported quality directions fail before a preview download. Provenance is published beside each model in the existing Hugging Face mirror. The files are downloadable packs, not an extra gigabyte in the application bundle.

Settings → Memory unloads models without removing downloaded packs or notes. It is disabled during recording and preparation. Widgets route this action to the main process and preserve active work. See results/model-controls/README.md for device checks and UI-test limitations.

## Full EU translation catalog (2026-09-07)

All 24 official EU languages plus Russian and Ukrainian now have strict OPUS translation routes. The mirror contains 52 direction packs; routes without a direct model pivot through English. The app downloads only selected packs. Translation availability is independent of the smaller Mozilla preview catalog; OPUS also supplies previews when Mozilla does not cover the selected pair.

The translation target menus and offline-pack source/target menus use this full catalog. The speech menu follows the recognizer’s actual language support: Maltese is included; Irish translation is available in both directions, but Irish speech recognition is not advertised. Background keyboard preview and final translation share the prepared TranslationSession engines.

See ../../Engine/Translation/Catalog/README.md for upstream model selection, per-file pins, native test outputs and mirror verification. The previous keyboard activation UX investigation remains separate.

## Import recorded audio

From Voice Memos or Files, use Share → MurMur, or use Import audio in the Notes toolbar. Select the spoken language and start transcription. The app uses the accurate recognizer directly, splitting the recording with CPU VAD and a 12–20 second safety cap. It streams decoding instead of loading an hour of PCM into memory.

Keep MurMur open while processing. Pause or backgrounding preserves completed fragments and the private source for continuation. Partial notes are labeled; the finished transcript becomes a normal note. Originals are unchanged. Imported copies remain only while needed for the job and are removed after completion or explicit removal of the import. See results/audio-import/README.md for checks and limitations.

## Text translator and current name

The app display name is Murmator as of build 6. Translate → Text supports typing/pasting, language swapping, on-device translation, copying and sharing, with a visible 10,000-character limit. Translate → Voice retains the live speech workflow. Existing language packs are reused; missing quality packs download on demand. Typed text is held for the app session and is not automatically saved as a note. See results/text-translator/README.md for native, device and UI verification.

## Storage management (build 7)

Settings → Storage and Memory → Manage storage show measured downloaded model files, including translation directions, speech SDK caches and imported speech packages. The app removes only the selected package after confirmation and after closing idle model owners; deletion is disabled while recording, translating, importing or finishing preparation. Shared speech cache locations are grouped together. Readiness markers and affected language preparation flags are invalidated so a later preparation can restore downloads. Imported Core ML packs may require the original model folder. Notes, recordings and chosen language entries are retained.

The total describes file sizes, not a guarantee of reclaimed APFS blocks. Global device free-space data is displayed locally and is not exported by the diagnostic. Removing a language from its list remains a separate preference action.

## List actions (build 8)

Notes, audio imports, selected languages, language catalogs, downloaded model files and the onboarding language summary use native iOS lists. Swipe a row to reveal its actions, or hold it for the context menu. VoiceOver exposes the same actions. Full swipes do not execute actions automatically.

Notes support opening, editing, copying, sharing and confirmed deletion. Imports expose pause, continuation/queueing, open transcript and confirmed removal according to their state. Languages expose preparation and removal from the list; catalogs expose add/remove selection. Storage actions share the existing confirmation and busy guards. Removing a language entry does not delete downloaded weights. A note that can still be updated by an import cannot be edited or deleted until the import is finished or removed.

UI validation runs in the separate simulator host with fixture notes and imports; storage checks use tiny test files. It does not run inference or touch the phone’s existing recordings or model downloads. See results/list-actions/README.md for results.

## Updated design, navigation and confirmations (build 9)

The September 8 design adds a pinned text-translation action, compact source/result cards, progress explanations, explicit cancellation, temporary copy feedback and an inline character-limit error. Memory distinguishes files on disk from loaded models and explains the shared text/refined-voice packs. Audio imports have a compact ongoing status and an explicit empty state.

Pushed screens use the system navigation bar and back gesture in one navigation stack. Destructive actions in note rows, note details, imports and model storage use modal alerts with Cancel. Existing swipe and context-menu actions are retained. See results/design-2026-09-08/README.md for validation and captures.

## System selected-text translation (build 11)

On iOS 18.4+, Settings → Default translation app opens the system Default Apps settings, where Murmator can be selected. The app now embeds its own TranslationUIProvider. It receives the selected text reactively, detects supported source languages, uses downloaded quality models, and offers copy, share and replacement when the source supports editing. Open the containing app once after an update to prepare its shared store.

The extension uses a dedicated language-pack App Group, without access to the notes/keyboard group. Existing translation packs move into this store; conflicting legacy copies are preserved and remain visible in Storage. Cross-process file locks protect download, import and deletion. The native extension memory mode maps INT8 weights read-only and bounds temporary buffers without changing weights or decoding parameters. See results/system-translation-2026-09-08/README.md for the device/kernel evidence, memory comparison and end-to-end replacement test.
